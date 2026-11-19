# --- Quine Linux Stateful Edition (stateful/kiwi/config-quine.sh) ---
# build-in-container.sh puts this at the end of Fedora's config.sh, before its
# final `exit 0`: it runs inside the image after Fedora's own setup.
set -euxo pipefail

# Our identity: quine-linux-release, not Fedora's KDE one.
grep -q '^NAME="Quine Linux"' /usr/lib/os-release

# The menu tree: quine-linux-desktop's file trigger already ran it when the
# packages went in; once more, so the image's menu is the tree's for certain.
/usr/libexec/quine-linux/build-menu

# User units ours turns on for every user (quine-linux-desktop's preset;
# nothing runs `systemctl --global preset` for a fresh image).
systemctl --global preset ssh-agent.socket gpg-agent.socket gpg-agent-ssh.socket \
  quine-app-launchers.path quine-app-launchers.service
systemctl enable quine-app-launchers.path quine-app-launchers.service

set +euxo pipefail
# --- end of Quine Linux Stateful Edition ---
