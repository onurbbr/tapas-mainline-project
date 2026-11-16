#!/usr/bin/env bash
#
# scripts/build-debs.sh — Produces tapas kernel / firmware / device .deb packages.
#
# No compilation needed; packages artifacts already present under staging/.
#
# Can be run standalone:
#   cd ~/package && bash scripts/build-debs.sh [all|kernel|firmware|device|image|modules]
#
# When invoked from build.sh, ROOT_DIR is inherited from the environment.
#
# Input directories (under STAGING):
#   staging/kernel/   : Image, the board DTBs, sm6225_defconfig, modules.tar.gz
#   staging/firmware/ : a complete install tree, copied verbatim into the package:
#                         usr/lib/firmware/{aw87xxx_acf.bin, qca/, ath10k/,
#                           qcom/{a630_sqe.fw, venus-6.0/, sm6225/{tplg,
#                           XIAOMI/TAPAS/{zap, ipa_fws, adsp, cdsp, modem,
#                           wlanmdsp, modem_pr/, *.jsn}}}}
#                       Where each blob ends up is decided when populating
#                       staging/, not in this script.
#                       NOTE: firmware-atheros is NOT used; this package replaces
#                       it (Conflicts: firmware-atheros).
#   staging/device/   : a complete install tree, copied verbatim into the package:
#                         usr/share/alsa/ucm2/Qualcomm/sm6225/tapas/{tapas.conf,
#                           tapas-HiFi.conf}
#                         usr/share/alsa/ucm2/conf.d/sm6225/
#                           Xiaomi-Redmi-Note-12-4G.conf  (relative symlink to
#                           the tapas.conf above)
#                         usr/lib/udev/rules.d/70-tapas-camera.rules
#                         usr/share/u-boot-menu/conf.d/tapas.conf
#                       As with firmware/, the layout is decided when populating
#                       staging/, not in this script.
#
# Output: debs/*.deb (4 files: image, modules, firmware, device)
#
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"

# ---------------------------------------------------------------- config ---
# When updating, change ONLY this section.
KVER="${KVER:-}"                  # uname -r; detected from modules.tar.gz when empty
KPKG_VER="${KPKG_VER:-}"          # Debian package version; derived from KVER when empty
FW_VER="20271019-2+tapas1"       # firmware-xiaomi-tapas Debian package version
DEV_VER="0.1-1+tapas1"           # device-xiaomi-tapas Debian package version
# Every board id of this design gets its DTB installed: the bootloader picks
# one by board id, and both live in the same package.
DTBS=(sm6225-xiaomi-tapas.dtb sm6225-xiaomi-topaz.dtb)

IMGPKG="linux-image-tapas"
MODPKG="linux-modules-tapas"
FWPKG="firmware-xiaomi-tapas"
DEVPKG="device-xiaomi-tapas"

STAGING="${STAGING:-$ROOT_DIR/staging}"
OUT="${OUT:-$ROOT_DIR/debs}"
MAINTAINER="${MAINTAINER:-Onur BÜBER <onurbuber@engineer.com>}"

