#!/usr/bin/env bash
#
# build.sh — Tapas build pipeline entry point.
#
# Usage:
#   ./build.sh [all|debs|image]
#
#   all    : debs → image           (full build)
#   debs   : package only           (staging/ must be ready)
#   image  : image only             (debs/ must be ready)
#
# Directory layout (relative to this file):
#   staging/
#     kernel/       ← built-in kernel here
#     firmware/     ← populated manually, not touched by scripts
#     device/       ← populated manually, not touched by scripts
#   debs/           ← build-debs.sh writes here
#   debian.img      ← build-image.sh writes here
#   debian-sparse.img ← sparse copy produced by build-image.sh
#   scripts/
#     build-debs.sh
#     build-image.sh
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
export ROOT_DIR

SCRIPTS="$ROOT_DIR/scripts"

log()  { echo ""; echo "==> [build.sh] $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

run_debs() {
    log "Stage 1/2: building .deb packages"
    bash "$SCRIPTS/build-debs.sh" "${DEB_TARGET:-all}"
}

run_image() {
    log "Stage 2/2: building debian.img"
    if [ "$(id -u)" -ne 0 ]; then
        die "The image stage requires root. Run: sudo ./build.sh image (or sudo ./build.sh all)"
    fi
    bash "$SCRIPTS/build-image.sh"
}

target="${1:-all}"
case "$target" in
    all)
        run_debs
        run_image
        ;;
    debs)   run_debs   ;;
    image)  run_image  ;;
    -h|--help|help)
        sed -n '3,12p' "$0"
        exit 0
        ;;
    *) die "unknown target: $target (all|debs|image)" ;;
esac

log "All done."
