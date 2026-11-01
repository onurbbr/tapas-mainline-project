#!/usr/bin/env bash
#
# scripts/build-image.sh — Builds a Debian image for Redmi Note 12 4G.
#
# Assumes debs/ is already populated (run build.sh debs first).
# ROOT_DIR is passed via env when invoked from build.sh.
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

# --- pre-checks ------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "This script requires root. Run: sudo ./build.sh image"

[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] \
    || echo "WARNING: qemu-aarch64 binfmt not registered; second-stage may fail."

# Verify debs/ is populated before doing any work.
for p in device-xiaomi-tapas firmware-xiaomi-tapas linux-image-tapas linux-modules-tapas; do
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

# --- 4) tapas packages + initrd --------------------------------------------
log "Installing tapas packages (kernel + modules + firmware + device)"
cp -r "$DEBS" "$MNT/tmp/debs"
chroot "$MNT" bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive
apt install -y /tmp/debs/*.deb
'

KERNEL=$(cd "$MNT/boot" && ls vmlinuz-* 2>/dev/null | head -1 | sed 's/^vmlinuz-//')
[ -n "$KERNEL" ] \
    || die "/boot/vmlinuz-* not found — was linux-image-tapas installed?"
log "Kernel: $KERNEL"

log "Building initramfs (includes tapas-firmware hook)"
chroot "$MNT" update-initramfs -c -k "$KERNEL"

# --- 5) boot.scr + fstab + hostname + user ---------------------------------
log "Writing boot.scr (root=UUID=$UUID)"
cat > "$MNT/boot/boot.cmd" <<'EOF'
setenv bootargs "clk_ignore_unused pd_ignore_unused root=UUID=__UUID__ rootwait rw"
load scsi 0:13 ${kernel_addr_r} /boot/vmlinuz-__KERNEL__
load scsi 0:13 ${fdt_addr_r} /boot/dtbs/sm6225-xiaomi-tapas.dtb
load scsi 0:13 ${ramdisk_addr_r} /boot/initrd.img-__KERNEL__
booti ${kernel_addr_r} ${ramdisk_addr_r}:${filesize} ${fdt_addr_r}
EOF
sed -i "s/__UUID__/$UUID/g; s/__KERNEL__/$KERNEL/g" "$MNT/boot/boot.cmd"
mkimage -C none -A arm64 -T script \
    -d "$MNT/boot/boot.cmd" \
    "$MNT/boot/boot.scr"
rm "$MNT/boot/boot.cmd"
log "boot.scr written (kernel: $KERNEL)"

log "Writing fstab"
printf '# Debian - single ext4 rootfs\nUUID=%s / ext4 defaults 0 1\n' "$UUID" \
    | tee "$MNT/etc/fstab" >/dev/null

echo debian | tee "$MNT/etc/hostname" >/dev/null

log "Creating user"
chroot "$MNT" bash -c '
set -e
if ! id onur >/dev/null 2>&1; then
    useradd -m -u 1000 -s /bin/bash -G sudo onur
fi
echo "onur:0000" | chpasswd
'

# --- 6) cleanup ------------------------------------------------------------
log "Cleanup"
rm -f "$MNT/usr/sbin/policy-rc.d"
rm -rf "$MNT/boot/boot.cmd"
rm -rf "$MNT/tmp/debs"
chroot "$MNT" apt clean

log "Unmounting"
cleanup_mounts
trap - EXIT

# --- 7) sparse copy --------------------------------------------------------
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
echo "Credentials:  user: onur  /  password: 0000"
echo ""
echo "Flash with:"
echo "  fastboot flash userdata $IMG_SPARSE"