# ------------------------------------------------------------- helpers ----
log() { echo "==> [build-debs] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

need_file() { [[ -f "$1" ]] || die "not found: $1"; }

# Finds the actual KVER inside modules.tar.gz (prevents packaging with wrong KVER).
detect_kver_in_tarball() {
    tar tzf "$STAGING/kernel/modules.tar.gz" \
        | grep -E '^lib/modules/[^/]+/?$' \
        | head -n1 \
        | sed -E 's#^lib/modules/([^/]+)/?#\1#'
}

# The local version that kernelrelease appends through CONFIG_LOCALVERSION.
LOCALVERSION_SUFFIX="-sm6225-upstream"

# 7.4.0-rc1-sm6225-upstream+ -> 7.4.0-rc1-1+tapas1
debver_from_kver() {
    local v="${1%"$LOCALVERSION_SUFFIX"*}"
    printf '%s-1+tapas1' "${v%+}"
}

# Fill in KVER and KPKG_VER from the build output, so that moving to a new
# kernel release does not need this script edited. modules.tar.gz carries
# lib/modules/<KVER>, which is what the kernel actually calls itself.
resolve_kernel_version() {
    local in_tar

    if [[ -z "$KVER" ]]; then
        need_file "$STAGING/kernel/modules.tar.gz"
        in_tar="$(detect_kver_in_tarball)"
        [[ -n "$in_tar" ]] || die "lib/modules/<ver> not found inside modules.tar.gz"
        KVER="$in_tar"
    fi
    if [[ -z "$KPKG_VER" ]]; then
        KPKG_VER="$(debver_from_kver "$KVER")"
        [[ -n "$KPKG_VER" ]] || die "cannot derive a package version from KVER=$KVER"
    fi
}

check_kernel_inputs() {
    resolve_kernel_version
    need_file "$STAGING/kernel/Image"
    need_file "$STAGING/kernel/sm6225_defconfig"
    local dtb
    for dtb in "${DTBS[@]}"; do
        need_file "$STAGING/kernel/$dtb"
    done
    need_file "$STAGING/kernel/modules.tar.gz"
    local in_tar
    in_tar="$(detect_kver_in_tarball)"
    [[ -n "$in_tar" ]] || die "lib/modules/<ver> not found inside modules.tar.gz"
    [[ "$in_tar" == "$KVER" ]] \
        || die "KVER mismatch: script KVER=$KVER but tarball contains $in_tar. Update KVER."
    log "kernel inputs OK (KVER=$KVER)"
}

# ------------------------------------------ kernel packages (image+modules) ----
build_image() {
    check_kernel_inputs
    local pkgdir="$STAGING/pkg-image"
    log "preparing image package: $IMGPKG ($KPKG_VER)"
    rm -rf "$pkgdir"
    mkdir -p "$pkgdir/DEBIAN" \
             "$pkgdir/boot/dtbs" \
             "$pkgdir/usr/lib/linux-image-$KVER/qcom" \
             "$pkgdir/usr/share/doc/$IMGPKG"

    cp "$STAGING/kernel/Image"            "$pkgdir/boot/vmlinuz-$KVER"
    # /boot/dtbs is where the boot script loads from; the second copy is the
    # location update-initramfs and any future flash-kernel hook expect.
    local dtb
    for dtb in "${DTBS[@]}"; do
        cp "$STAGING/kernel/$dtb"         "$pkgdir/boot/dtbs/"
        cp "$STAGING/kernel/$dtb"         "$pkgdir/usr/lib/linux-image-$KVER/qcom/"
    done
    cp "$STAGING/kernel/sm6225_defconfig" "$pkgdir/usr/share/doc/$IMGPKG/"
    # Official Debian location for update-initramfs compression control.
    cp "$STAGING/kernel/sm6225_defconfig" "$pkgdir/boot/config-$KVER"

    cat > "$pkgdir/DEBIAN/control" <<EOF
Package: $IMGPKG
Version: $KPKG_VER
Section: kernel
Priority: optional
Architecture: arm64
Depends: $MODPKG (= $KPKG_VER), zstd, initramfs-tools
Maintainer: $MAINTAINER
Description: Mainline kernel image for Xiaomi Redmi Note 12 4G (tapas, SM6225)
 Mainline $KVER Image + the DTBs of both board ids (modules are in the
 $MODPKG package).
 For boot with U-Boot + extlinux.
EOF

    # Kurulum sonrası initrd oluştur.
    cat > "$pkgdir/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
case "\$1" in
    configure)
        if command -v update-initramfs >/dev/null 2>&1; then
            update-initramfs -c -k $KVER || update-initramfs -u -k $KVER || true
        fi
        ;;
esac
exit 0
EOF
    chmod 755 "$pkgdir/DEBIAN/postinst"

    # Paket kaldırılınca /boot/initrd.img-<KVER> dosyasını temizle.
    cat > "$pkgdir/DEBIAN/postrm" <<EOF
#!/bin/sh
set -e
case "\$1" in
    remove|purge)
        rm -f /boot/initrd.img-$KVER
        ;;
esac
exit 0
EOF
    chmod 755 "$pkgdir/DEBIAN/postrm"

    mkdir -p "$OUT"
    dpkg-deb --root-owner-group --build "$pkgdir" "$OUT/${IMGPKG}_${KPKG_VER}_arm64.deb"
    log "produced: $OUT/${IMGPKG}_${KPKG_VER}_arm64.deb"
}

