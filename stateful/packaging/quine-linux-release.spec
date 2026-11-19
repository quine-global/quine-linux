# Quine Linux Stateful Edition's identity, in place of Fedora's
# fedora-release-identity-kde-desktop (docs/STATEFUL_EDITION.md).
# stateful/packaging/build-rpms.sh builds it, with:
#   fedora_evr  the version-release of Fedora's fedora-release-common it
#               pairs with: common Requires fedora-release-identity of exactly
#               that, so a new fedora-release needs a rebuild of this
#   SOURCE0     os-release: Fedora's KDE identity's, with our name
#   SOURCE1     Fedora's KDE identity's systemd preset (80-kde-desktop.preset)
%global fedora_version %(echo %{fedora_evr} | cut -d- -f1)

Name:           quine-linux-release
Version:        %{fedora_version}
Release:        1%{?dist}
Summary:        Quine Linux Stateful Edition release files
License:        MIT
URL:            https://linux.quineglobal.com
BuildArch:      noarch
Source0:        os-release
Source1:        80-kde-desktop.preset
Source2:        quine.repo

# What fedora-release-identity-kde-desktop is to Fedora's KDE Edition.
Provides:       fedora-release-identity = %{fedora_evr}
Conflicts:      fedora-release-identity
Requires(meta): fedora-release-kde-desktop = %{fedora_evr}
Requires:       redhat-systemd-presets-desktop

%description
Names the system Quine Linux (Stateful Edition) in os-release, enables what
Fedora's KDE Plasma Desktop Edition enables, and configures Quine Linux's
package repository.

%install
install -Dpm 0644 %{SOURCE0} %{buildroot}%{_prefix}/lib/os-release
install -Dpm 0644 %{SOURCE1} %{buildroot}%{_prefix}/lib/systemd/system-preset/80-kde-desktop.preset
install -Dpm 0644 %{SOURCE2} %{buildroot}%{_sysconfdir}/yum.repos.d/quine.repo

%files
%{_prefix}/lib/os-release
%{_prefix}/lib/systemd/system-preset/80-kde-desktop.preset
%config(noreplace) %{_sysconfdir}/yum.repos.d/quine.repo
