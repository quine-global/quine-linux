# Built on our Aurora fork (quine-global/aurora), which its own workflow
# builds and publishes to this forge's registry (`stable` for x86_64,
# `stable-arm64` for aarch64; iso.yml picks). Pass e.g.
# --build-arg BASE_IMAGE=ghcr.io/ublue-os/aurora:stable to build on stock
# upstream Aurora instead, or localhost/aurora:stable for a local build of
# the fork.
ARG BASE_IMAGE=forge.in.quineglobal.com/quine-global/aurora:stable

# --- Aurora, upgraded to Fedora's latest packages. ---
# Quine Linux is bleeding edge: it ships what Fedora has today, not only
# what Aurora's stable has caught up to, and we fix what breaks. Every
# stage below starts here, so the builders compile against exactly what
# ships. The kernel stays Aurora's: it comes signed from Universal Blue's
# akmods, paired with the prebuilt kernel modules installed with it.
# UPDATES_STAMP (the Taskfile passes the hour) makes the layer cache redo
# the upgrade instead of keeping the first one forever.
FROM ${BASE_IMAGE} AS updated
ARG UPDATES_STAMP=unset
RUN set -eux; \
    echo "Fedora updates as of ${UPDATES_STAMP}"; \
    dnf upgrade -y --refresh --exclude='kernel*'; \
    # The repo metadata stays (the final stage drops it at its end): every
    # stage below resolves against this same snapshot of the repos, still
    # fresh for the whole build (Fedora's repo files: 6h for updates). Each
    # fetching its own came from different mirrors, and a mirror that hadn't
    # caught up with an update pushed that morning lacked the -devel
    # packages for what this stage had installed (2026-11-16).
    dnf clean packages; \
    # The initramfs holds copies of systemd and friends: rebuild it from the
    # upgraded ones, the way Universal Blue's images build theirs.
    KVER="$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}')"; \
    TMPDIR=/var/tmp dracut --no-hostonly --kver "$KVER" --reproducible --zstd \
        --add ostree -f "/usr/lib/modules/$KVER/initramfs.img"; \
    chmod 0600 "/usr/lib/modules/$KVER/initramfs.img"

# --- Builds the out-of-tree snd-hda-codec-cs8409 module (iMac19,2 mic fix). ---
# See docs/imac19-2-mic-fix.md and patches/snd-hda-codec-cs8409/ for the full
# story. Kept as its own stage so the build toolchain never lands in the
# final image, and built FROM the same `updated` stage as the final one so the
# kernel-devel headers installed here can never drift out of sync with the
# kernel that actually ships below.
FROM updated AS kmod-builder

RUN set -eux; \
    NVR="$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}')"; \
    VERSION="$(rpm -q kernel-core --qf '%{VERSION}')"; \
    RELEASE="$(rpm -q kernel-core --qf '%{RELEASE}')"; \
    ARCH="$(rpm -q kernel-core --qf '%{ARCH}')"; \
    echo "Building snd-hda-codec-cs8409 against kernel ${NVR}"; \
    dnf install -y gcc make elfutils-libelf-devel bc perl patch; \
    dnf install -y "kernel-devel-${NVR}" \
      || dnf install -y "https://kojipkgs.fedoraproject.org/packages/kernel/${VERSION}/${RELEASE}/${ARCH}/kernel-devel-${NVR}.rpm"; \
    echo "${NVR}" > /kernel-nvr.txt

COPY patches/snd-hda-codec-cs8409/vendor/ /usr/src/snd-hda-codec-cs8409/
COPY patches/snd-hda-codec-cs8409/0001-imac19-2-force-intmike-adc-nid-fallback.patch /tmp/

# --fuzz=0: fail loudly on a context mismatch (e.g. a future kernel bump that
# shifts this file) instead of silently mis-patching.
RUN set -eux; \
    cd /usr/src/snd-hda-codec-cs8409; \
    patch -p1 --fuzz=0 < /tmp/0001-imac19-2-force-intmike-adc-nid-fallback.patch; \
    make KVER="$(cat /kernel-nvr.txt)"; \
    mkdir -p /output; \
    cp snd-hda-codec-cs8409.ko /output/

# --- Builds Kickoff (the start menu) with our update bar. ---
# Kickoff is QML packed into one plugin of plasma-desktop. This rebuilds
# just that plugin from our fork, quine-global/plasma-desktop, branch
# quine-v<version>: KDE's release of the plasma-desktop version the image
# ships, plus our commits. The final stage puts it in place of the stock
# one. Like kmod-builder, it's built FROM `updated` so it can't drift from
# the Plasma it runs on; the -devel packages are pinned to the installed
# versions (older ones come from Fedora's updates-archive). kickoff/ holds
# the CMakeLists.txt that builds the applet outside plasma-desktop's tree.
FROM updated AS kickoff-builder

