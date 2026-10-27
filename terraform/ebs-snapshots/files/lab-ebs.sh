#!/usr/bin/env bash
# lab-ebs: on-instance helper for the Day 4 EBS snapshots lab, installed by cloud-init.
# Run it as root in a Session Manager shell: sudo lab-ebs <command>. Without arguments it prints the usage.
# Manifests and the writer state live in /var/lib/lab-ebs, on the root volume, so no data-volume
# snapshot ever contains the reference it is checked against. fio results go to /tmp/lab-fio-*.json,
# where scripts/collect-fio.sh picks them up.
set -euo pipefail

DATA=/mnt/lab-data
RESTORED=/mnt/lab-restored
STATE=/var/lib/lab-ebs

usage() {
  cat <<'EOF'
sudo lab-ebs <command>
  devices                    block devices with the EBS volume ID (serial), filesystem and UUID
  prepare <vol-id>           mkfs.ext4 on an empty data volume and mount it on /mnt/lab-data
  mount <vol-id> <dir> [ro]  mount a volume by its ID (journal recovery shows up in dmesg)
  umount <dir>               unmount; lists who holds it if busy
  detach-ready <vol-id>      exit 0 only if nothing on the volume is mounted or open (run before a detach)
  seed                       write the test dataset (4 x 64 MiB random + 1000 x 4 KiB files)
  mutate                     change the dataset: overwrite 8 MiB, delete 100 files, add 32 MiB
  manifest <label> [dir]     sha256 of every dataset file into /var/lib/lab-ebs/<label>.sha256
  verify <label> [dir]       check a dir (default /mnt/lab-restored) against a manifest
  freeze [seconds]           sync + fsfreeze /mnt/lab-data; thaws on its own after N s (default 120)
  thaw                       unfreeze /mnt/lab-data now
  probe                      exit 0 only if /mnt/lab-data accepts a write within 5 s (not frozen)
  writer start|stop          simulated app appending records to <data>/app/journal.log
  writer check <dir> [time]  integrity of a journal.log; time = snapshot StartTime (ISO 8601)
  latency <name> [dir]       fio randread 4k QD1, 60 s, read-only, on the dataset files of dir
  init <vol-id>              read every block of a restored volume (initialization), read-only
  status                     mounts, writer and pending auto-thaw
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }

# EBS NVMe devices carry the volume ID without the hyphen as their serial. /dev/sdf does not
# map to a fixed nvmeXn1, and a restored volume has the same filesystem UUID and label as its source.
dev_of() {
  local serial="${1/-/}" name
  name="$(lsblk -dn -o NAME,SERIAL | awk -v s="$serial" '$2 == s {print $1}')"
  [[ -n "$name" ]] || die "volume $1 is not attached (no device with serial $serial)"
  echo "/dev/$name"
}

# Refuses the disk that holds /, a disk with partitions (the root disk has four), a non-EBS device
# and anything mounted, so neither prepare nor mount can ever touch the root volume.
require_unused() {
  local dev="$1" root_part root_disk model
  root_part="$(findmnt -n -o SOURCE /)"
  root_disk="/dev/$(lsblk -no PKNAME "$root_part" 2>/dev/null || true)"
  [[ "$root_disk" != /dev/ ]] || die "could not find the disk of / ($root_part); refusing to go on"
  [[ "$dev" != "$root_disk" ]] || die "$dev holds / (the root volume)"
  [[ "$(lsblk -n -o NAME "$dev" | wc -l)" -eq 1 ]] || die "$dev has partitions; a lab volume has none"
  model="$(lsblk -dn -o MODEL "$dev")"
  [[ "$model" == "Amazon Elastic Block Store"* ]] || die "$dev is not an EBS volume (model: $model)"
  [[ -z "$(lsblk -n -o MOUNTPOINTS "$dev" | tr -d '[:space:]')" ]] || die "$dev is already mounted"
}

# Day 1 lesson: a directory that is not a mount point silently writes to the root volume.
require_mount() {
  mountpoint -q "$1" || die "$1 is not a mount point; mount the volume first"
}

# Formats only a device with no signature at all: blkid -p probes the disk itself (not the cache), and
# a partition table (PTTYPE) or any filesystem other than ext4 stops it. An ext4 device is only mounted.
cmd_prepare() {
  local dev probe
  dev="$(dev_of "${1:?usage: prepare <vol-id>}")"
  require_unused "$dev"
  probe="$(blkid -p -o export "$dev" || true)"
  if [[ -z "$probe" ]]; then
    mkfs.ext4 -q -L lab-data -E lazy_itable_init=0,lazy_journal_init=0 "$dev"
  elif ! grep -qx 'TYPE=ext4' <<< "$probe" || grep -q '^PTTYPE=' <<< "$probe"; then
    die "$dev already has a signature ($(tr '\n' ' ' <<< "$probe")); refusing to format it"
  fi
  cmd_mount "$1" "$DATA"
}

