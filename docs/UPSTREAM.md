# Keeping up with upstream

Quine Linux is built from other people's moving parts. This is how they
move, what that breaks, and how we've chosen to live with it: bleeding
edge, fixing forward. At the end: what we'd do instead if we wanted to be
stable.

## The layers

| Layer | What it gives us | How it moves |
|---|---|---|
| **Fedora** | Every package, and the source for each | Updates go stable in batches through Bodhi, most days. Mirrors pick each push up over the following hours. |
| **Universal Blue / Aurora** (our fork, `quine-global/aurora`) | A tested image: Kinoite plus Aurora's package set, and a signed kernel with prebuilt modules (akmods) | `stable` is a snapshot, rebuilt on Aurora's schedule after its own testing. It trails Fedora by days. |
| **Us** (`Containerfile`) | Our overlay, our apps, and patched builds of parts of Plasma (Kickoff, libtaskmanager) and of a kernel module (CS8409) | Every push to `main` and daily, published straight to every machine. |

Each layer is fine on its own. The trouble is where they meet, because they
move at different speeds.

## What goes wrong

### Lagging: the base is older than its source

We don't just install things on top of Aurora: we rebuild pieces of it with
our patches, and a rebuilt piece has to match the rest exactly. Our
libtaskmanager replaces one file inside Plasma, and only works against the
Plasma it was built from. So the builder needs the source and `-devel`
packages of *exactly* the version in the image.

When Aurora's `stable` trails Fedora, that version is no longer Fedora's
newest, and Fedora's repos keep only the newest. Binaries get a second life
in `updates-archive`; **source packages get none**. On 2026-11-15 the image
had Plasma 6.8.2 while Fedora had moved to 6.8.3, `dnf download --source`
found nothing (and still exited 0), and the build broke.

### Too soon: two parts of one build see different worlds

A Fedora push reaches mirrors over hours. Two downloads minutes apart can
hit two mirrors, one with the push and one without. On 2026-11-16 one stage
of our build upgraded to Plasma 6.8.3 from a current mirror, and the next
stage asked a stale one for the matching `-devel` packages, which it didn't
have yet.

### Pinning: a pin holds still while the world moves

Pinning (an exact version, a digest, a snapshot) makes builds repeatable,
but a pin rots. What it points to disappears upstream (see above), security
fixes wait until someone bumps it, and the longer it sits, the bigger and
riskier the eventual bump. A pin is only as good as the archive behind it.

### Old versions are hard to get back

| Thing | Kept? |
|---|---|
| Fedora binary RPMs | Newest in `updates`; older in `updates-archive` |
| Fedora source RPMs | **Newest only.** No archive repo |
| Fedora builds of any version | Koji (`kojipkgs.fedoraproject.org`), every build, binaries and sources, but as files, not a repo |
| KDE release tarballs | `download.kde.org`, indefinitely |
| Container tags (`aurora:stable`) | Move; old digests vanish once nothing refers to them |
| Our Pulp mirrors | Today they mirror upstream exactly (`mirror_content_only`), so they drop old versions when upstream does |

## Our strategy: bleeding edge, fix forward

1. **Track Fedora's latest, every build.** The `Containerfile`'s first stage,
   `updated`, upgrades Aurora to Fedora's newest packages before anything
   else. What we ship is never older than Fedora, so whatever we need the
   source of is always in Fedora's repos. Shipping combinations Aurora
   hasn't tested yet is accepted: what breaks, we fix.
2. **Except the kernel.** It comes signed from Universal Blue together with
   its prebuilt modules; upgrading it alone would break them. It moves when
   Aurora's `stable` moves.
3. **One snapshot per build.** The `updated` stage keeps its repo metadata,
   so every later stage resolves against the same picture of Fedora
   instead of whichever mirror it lands on. The final stage throws it away.
4. **Build our patches against exactly what ships.** Every builder stage
   starts `FROM updated`, and pins its `-devel` packages to the installed
   versions. If a new Plasma moves the code a patch touches, the build stops
   and says so; we update the patch.
5. **When something old is needed anyway, go to the source of record.** The
   libtaskmanager build falls back to Koji for a source RPM the repos no
   longer carry.
6. **Fix forward, fast.** A daily build means breakage shows up within a day
   of the upstream change that caused it, while the change is small and
   fresh. Users get the same speed in reverse: every fix reaches every
   machine on its next update. Their safety net is bootc: the previous
   system stays installed, and `update-confirm` offers to roll back after an
   update.

The price: we ship what nobody has tested together before, our users find
some of the problems before we do, and a bad upstream day becomes our bad
day. For a system that wants new hardware support and new Plasma features
the week they land, that's the trade we've chosen.

## If we wanted to be stable instead

The same building blocks, used to hold still and move deliberately:

1. **Build from snapshots, not live mirrors.** Point every build's dnf at
   Pulp (`pulp.in.quineglobal.com`, which already mirrors Fedora, its source
   repos, and the COPRs and other repos Aurora uses), and build against a
   *named repository version* instead of whatever synced last. A build is
   then repeatable: the same commit and the same snapshot give the same
   image.
2. **Keep the past.** Switch Pulp's sync policy from `mirror_content_only`
   to `additive`, so a package stays once we've seen it, source RPMs
   included. That's the archive Fedora doesn't keep for sources. Raise
   `retain_repo_versions` and budget the disk for it.
3. **Mirror what we patch.** Forge mirrors of `plasma-workspace` (like our
   `plasma-desktop` fork for Kickoff) give us any version's source,
   permanently, from our own infrastructure.
4. **Two channels.** Builds of the latest go to a `testing` tag. A build is
   promoted to `stable`, which is what installed systems follow, only after
   the VM test passes and it has run on our own machines for a while.
   Promotion re-tags the already-built image: nothing is rebuilt.
5. **Follow Aurora instead of overtaking it.** Drop the `updated` stage,
   or limit it to `dnf upgrade --security`, so we ship Aurora's tested
   package set plus security fixes.
6. **Bump on purpose.** Snapshot moves become reviewed changes, like the
   image pins in petersweb-infra: a PR that says what changed, tested
   before it merges.

Most of this infrastructure already exists (Pulp, the forge's registry and
mirrors, the VM test). Being stable would mostly mean wiring the build to
it and adding the promotion step, at the cost of shipping new upstream work
later and maintaining the archive.