COPY kickoff/CMakeLists.txt /tmp/kickoff/

RUN set -eux; \
    v() { rpm -q --qf '%{VERSION}-%{RELEASE}' "$1"; }; \
    devel=(cmake gcc-c++ extra-cmake-modules \
      "libplasma-devel-$(v libplasma)" \
      "qt6-qtbase-devel-$(v qt6-qtbase)" \
      "qt6-qtdeclarative-devel-$(v qt6-qtdeclarative)"); \
    for f in kcoreaddons kconfig kpackage kwindowsystem kservice ki18n kguiaddons knotifications; do \
      devel+=("kf6-$f-devel-$(v "kf6-$f")"); \
    done; \
    dnf install -y --setopt=install_weak_deps=False "${devel[@]}"; \
    V="$(rpm -q --qf '%{VERSION}' plasma-desktop)"; \
    echo "Building Kickoff from quine-global/plasma-desktop, branch quine-v${V}"; \
    curl -fsSL --retry 3 -o /tmp/plasma-desktop.tar.gz \
      "https://forge.in.quineglobal.com/quine-global/plasma-desktop/archive/quine-v${V}.tar.gz" \
      || { echo "No branch quine-v${V} in quine-global/plasma-desktop: the image moved to Plasma ${V}; its rebase workflow makes the branch, or failed to (check its Actions)" >&2; exit 1; }; \
    mkdir -p /build-src; \
    tar -xzf /tmp/plasma-desktop.tar.gz -C /build-src --strip-components=2 \
      plasma-desktop/applets/kickoff; \
    cp /tmp/kickoff/CMakeLists.txt /build-src/; \
    cmake -S /build-src -B /build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr; \
    cmake --build /build -j"$(nproc)"; \
    DESTDIR=/out cmake --install /build --strip; \
    ls -l /out/usr/lib64/qt6/plugins/plasma/applets/org.kde.plasma.kickoff.so

# --- Builds libtaskmanager (the task manager's models) with our launch
# feedback (README, "Launch feedback"). taskmanager/build.sh: Fedora's own
# source of the plasma-workspace the image ships, plus
# taskmanager/startup-feedback.patch, -devel pinned like kickoff-builder's.
FROM updated AS taskmanager-builder

COPY taskmanager/ /tmp/taskmanager/
RUN /tmp/taskmanager/build.sh

# --- Rebuilds what's behind administrator password prompts (README,
# "Administrator prompts"): polkit-qt6-1, polkit-kde (the password dialog)
# and kio-admin (Dolphin's "Act as Administrator"), each from Fedora's own
# source RPM of the version the image ships, plus our patch in admin-auth/.
FROM updated AS admin-auth-builder

COPY admin-auth/ /tmp/admin-auth/
RUN /tmp/admin-auth/build.sh

# --- Python packages for our scripts (quine-app-updates), with uv. ---
# python/pyproject.toml lists them and python/uv.lock pins each version and
# its sdist's hash (`uv sync --frozen` refuses anything else). They go into
# a venv on the system's python3 at /usr/lib/quine-linux/python, which the
# scripts' shebangs name, so they don't depend on which python3-* RPMs the
# base happens to ship. Built FROM `updated`: compiled against the Python and
# GLib that ship. PyGObject and pycairo have no Linux wheels on PyPI, hence
# the compiler and -devel packages, which stay in this stage.
FROM updated AS python-builder

RUN dnf install -y --setopt=install_weak_deps=False uv gcc pkgconf-pkg-config \
      python3-devel gobject-introspection-devel cairo-devel cairo-gobject-devel

COPY python/pyproject.toml python/uv.lock /src/

RUN cd /src && \
    UV_PYTHON_DOWNLOADS=never UV_COMPILE_BYTECODE=1 UV_CACHE_DIR=/tmp/uv-cache \
    UV_PROJECT_ENVIRONMENT=/usr/lib/quine-linux/python \
      uv sync --frozen --no-dev --python /usr/bin/python3

# --- Final image. ---
FROM updated AS final

COPY overlay/ /

# alsa-tools provides hda-verb, used by cs8409-intmike-power-fixup.service.
RUN dnf install -y alsa-tools

# kdialog: update-confirm's "Keep this update / Roll back" prompt after an
# update (overlay/usr/libexec/quine-linux/update-confirm). Usually already in
# Kinoite; this makes sure.
RUN dnf install -y kdialog

