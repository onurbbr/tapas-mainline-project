#!/usr/bin/env bash
#
# scripts/build-image.sh — Builds a Debian image for Redmi Note 12 4G.
#
# Assumes debs/ is already populated (run build.sh debs first).
# ROOT_DIR is passed via env when invoked from build.sh.
#
# The account created in the image defaults to user:0000. Set TAPAS_USER and
# TAPAS_PASSWORD to change it; build.sh forwards both.
#
# Can also be run standalone (requires root):
#   cd ~/package && sudo bash scripts/build-image.sh
#
# After flashing:
#   fastboot flash userdata debian-sparse.img
#
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"

IMG="$ROOT_DIR/debian.img"
IMG_SPARSE="$ROOT_DIR/debian-sparse.img"
MNT="$ROOT_DIR/mnt"
DEBS="$ROOT_DIR/debs"
SUITE=sid
MIRROR=https://deb.debian.org/debian
SIZE_MB=8192

log() { printf '\n==> [build-image] %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# Account created inside the image. These come from build.sh, or from the
# environment when this script is run on its own.
TAPAS_USER="${TAPAS_USER:-user}"
TAPAS_PASSWORD="${TAPAS_PASSWORD:-0000}"

# The name is handed to useradd and the password to chpasswd, which splits its
# input on the first ':'; reject what those tools cannot take before spending
# ten minutes on debootstrap.
printf '%s' "$TAPAS_USER" | LC_ALL=C grep -qxE '[a-z_][a-z0-9_.-]{0,31}' \
    || die "invalid TAPAS_USER '$TAPAS_USER'"
[ -n "$TAPAS_PASSWORD" ] || die "TAPAS_PASSWORD must not be empty"
case "$TAPAS_PASSWORD" in
    *:*)     die "TAPAS_PASSWORD must not contain ':'" ;;
    *$'\n'*) die "TAPAS_PASSWORD must not contain a newline" ;;
esac

# --- pre-checks ------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "This script requires root. Run: sudo ./build.sh image"

[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] \
    || echo "WARNING: qemu-aarch64 binfmt not registered; second-stage may fail."

# Verify debs/ is populated before doing any work.
for p in device-xiaomi-sm6225 firmware-xiaomi-sm6225 linux-image-sm6225 linux-modules-sm6225; do
    ls "$DEBS"/${p}_*.deb >/dev/null 2>&1 \
        || die "Package $p not found in $DEBS/. Run 'build.sh debs' first."
done

mkdir -p "$MNT"
if mountpoint -q "$MNT"; then
    die "$MNT is still mounted. Run: sudo umount -R $MNT"
fi
if [ -e "$IMG" ] && losetup -j "$IMG" | grep -q .; then
    die "$IMG is attached to a loop device (stale mount). Reboot the host."
fi

# --- 1) image + filesystem -------------------------------------------------
log "Creating image ($IMG, ${SIZE_MB}M)"
rm -f "$IMG"
dd if=/dev/zero of="$IMG" bs=1M count="$SIZE_MB" status=progress
sync
mkfs.ext4 -F "$IMG"

UUID=$(tune2fs -l "$IMG" | awk -F: '/Filesystem UUID/ {gsub(/ /, "", $2); print $2}')
log "Root UUID: $UUID"

# --- 2) debootstrap + second-stage -----------------------------------------
mount -o loop "$IMG" "$MNT"

cleanup_mounts() {
    rm -f "${CRED_FILE:-}"
    umount -R "$MNT/dev"  2>/dev/null || true
    umount -R "$MNT/proc" 2>/dev/null || true
    umount -R "$MNT/sys"  2>/dev/null || true
    umount -R "$MNT/run"  2>/dev/null || true
    umount -R "$MNT"      2>/dev/null || true
}
trap cleanup_mounts EXIT

log "debootstrap --foreign"
debootstrap --foreign --arch=arm64 "$SUITE" "$MNT" "$MIRROR"

mount --rbind /dev  "$MNT/dev"  && mount --make-rslave "$MNT/dev"
mount --rbind /sys  "$MNT/sys"  && mount --make-rslave "$MNT/sys"
mount -t proc proc  "$MNT/proc"
cp -L /etc/resolv.conf "$MNT/etc/resolv.conf"

echo "deb $MIRROR $SUITE main contrib non-free non-free-firmware" \
    | tee "$MNT/etc/apt/sources.list" >/dev/null

# Prevent services from starting during the build.
printf '#!/bin/sh\nexit 101\n' | tee "$MNT/usr/sbin/policy-rc.d" >/dev/null
chmod +x "$MNT/usr/sbin/policy-rc.d"

log "debootstrap --second-stage"
chroot "$MNT" /debootstrap/debootstrap --second-stage

# --- 3) packages -----------------------------------------------------------
log "Refreshing bind mounts after second-stage"
mount --rbind /dev  "$MNT/dev"  && mount --make-rslave "$MNT/dev"
mount --rbind /sys  "$MNT/sys"  && mount --make-rslave "$MNT/sys"
mount -t proc  proc  "$MNT/proc"
mount -t tmpfs tmpfs "$MNT/run"
mkdir -p "$MNT/run/udev" "$MNT/run/dbus"

log "System packages"
chroot "$MNT" bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y initramfs-tools build-essential
apt install -y qrtr-tools rmtfs tqftpserv protection-domain-mapper alsa-ucm-conf qcom-phone-utils zstd sudo
apt install -y udisks2
# alsa-utils for amixer and arecord, and for alsactl in /usr/sbin, which is not
# on the default path; openssh-server so the device is reachable over the
# network after a fresh flash, without a keyboard attached; bash-completion so
# the shell completes command and file names out of the box.
apt install -y alsa-utils openssh-server bash-completion
'

