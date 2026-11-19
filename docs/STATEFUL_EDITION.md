# Quine Linux Stateful Edition: plan

A second edition of Quine Linux built like **Fedora's KDE Plasma Desktop
Edition**: an ordinary, writable Fedora system that installs and updates
packages with dnf, rather than a bootc image that's replaced whole. It
should look and behave like today's Quine Linux (our apps, menu, Flatpaks,
installer, fixes). Only how the system is put together and updated
changes.

Status: **plan**. Nothing below is built yet.

Today's edition, the bootc image, is the **Home Edition**.

## Upstream: how Fedora makes its KDE Edition

All of these are on Fedora's forge (forge.fedoraproject.org). Pagure is
retired for these repos.

- **releng/kiwi-descriptions:** the image definitions. KIWI (not
  lorax/livemedia-creator any more) builds every Fedora image from
  `Fedora.kiwi`. It has one branch per release, and `rawhide`.
  - `teams/kde.xml` has two profiles, `KDE-Desktop-Live` (the ISO,
    `--image-type=iso`) and `KDE-Desktop-Disk` (a disk image, `oem`).
    It adds `fedora-release-kde` and `plasma-welcome-fedora`.
  - `components/desktops/kde.xml` (profile `KDE-Desktop`) installs these
    comps groups:
    - `kde-desktop-environment`, `kde-apps`, `kde-media` and `kde-pim`;
    - `firefox` and `libreoffice`;
    - plus `kde-l10n` and `fuse`.

    It also ignores a list of packages (`gnome-disk-utility`, `tracker`,
    `k3b`, `ktorrent`, `initial-setup` and others).
  - `components/liveinstall.xml` builds the live ISO:
    - erofs (lzma) and dmsquash, UEFI with GPT;
    - Anaconda (`anaconda-live`, `anaconda-webui` through comps), plus
      `livesys-scripts`.

    `components/boot.xml` builds the disk image: btrfs with root as a
    subvolume, `compress=zstd:1`, `x-systemd.growfs`, and ext4 `/boot`.
  - `config.sh`, the post-install script, covers every profile. For KDE it
    sets `livesys_session="kde"`. It doesn't enable initial-setup:
    `plasma-setup` creates the first account instead.
  - The image is built with `sudo ./kiwi-build --kiwi-file=Fedora.kiwi
    --image-type=iso --image-profile=KDE-Desktop-Live --output-dir …`, on
    Fedora, with `kiwi kiwi-systemdeps distribution-gpg-keys`. The tmt
    plans in `tmt/plans/desktop/kde/` do exactly that.
- **releng/fedora-comps:** the package groups. The current one is
  `comps-f46.xml.in`. `kde-desktop` has 93 packages. As of F46 they include
  `plasma-login-manager` (replacing SDDM), `plasma-setup`, `kde-connect`,
  `flatpak-kcm` and `fedora-flathub-remote`.
- **kde/kde-settings:** Fedora's Plasma defaults (the
  `fedoradark`/`fedoralight` look-and-feel, the kickoff favourites file, the
  kde-profile). Aurora's defaults sit on top of these today. In the Stateful
  Edition, ours do.

What this means for us: Fedora's KDE Edition is a KIWI profile plus comps
groups plus a release package. We can build **our** edition the same way,
starting from Fedora's descriptions instead of Aurora's image.

## The one big difference

On the Home Edition, the image *is* the system: every change ships in
the next image, and `bootc` swaps it in, with rollback for free.

On a stateful system, **the ISO only matters on day one.** After that,
the only way to change an installed machine is through packages. So:

> Everything we change has to ship as an RPM, from a Quine repo that every
> installed machine keeps enabled.

A `RUN sed …` in a Containerfile has no stateful equivalent. Each one
becomes a file in a package, or a package trigger.

## Our changes, one by one