# cloud-utils-growpart: growpart, which grow-root
# (quine-grow-root.service) grows the root partition with when the disk
# image is written to a bigger disk.
RUN dnf install -y cloud-utils-growpart

# The venv quine-app-updates runs on (python-builder, above): PyGObject, for
# GLib's key file parser, which it reads and writes Flatpak apps' menu
# entries with. The check makes sure gi comes from the venv.
COPY --from=python-builder /usr/lib/quine-linux/python/ /usr/lib/quine-linux/python/
RUN /usr/lib/quine-linux/python/bin/python3 -c \
      'import gi; from gi.repository import GLib; assert gi.__file__.startswith("/usr/lib/quine-linux/python/"), gi.__file__; print("PyGObject", gi.__version__, "from", gi.__file__)'

# calligra-words, tailscale, teamviewer: NOT baked in here -- layer-wizard
# (already installed below) ships them as built-in recipes instead, so
# they're install-on-demand per machine rather than forced onto every
# system, and the recipes work on any rpm-ostree bootc system running
# layer-wizard, not just this image.

# Removes apps from the base image's default set that don't belong in ours.
# Native RPMs: plasma-welcome (Welcome Center), Sunshine (game-stream host),
# KDE Connect (phone pairing: notifications, files and clipboard between a
# phone and the computer; kde-connect, its daemon and libs, which nothing
# else needs), KDebugSettings (turns Qt debug-log categories on and off; a
# developer tool), KWalletManager (browses the wallet's saved passwords; the
# wallet itself, kwalletd, stays, and so do the apps that use it).
RUN dnf remove -y plasma-welcome Sunshine kde-connect kdeconnectd kde-connect-libs \
      kdebugsettings kwalletmanager5

# Falkon on the taskbar: pinned after the browser in Aurora's panel layout
# (both of its look-and-feel themes), for new users. Users who already have
# a panel get it from a Plasma update script
# (overlay/usr/share/plasma/shells/org.kde.plasma.desktop/contents/updates/91-quine-pin-falkon.js).
RUN set -eux; \
    for f in /usr/share/plasma/look-and-feel/dev.getaurora.*/contents/layouts/org.kde.plasma.desktop-layout.js; do \
      grep -q '"preferred://browser",' "$f"; \
      sed -i 's|^\( *\)"preferred://browser",$|&\n\1"applications:org.kde.falkon.desktop",|' "$f"; \
      grep -q '"applications:org.kde.falkon.desktop",' "$f"; \
    done

# Our name, over Aurora's, in os-release: what the installer (its title and
# "Let's install ... now"), Plasma's About page and fastfetch show, and new
# installs' default hostname. Aurora's build (18-image-info.sh) wrote these;
# its version stays, as the image's build version. ID=aurora and
# VARIANT_ID stay too: Universal Blue's tooling (ujust, uupd, image-info)
# reads them.
RUN set -eux; \
    f=/usr/lib/os-release; \
    sed -i -e 's|^NAME=.*|NAME="Quine Linux"|' \
           -e 's|^PRETTY_NAME="Aurora|PRETTY_NAME="Quine Linux|' \
           -e 's|^DEFAULT_HOSTNAME=.*|DEFAULT_HOSTNAME="quine-linux"|' \
           -e 's|^HOME_URL=.*|HOME_URL="https://linux.quineglobal.com"|' "$f"; \
    grep -E '^(NAME|PRETTY_NAME|ID|DEFAULT_HOSTNAME|HOME_URL)=' "$f"; \
    grep -q '^NAME="Quine Linux"' "$f"; \
    grep -q '^PRETTY_NAME="Quine Linux' "$f"

COPY --from=kmod-builder /output/snd-hda-codec-cs8409.ko /tmp/snd-hda-codec-cs8409.ko

# Installs into .../extra/. That alone doesn't beat the in-tree copy under
# .../kernel/...: with no depmod config the two rank equally and depmod keeps
# whichever it reads first, which on the CI builders was the in-tree one
# (until 2026-11-21 every image shipped Fedora's driver). The overlay's
# usr/lib/depmod.d/quine-cs8409.conf makes extra/ win; the check below stops
# the build if it ever doesn't.
RUN set -eux; \
    NVR="$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}')"; \
    mkdir -p "/usr/lib/modules/${NVR}/extra"; \
    mv /tmp/snd-hda-codec-cs8409.ko "/usr/lib/modules/${NVR}/extra/snd-hda-codec-cs8409.ko"; \
    depmod -a "${NVR}"; \
    modinfo -k "${NVR}" -n snd-hda-codec-cs8409 | tee /dev/stderr \
      | grep -qx "/usr/lib/modules/${NVR}/extra/snd-hda-codec-cs8409.ko"

