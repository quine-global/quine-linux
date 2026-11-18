# Testing a build on a Proxmox VM

`.forgejo/vm-test.sh` puts a Quine Linux build on zeus's test VM, **107**
(`quine-live-test`: UEFI, q35, a 64 GB system disk and a 100 GB second
one), boots it and waits for it to come up. Everything goes through
Proxmox's API, with a token that can do nothing else. Two kinds:

- **`disk`** (the default): the build's **disk image**, the installed
  system (`disk/latest/disk.qcow2`, or a release's
  `quine-linux-<tag>-x86_64.qcow2`), becomes the VM's system disk. The VM
  starts at Plasma's first-start setup, where you create the account.
- **`live`**: the **live ISO** (`live/latest/live.iso`, or a release's
  `quine-linux-<tag>-live-x86_64.iso`) on the VM's CD, booted from: the
  live desktop and the installer. The system disk is left alone, to
  install onto; the second disk has an ext4 partition labelled `data`,
  for the installer's Data disk step.

How to run it:

- **From Forgejo:** Actions → **VM test** → Run workflow, with a release tag
  (`v0.1.1-alpha.1`) or `latest` (the last build of `main`), and the kind.
- **From a laptop on the tailnet:** `task vm` (short for `task test:vm`)
  puts the newest build's disk image on it; `task vm TAG=v0.1.2` a
  release's, `task vm KIND=live` the live ISO. No secrets to set: without
  `PVE_TOKEN` the script makes the same calls as `pvesh` over root SSH to
  zeus (`PVE_SSH`), and for `latest` it reads quine-linux's own MinIO keys
  over SSH from the forge VM (`MINIO_SSH`), unless `RCLONE_CONFIG_STORE_*`
  (as in `iso.yml`) or `URL` is set. rclone comes from nixpkgs if it isn't
  installed.

## What it does

1. Picks the file: a release's public one, with its checksum from the
   release's `SHA256SUMS`, or for `latest` a 3-hour presigned link to MinIO.
2. Stops VM 107 and has Proxmox download the file straight from MinIO
   (checked against the checksum for a release).
3. **disk:** imports the image as a new system disk (`virtio0` on
   `local-lvm`, keeping the old one's options), deletes the old disk,
   grows the new one to 64 GB (`DISK_SIZE`; the root grows to fill it at
   boot, `quine-grow-root.service`), detaches the CD, boots from the disk,
   and deletes the downloaded image. **live:** puts the ISO
   (`local:iso/quine-linux-live-test.iso`) on the CD and boots from it.
   Both enable the QEMU guest agent's channel and start the VM.
4. Waits (15 minutes at most) for the guest agent to answer: Fedora's
   `qemu-guest-agent` is in the image (Kinoite's `packages/common.yaml`).
   It passes when it does, and reports the OS and kernel the guest gives,
   in the job summary too. It fails if the agent never answers: look at
   the VM's console in Proxmox.

The VM stays running afterwards, to look at in Proxmox's console.

## The token (once, on zeus)

A user with no password and a token, allowed only what the script calls
(each from Proxmox's own permission checks):

| Where | Privileges | For |
|---|---|---|
| `/vms/107` | `VM.Audit`, `VM.PowerMgmt`, `VM.Config.CDROM`, `VM.Config.Options`, `VM.Config.Disk`, `VM.GuestAgent.Audit` | status, stop/start, the CD, the system disk and boot order, the agent, asking the guest its OS |
| `/storage/local` | `Datastore.AllocateTemplate`, `Datastore.Allocate`, `Datastore.Audit` | downloading the ISO or disk image; deleting the old one |
| `/storage/local-lvm` | `Datastore.AllocateSpace`, `Datastore.Audit` | the new system disk; deleting the old one |
| `/nodes/zeus` | `Sys.AccessNetwork` | Proxmox downloading from a URL |

`Datastore.Allocate` on `local` also allows deleting anything else stored
there (ISOs, templates): Proxmox has no narrower right for deleting a file.
`VM.Config.Disk` lets it change VM 107's disks, which `disk` does; it's
only granted on VM 107.

```sh
pveum role add QuineVMTest -privs "VM.Audit VM.PowerMgmt VM.Config.CDROM VM.Config.Options VM.Config.Disk VM.GuestAgent.Audit"
pveum role add QuineVMTestStorage -privs "Datastore.AllocateTemplate Datastore.Allocate Datastore.Audit"
pveum role add QuineVMTestDisk -privs "Datastore.AllocateSpace Datastore.Audit"
pveum role add QuineVMTestNode -privs "Sys.AccessNetwork"
pveum user add quine-ci@pve --comment "Forgejo: quine-linux's VM test (docs/VM_TEST.md)"
pveum user token add quine-ci@pve vm-test --privsep 0 --comment "quine-linux VM test"
pveum acl modify /vms/107 -user quine-ci@pve -role QuineVMTest
pveum acl modify /storage/local -user quine-ci@pve -role QuineVMTestStorage
pveum acl modify /storage/local-lvm -user quine-ci@pve -role QuineVMTestDisk
pveum acl modify /nodes/zeus -user quine-ci@pve -role QuineVMTestNode
```

An existing setup from before the disk image (no `VM.Config.Disk`, no
`local-lvm`) needs only the change:

```sh
pveum role modify QuineVMTest -privs "VM.Audit VM.PowerMgmt VM.Config.CDROM VM.Config.Options VM.Config.Disk VM.GuestAgent.Audit"
pveum role add QuineVMTestDisk -privs "Datastore.AllocateSpace Datastore.Audit"
pveum acl modify /storage/local-lvm -user quine-ci@pve -role QuineVMTestDisk
```

`token add` prints the secret once. Store it as the quine-global (or
quine-linux) Actions secret **`PVE_TOKEN`**, in the form
`quine-ci@pve!vm-test=<secret>`.

## VM 107

It was made by hand (its description says so), not in tofu. If it stays as
the test VM, it belongs in `terraform/modules/zeus` like the others.