| Today (Home Edition) | Stateful Edition |
|---|---|
| `overlay/` (Flatpak preinstalls and remote, kwin rules, gitconfig, journald cap, disk-cleanup, ssh/gpg agents, quine-app-updates and its launchers) | **`quine-linux-desktop` RPM**: the same files, from a spec in this repo. Most of the overlay works unchanged on plain Fedora |
| The menu tree (`menu/`, `build-menu`) | In `quine-linux-desktop`. `build-menu` becomes a **file trigger** (`%transfiletriggerin` on `/usr/share/applications`), so the menu updates whenever a package adds an app. That matters more here, because people install RPMs all the time |
| Name in os-release, our repos and keys | **`quine-linux-release`**, in place of `fedora-release-kde`. `ID=fedora` stays, so dnf and Fedora tooling keep working. `NAME="Quine Linux"`, `VARIANT="Stateful Edition"` |
| Kickoff (plasma-desktop fork), libtaskmanager (plasma-workspace), polkit-qt6-1, polkit-kde, kio-admin, all patched | **Full rebuilt RPMs** (`.quine` release), in our repo with a **higher dnf priority** than Fedora's. When Fedora updates Plasma, machines wait for our rebuild instead of replacing our patched packages with Fedora's. This needs a **rebuild bot** (below) |
| layer-wizard, dnf-package-store, swap-watchdog (installed at build time only) | Our `quine` RPM repo stays **enabled on installed machines**, so they update with dnf. **layer-wizard is dropped**: it layers onto rpm-ostree, and on a stateful system you just install. dnf-package-store does that |
| KeyMaker and Quple Flatpaks, flatpak.quineglobal.com | Unchanged |
| cs8409 kmod, built for the image's one kernel | Kernels update on their own here, so this becomes an **akmod** (`akmod-snd-hda-codec-cs8409`), rebuilt at boot for each new kernel. With Secure Boot, akmods signs the module with a machine-local key that needs a MOK enrollment, but only on that iMac |
| Updates: uupd, `update-confirm` / `update-rollback`, bootc rollback | **As Fedora KDE does:** Discover/PackageKit offline updates, downloaded in the background and applied on restart. **No snapshots or rollback** (Fedora KDE has none), so `update-confirm`, `update-rollback` and "Keep this update / Roll back" aren't part of this edition |
| Kickoff's update bar (`update-check` reads bootc status) | `update-check` asks PackageKit whether an offline update is ready. Same bar, different source |
| `grow-root`, `rpm-ostree-cleanup`, ujust, brew, Universal Blue units | Dropped. KIWI's disk image grows itself (`x-systemd.growfs`), and the rest is atomic-only or Universal Blue's |
| Live ISO: titanoboa, our MokManager fix, Anaconda web UI with the Data disk step | **KIWI's live ISO** (`KDE-Desktop-Live` plus our profile). The Data disk step stays: `anaconda-webui` rebuilt with `steps.patch`, from our repo. Fedora's signed shim and kernel boot without our MOK |
| `ID=aurora`, `VARIANT_ID` kept for Universal Blue tooling | Not needed. The installer profile keys on `ID=fedora` and our variant |

## How it's built

- **`stateful/` in this repo:**
  - `quine.kiwi` includes Fedora's descriptions, pinned to the release
    branch as a git submodule or a fetched tag. It adds a
    `Quine-Stateful-Live` profile (and `-Disk`) that `requires` Fedora's
    `KDE-Desktop` and layers ours on top: our release package, our repo,
    `quine-linux-desktop`, the rebuilt packages, ignores (KDE Connect,
    plasma-welcome, Sunshine, as today), and Audacity and friends through
    Flatpak preinstall.
  - Our own `config.sh` additions for live-session-only tweaks (what
    `live/build.sh` does today).