build_modules() {
    check_kernel_inputs
    local pkgdir="$STAGING/pkg-modules"
    log "preparing modules package: $MODPKG ($KPKG_VER)"
    rm -rf "$pkgdir"
    mkdir -p "$pkgdir/DEBIAN"

    tar xzf "$STAGING/kernel/modules.tar.gz" -C "$pkgdir/"

    cat > "$pkgdir/DEBIAN/control" <<EOF
Package: $MODPKG
Version: $KPKG_VER
Section: kernel
Priority: optional
Architecture: arm64
Maintainer: $MAINTAINER
Description: Kernel modules for Xiaomi Redmi Note 12 4G (tapas, SM6225)
 /lib/modules/$KVER (kernel image is in the $IMGPKG package).
EOF

    cat > "$pkgdir/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
if command -v depmod >/dev/null 2>&1; then
  depmod $KVER || true
fi
exit 0
EOF
    chmod 755 "$pkgdir/DEBIAN/postinst"

    mkdir -p "$OUT"
    dpkg-deb --root-owner-group --build "$pkgdir" "$OUT/${MODPKG}_${KPKG_VER}_arm64.deb"
    log "produced: $OUT/${MODPKG}_${KPKG_VER}_arm64.deb"
}

# kernel = image + modules
build_kernel() {
    build_image
    build_modules
}

# ----------------------------------------------------- firmware package ----
build_firmware() {
    # staging/firmware is a complete install tree (usr/lib/firmware/... and
    # usr/share/qcom/...), not a bag of loose blobs: it is the payload of the
    # package.  Everything is copied verbatim; only DEBIAN/, the docs and the
    # initramfs hook are generated here.  Whatever layout a blob needs is
    # decided once, when populating staging, instead of being re-encoded in
    # this function.
    local root="$STAGING/firmware"
    local fwdir="$root/usr/lib/firmware"
    local tapasdir="$fwdir/qcom/sm6225/XIAOMI/TAPAS"

    [[ -d "$root" ]] || die "not found: $root"
    [[ -d "$fwdir" ]] || die "not found: $fwdir (staging/firmware must be an install tree)"
    [[ -d "$tapasdir" ]] || die "not found: $tapasdir"

    local f
    for f in \
        aw87xxx_acf.bin \
        qcom/a630_sqe.fw \
        qcom/sm6225/Xiaomi-Redmi-Note-12-4G-tplg.bin \
        qcom/venus-6.0/venus.mbn \
        qcom/sm6225/XIAOMI/TAPAS/a610_zap.mdt \
        qcom/sm6225/XIAOMI/TAPAS/a610_zap.elf \
        qcom/sm6225/XIAOMI/TAPAS/a610_zap.b00 \
        qcom/sm6225/XIAOMI/TAPAS/a610_zap.b01 \
        qcom/sm6225/XIAOMI/TAPAS/a610_zap.b02 \
        qcom/sm6225/XIAOMI/TAPAS/ipa_fws.mdt \
        qcom/sm6225/XIAOMI/TAPAS/ipa_fws.elf \
        qcom/sm6225/XIAOMI/TAPAS/ipa_fws.b00 \
        qcom/sm6225/XIAOMI/TAPAS/ipa_fws.b01 \
        qcom/sm6225/XIAOMI/TAPAS/ipa_fws.b02 \
        qcom/sm6225/XIAOMI/TAPAS/ipa_fws.b03 \
        qcom/sm6225/XIAOMI/TAPAS/ipa_fws.b04 \
        qcom/sm6225/XIAOMI/TAPAS/adsp.mdt \
        qcom/sm6225/XIAOMI/TAPAS/cdsp.mdt \
        qcom/sm6225/XIAOMI/TAPAS/modem.mdt \
        qcom/sm6225/XIAOMI/TAPAS/wlanmdsp.mbn \
        qca/cmbtfw13.tlv \
        qca/cmnv13t.bin \
        ath10k/WCN3990/hw1.0/board-2.bin \
        ath10k/WCN3990/hw1.0/firmware-5.bin \
        ath10k/WCN3990/hw1.0/wlanmdsp.mbn; do
        need_file "$fwdir/$f"
    done

    # Segment count checks: a truncated split image still passes need_file, but
    # the remote processor fails to authenticate it at boot.
    local prefix n
    for prefix in adsp cdsp modem; do
        n=$(ls "$tapasdir"/$prefix.b* 2>/dev/null | wc -l)
        [[ "$n" -gt 0 ]] || die "no segments found: $tapasdir/$prefix.b*"
        log "$prefix segments: $n files"
    done
    [[ -d "$tapasdir/modem_pr" ]] || die "modem_pr missing: $tapasdir/modem_pr"

    local pkgdir="$STAGING/pkg-firmware"
    log "preparing firmware package: $FWPKG ($FW_VER)"
    rm -rf "$pkgdir"
    mkdir -p "$pkgdir/DEBIAN" \
             "$pkgdir/usr/share/initramfs-tools/hooks" \
             "$pkgdir/usr/share/doc/$FWPKG"

    # Reject stray top-level entries: the tree is copied as-is, so anything
    # outside usr/ would end up in the package root.
    local stray
    stray=$(find "$root" -mindepth 1 -maxdepth 1 ! -name usr -print)
    [[ -z "$stray" ]] || die "unexpected entry in staging/firmware: $stray"

    cp -a "$root/usr" "$pkgdir/"
    log "payload: $(find "$pkgdir/usr" -type f | wc -l) files, $(du -sh "$pkgdir/usr" | cut -f1)"

    # initramfs hook: the ADSP/modem/WLAN blobs have to be in the initramfs,
    # the GPU zap because the display may need it before root is mounted.
    # Pattern follows qcom-phone-utils's qcom-firmware hook (add_firmware + list).
    cat > "$pkgdir/usr/share/initramfs-tools/hooks/tapas-firmware" <<'HOOKEOF'
#!/bin/sh
set -e

PREREQS=""
case $1 in
    prereqs) echo "${PREREQS}"; exit 0;;
