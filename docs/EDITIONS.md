# One manifest for both editions: sketch

**Status: a proposal, not built.**

Today the Home Edition is described by its `Containerfile` and the
Stateful Edition by `stateful/kiwi/quine/quine.xml`, `config-quine.sh` and
`quine-linux-desktop.spec`. The two repeat each other: the same package
installs and removals, Flatpaks, services and menu tree, written twice in
two formats. The proposal is one file, `editions.toml`, saying what each
edition is made of. Each build reads it, and only the parts that really
differ stay edition-specific (the base, how the image is assembled, how it
updates).

## The file

```toml
# editions.toml: what each Quine Linux edition is made of. Both builds
# read it (Containerfile: `editions/apply home`; stateful/: KIWI's package
# lists are generated from it). [common] is in both; an edition's own
# lists add to it, and `drop` takes things out of common for that edition.

[common]
# Packages from Fedora, or from Quine Linux's repo
# (packages.quineglobal.com/quine-linux/rpm/).
packages = [
  "quine-linux-desktop",   # overlay/ + menu/ as an RPM (stateful/packaging)
  "dnf-package-store",
  "swap-watchdog",
  "kdialog",
]
# Not in either edition.
remove = ["plasma-welcome", "kde-connect", "kdeconnectd", "kde-connect-libs"]
# Fedora's own packages rebuilt with our patches, at the version each
# edition's Fedora has (admin-auth/build.sh, taskmanager/, kickoff/).
rebuilt = [
  { package = "polkit-qt6-1", patch = "admin-auth/polkit-qt-1.patch" },
  { package = "polkit-kde",   patch = "admin-auth/polkit-kde.patch" },
  { package = "kio-admin",    patch = "admin-auth/kio-admin.patch" },
  { package = "plasma-desktop",   source = "forge:quine-global/plasma-desktop@quine-v{plasma}" },
  { package = "plasma-workspace", patch = "taskmanager/startup-feedback.patch" },
]
# Flatpaks installed on first boot (flatpak-preinstall).
flatpaks = [
  "org.kde.falkon", "com.fastmail.Fastmail", "io.github.tobagin.karere",
  "org.audacityteam.Audacity", "io.github.tobagin.keysmith",
  "com.quineglobal.Quple", "org.kde.kclock", "org.kde.qrca",
]
menu = "menu/"
services      = ["quine-app-launchers.path", "quine-app-launchers.service"]
user-services = ["ssh-agent.socket", "gpg-agent.socket",
                 "quine-app-launchers.path", "quine-app-launchers.service"]
os-release = { NAME = "Quine Linux" }

[home]
kind = "bootc"                         # Containerfile, bootc-image-builder, titanoboa
base = "forge.in.quineglobal.com/quine-global/aurora:stable"
packages = ["layer-wizard", "cloud-utils-growpart", "alsa-tools"]
remove   = ["Sunshine"]
flatpaks = ["org.mozilla.firefox"]
kmods    = ["patches/snd-hda-codec-cs8409"]
services = ["rpm-ostree-cleanup.timer", "quine-update-check.timer",
            "quine-grow-root.service", "quine-data-disk-relabel.service",
            "cs8409-intmike-power-fixup.service"]
user-services = ["disk-cleanup.timer"]
os-release = { VARIANT = "Home Edition", keep = ["ID", "VARIANT_ID"] }  # ID=aurora

[stateful]
kind = "kiwi"                          # Fedora's KIWI descriptions + ours
base = { fedora = 45, profile = "KDE-Desktop" }   # stateful/fedora.env's pin
# Fedora KDE ships Firefox and LibreOffice as RPMs: nothing to add.
os-release = { VARIANT = "Stateful Edition", keep = ["ID", "VARIANT_ID"] }  # ID=fedora, VARIANT_ID=kde
```

## How each build reads it

- **One small tool, `editions/`** (Python's `tomllib`, already in both
  build environments):
  - `editions/resolve <edition>` prints the merged lists: common, plus the
    edition's own, minus its `drop`.
  - `editions/apply <edition>` does them on a running system: `dnf install`,
    `dnf remove`, the preinstall file, `systemctl enable`, os-release.
- **Home Edition:** the Containerfile's separate `RUN dnf install …`,
  `dnf remove …`, `systemctl enable …` and os-release `sed` become one
  `RUN editions/apply home`. Its builder stages (kickoff, taskmanager,
  admin-auth) build the `rebuilt` list as RPMs, which are installed the
  same way. Today they copy `.so` files in instead.
- **Stateful Edition:**
  - `build-in-container.sh` generates `quine.xml`'s `<package>` and
    `<ignore>` lists from `resolve stateful`, and builds the `rebuilt` list
    for Fedora 45.
  - `config-quine.sh` runs `editions/apply stateful --services-only` for
    the units.
- **quine-linux-desktop** stops filtering the preinstall file in its
  spec. The preinstall file is generated from `flatpaks`, so Firefox's
  Flatpak simply isn't in the Stateful Edition's list.
- **A check in both builds:** after building, `editions/verify <edition>`
  checks the result has every package and service, and none of the
  removed ones (`rpm -q`, `systemctl is-enabled`). That catches a base
  update that quietly adds something back.

## What stays edition-specific

| | Home | Stateful |
|---|---|---|
| Base | Aurora's bootc image | Fedora's KDE KIWI profile |
| Assembling | Containerfile layers | KIWI installs into an empty root |
| Installer | titanoboa's live ISO + our MokManager fix | KIWI's live ISO |
| Updates | bootc images, update-confirm and rollback | dnf, as Fedora KDE |
| Kernel modules | built once for the image's kernel | an akmod, per kernel |

These are the parts the manifest names (`kind`, `base`) but doesn't
describe. Each stays in its own directory (`live/`, `stateful/`).

## Order of work

1. `quine-linux-desktop` and the rebuilt packages published to Quine Linux's
   repo (packages.quineglobal.com), and the Home Edition installing them
   instead of copying `overlay/` and `.so` files. Both editions then get
   the same bits.
2. `editions.toml` and `editions/resolve` / `apply`, with the Containerfile
   switched over first. Its result should be byte-for-byte the same image
   contents, which `verify` and a diff of `rpm -qa` show.
3. The Stateful Edition's KIWI lists generated from it.
