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
#   staging/kernel/   : Image, sm6225-xiaomi-tapas.dtb, sm6225_defconfig, modules.tar.gz
#   staging/firmware/ : a complete install tree, copied verbatim into the package:
#                         usr/lib/firmware/{aw87xxx_acf.bin, qca/, ath10k/,
#                           qcom/{a630_sqe.fw, venus-6.0/, sm6225/{tplg,
#                           XIAOMI/TAPAS/{zap, ipa_fws, adsp, cdsp, modem,
#                           wlanmdsp, modem_pr/, *.jsn}}}}
#                         usr/share/qcom/sm6225/Xiaomi/tapas/{acdb/, dsp/,
#                           sensors/, socinfo/}
#                       Where each blob ends up is decided when populating
#                       staging/, not in this script.  The dsp/ and sensors/
#                       trees are the Snapdragon Sensor Core payload: the ADSP
#                       loads its libraries from usr/share/qcom, and userspace
#                       needs the config JSONs, the generated registry and the
#                       socinfo values the DSP keys on.
#                       NOTE: firmware-atheros is NOT used; this package replaces
#                       it (Conflicts: firmware-atheros).
#   staging/device/   : a complete install tree, copied verbatim into the package:
#                         usr/share/alsa/ucm2/Qualcomm/sm6225/tapas/{tapas.conf,
#                           tapas-HiFi.conf}
#                         usr/share/alsa/ucm2/conf.d/sm6225/
#                           Xiaomi-Redmi-Note-12-4G.conf  (relative symlink to
#                           the tapas.conf above)
#                         usr/lib/udev/rules.d/99-tapas-sensors.rules
#                         usr/lib/systemd/system/hexagonrpcd.service.d/tapas.conf
#                         usr/lib/systemd/system/iio-sensor-proxy.service.d/
#                           tapas.conf
#                       As with firmware/, the layout is decided when populating
#                       staging/, not in this script.
#
# Output: debs/*.deb (4 files: image, modules, firmware, device)
#
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"

# ---------------------------------------------------------------- config ---
# When updating, change ONLY this section.
KVER="7.3.0-sm6225-upstream+"     # uname -r; must MATCH lib/modules/<KVER> inside modules.tar.gz
KPKG_VER="7.3.0-1+tapas1"         # linux-image-tapas + linux-modules-tapas Debian package version
FW_VER="20271019-2+tapas1"       # firmware-xiaomi-tapas Debian package version
DEV_VER="0.1-1+tapas1"           # device-xiaomi-tapas Debian package version
DTB="sm6225-xiaomi-tapas.dtb"     # kernel DTB filename

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

