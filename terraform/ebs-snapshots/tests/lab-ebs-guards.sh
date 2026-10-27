#!/usr/bin/env bash
# Run from anywhere: bash terraform/ebs-snapshots/tests/lab-ebs-guards.sh terraform/ebs-snapshots/files/lab-ebs.sh
# Stubbed tests of the lab-ebs device guards: fake NVMe layout, no real disks touched.
# Layout: nvme0n1 = root (vol-0root, partitions p1 on /), nvme1n1 = data (vol-0data),
# nvme2n1 = restored (vol-0rest), nvme3n1 = partitioned EBS (vol-0part), nvme4n1 = non-EBS (vol-0local).
source "$1"; set +eu +o pipefail
DATA=$(mktemp -d)
findmnt() { echo /dev/nvme0n1p1; }
lsblk() {
  local args="$*" dev="${!#}"
  case "$args" in
    "-dn -o NAME,SERIAL") printf 'nvme0n1 vol0root\nnvme1n1 vol0data\nnvme2n1 vol0rest\nnvme3n1 vol0part\nnvme4n1 vol0local\n' ;;
    "-no PKNAME /dev/nvme0n1p1") echo nvme0n1 ;;
    "-n -o NAME "*) case "$dev" in */nvme0n1) printf 'nvme0n1\np1\np15\n';; */nvme3n1) printf 'nvme3n1\np1\n';; *) echo x;; esac ;;
    "-dn -o MODEL "*) [[ "$dev" == */nvme4n1 ]] && echo "Local NVMe" || echo "Amazon Elastic Block Store" ;;
    "-n -o MOUNTPOINTS "*) [[ "$dev" == */nvme2n1 && -n "${RESTORED_MOUNTED:-}" ]] && echo /mnt/lab-restored || echo "" ;;
  esac
}
blkid() { echo -n "${PROBE:-}"; [[ -n "${PROBE:-}" ]]; }
mkfs.ext4() { echo "MKFS ${!#}"; }
mount() { echo "MOUNT $*"; }
mountpoint() { return 1; }
dmesg() { :; }
fuser() { :; }
t() { local name="$1"; shift; echo "--- $name"; ( set -e; "$@" ) 2>&1 | sed 's/^/    /'; }
t "prepare root volume"            cmd_prepare vol-0root
t "prepare partitioned EBS"        cmd_prepare vol-0part
t "prepare non-EBS device"         cmd_prepare vol-0local
t "prepare unknown volume"         cmd_prepare vol-0nope
t "prepare empty data volume"      cmd_prepare vol-0data
t "prepare data volume with ext4"  env PROBE=$'UUID=1\nTYPE=ext4' bash -c "source $1; $(declare -f findmnt lsblk blkid mkfs.ext4 mount mountpoint dmesg); DATA=$DATA; cmd_prepare vol-0data"
t "prepare data volume with xfs"   env PROBE=$'UUID=1\nTYPE=xfs' bash -c "source $1; $(declare -f findmnt lsblk blkid mkfs.ext4 mount mountpoint dmesg); DATA=$DATA; cmd_prepare vol-0data"
t "prepare data volume with gpt"   env PROBE=$'PTUUID=1\nPTTYPE=gpt' bash -c "source $1; $(declare -f findmnt lsblk blkid mkfs.ext4 mount mountpoint dmesg); DATA=$DATA; cmd_prepare vol-0data"
t "mount root volume"              cmd_mount vol-0root /mnt/x ro
t "mount restored (already mounted)" env RESTORED_MOUNTED=1 bash -c "source $1; $(declare -f findmnt lsblk blkid mount mountpoint dmesg); cmd_mount vol-0rest $DATA ro"
t "detach-ready mounted"           env RESTORED_MOUNTED=1 bash -c "source $1; $(declare -f lsblk fuser); cmd_detach_ready vol-0rest"
t "detach-ready unmounted"         cmd_detach_ready vol-0rest