# Our own apps, from the forge's `quine` RPM group: each repo's rpm.yml
# builds and uploads them (quine-global/layer-wizard, dnf-package-store,
# swap-watchdog). The repo is only used here, not left configured: the apps
# update with the image. kdotool, which swap-watchdog drives, is Fedora's.
# Forgejo signs the repository metadata, not the packages, so dnf checks the
# metadata (repo_gpgcheck), which pins each package's checksum.
RUN dnf install -y \
      --repofrompath=quine,https://forge.in.quineglobal.com/api/packages/quine-global/rpm/quine \
      --setopt=quine.gpgcheck=0 --setopt=quine.repo_gpgcheck=1 \
      --setopt=quine.gpgkey=https://forge.in.quineglobal.com/api/packages/quine-global/rpm/repository.key \
      layer-wizard dnf-package-store swap-watchdog

# Kickoff with our update bar (kickoff-builder, above), over plasma-desktop's.
COPY --from=kickoff-builder /out/usr/lib64/qt6/plugins/plasma/applets/org.kde.plasma.kickoff.so \
     /usr/lib64/qt6/plugins/plasma/applets/org.kde.plasma.kickoff.so

# libtaskmanager with our launch feedback (taskmanager-builder, above), over
# plasma-workspace-libs': the same file name, which libtaskmanager.so.6 links to.
COPY --from=taskmanager-builder /out/usr/lib64/ /usr/lib64/

# polkit-qt6-1, polkit-kde and kio-admin with our patches (admin-auth-builder,
# above): the same versions as Fedora's, release <Fedora's>.quine, so they
# replace them as packages (rpm -V stays clean).
COPY --from=admin-auth-builder /out/ /tmp/admin-auth-rpms/
RUN dnf install -y /tmp/admin-auth-rpms/*.rpm && \
    rpm -q polkit-qt6-1 polkit-kde kio-admin | tee /dev/stderr | grep -c '\.quine\.' | grep -qx 3 && \
    rm -rf /tmp/admin-auth-rpms

# The start menu: the menu tree (menu/, README "The menu tree") becomes
# Plasma's menu file, and its names and .hidden go into the apps' menu
# entries. After every step that installs apps, so it sees them all.
COPY menu/ /usr/share/quine-linux/menu/
RUN /usr/libexec/quine-linux/build-menu && \
    grep -q quine-menu- /etc/xdg/menus/plasma-applications.menu

# System-level units are enabled explicitly.
# quine-update-check.timer: the status Kickoff's update bar shows.
# quine-data-disk-relabel.service: once, after an install with a data disk.
# quine-app-launchers.{path,service}: Flatpak apps' menu entries open through
# quine-app-updates, which updates an app as it opens (README "App updates on
# launch").
# quine-grow-root.service: the root fills its disk when the disk image was
# written to a bigger one (overlay/usr/libexec/quine-linux/grow-root).
RUN systemctl enable rpm-ostree-cleanup.timer cs8409-intmike-power-fixup.service \
      quine-update-check.timer quine-data-disk-relabel.service \
      quine-app-launchers.path quine-app-launchers.service quine-grow-root.service

# User units, for every user (links in /etc/systemd/user/). A preset file
# alone doesn't do it: nothing runs `systemctl --global preset` for files
# laid into the image. overlay/usr/lib/systemd/user-preset/90-quine-linux.preset
# lists the same. disk-cleanup.timer: weekly cleanup. ssh-agent.socket and
# gpg-agent.socket: both agents, socket-activated. gpg-agent's ssh socket
# (gpg-agent-ssh.socket) stays off, so SSH keys go to ssh-agent only.
# quine-app-launchers.{path,service}: the same as the system ones, for apps
# in the user's own Flatpak installation.
RUN systemctl --global enable disk-cleanup.timer ssh-agent.socket gpg-agent.socket \
      quine-app-launchers.path quine-app-launchers.service && \
    systemctl --global disable gpg-agent-ssh.socket && \
    test -L /etc/systemd/user/sockets.target.wants/ssh-agent.socket && \
    test -L /etc/systemd/user/sockets.target.wants/gpg-agent.socket && \
    test ! -e /etc/systemd/user/sockets.target.wants/gpg-agent-ssh.socket && \
    test ! -e /usr/lib/systemd/user/sockets.target.wants/gpg-agent-ssh.socket

# Last: the repo metadata the `updated` stage kept for the build's stages,
# and anything since. Not part of the system.
RUN dnf clean all && rm -rf /var/cache/libdnf5
