/*
 * quine-linux: the "Data disk" step. Optionally keeps home folders, Flatpak
 * apps, containers (and a swap file) on a second disk, e.g. a large hard
 * disk next to a small SSD, the way the iMac is set up. The system itself
 * still goes where the storage step put it.
 *
 * The choice is written to /run/quine-data-disk.json ({device, name, label,
 * uuid}, or no file for "no data disk"). The kickstart %post data-disk.ks
 * (live/build.sh) reads it after installing: mounts the partition at
 * /var/hdd and binds what's on it into place, reusing an existing layout
 * (home-<user>/, flatpak/, podman-storage/, swapfile) or creating one.
 * The partition is never formatted: its files stay.
 *
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */
import cockpit from "cockpit";

import React, { useContext, useEffect, useMemo, useState } from "react";
import { Alert } from "@patternfly/react-core/dist/esm/components/Alert/index.js";
import { Content } from "@patternfly/react-core/dist/esm/components/Content/index.js";
import { Form, FormGroup } from "@patternfly/react-core/dist/esm/components/Form/index.js";
import { Radio } from "@patternfly/react-core/dist/esm/components/Radio/index.js";

import { StorageContext } from "../../contexts/Common.jsx";
import { useOriginalDevices } from "../../hooks/Storage.jsx";

const _ = cockpit.gettext;
const SCREEN_ID = "quine-screen-data-disk";
const CHOICE_FILE = "/run/quine-data-disk.json";
const FILESYSTEMS = ["ext4", "xfs", "btrfs"];
// Labels that mark a partition meant for this (the iMac's is "hdd").
const DATA_LABELS = ["hdd", "data", "quine-data"];

const attr = (device, key) => device?.formatData?.attrs?.v?.[key] || "";
const diskOf = (devices, device) => {
    let d = device;
    // A partition's parent is its disk; follow until a device without parents.
    while (d?.parents?.v?.length) {
        d = devices[d.parents.v[0]];
    }
    return d;
};

