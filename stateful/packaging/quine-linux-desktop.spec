# Quine Linux's desktop for the Stateful Edition (docs/STATEFUL_EDITION.md):
# the Home Edition's overlay files that work on any Fedora KDE system, and the
# menu tree. stateful/packaging/build-rpms.sh builds it from this repo
# (SOURCE0, a tarball of overlay/ and menu/), with `quine_version` set.
# Left out, as atomic-only (bootc, rpm-ostree, uupd): update-*, grow-root,
# rpm-ostree-cleanup, quine-update-check, uupd drop-ins; and for now the
# data-disk relabel (with the installer step, phase 5), cs8409 (an akmod,
# phase 5) and disk-cleanup (podman isn't in Fedora KDE).

Name:           quine-linux-desktop
Version:        %{quine_version}
Release:        1%{?dist}
Summary:        Quine Linux's desktop: apps, menu, Flatpak updates on launch
License:        MIT
URL:            https://linux.quineglobal.com
BuildArch:      noarch
Source0:        quine-linux-desktop.tar

# quine-app-updates and build-menu: GLib's key file parser, as GIO reads
# menu entries. (The Home Edition has these in its own venv.)
Requires:       python3-gobject-base
Requires:       flatpak
Requires:       kdialog
Requires:       quine-linux-release
BuildRequires:  systemd-rpm-macros

%description
Quine Linux's desktop defaults: the start menu as a directory tree (README
"The menu tree"), Flatpak apps that update when they're opened, our Flatpak
repository and preinstalled apps, KWin defaults, and agents for SSH and GPG.

%prep
%setup -q -c

%install
o=overlay
for f in \
    etc/flatpak/preinstall.d/quine-linux.preinstall \
    etc/flatpak/remotes.d/quine.flatpakrepo \
    etc/gitconfig \
    etc/profile.d/quine-app-launchers.sh \
    etc/systemd/journald.conf.d/size-cap.conf \
    etc/xdg/kwinrc \
    etc/xdg/kwinrulesrc \
    usr/lib/systemd/system/quine-app-launchers.path \
    usr/lib/systemd/system/quine-app-launchers.service \
    usr/lib/systemd/user/quine-app-launchers.path \
    usr/lib/systemd/user/quine-app-launchers.service \
    usr/lib/systemd/user-preset/90-quine-linux.preset \
    usr/share/user-tmpfiles.d/quine-gnupg.conf; do
  install -Dpm 0644 "$o/$f" "%{buildroot}/$f"
done
for f in \
    usr/bin/quine-app-updates \
    usr/libexec/quine-linux/build-menu \
    usr/lib/systemd/user-environment-generators/61-quine-app-launchers; do
  install -Dpm 0755 "$o/$f" "%{buildroot}/$f"
done
# Fedora's python3 with python3-gobject, not the Home Edition's venv.
sed -i '1s|^#!.*python3$|#!/usr/bin/python3|' \
  %{buildroot}/usr/bin/quine-app-updates %{buildroot}/usr/libexec/quine-linux/build-menu
head -1 %{buildroot}/usr/bin/quine-app-updates | grep -qx '#!/usr/bin/python3'
# Fedora KDE ships Firefox as an RPM: the Flatpak would be a second one.
awk '/^\[Flatpak Preinstall /{skip = ($0 == "[Flatpak Preinstall org.mozilla.firefox]")} !skip' \
  "$o/etc/flatpak/preinstall.d/quine-linux.preinstall" \
  > %{buildroot}/etc/flatpak/preinstall.d/quine-linux.preinstall
! grep -q org.mozilla.firefox %{buildroot}/etc/flatpak/preinstall.d/quine-linux.preinstall
mkdir -p %{buildroot}/usr/share/quine-linux
cp -a menu %{buildroot}/usr/share/quine-linux/menu

%post
%systemd_post quine-app-launchers.path quine-app-launchers.service
%systemd_user_post quine-app-launchers.path quine-app-launchers.service

%preun
%systemd_preun quine-app-launchers.path quine-app-launchers.service
%systemd_user_preun quine-app-launchers.path quine-app-launchers.service

# The start menu is the tree's (build-menu): again whenever a package adds or
# removes an app, or replaces Plasma's menu file, at the end of the
# transaction.
%transfiletriggerin -- /usr/share/applications /etc/xdg/menus
/usr/libexec/quine-linux/build-menu >/dev/null || :

%transfiletriggerpostun -- /usr/share/applications
/usr/libexec/quine-linux/build-menu >/dev/null || :

%posttrans
/usr/libexec/quine-linux/build-menu >/dev/null || :

%files
%config(noreplace) /etc/flatpak/preinstall.d/quine-linux.preinstall
/etc/flatpak/remotes.d/quine.flatpakrepo
%config(noreplace) /etc/gitconfig
/etc/profile.d/quine-app-launchers.sh
%config(noreplace) /etc/systemd/journald.conf.d/size-cap.conf
%config(noreplace) /etc/xdg/kwinrc
%config(noreplace) /etc/xdg/kwinrulesrc
/usr/bin/quine-app-updates
/usr/libexec/quine-linux/
/usr/lib/systemd/system/quine-app-launchers.path
/usr/lib/systemd/system/quine-app-launchers.service
/usr/lib/systemd/user/quine-app-launchers.path
/usr/lib/systemd/user/quine-app-launchers.service
/usr/lib/systemd/user-environment-generators/61-quine-app-launchers
/usr/lib/systemd/user-preset/90-quine-linux.preset
/usr/share/user-tmpfiles.d/quine-gnupg.conf
/usr/share/quine-linux/
