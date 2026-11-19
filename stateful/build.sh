#!/usr/bin/env bash
# Builds Quine Linux Stateful Edition (docs/STATEFUL_EDITION.md) on this
# machine: a privileged Fedora container (KIWI needs loop devices) runs
# stateful/build-in-container.sh. There are no published downloads: this is
# how you get it (README "Stateful Edition: build it yourself").
#
# Usage: stateful/build.sh [--disk]   (--disk: the disk image too)
#   CONTAINER_RUNTIME  podman or docker (default: podman if it's installed)
#   WORK_DIR           scratch, ~30 GB (default /var/tmp/quine-stateful;
#                      removed afterwards)
#   OUTPUT_DIR         results (default output/stateful)
#
# Linux: root podman or docker (it asks for sudo for podman). macOS: Docker
# Desktop, or a rootful podman machine (`podman machine set --rootful`); the
# image is built for the Mac's own architecture (aarch64 on Apple silicon).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/stateful/fedora.env"

runtime=${CONTAINER_RUNTIME:-}
if [ -z "$runtime" ]; then
  if command -v podman >/dev/null; then runtime=podman
  elif command -v docker >/dev/null; then runtime=docker
  else echo "Needs podman or docker." >&2; exit 1; fi
fi
# Rootless podman can't hand the container loop devices.
if [ "$(uname -s)" = Linux ] && [ "$runtime" = podman ] && [ "$(id -u)" != 0 ]; then
  exec sudo --preserve-env=CONTAINER_RUNTIME,WORK_DIR,OUTPUT_DIR "$0" "$@"
fi

if [ "$(uname -s)" = Linux ]; then
  work=${WORK_DIR:-/var/tmp/quine-stateful}
else
  # On macOS the container runs in the runtime's Linux VM: keep the scratch
  # space inside it (a volume), not on a shared Mac folder.
  work=${WORK_DIR:-}
fi
output=${OUTPUT_DIR:-$root/output/stateful}
mkdir -p "$output"
if [ -n "$work" ]; then
  mkdir -p "$work"
  trap 'rm -rf "$work"' EXIT
  df -h "$work" | tail -1
  work_mount=$work
else
  work_mount=quine-stateful-work
  trap '"$runtime" volume rm -f quine-stateful-work >/dev/null 2>&1 || true' EXIT
fi

"$runtime" run --rm --privileged --network host \
  -v /dev:/dev \
  -v "$root:/src:ro" -v "$work_mount:/work" -v "$output:/output" \
  "quay.io/fedora/fedora:$FEDORA_VERSION" \
  /src/stateful/build-in-container.sh "$@"
ls -lh "$output"
