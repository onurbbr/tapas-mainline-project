#!/usr/bin/env bash
#
# build.sh — Tapas build pipeline entry point.
#
# Usage:
#   ./build.sh [all|debs|image|clean] [--user NAME] [--password PASS]
#
#   all    : debs → image           (full build)
#   debs   : package only           (staging/ must be ready)
#   image  : image only             (debs/ must be ready)
#   clean  : remove the products of an earlier run, build nothing
#
# Each stage removes the products it is about to write first, so a rebuilt
# kernel cannot be mixed with packages or an image left over from the last one.
# staging/{kernel,firmware,device} are inputs and are never touched.
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
  ./build.sh [all|debs|image|clean] [--user NAME] [--password PASS]

  all    : debs → image           (full build)
  debs   : package only           (staging/ must be ready)
  image  : image only             (debs/ must be ready)
  clean  : remove the products of an earlier run, build nothing

  --user NAME       account created in the image    (default: user)
  --password PASS   password for that account       (default: 0000)

Both stages clean up after themselves: the debs stage drops the .deb files and
the unpacked package trees an earlier run left in debs/ and staging/pkg-*,
the image stage drops debian.img and debian-sparse.img. That matters when the
kernel version changes, because build-image.sh installs every .deb it finds in
debs/ and an old kernel package would otherwise be installed next to the new
one.

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

# Both clean-ups refuse to run while the previous image is still in use, so an
# interrupted image build has to be unwound by hand instead of being papered
# over: deleting a mounted image would corrupt the mount.
guard_image_in_use() {
    if [ -e "$ROOT_DIR/debian.img" ] \
        && losetup -j "$ROOT_DIR/debian.img" 2>/dev/null | grep -q .; then
        die "debian.img is attached to a loop device; detach it or reboot first"
    fi
    if mountpoint -q "$ROOT_DIR/mnt"; then
        die "$ROOT_DIR/mnt is still mounted; run: sudo umount -R $ROOT_DIR/mnt"
    fi
}

# Packages of an earlier run. Kept apart from the image products because the
# debs stage must not throw away an image someone is about to boot.
clean_debs() {
    local removed=0 f
    for f in "$ROOT_DIR"/debs/*.deb; do
        [ -e "$f" ] || continue
        log "removing stale package: ${f#$ROOT_DIR/}"
        rm -f "$f"
        removed=$((removed + 1))
    done
    for f in "$ROOT_DIR"/staging/pkg-*; do
        [ -d "$f" ] || continue
        log "removing leftover package tree: ${f#$ROOT_DIR/}"
        rm -rf "$f"
        removed=$((removed + 1))
    done
    log "packages cleaned ($removed item(s) removed)"
}

clean_image() {
    local removed=0 f
    guard_image_in_use
    for f in "$ROOT_DIR/debian.img" "$ROOT_DIR/debian-sparse.img"; do
        [ -e "$f" ] || continue
        log "removing previous image: ${f#$ROOT_DIR/}"
        rm -f "$f"
        removed=$((removed + 1))
    done
    # mnt/ is the mount point and chroot of the image stage; anything in it
    # comes from a run that did not finish.
    if [ -d "$ROOT_DIR/mnt" ] && [ -n "$(ls -A "$ROOT_DIR/mnt" 2>/dev/null)" ]; then
        log "emptying leftover chroot: mnt/"
        rm -rf "${ROOT_DIR:?}/mnt"
        mkdir -p "$ROOT_DIR/mnt"
        removed=$((removed + 1))
    fi
    log "image cleaned ($removed item(s) removed)"
}

run_debs() {
    log "Stage 1/2: building .deb packages"
    clean_debs
    bash "$SCRIPTS/build-debs.sh" "${DEB_TARGET:-all}"
}

run_image() {
    log "Stage 2/2: building debian.img as $TAPAS_USER"
    if [ "$(id -u)" -ne 0 ]; then
        die "The image stage requires root. Run: sudo ./build.sh image (or sudo ./build.sh all)"
    fi
    clean_image
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
    clean)
        clean_debs
        clean_image
        ;;
    *) die "unknown target: $target (all|debs|image|clean)" ;;
esac

log "All done."