cmd_mount() {
  local dev dir="${2:?usage: mount <vol-id> <dir> [ro]}" opts=defaults
  dev="$(dev_of "$1")"
  require_unused "$dev"
  [[ "${3:-}" == ro ]] && opts=ro
  mkdir -p "$dir"
  mountpoint -q "$dir" && die "$dir is already mounted"
  mount -o "$opts" "$dev" "$dir"
  echo "$dev ($1) on $dir, $(findmnt -n -o FSTYPE,OPTIONS "$dir")"
  dmesg | grep -E "EXT4-fs \($(basename "$dev")\)" | tail -n 5 || true
}

cmd_umount() {
  local dir="${1:?usage: umount <dir>}"
  umount "$dir" || { fuser -vm "$dir" || true; die "$dir is busy"; }
}

cmd_detach_ready() {
  local dev holders
  dev="$(dev_of "${1:?usage: detach-ready <vol-id>}")"
  [[ -z "$(lsblk -n -o MOUNTPOINTS "$dev" | tr -d '[:space:]')" ]] || die "$dev ($1) is mounted: lab-ebs umount first"
  holders="$(fuser "$dev" 2>/dev/null || true)"
  [[ -z "${holders// /}" ]] || die "$dev ($1) is open by PIDs$holders"
  echo "READY: $dev ($1) is not mounted or open; the detach can go ahead"
}

cmd_seed() {
  require_mount "$DATA"
  local d="$DATA/dataset" i
  mkdir -p "$d/big" "$d/small"
  for i in 1 2 3 4; do head -c 64M /dev/urandom > "$d/big/random-$i.bin"; done
  for i in $(seq -w 1 1000); do head -c 4K /dev/urandom > "$d/small/f-$i.bin"; done
  sync -f "$d"
  du -sh "$d"
}

cmd_mutate() {
  require_mount "$DATA"
  local d="$DATA/dataset"
  [[ -f "$d/big/random-1.bin" ]] || die "no dataset; run seed first"
  dd if=/dev/urandom of="$d/big/random-1.bin" bs=1M count=8 conv=notrunc status=none
  rm -f "$d"/small/f-0{001..100}.bin
  mkdir -p "$d/new"
  head -c 32M /dev/urandom > "$d/new/random-5.bin"
  sync -f "$d"
  du -sh "$d"
}

cmd_manifest() {
  local label="${1:?usage: manifest <label> [dir]}" dir="${2:-$DATA}"
  require_mount "$dir"
  mkdir -p "$STATE"
  (cd "$dir" && find dataset -type f -print0 | sort -z | xargs -0 sha256sum) > "$STATE/$label.sha256"
  echo "$STATE/$label.sha256: $(wc -l < "$STATE/$label.sha256") files"
}

cmd_verify() {
  local label="${1:?usage: verify <label> [dir]}" dir="${2:-$RESTORED}" m extra
  m="$STATE/$label.sha256"
  [[ -f "$m" ]] || die "no manifest $m"
  require_mount "$dir"
  extra="$(comm -13 <(awk '{print $2}' "$m" | sort) <(cd "$dir" && find dataset -type f | sort))"
  if (cd "$dir" && sha256sum --quiet -c "$m") && [[ -z "$extra" ]]; then
    echo "OK: $dir matches $label ($(wc -l < "$m") files, no extra files)"
  else
    [[ -n "$extra" ]] && printf 'extra file (not in %s): %s\n' "$label" $extra
    die "$dir does not match $label"
  fi
}

cmd_freeze() {
  local secs="${1:-120}"
  require_mount "$DATA"
  systemctl stop lab-ebs-thaw.timer 2>/dev/null || true
  systemctl reset-failed lab-ebs-thaw.service 2>/dev/null || true
  systemd-run --quiet --unit=lab-ebs-thaw --on-active="${secs}s" /usr/sbin/fsfreeze -u "$DATA"
  sync -f "$DATA"
  fsfreeze -f "$DATA"
  echo "frozen at $(date -u +%FT%T.%3NZ); auto-thaw in ${secs}s. Writes to $DATA now block."
}

cmd_thaw() {
  local was=frozen
  fsfreeze -u "$DATA" 2>/dev/null || was="not frozen (auto-thaw already ran?)"
  systemctl stop lab-ebs-thaw.timer 2>/dev/null || true
  echo "thawed at $(date -u +%FT%T.%3NZ); $DATA was $was"
}

# A write to a frozen filesystem blocks in uninterruptible sleep, so a timeout can't kill it. The
# probe runs in the background, and an unfinished write after 5 s means frozen. It completes on its own at the thaw.
cmd_probe() {
  local pid i
  require_mount "$DATA"
  touch "$DATA/.lab-ebs-probe" </dev/null >/dev/null 2>&1 &
  pid=$!
  for i in $(seq 1 10); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done
  kill -0 "$pid" 2>/dev/null && die "$DATA did not take a write in 5 s: still frozen"
  wait "$pid" || die "probe write to $DATA failed"
  rm -f "$DATA/.lab-ebs-probe"
  echo "WRITABLE: $DATA accepts writes"
}

