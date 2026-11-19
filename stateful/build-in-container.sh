#!/usr/bin/env bash
# Builds the Stateful Edition inside a privileged Fedora container
# (stateful/build.sh starts it): our RPMs, then the live ISO (and with
# --disk, the disk image) with KIWI, from Fedora's image descriptions plus
# ours. The repo is at /src (read-only); /work is scratch; results go to
# /output: Quine-Linux-Stateful-Live.iso, Quine-Linux-Stateful-Disk.raw.
set -euo pipefail
disk=
[ "${1:-}" = --disk ] && disk=1
src=/src
. "$src/stateful/fedora.env"
. /etc/os-release
[ "$VERSION_ID" = "$FEDORA_VERSION" ] || { echo "This container is Fedora $VERSION_ID; stateful/fedora.env says $FEDORA_VERSION" >&2; exit 1; }
for v in version release-version; do
  grep -q "<$v>$FEDORA_VERSION</$v>" "$src/stateful/kiwi/Quine.kiwi" ||
    { echo "stateful/kiwi/Quine.kiwi's <$v> isn't $FEDORA_VERSION (stateful/fedora.env)" >&2; exit 1; }
done

dnf install -y --setopt=install_weak_deps=False \
  kiwi kiwi-systemdeps distribution-gpg-keys createrepo_c git-core dnf5-plugins curl gnupg2

# --- Our RPMs, into a local repository KIWI installs from.
repo=/work/repo
rm -rf "$repo" && mkdir -p "$repo"
"$src/stateful/packaging/build-rpms.sh" "$repo"
# The administrator prompts (admin-auth/build.sh): it rebuilds the version
# installed here, from Fedora's source RPM, into /out.
dnf install -y --setopt=install_weak_deps=False polkit-qt6-1 polkit-kde kio-admin
mkdir -p /out
"$src/admin-auth/build.sh"
mv -v /out/*.rpm "$repo/"
createrepo_c "$repo"
ls -l "$repo"

# --- Fedora's descriptions at the pinned commit, with ours added.
desc=/work/descriptions
rm -rf "$desc" && mkdir -p "$desc"
git -C "$desc" init -q
git -C "$desc" fetch -q --depth 1 "$KIWI_DESCRIPTIONS_URL" "$KIWI_DESCRIPTIONS_COMMIT"
git -C "$desc" checkout -q FETCH_HEAD
cp "$src/stateful/kiwi/Quine.kiwi" "$desc/"
cp -r "$src/stateful/kiwi/quine" "$desc/quine"
sed -i "s|QUINE_LOCAL_REPO|$repo|" "$desc/quine/quine.xml"
# Our apps' repo: its metadata is signed (not its packages, which the
# metadata pins by checksum). Checked here, as KIWI's dnf can't.
quine=https://packages.quineglobal.com/quine-linux/rpm
curl -fsS --retry 3 -o /work/quine.key "$quine/repository.key"
curl -fsS --retry 3 -o /work/repomd.xml "$quine/repodata/repomd.xml"
curl -fsS --retry 3 -o /work/repomd.xml.asc "$quine/repodata/repomd.xml.asc"
gpg --batch --dearmor </work/quine.key >/work/quine.gpg
gpgv --keyring /work/quine.gpg /work/repomd.xml.asc /work/repomd.xml
! grep -q 'QUINE_' "$desc/quine/quine.xml"
# Ours runs at the end of Fedora's config.sh, which ends with `exit 0`.
[ "$(tail -n 1 "$desc/config.sh")" = "exit 0" ] ||
  { echo "Fedora's config.sh no longer ends with 'exit 0': see where config-quine.sh should go" >&2; exit 1; }
sed -i '$d' "$desc/config.sh"
cat "$src/stateful/kiwi/config-quine.sh" >>"$desc/config.sh"
echo 'exit 0' >>"$desc/config.sh"

# --- KIWI: kiwi-ng itself rather than Fedora's kiwi-build, which names ISOs
# from a table of Fedora's own profiles.
build() { # TYPE PROFILE TARGET [kiwi args...]
  local type=$1 profile=$2 target=$3; shift 3
  rm -rf "$target"
  kiwi-ng --type="$type" --profile="$profile" --kiwi-file=Quine.kiwi \
    system build --description "$desc" --target-dir "$target" "$@"
}
mkdir -p /output
build iso Quine-KDE-Desktop-Live /work/live \
  --set-type-attr volid="Quine-Linux-Stateful-$FEDORA_VERSION" \
  --set-type-attr application_id="Quine-Linux-Stateful-$FEDORA_VERSION" \
  --set-type-attr publisher="Quine Global"
mv -v /work/live/*.iso /output/Quine-Linux-Stateful-Live.iso
if [ -n "$disk" ]; then
  build oem Quine-KDE-Desktop-Disk /work/disk
  mv -v /work/disk/*.raw /output/Quine-Linux-Stateful-Disk.raw
fi
ls -lh /output