log "Timezone + locale + keyboard (Europe/Istanbul, en_US.UTF-8, us/pc105)"
chroot "$MNT" bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y tzdata locales keyboard-configuration systemd-timesyncd
export DEBIAN_FRONTEND=dialog
dpkg-reconfigure tzdata
dpkg-reconfigure locales
dpkg-reconfigure keyboard-configuration
'

log "Installing Phosh Mobile"
chroot "$MNT" bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive
apt install -y phosh-phone phosh-full phosh-games-
'

# --- 4) fstab ---------------------------------------------------------------
# This has to happen before the kernel packages below.  Their postinst runs
# u-boot-update, which takes the root= argument from /etc/fstab and, finding
# no "/" entry, falls back to /proc/cmdline.  In a chroot that is the build
# host's command line, so the image would boot with the host's root UUID.
log "Writing fstab"
printf '# Debian - single ext4 rootfs\nUUID=%s / ext4 defaults 0 1\n' "$UUID" \
    | tee "$MNT/etc/fstab" >/dev/null

echo debian | tee "$MNT/etc/hostname" >/dev/null

# --- 5) SM6225 packages + initrd --------------------------------------------
log "Installing SM6225 packages (kernel + modules + firmware + device)"
cp -r "$DEBS" "$MNT/tmp/debs"
chroot "$MNT" bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive
apt install -y /tmp/debs/*.deb
'

KERNEL=$(cd "$MNT/boot" && ls vmlinuz-* 2>/dev/null | head -1 | sed 's/^vmlinuz-//')
[ -n "$KERNEL" ] \
    || die "/boot/vmlinuz-* not found — was linux-image-sm6225 installed?"
log "Kernel: $KERNEL"

log "Building initramfs (includes tapas-firmware hook)"
chroot "$MNT" update-initramfs -c -k "$KERNEL"

# The kernel postinst already ran u-boot-update, but at that point there was no
# /boot/initrd.img-$KERNEL yet, and u-boot-update only writes the "initrd" line
# when the file it names already exists.  Without a ramdisk the kernel has no
# way to turn root=UUID=... into a device and panics.  Regenerate the menu now
# that the initramfs is there.
log "Updating the boot menu with the new initramfs"
chroot "$MNT" u-boot-update

# --- 6) user ----------------------------------------------------------------
# The boot menu is not written here. u-boot-menu generates it on the installed
# system from the kernels that are present, so the image only has to contain
# the kernel itself.
log "Creating user $TAPAS_USER"
# chpasswd reads user:password pairs from stdin. Feeding it from a file keeps
# the password off the command line and out of ps, and leaves the quoting of
# whatever characters it contains to printf.
CRED_FILE="$(mktemp)"
printf '%s:%s\n' "$TAPAS_USER" "$TAPAS_PASSWORD" > "$CRED_FILE"
chmod 600 "$CRED_FILE"

# -u 1000 keeps the seat, /run/user/1000 and the udev rules working no matter
# what the account is called.
if chroot "$MNT" id "$TAPAS_USER" >/dev/null 2>&1; then
    chroot "$MNT" usermod -s /bin/bash -aG sudo "$TAPAS_USER"
else
    chroot "$MNT" useradd -m -u 1000 -s /bin/bash -G sudo "$TAPAS_USER"
fi
chroot "$MNT" chpasswd < "$CRED_FILE"
rm -f "$CRED_FILE"

# --- 6b) boot menu check ----------------------------------------------------
# The kernel postinst generates extlinux.conf.  Verify it points at the root
# filesystem of this image and not at whatever fstab or cmdline it saw first.
if [ -f "$MNT/boot/extlinux/extlinux.conf" ]; then
    grep -q "root=UUID=${UUID}\b" "$MNT/boot/extlinux/extlinux.conf" \
        || die "extlinux.conf does not use the image's root UUID ($UUID)"
    grep -q "initrd /boot/initrd.img" "$MNT/boot/extlinux/extlinux.conf" \
        || die "extlinux.conf loads no initramfs; the kernel cannot resolve root=UUID="
    log "Boot menu: root=UUID=$UUID, initrd present"
else
    log "WARNING: no extlinux.conf in the image"
fi

# --- 7) cleanup ------------------------------------------------------------
log "Cleanup"
rm -f "$MNT/usr/sbin/policy-rc.d"
rm -rf "$MNT/tmp/debs"
chroot "$MNT" apt clean

log "Unmounting"
cleanup_mounts
trap - EXIT

# --- 8) sparse copy --------------------------------------------------------
# Convert the raw image to a sparse image so fastboot flash is faster and
# the file takes up less space on disk.  cp --sparse=always reads zero-filled
# blocks and punches holes instead of writing them, which is exactly what the
# ext4 free space looks like after a fresh install.
log "Creating sparse image ($IMG_SPARSE)"
rm -f "$IMG_SPARSE"
cp --sparse=always "$IMG" "$IMG_SPARSE"
log "Sparse image size on disk: $(du -h "$IMG_SPARSE" | cut -f1) (raw: $(du -h "$IMG" | cut -f1))"

log "Done: $IMG  |  sparse: $IMG_SPARSE (root UUID: $UUID)"
echo ""
echo "Credentials:  user: $TAPAS_USER  /  password: $TAPAS_PASSWORD"
echo ""
echo "Flash with:"
echo "  fastboot flash userdata $IMG_SPARSE"
