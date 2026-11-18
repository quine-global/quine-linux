#!/usr/bin/env bash
# Rebuilds the three packages behind administrator password prompts with our
# patches (README: "Administrator prompts"), as RPMs in /out, for the
# Containerfile's admin-auth-builder stage. Runs FROM the `updated` stage:
# each comes from Fedora's own source RPM of the version the image ships,
# built with Fedora's own spec, with one patch added, and a ".quine" on its
# release so it replaces Fedora's build. If a new version moves the code, the
# patch stops applying and the build says so.
#   polkit-qt-1.patch  (polkit-qt6-1): tells the agent which request polkitd
#                      cancelled.
#   polkit-kde.patch   (polkit-kde, the password dialog): requests wait their
#                      turn instead of failing while a dialog is open; one
#                      whose asker has exited closes.
#   kio-admin.patch    (kio-admin, Dolphin's "Act as Administrator"): no second
#                      dialog, calls that outlast the dialog, real errors.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)

# source package, binary package that ships its version, patch
builds=(
  "polkit-qt-1 polkit-qt6-1 polkit-qt-1.patch"
  "polkit-kde polkit-kde polkit-kde.patch"
  "kio-admin kio-admin kio-admin.patch"
)
# What goes into the image: the binary packages the image already has.
keep=(polkit-qt6-1 polkit-kde kio-admin)

dnf install -y --setopt=install_weak_deps=False rpm-build patch
dist="$(rpm -E '%{dist}').quine"
top=$(mktemp -d)
mkdir -p /out

for b in "${builds[@]}"; do
  read -r src bin patch <<<"$b"
  nvr=$(rpm -q --qf '%{VERSION}-%{RELEASE}' "$bin")
  V=$(rpm -q --qf '%{VERSION}' "$bin")
  echo "Rebuilding $src-$nvr with $patch"
  cd "$top"
  # As taskmanager/build.sh: the source repos only carry each package's newest
  # build, and Koji keeps every one.
  srpm="$src-$nvr.src.rpm"
  dnf download --source --enablerepo=fedora-source,updates-source "$src-$nvr" || true
  if [ ! -s "$srpm" ]; then
    url="https://kojipkgs.fedoraproject.org/packages/$src/$V/${nvr#"$V"-}/src/$srpm"
    echo "$srpm isn't in the repos any more; from Koji: $url"
    curl -fsSL --retry 5 -o "$srpm" "$url"
  fi
  rpm -i --define "_topdir $top/$src" "$srpm"
  spec="$top/$src/SPECS/$src.spec"
  cp "$here/$patch" "$top/$src/SOURCES/quine-$patch"
  # %autosetup -p1 applies every Patch line; ours goes after Source0.
  grep -q '^%autosetup.*-p1' "$spec" || { echo "$spec has no '%autosetup -p1' to apply $patch with" >&2; exit 1; }
  sed -i "0,/^Source0:/{/^Source0:/a Patch9001: quine-$patch
}" "$spec"
  grep -q "^Patch9001: quine-$patch" "$spec"
  dnf builddep -y --setopt=install_weak_deps=False "$spec"
  rpmbuild -bb --define "_topdir $top/$src" --define "dist $dist" \
    --define 'debug_package %{nil}' "$spec"
  for k in "${keep[@]}"; do
    find "$top/$src/RPMS" -name "$k-$V-*.rpm" -exec cp -v {} /out/ \;
  done
done

# One of each, and each newer than the one it replaces.
for k in "${keep[@]}"; do
  f=(/out/"$k"-[0-9]*.rpm)
  [ "${#f[@]}" = 1 ] && [ -s "${f[0]}" ] || { echo "expected one $k RPM in /out, got: ${f[*]}" >&2; exit 1; }
  new=$(rpm -qp --qf '%{EPOCH}:%{VERSION}-%{RELEASE}' "${f[0]}" | sed 's/^(none)/0/')
  old=$(rpm -q --qf '%{EPOCH}:%{VERSION}-%{RELEASE}' "$k" | sed 's/^(none)/0/')
  rpm --eval "%{lua: print(rpm.vercmp('$new', '$old'))}" | grep -qx 1 \
    || { echo "$k: $new isn't newer than the installed $old" >&2; exit 1; }
done
ls -l /out