# Each record: seq, epoch ms, 16 hex chars of sha256(seq). Plain appends with no fsync, like an
# app that trusts the page cache; check shows how much of it reached a crash-consistent snapshot.
cmd_writer() {
  case "${1:-}" in
    start)
      require_mount "$DATA"
      mkdir -p "$DATA/app"
      systemd-run --quiet --unit=lab-ebs-writer /bin/bash -c '
        f='"$DATA"'/app/journal.log; s=$( [ -s "$f" ] && tail -n 1 "$f" | cut -d" " -f1 || echo 0 )
        while :; do s=$((s+1)); h=$(printf %d "$s" | sha256sum); printf "%d %s %s\n" "$s" "$(date +%s%3N)" "${h:0:16}" >> "$f"; sleep 0.01; done'
      echo "writer running (systemctl status lab-ebs-writer)" ;;
    stop) systemctl stop lab-ebs-writer && echo "writer stopped" ;;
    check) writer_check "${2:?usage: writer check <dir> [time]}" "${3:-}" ;;
    *) die "usage: writer start|stop|check <dir> [time]" ;;
  esac
}

writer_check() {
  local f="$1/app/journal.log"
  [[ -f "$f" ]] || die "no $f"
  python3 -I - "$f" "$2" <<'EOF'
import datetime, hashlib, sys
path, when = sys.argv[1], sys.argv[2]
good = bad = gaps = 0
prev = last_ts = None
with open(path, "rb") as fh:
    for raw in fh:
        parts = raw.decode(errors="replace").rstrip("\n").split(" ")
        ok = raw.endswith(b"\n") and len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit() \
            and hashlib.sha256(parts[0].encode()).hexdigest()[:16] == parts[2]
        if not ok:
            bad += 1
            continue
        seq = int(parts[0])
        if prev is not None and seq != prev + 1:
            gaps += 1
        prev, last_ts, good = seq, int(parts[1]), good + 1
print(f"{path}: {good} good records, {bad} bad (partial or garbage), {gaps} gaps, last seq {prev}")
if last_ts is not None:
    last = datetime.datetime.fromtimestamp(last_ts / 1000, datetime.timezone.utc)
    print(f"last record at {last.isoformat(timespec='milliseconds')}")
    if when:
        snap = datetime.datetime.fromisoformat(when.replace("Z", "+00:00"))
        print(f"snapshot StartTime minus last record: {(snap - last).total_seconds():.3f} s")
EOF
}

cmd_latency() {
  local name="${1:?usage: latency <name> [dir]}" dir="${2:-$RESTORED}" files
  require_mount "$dir"
  files="$(find "$dir/dataset/big" -name '*.bin' | sort | paste -sd:)"
  [[ -n "$files" ]] || die "no dataset files in $dir"
  fio --name="$name" --filename="$files" --readonly --rw=randread --bs=4k --iodepth=1 --direct=1 \
    --ioengine=libaio --runtime=60 --time_based --output-format=json --output="/tmp/lab-fio-$name.json"
  fio_summary "/tmp/lab-fio-$name.json"
}

cmd_init() {
  local dev
  dev="$(dev_of "${1:?usage: init <vol-id>}")"
  fio --name=init --filename="$dev" --readonly --rw=read --bs=1M --iodepth=32 --direct=1 \
    --ioengine=libaio --output-format=json --output=/tmp/lab-fio-init.json
  fio_summary /tmp/lab-fio-init.json
}

fio_summary() {
  python3 -I - "$1" <<'EOF'
import json, sys
r = json.load(open(sys.argv[1]))["jobs"][0]["read"]
p = r["clat_ns"].get("percentile", {})
ms = lambda k: p.get(k, 0) / 1e6
print(f"{sys.argv[1]}: {r['iops']:.0f} IOPS, {r['bw'] / 1024:.1f} MiB/s, {r['runtime'] / 1000:.0f} s, "
      f"clat p50 {ms('50.000000'):.2f} ms, p99 {ms('99.000000'):.2f} ms, max {r['clat_ns']['max'] / 1e6:.2f} ms")
EOF
}

cmd_status() {
  lsblk -o NAME,SIZE,SERIAL,FSTYPE,LABEL,UUID,MOUNTPOINTS
  systemctl is-active --quiet lab-ebs-writer && echo "writer: running" || echo "writer: stopped"
  systemctl list-timers lab-ebs-thaw.timer --no-legend 2>/dev/null | grep -q . && echo "auto-thaw: pending" || true
}

main() {
  [[ $# -gt 0 ]] || { usage; exit 0; }
  [[ $EUID -eq 0 ]] || die "run as root: sudo lab-ebs $*"
  mkdir -p "$STATE"
  local cmd="$1"; shift
  case "$cmd" in
    devices|status) cmd_status ;;
    detach-ready) cmd_detach_ready "$@" ;;
    prepare|mount|umount|seed|mutate|manifest|verify|freeze|thaw|probe|writer|latency|init) "cmd_$cmd" "$@" ;;
    *) usage; exit 1 ;;
  esac
}

# Sourcing it (tests) defines the functions without running anything.
[[ "${BASH_SOURCE[0]}" != "$0" ]] || main "$@"