esac

. /usr/share/initramfs-tools/hook-functions

# tapas (sm6225/XIAOMI/TAPAS) fixed firmware list.  Single-device package,
# so no need to read soc/model from cmdline like qcom-firmware does.
FW_LIST="aw87xxx_acf.bin
qcom/sm6225/Xiaomi-Redmi-Note-12-4G-tplg.bin
qcom/a630_sqe.fw
qcom/venus-6.0/venus.mbn
qcom/sm6225/XIAOMI/TAPAS/a610_zap.mdt
qcom/sm6225/XIAOMI/TAPAS/a610_zap.elf
qcom/sm6225/XIAOMI/TAPAS/a610_zap.b00
qcom/sm6225/XIAOMI/TAPAS/a610_zap.b01
qcom/sm6225/XIAOMI/TAPAS/a610_zap.b02
qcom/sm6225/XIAOMI/TAPAS/ipa_fws.mdt
qcom/sm6225/XIAOMI/TAPAS/ipa_fws.elf
qcom/sm6225/XIAOMI/TAPAS/ipa_fws.b00
qcom/sm6225/XIAOMI/TAPAS/ipa_fws.b01
qcom/sm6225/XIAOMI/TAPAS/ipa_fws.b02
qcom/sm6225/XIAOMI/TAPAS/ipa_fws.b03
qcom/sm6225/XIAOMI/TAPAS/ipa_fws.b04
qca/cmbtfw13.tlv
qca/cmnv13t.bin
ath10k/WCN3990/hw1.0/board-2.bin
ath10k/WCN3990/hw1.0/firmware-5.bin
ath10k/WCN3990/hw1.0/wlanmdsp.mbn
qcom/sm6225/XIAOMI/TAPAS/wlanmdsp.mbn"

# NON-HLOS.bin: adsp + cdsp + modem (mdt + all b* segments).
for _p in adsp cdsp modem; do
    FW_LIST="${FW_LIST} qcom/sm6225/XIAOMI/TAPAS/${_p}.mdt"
    for _s in /lib/firmware/qcom/sm6225/XIAOMI/TAPAS/${_p}.b*; do
        [ -e "$_s" ] || continue
        FW_LIST="${FW_LIST} qcom/sm6225/XIAOMI/TAPAS/$(basename "$_s")"
    done
done

for fwfile in ${FW_LIST}; do
    if [ -f "/lib/firmware/updates/${version?}/${fwfile}" ] ||
       [ -f "/lib/firmware/updates/${fwfile}" ]             ||
       [ -f "/lib/firmware/${version}/${fwfile}" ]          ||
       [ -f "/lib/firmware/${fwfile}" ]; then
        add_firmware "${fwfile}"
    else
        echo "I: Ignoring missing firmware ${fwfile}"
    fi
