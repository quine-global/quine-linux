#!/usr/bin/env bash
# Builds Quine Linux Stateful Edition (docs/STATEFUL_EDITION.md) on this
# machine: a privileged Fedora container (KIWI needs loop devices) runs
# stateful/build-in-container.sh. Root podman, ~30 GB free in WORK_DIR.
# Usage: stateful/build.sh [--disk]   (--disk: the disk image too)
#   WORK_DIR    scratch (default /var/tmp/quine-stateful; removed after)
#   OUTPUT_DIR  results (default output/stateful)
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/stateful/fedora.env"
work=${WORK_DIR:-/var/tmp/quine-stateful}
output=${OUTPUT_DIR:-$root/output/stateful}
mkdir -p "$work" "$output"
trap 'rm -rf "$work"' EXIT
df -h "$work" | tail -1
podman run --rm --privileged --network host \
  -v /dev:/dev \
  -v "$root:/src:ro" -v "$work:/work" -v "$output:/output" \
  "quay.io/fedora/fedora:$FEDORA_VERSION" \
  /src/stateful/build-in-container.sh "$@"
ls -lh "$output"