check_kernel_inputs() {
    need_file "$STAGING/kernel/Image"
    need_file "$STAGING/kernel/$DTB"
    need_file "$STAGING/kernel/sm6225_defconfig"
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
    cp "$STAGING/kernel/$DTB"             "$pkgdir/boot/dtbs/"
    cp "$STAGING/kernel/$DTB"             "$pkgdir/usr/lib/linux-image-$KVER/qcom/"
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
 Mainline $KVER Image + DTB (modules are in the $MODPKG package).
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
    local sharedir="$root/usr/share/qcom/sm6225/Xiaomi/tapas"

    [[ -d "$root" ]] || die "not found: $root"
    [[ -d "$fwdir" ]] || die "not found: $fwdir (staging/firmware must be an install tree)"
    [[ -d "$tapasdir" ]] || die "not found: $tapasdir"
    [[ -d "$sharedir" ]] || die "not found: $sharedir"

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

    # Files hexagonrpcd serves to the ADSP through its reverse tunnel.  The
    # daemon builds a small VFS out of this directory: acdb/, dsp/<dsp>/,
    # sensors/config, sensors/registry and sensors/sns_reg.conf must all be
    # present or it refuses to start, so validate them here rather than
    # discovering it on the phone.  See hexagonrpcd(1) for the mapping back
    # to the Android paths.
    [[ -d "$sharedir/acdb" ]] || die "not found: $sharedir/acdb (required by hexagonrpcd)"
    [[ -d "$sharedir/sensors/config" ]] || die "not found: $sharedir/sensors/config"
    [[ -d "$sharedir/sensors/registry" ]] || die "not found: $sharedir/sensors/registry"
    [[ -f "$sharedir/sensors/sns_reg.conf" ]] || die "not found: $sharedir/sensors/sns_reg.conf"
    [[ -d "$sharedir/dsp/adsp" ]] || die "not found: $sharedir/dsp/adsp"
    [[ -f "$sharedir/socinfo/soc_id" ]] || die "not found: $sharedir/socinfo/soc_id"

    # Keep these non-empty checks: an empty registry or an acdb tree without a
    # calibration database means the DSP publishes no usable sensors, which is
    # silent and hard to diagnose later.
    n=$(find "$sharedir/acdb" -name '*_acdb_cal.acdb' | wc -l)
    [[ "$n" -gt 0 ]] || die "no *_acdb_cal.acdb under $sharedir/acdb"
    log "acdb calibration databases: $n"
    n=$(find "$sharedir/acdb" -name '*.pmd' | wc -l)
    [[ "$n" -gt 0 ]] || die "no neural network models (*.pmd) under $sharedir/acdb"
    log "acdb nn models: $n"
    n=$(find "$sharedir/sensors/config" -name '*.json' | wc -l)
    [[ "$n" -gt 0 ]] || die "no sensor config JSONs in $sharedir/sensors/config"
    log "sensor configs: $n files"
    n=$(find "$sharedir/sensors/registry" -type f | wc -l)
    [[ "$n" -gt 0 ]] || die "empty sensor registry: $sharedir/sensors/registry"
    log "sensor registry: $n entries"

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
 for SM6225, plus the files hexagonrpcd serves to the ADSP: DSP
 libraries, ACDB calibration data, and the Snapdragon Sensor Core
 configuration (vendor JSONs, generated registry, socinfo values).
 Replaces firmware-atheros; cannot be installed together.
 Includes initramfs-tools hook.
EOF

    mkdir -p "$OUT"
    dpkg-deb --root-owner-group --build "$pkgdir" "$OUT/${FWPKG}_${FW_VER}_all.deb"
    log "produced: $OUT/${FWPKG}_${FW_VER}_all.deb"
}

# ------------------------------------------------------- device package ----
build_device() {
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
    need_file "$root/usr/lib/udev/rules.d/99-tapas-sensors.rules"
    need_file "$root/usr/lib/systemd/system/hexagonrpcd.service.d/tapas.conf"
    need_file "$root/usr/lib/systemd/system/iio-sensor-proxy.service.d/tapas.conf"

    # 99-tapas-sensors.rules advertises the SSC accelerometer and proximity
    # driver types, which iio-sensor-proxy's own rule leaves out, and supplies
    # the accelerometer mount matrix: the chip sits rotated 180 degrees in the
    # board plane, so both X and Y are inverted.
    # hexagonrpcd needs to be told where the Snapdragon Sensor Core payload
    # lives, since the distribution default points at a droid-juicer directory
    # that no tapas install has. The proxy additionally has to start after
    # hexagonrpcd: it probes each sensor only once and never retries, while the
    # FastRPC device unit that pulls it in appears about a minute before
    # hexagonrpcd would otherwise start, so the proximity driver would time out
    # and be dropped on every boot.

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
Depends: alsa-ucm-conf, qcom-phone-utils, hexagonrpcd, iio-sensor-proxy, $FWPKG (= $FW_VER), $IMGPKG (= $KPKG_VER), $MODPKG (= $KPKG_VER)
Maintainer: $MAINTAINER
Description: Device files for Xiaomi Redmi Note 12 4G (tapas)
 ALSA UCM config for SM6225, plus the udev rules and systemd configuration
 that drive the Snapdragon Sensor Core stack through hexagonrpcd and
 iio-sensor-proxy.
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