export const DataDisk = ({ setIsFormValid }) => {
    const devices = useOriginalDevices();
    const { diskSelection } = useContext(StorageContext);
    const selectedDisks = useMemo(() => diskSelection?.selectedDisks || [], [diskSelection]);

    // Filesystems that could hold the data: one per partition (a btrfs
    // partition's subvolumes all have its path, and the install mounts the
    // path), and only on disks the system isn't going to, which it erases.
    const candidates = useMemo(() => {
        const byPath = new Map();
        Object.values(devices || {})
                .filter(d => FILESYSTEMS.includes(d.formatData?.type?.v))
                .filter(d => !(d.children?.v?.length))
                .forEach(d => {
                    const disk = diskOf(devices, d);
                    if (selectedDisks.includes(disk?.name?.v) || byPath.has(d.path.v)) {
                        return;
                    }
                    byPath.set(d.path.v, {
                        path: d.path.v,
                        size: d.size.v,
                        fs: d.formatData.type.v,
                        label: attr(d, "label"),
                        uuid: attr(d, "uuid"),
                        diskDescription: disk?.description?.v || "",
                    });
                });
        return [...byPath.values()].sort((a, b) => a.path.localeCompare(b.path));
    }, [devices, selectedDisks]);

    // The partition to suggest: one labelled for this ("data", "hdd"), else
    // the largest. With one, the second disk is what's chosen to begin with:
    // a second disk is what this step is for.
    const suggested = useMemo(() => (
        candidates.find(c => DATA_LABELS.includes(c.label.toLowerCase())) ||
        [...candidates].sort((a, b) => b.size - a.size)[0]
    ), [candidates]);
    const [useDisk, setUseDisk] = useState(false);
    const [chosen, setChosen] = useState("");
    // The disks are read after the page first draws, so the suggestion is
    // applied when they arrive, unless a choice has been made by then.
    const [touched, setTouched] = useState(false);
    useEffect(() => {
        if (!touched && suggested) {
            setUseDisk(true);
            setChosen(suggested.path);
        }
    }, [touched, suggested]);
    const chosenCandidate = candidates.find(c => c.path === chosen);
    // Using the disk with nothing (or something gone, after going back to
    // change the system disk) chosen: the suggestion.
    useEffect(() => {
        if (useDisk && !chosenCandidate && suggested) {
            setChosen(suggested.path);
        }
    }, [useDisk, chosenCandidate, suggested]);
    const valid = !useDisk || !!chosenCandidate;

    useEffect(() => {
        setIsFormValid(valid);
    }, [valid, setIsFormValid]);

    // Keep the choice file in step with the page: written when a usable
    // partition is chosen, removed otherwise.
    useEffect(() => {
        const file = cockpit.file(CHOICE_FILE, { superuser: "try" });
        const content = useDisk && valid && chosenCandidate
            ? JSON.stringify({
                device: chosenCandidate.path,
                label: chosenCandidate.label,
                uuid: chosenCandidate.uuid,
            }) + "\n"
            : null;
        file.replace(content).catch(e => console.error("data disk: writing", CHOICE_FILE, e));
        return () => file.close();
    }, [useDisk, valid, chosenCandidate]);

    const describe = c => cockpit.format(
        "$0 — $1, $2$3$4",
        c.path,
        cockpit.format_bytes(c.size),
        c.fs,
        c.label ? cockpit.format(_(", label “$0”"), c.label) : "",
        c.diskDescription ? cockpit.format(" ($0)", c.diskDescription) : ""
    );

    return (
        <Form id={SCREEN_ID} isHorizontal={false}>
            <Content component="p">
                {_("The system goes on the disk you chose in the previous steps. If this computer has a second, larger disk, your home folder, Flatpak apps and containers can live there instead, so they don't fill up the system disk.")}
            </Content>
            <FormGroup role="radiogroup" isStack fieldId={SCREEN_ID + "-choice"}>
                <Radio
                  id={SCREEN_ID + "-none"}
                  name={SCREEN_ID + "-choice"}
                  isChecked={!useDisk}
                  onChange={() => { setTouched(true); setUseDisk(false); }}
                  label={_("Keep everything on the system disk")}
                />
                <Radio
                  id={SCREEN_ID + "-use"}
                  name={SCREEN_ID + "-choice"}
                  isChecked={useDisk}
                  onChange={() => { setTouched(true); setUseDisk(true); }}
                  label={_("Use a second disk for home folders, apps and containers")}
                  description={_("Its files are kept, nothing on it is erased. If it already holds home folders, apps and containers from an earlier install, they're used again.")}
                />
            </FormGroup>
            {useDisk && candidates.length === 0 &&
                <Alert isInline variant="warning" title={_("No second disk to use")}>
                    {_("This needs an ext4, XFS or Btrfs partition on a disk other than the system's. Create one first, for example with KDE Partition Manager, or keep everything on the system disk.")}
                </Alert>}
            {useDisk && candidates.length > 1 &&
                <FormGroup role="radiogroup" isStack label={_("Partition")} fieldId={SCREEN_ID + "-partition"}>
                    {candidates.map(c => (
                        <Radio
                          key={c.path}
                          id={SCREEN_ID + "-partition-" + c.path.replace(/\W/g, "-")}
                          name={SCREEN_ID + "-partition"}
                          isChecked={chosen === c.path}
                          onChange={() => { setTouched(true); setChosen(c.path); }}
                          label={describe(c)}
                        />
                    ))}
                </FormGroup>}
            {useDisk && candidates.length === 1 && chosenCandidate &&
                <Content component="p">
                    {cockpit.format(_("Using $0."), describe(chosenCandidate))}
                </Content>}
            {useDisk && chosenCandidate &&
                <Content component="small">
                    {_("Reinstalling? Home folders already on this disk are given back by user name: when the computer first starts, create your account with the same user name as before.")}
                </Content>}
        </Form>
    );
};
