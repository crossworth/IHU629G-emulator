#!/usr/bin/env bash
# Run a command inside the build container, with the repo mounted at /project.
#
# Usage: tools/drun.sh [-w DIR] [--] <command...>
#   -w DIR   working directory under /project (default /project)
#
# Scripts under tools/stages/ are meant to run INSIDE this container; host
# stage scripts invoke them as: tools/drun.sh -- bash tools/stages/XX.sh
#
# Builds the image on first use. All Linux-side tooling (debugfs, dtc, kernel
# build, ramdisk repack) goes through here; QEMU itself runs on the macOS host
# because HVF acceleration only exists there.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
IMAGE=ex2-build:latest

docker build -q -t "$IMAGE" "$HERE/env" >/dev/null 2>&1 || {
  echo "building container image..." >&2
  docker build -t "$IMAGE" "$HERE/env" >&2
}

WORKDIR=/project
if [ "${1:-}" = "-w" ]; then
  WORKDIR="$2"
  [[ "$WORKDIR" = /* ]] || WORKDIR="/project/$WORKDIR"
  shift 2
fi
[ "${1:-}" != "--" ] || shift

DUMP_DIR="${EX2_DUMP:-$REPO/dump}"
D_ARGS=()
[ -d "$DUMP_DIR" ] && D_ARGS=("-v" "$DUMP_DIR:/dump:ro")

# Kernel tree persists in a case-sensitive ext4 volume: the kernel build
# breaks on case-insensitive mounts (xt_TCPMSS.c vs xt_tcpmss.c) and the
# project dir lives on APFS.
PLATFORM="${EX2_PLATFORM:-linux/arm64}"
if [ "$PLATFORM" = "linux/amd64" ]; then
  IMAGE=ex2-build-amd64:latest
  docker build -q --platform linux/amd64 -t "$IMAGE" "$HERE/env" >/dev/null 2>&1 || {
    echo "building amd64 container image..." >&2
    docker build --platform linux/amd64 -t "$IMAGE" "$HERE/env" >&2
  }
fi
exec docker run --rm \
  --platform "$PLATFORM" \
  -v "$REPO:/project" \
  -v ex2-kbuild:/root/kbuild \
  ${D_ARGS[@]+"${D_ARGS[@]}"} \
  -w "$WORKDIR" \
  "$IMAGE" "$@"
# (IMAGE defaults to ex2-build:latest at the top; the amd64 branch above
# overrides it to ex2-build-amd64:latest - both built from the same
# Dockerfile, different --platform.)