- **`packaging/` in this repo:** spec files for `quine-linux-release`,
  `quine-linux-desktop` and the akmod. The rebuilt Fedora packages reuse
  what `admin-auth/build.sh` and `taskmanager/build.sh` already do (the
  installed version's SRPM, plus our patch, plus `.quine`), but produce
  whole RPMs instead of files copied into an image.
- **CI** (`.forgejo/workflows/stateful.yml`), on the same runners:
  - RPMs go to the forge's RPM registry, in a new group
    (`quine-stateful`), signed.
  - KIWI builds the ISO and disk image in a privileged
    `registry.fedoraproject.org/fedora:<ver>` container (KIWI needs loop
    devices; podman on the NixOS runners can do `--privileged`).
  - Outputs go to MinIO under `quine-linux/stateful/`.
  - The Home Edition's 3-hour build doesn't apply. A KIWI ISO is roughly
    30–60 minutes. Plasma rebuilds cost more but only run when Fedora
    updates.
- **Rebuild bot:** a scheduled job compares Fedora's current versions of
  our five patched packages with our repo's. When Fedora is newer, it
  rebuilds and publishes. If the patch no longer applies, the job fails and
  says so (like the image build does today), and machines keep the
  previous Plasma until it's fixed. They never end up on an unpatched one.
- **VM test:** a second VM on zeus (e.g. 108) with the same
  `vm-test.sh` flow, given the KIWI disk image (`oem`) or the ISO.

## Disk space (estimates, before phase 1 measures them)

- **Per build, on a runner, freed afterwards:** about 25–30 GB per
  architecture. That covers KIWI's root tree (~8–10 GB for KDE with
  LibreOffice and PIM), the ISO (~3 GB), the raw disk image (~10–12 GB)
  and dnf's cache (~2–3 GB). The x86 runner has ~125 GB free. The arm64
  runner's 54 GB root disk is the tight one: KIWI's work directory should
  go on its 49 GB containers disk.
- **Plasma rebuilds:** a few GB of build tree, freed after each one.
- **Kept, in MinIO:** as for the Home Edition, each build overwrites
  `latest`: ~6 GB per architecture (the ISO, plus the compressed disk
  image), so ~12 GB in all, plus ~12 GB per release.
- **No container images.** KIWI's output is the ISO and the disk image, so
  the forge's container registry, which is where the Home Edition's disk
  space goes (every build's image is kept, and the weekly Forgejo dump
  includes it), doesn't grow.
- **Kept, in the forge's RPM registry:** under 1 GB per architecture for a
  few versions of our rebuilt packages.
- **VM 108 on zeus:** 64 GB thin-provisioned, ~10–15 GB really used.
  zeus's local-lvm has ~345 GB free.

## Phases

1. **Build Fedora's own KDE Edition with KIWI on our runner, unchanged.**
   This proves the tooling (privileged podman, loop devices, erofs)
   before any of ours is involved. Boot it on VM 108.
2. **Branded and ours:** `quine-linux-release`, our repos enabled,
   `quine-linux-desktop` (overlay, menu tree with its trigger, Flatpaks),
   our apps from the `quine` repo, removals. The ISO installs a system
   that then updates with plain dnf.
3. **Patched packages:** the rebuilt Plasma/polkit/kio-admin RPMs, repo
   priority, and the rebuild bot.
4. **Updates:** Fedora KDE's offline updates, and the Kickoff update bar
   reading PackageKit.
5. **Installer and hardware:** the Data disk step in the stateful
   installer, the cs8409 akmod, arm64, and a release flow (`stateful-v*`
   tags) next to the Home Edition's.

After phase 2 there's a usable system. Phases 3–5 bring it to parity.

## A bonus: one source for both editions

Once our changes are RPMs, the Home Edition could install the same
`quine-linux-desktop` and rebuilt packages instead of copying `overlay/`
and `.so` files into the image. Both editions would then get each fix from
one place. That isn't required for the Stateful Edition, but packaging
choices should leave the door open.

## Decided

- Today's edition is the **Home Edition** (its os-release `VARIANT` and
  download names follow when the Stateful Edition ships).
- **Updates as Fedora KDE does them**, with no snapshots or rollback.

## Open questions

- **Apps as RPMs or Flatpaks:** Fedora KDE ships Firefox and LibreOffice
  as RPMs. Keep Fedora's RPMs, or match the Home Edition's Flatpaks
  (Firefox, Falkon, Audacity…)?
- **Fedora version:** the current stable release (like the Home Edition's
  "bleeding edge" packages, which dnf gives anyway), not Rawhide?
- **One forge RPM group or two:** do the Home Edition's `quine` group and
  the stateful packages share one repository?
