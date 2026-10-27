#!/usr/bin/env bash
# Stubbed tests of scripts/ebs-snapshots.sh take: the thaw path when SSM or CreateSnapshot fail.
# No AWS calls: aws, terraform, ssm_run and sleep are replaced by functions.
#   bash terraform/ebs-snapshots/tests/take-thaw.sh scripts/ebs-snapshots.sh
# Scenario knobs (env): CREATE_FAIL=1, THAW_FAILS=<n tries that fail>, PROBE_FAIL=1, FREEZE_FAIL=1.
script="${1:?usage: take-thaw.sh <path to scripts/ebs-snapshots.sh>}"

run() {
  local name="$1"; shift
  echo "--- $name"
  env "$@" bash -c '
    source "$1"; set +e
    LOG=$(mktemp)
    sleep() { :; }
    terraform() { case "$*" in *instance_id*) echo i-0test;; *data_volume_id*) echo vol-0data;; esac; }
    aws() {
      case "$*" in
        "sts get-caller-identity"*) echo "arn:aws:sts::004009722521:assumed-role/terraform-lab-role/s" ;;
        "ec2 describe-snapshots"*) echo 0 ;;
        "ssm describe-instance-information"*) echo Online ;;
        "ec2 create-snapshot"*) [[ -n "${CREATE_FAIL:-}" ]] && { echo "An error occurred (RequestLimitExceeded)" >&2; return 255; }
                                printf "snap-0new\tpending\t2026-10-27T15:00:00Z\n" ;;
      esac
    }
    ssm_run() {
      echo "ssm: $2" >> "$LOG"
      case "$2" in
        "lab-ebs freeze 60") [[ -n "${FREEZE_FAIL:-}" ]] && { echo "ERROR: freeze ended as Failed" >&2; return 1; }
                             echo "frozen at T0" ;;
        "lab-ebs thaw && lab-ebs probe")
          n=$(grep -c "thaw &&" "$LOG")
          (( n <= ${THAW_FAILS:-0} )) && { echo "ERROR: thaw ended as TimedOut" >&2; return 1; }
          echo "thawed at T1; /mnt/lab-data was frozen"; echo "WRITABLE: /mnt/lab-data accepts writes" ;;
        "lab-ebs probe") [[ -n "${PROBE_FAIL:-}" ]] && { echo "ERROR: probe ended as TimedOut" >&2; return 1; }
                         echo "WRITABLE: /mnt/lab-data accepts writes" ;;
      esac
    }
    unset AWS_CREDENTIAL_EXPIRATION
    ( set -euo pipefail; take s1 ); rc=$?   # errexit as in the real script
    echo "exit=$rc; SSM calls: $(paste -sd, "$LOG")"
  ' take-thaw "$script" 2>&1 | sed 's/^/    /'
}

run "happy path"
run "thaw fails twice, third try ok"                 THAW_FAILS=2
run "SSM thaw down, auto-thaw confirmed by probe"     THAW_FAILS=3
run "SSM down for good: manual steps, exit 1"         THAW_FAILS=3 PROBE_FAIL=1
run "create-snapshot fails while frozen"              CREATE_FAIL=1
run "freeze result lost: thaw still sent"             FREEZE_FAIL=1
