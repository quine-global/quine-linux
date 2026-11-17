#!/usr/bin/env bash
# vm-test.sh [TAG]: boots a Quine Linux live ISO on a Proxmox VM (zeus's
# VM 107, quine-live-test) and waits for it to come up. TAG is a release
# tag (v0.1.1-alpha.1: its public ISO, checked against its SHA256SUMS) or
# `latest` (the last build of main, from MinIO through a presigned link).
#
# Through Proxmox's API only: with an API token that can do no more than
# this (docs/VM_TEST.md), or, with no token (from a laptop on the tailnet),
# the same calls as `pvesh` over root SSH to zeus:
#   1. stop the VM, detach the ISO, replace it with TAG's (Proxmox
#      downloads it straight from MinIO), attach it, enable the QEMU guest
#      agent's channel, start the VM. The VM must already boot from its CD
#      (ide2) first: the boot order is a disk setting in Proxmox, which the
#      token can't change (it would let it change the VM's disks too);
#   2. wait for the live system's guest agent (Fedora's qemu-guest-agent,
#      in the image) to answer, and report the OS it says it runs.
# The VM is left running, at the live desktop, for a look in its console.
#
# Environment:
#   PVE_TOKEN    `user@realm!tokenid=secret`; unset: over SSH to PVE_SSH
#   PVE_SSH      default root@zeus.ts.quineglobal.com
#   PVE_URL      default https://proxmox.in.coldairnetworks.com (tailnet)
#   PVE_NODE     default zeus;  VMID default 107;  PVE_STORAGE default local
#   ISO_URL      instead of working it out from TAG
#   BOOT_TIMEOUT seconds to wait for the guest agent, default 900
#   For TAG=latest: RCLONE_CONFIG_STORE_* (as iso.yml) and MINIO_BUCKET;
#                unset: quine-linux's own MinIO keys, read over SSH from
#                the forge VM (MINIO_SSH, default
#                root@mainframe-vm.ts.quineglobal.com). rclone comes from
#                nixpkgs when it isn't installed.
set -euo pipefail

tag=${1:-${TAG:-latest}}
pve_token=${PVE_TOKEN:-}
pve_ssh=${PVE_SSH:-root@zeus.ts.quineglobal.com}
pve=${PVE_URL:-https://proxmox.in.coldairnetworks.com}/api2/json
node=${PVE_NODE:-zeus}
vmid=${VMID:-107}
storage=${PVE_STORAGE:-local}
iso=quine-linux-live-test.iso
timeout=${BOOT_TIMEOUT:-900}
bucket=${MINIO_BUCKET:-quine-linux}
public=https://s3.quineglobal.com/$bucket

log() { echo "== $*" >&2; }
api() { # METHOD PATH [--data-urlencode k=v...]: the response's .data; fails, saying why, on an error
  local method=$1 path=$2 out code
  shift 2
  if [ -z "$pve_token" ]; then
    api_ssh "$method" "$path" "$@"
    return
  fi
  out=$(curl -sS -w '\n%{http_code}' -X "$method" -H "Authorization: PVEAPIToken=$PVE_TOKEN" "$pve$path" "$@") || return 1
  code=${out##*$'\n'}
  out=${out%$'\n'*}
  if [ "${code:0:1}" != 2 ]; then
    echo "Proxmox: $method $path: HTTP $code $(jq -r '.message // .errors // empty' <<<"$out" 2>/dev/null)" >&2
    return 1
  fi
  jq -c '.data' <<<"$out"
}
# The same call as pvesh on zeus, over SSH, as root (no token needed).
api_ssh() {
  local method=$1 path=$2 cmd kv out
  shift 2
  case $method in GET) cmd=get ;; POST) cmd=create ;; PUT) cmd=set ;; DELETE) cmd=delete ;; esac
  local args=()
  while [ $# -gt 0 ]; do
    [ "$1" = --data-urlencode ] || { echo "api_ssh: unexpected argument $1" >&2; return 1; }
    kv=$2
    args+=("--${kv%%=*}" "${kv#*=}")
    shift 2
  done
  out=$(ssh -o BatchMode=yes "$pve_ssh" "$(printf '%q ' pvesh "$cmd" "$path" ${args[@]+"${args[@]}"} --output-format json)") || {
    echo "Proxmox (ssh $pve_ssh): $method $path failed" >&2
    return 1
  }
  # pvesh can print a line of its own first ("update VM 107: ..."); the
  # result, if any, is the last line that's JSON.
  out=$(grep -E '^[[{"]|^null$|^-?[0-9]' <<<"$out" | tail -n 1 || true)
  if [ -n "$out" ]; then jq -c . <<<"$out"; else echo null; fi
}
# Waits for a Proxmox task (UPID) and fails if it did.
wait_task() {
  local upid=$1 status path
  path=$upid
  [ -z "$pve_token" ] || path=$(jq -rn --arg u "$upid" '$u|@uri')
  while :; do
    status=$(api GET "/nodes/$node/tasks/$path/status")
    [ "$(jq -r .status <<<"$status")" = stopped ] && break
    sleep 3
  done
  [ "$(jq -r .exitstatus <<<"$status")" = OK ] || {
    echo "::error::Proxmox task failed: $(jq -r .exitstatus <<<"$status") ($upid)" >&2
    exit 1
  }
}