done
HOOKEOF
    chmod 755 "$pkgdir/usr/share/initramfs-tools/hooks/tapas-firmware"

    cat > "$pkgdir/DEBIAN/control" <<EOF
Package: $FWPKG
Version: $FW_VER
Section: kernel
Priority: optional
Architecture: all
Depends: qrtr-tools, rmtfs, tqftpserv, protection-domain-mapper, libssc2
Conflicts: firmware-atheros
Maintainer: $MAINTAINER
Description: Proprietary firmware blobs for Xiaomi Redmi Note 12 4G (tapas)
 GPU zap, IPA, SQE, ADSP, CDSP, modem, Venus video, WCN3990 WLAN
 (board-2.bin + fw), WCN3950 BT (stock), audio topology and amp firmware
 for SM6225.
 Replaces firmware-atheros; cannot be installed together.
 Includes initramfs-tools hook.
EOF

    mkdir -p "$OUT"
    dpkg-deb --root-owner-group --build "$pkgdir" "$OUT/${FWPKG}_${FW_VER}_all.deb"
    log "produced: $OUT/${FWPKG}_${FW_VER}_all.deb"
}

# ------------------------------------------------------- device package ----
build_device() {
    resolve_kernel_version
    local root="$STAGING/device"
    local ucm="$root/usr/share/alsa/ucm2/Qualcomm/sm6225/tapas"
    local pkgdir="$STAGING/pkg-device"

    [[ -d "$root/usr" ]] || die "not found: $root/usr"

    # The staging tree is the installed layout, so every path below is the
    # path the file ends up at on the target. Anything missing here is a
    # packaging bug, not a template to fill in.
    need_file "$ucm/tapas.conf"
    need_file "$ucm/tapas-HiFi.conf"
    need_file "$root/usr/share/alsa/ucm2/conf.d/sm6225/Xiaomi-Redmi-Note-12-4G.conf"
    need_file "$root/usr/lib/udev/rules.d/70-tapas-camera.rules"

    log "preparing device package: $DEVPKG ($DEV_VER)"
    rm -rf "$pkgdir"
    mkdir -p "$pkgdir/DEBIAN"

    # The UCM alias is a relative symlink inside the tree, so a verbatim copy
    # keeps it intact and needs no recreate step here.
    cp -a "$root/usr" "$pkgdir/"

    cat > "$pkgdir/DEBIAN/control" <<EOF
Package: $DEVPKG
Version: $DEV_VER
Section: kernel
Priority: optional
Architecture: all
Depends: alsa-ucm-conf, qcom-phone-utils, $FWPKG (= $FW_VER), $IMGPKG (= $KPKG_VER), $MODPKG (= $KPKG_VER)
Maintainer: $MAINTAINER
Description: Device files for Xiaomi Redmi Note 12 4G (tapas)
 ALSA UCM config for SM6225, the camera udev rules and the boot menu
 configuration.
EOF

    mkdir -p "$OUT"
    dpkg-deb --root-owner-group --build "$pkgdir" "$OUT/${DEVPKG}_${DEV_VER}_all.deb"
    log "produced: $OUT/${DEVPKG}_${DEV_VER}_all.deb"
}

# ----------------------------------------------------------------- main ---
target="${1:-all}"
case "$target" in
    all)      build_kernel; build_firmware; build_device ;;
    kernel)   build_kernel ;;
    image)    build_image ;;
    modules)  build_modules ;;
    firmware) build_firmware ;;
    device)   build_device ;;
    -h|--help|help)
        echo "Usage: $0 [all|kernel|image|modules|firmware|device]"
        echo "  STAGING=... OUT=... $0 all"
        exit 0
        ;;
    *) die "unknown target: $target (all|kernel|image|modules|firmware|device)" ;;
esac

log "outputs:"
ls -lh "$OUT/${IMGPKG}_${KPKG_VER}_arm64.deb" \
       "$OUT/${MODPKG}_${KPKG_VER}_arm64.deb" \
       "$OUT/${FWPKG}_${FW_VER}_all.deb" \
       "$OUT/${DEVPKG}_${DEV_VER}_all.deb" 2>/dev/null || ls -lh "$OUT/"
log "done."

log "Cleaning up staging package dirs"
rm -rf "$STAGING/pkg-image" "$STAGING/pkg-modules" "$STAGING/pkg-firmware" "$STAGING/pkg-device"
