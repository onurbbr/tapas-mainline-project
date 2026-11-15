#!/usr/bin/env bash
#
# build.sh — Tapas build pipeline entry point.
#
# Usage:
#   ./build.sh [all|debs|image] [--user NAME] [--password PASS]
#
#   all    : debs → image           (full build)
#   debs   : package only           (staging/ must be ready)
#   image  : image only             (debs/ must be ready)
#
#   --user NAME       account created in the image    (default: user)
#   --password PASS   password for that account       (default: 0000)
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

# Account created inside the image. The values are checked here rather than
# deep inside the image build, so a typo fails in a second instead of after a
# full debootstrap run. Both can also come from the environment, which is what
# the image stage picks up when it is run on its own.
TAPAS_USER="${TAPAS_USER:-user}"
TAPAS_PASSWORD="${TAPAS_PASSWORD:-0000}"

log()  { echo ""; echo "==> [build.sh] $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage:
  ./build.sh [all|debs|image] [--user NAME] [--password PASS]

  all    : debs → image           (full build)
  debs   : package only           (staging/ must be ready)
  image  : image only             (debs/ must be ready)

  --user NAME       account created in the image    (default: user)
  --password PASS   password for that account       (default: 0000)

The image stage needs root. sudo filters the environment it is called with, so
pass the credentials as arguments and not in front of it:

  sudo ./build.sh --user onur --password 1234

When only the image is rebuilt, the stage reads the same values from the
environment:

  sudo TAPAS_USER=onur TAPAS_PASSWORD=1234 bash scripts/build-image.sh
EOF
}

# The name goes straight to useradd, and the password to chpasswd, which reads
# user:password pairs and splits on the first ':'; keep both within what those
# tools accept instead of letting them fail halfway through the build.
validate_credentials() {
    printf '%s' "$TAPAS_USER" \
        | LC_ALL=C grep -qxE '[a-z_][a-z0-9_.-]{0,31}' \
        || die "invalid user name '$TAPAS_USER': lowercase letters, digits, '_', '-' or '.', starting with a letter or '_', at most 32 characters"
    [ -n "$TAPAS_PASSWORD" ] || die "the password must not be empty"
    case "$TAPAS_PASSWORD" in
        *:*)     die "the password must not contain ':'" ;;
        *$'\n'*) die "the password must not contain a newline" ;;
    esac
}

run_debs() {
    log "Stage 1/2: building .deb packages"
    bash "$SCRIPTS/build-debs.sh" "${DEB_TARGET:-all}"
}

run_image() {
    log "Stage 2/2: building debian.img as $TAPAS_USER"
    if [ "$(id -u)" -ne 0 ]; then
        die "The image stage requires root. Run: sudo ./build.sh image (or sudo ./build.sh all)"
    fi
    bash "$SCRIPTS/build-image.sh"
}

target=""
while [ $# -gt 0 ]; do
    case "$1" in
        --user)
            [ $# -ge 2 ] || die "--user needs a value"
            TAPAS_USER="$2"
            shift 2
            ;;
        --user=*)     TAPAS_USER="${1#*=}"; shift ;;
        --password)
            [ $# -ge 2 ] || die "--password needs a value"
            TAPAS_PASSWORD="$2"
            shift 2
            ;;
        --password=*) TAPAS_PASSWORD="${1#*=}"; shift ;;
        -h|--help|help) usage; exit 0 ;;
        -*) die "unknown option: $1" ;;
        *)
            [ -z "$target" ] || die "more than one target given: '$target' and '$1'"
            target="$1"
            shift
            ;;
    esac
done
target="${target:-all}"

validate_credentials
export TAPAS_USER TAPAS_PASSWORD

case "$target" in
    all)
        run_debs
        run_image
        ;;
    debs)   run_debs   ;;
    image)  run_image  ;;
    *) die "unknown target: $target (all|debs|image)" ;;
esac

log "All done."