# Which ISO, and its checksum when there is one.
checksum=
if [ -n "${ISO_URL:-}" ]; then
  url=$ISO_URL
elif [ "$tag" = latest ]; then
  command -v rclone >/dev/null || rclone() { nix run nixpkgs#rclone -- "$@"; }
  if [ -z "${RCLONE_CONFIG_STORE_SECRET_ACCESS_KEY:-}" ]; then
    minio_ssh=${MINIO_SSH:-root@mainframe-vm.ts.quineglobal.com}
    log "reading quine-linux's MinIO keys from $minio_ssh"
    creds=$(ssh -o BatchMode=yes "$minio_ssh" cat /run/agenix/minio-quine-linux)
    export RCLONE_CONFIG_STORE_TYPE=s3 RCLONE_CONFIG_STORE_PROVIDER=Minio
    export RCLONE_CONFIG_STORE_ENDPOINT=${RCLONE_CONFIG_STORE_ENDPOINT:-https://s3.quineglobal.com}
    RCLONE_CONFIG_STORE_ACCESS_KEY_ID=$(sed -n 's/^AWS_ACCESS_KEY_ID=//p' <<<"$creds")
    RCLONE_CONFIG_STORE_SECRET_ACCESS_KEY=$(sed -n 's/^AWS_SECRET_ACCESS_KEY=//p' <<<"$creds")
    export RCLONE_CONFIG_STORE_ACCESS_KEY_ID RCLONE_CONFIG_STORE_SECRET_ACCESS_KEY
    unset creds
  fi
  url=$(rclone link --expire 3h "store:$bucket/live/latest/live.iso")
else
  name=quine-linux-$tag-live-x86_64.iso
  url=$public/releases/$tag/$name
  checksum=$(curl -fsS "$public/releases/$tag/SHA256SUMS" | awk -v n="$name" '$2 == n || $2 == "*"n {print $1}')
  [ -n "$checksum" ] || { echo "::error::$name isn't in $tag's SHA256SUMS" >&2; exit 1; }
fi
log "VM $vmid on $node: booting $tag"

boot=$(api GET "/nodes/$node/qemu/$vmid/config" | jq -r '.boot // ""')
case "$boot" in
  order=ide2*) ;;
  *) echo "::error::VM $vmid must boot from its CD first (boot: order=ide2;...), not '$boot'. Set it in Proxmox; the token can't (docs/VM_TEST.md)." >&2; exit 1 ;;
esac

if [ "$(api GET "/nodes/$node/qemu/$vmid/status/current" | jq -r .status)" = running ]; then
  log "stopping VM $vmid"
  wait_task "$(api POST "/nodes/$node/qemu/$vmid/status/stop" | jq -r .)"
fi

log "replacing $storage:iso/$iso"
api PUT "/nodes/$node/qemu/$vmid/config" --data-urlencode "ide2=none,media=cdrom" >/dev/null
api DELETE "/nodes/$node/storage/$storage/content/$storage:iso/$iso" >/dev/null 2>&1 || true
args=(--data-urlencode "url=$url" --data-urlencode "content=iso" --data-urlencode "filename=$iso")
[ -z "$checksum" ] || args+=(--data-urlencode "checksum=$checksum" --data-urlencode "checksum-algorithm=sha256")
wait_task "$(api POST "/nodes/$node/storage/$storage/download-url" "${args[@]}" | jq -r .)"

api PUT "/nodes/$node/qemu/$vmid/config" \
  --data-urlencode "ide2=$storage:iso/$iso,media=cdrom" \
  --data-urlencode "agent=enabled=1" >/dev/null

log "starting VM $vmid"
wait_task "$(api POST "/nodes/$node/qemu/$vmid/status/start" | jq -r .)"
started=$SECONDS

log "waiting up to ${timeout}s for the live system's guest agent"
until osinfo=$(api GET "/nodes/$node/qemu/$vmid/agent/get-osinfo" 2>/dev/null) && [ -n "$osinfo" ] && [ "$osinfo" != null ]; do
  if [ $((SECONDS - started)) -ge "$timeout" ]; then
    echo "::error::VM $vmid didn't come up in ${timeout}s: no answer from its guest agent. Look at its console in Proxmox." >&2
    exit 1
  fi
  sleep 10
done

result=$(jq -r --arg tag "$tag" --arg s "$((SECONDS - started))" '"\($tag) booted on VM '"$vmid"' in \($s)s: \(.result["pretty-name"] // .result.name) (kernel \(.result["kernel-release"]))"' <<<"$osinfo")
log "$result"
[ -z "${GITHUB_STEP_SUMMARY:-}" ] || echo "$result" >>"$GITHUB_STEP_SUMMARY"
