#!/usr/bin/env bash
# Builds the Stateful Edition's own RPMs into REPO_DIR, inside a Fedora
# container of FEDORA_VERSION (stateful/build-in-container.sh runs it):
#   quine-linux-release  our identity, from Fedora's KDE identity package
#                        (its os-release, with our name, and its preset)
#   quine-linux-desktop  overlay/ files and menu/ (quine-linux-desktop.spec)
# Usage: build-rpms.sh REPO_DIR   (QUINE_VERSION: quine-linux-desktop's
# version; default: the UTC date and time)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=$1
version=${QUINE_VERSION:-$(date -u +%Y%m%d.%H%M)}

dnf install -y --setopt=install_weak_deps=False rpm-build systemd-rpm-macros cpio dnf5-plugins
top=$(mktemp -d)
src=$top/SOURCES
mkdir -p "$src" "$out"

# --- quine-linux-release: Fedora's KDE identity, renamed.
(cd "$top" && dnf download fedora-release-identity-kde-desktop)
identity=$(ls "$top"/fedora-release-identity-kde-desktop-*.noarch.rpm)
evr=$(rpm -qp --qf '%{VERSION}-%{RELEASE}' "$identity")
mkdir "$top/identity"
rpm2cpio "$identity" | (cd "$top/identity" && cpio -idm --quiet)
cp "$top/identity/usr/lib/systemd/system-preset/80-kde-desktop.preset" "$src/"
# ID=fedora and VARIANT_ID=kde stay: dnf, Anaconda's profile for KDE and
# Fedora's tooling key on them (as the Home Edition keeps ID=aurora).
sed -e 's|^NAME=.*|NAME="Quine Linux"|' \
    -e 's|^PRETTY_NAME=.*|PRETTY_NAME="Quine Linux '"${evr%%-*}"' (Stateful Edition)"|' \
    -e 's|^VARIANT=.*|VARIANT="Stateful Edition"|' \
    -e 's|(KDE Plasma Desktop Edition)|(Stateful Edition)|' \
    -e 's|^DEFAULT_HOSTNAME=.*|DEFAULT_HOSTNAME="quine-linux"|' \
    -e 's|^HOME_URL=.*|HOME_URL="https://linux.quineglobal.com"|' \
    "$top/identity/usr/lib/os-release" >"$src/os-release"
grep -q '^DEFAULT_HOSTNAME=' "$src/os-release" || echo 'DEFAULT_HOSTNAME="quine-linux"' >>"$src/os-release"
grep -E '^(NAME|PRETTY_NAME|ID|VARIANT|VARIANT_ID)=' "$src/os-release"
grep -qx 'ID=fedora' "$src/os-release"
grep -qx 'VARIANT_ID=kde' "$src/os-release"
! grep -q 'KDE Plasma Desktop Edition' "$src/os-release"
cp "$here/quine.repo" "$src/"
rpmbuild -bb --define "_topdir $top" --define "fedora_evr $evr" "$here/quine-linux-release.spec"

# --- quine-linux-desktop: overlay/ and menu/ as they are in this checkout.
tar -C "$root" -cf "$src/quine-linux-desktop.tar" overlay menu
rpmbuild -bb --define "_topdir $top" --define "quine_version $version" "$here/quine-linux-desktop.spec"

find "$top/RPMS" -name '*.rpm' -exec cp -v {} "$out/" \;
