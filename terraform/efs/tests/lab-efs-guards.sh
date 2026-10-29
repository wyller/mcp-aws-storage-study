#!/usr/bin/env bash
# Run from anywhere: bash terraform/efs/tests/lab-efs-guards.sh terraform/efs/files/lab-efs.sh
# Stubbed tests of the lab-efs guards and of the "try" rollback: no AWS, no NFS, nothing mounted.
# Mount state lives in files under $T; mount, umount, findmnt, timeout and stat are stubs.
source "$1"; set +eu +o pipefail
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
MNT_APP=$T/efs-app MNT_OTHER=$T/efs-other MNT_ROOT=$T/efs-root MNT_TRY=$T/efs-try
ENV_FILE=$T/env
printf 'FS_ID=fs-0abc\nAP_APP=fsap-0app\nAP_OTHER=fsap-0other\nCLIENT=a\nREGION=us-east-1\n' > "$ENV_FILE"

mounted() { touch "$T/m.$(basename "$1")"; }
mountpoint() { [[ -e "$T/m.$(basename "${!#}")" ]]; }
findmnt() {
  case "$*" in
    *"-o FSTYPE "*) echo "${FSTYPE:-nfs4}" ;;
    *"-o SOURCE "*) echo "${SRC:-127.0.0.1:/}" ;;
    *) echo "stub findmnt $*" ;;
  esac
}
timeout() { while [[ "$1" == -* ]]; do shift 2; done; shift; "$@"; }
# MOUNT_RC: exit code of the fake mount (0 marks the target as mounted); MOUNT_MSG: what it prints.
mount() {
  echo "MOUNT $*"; [[ -n "${MOUNT_MSG:-}" ]] && echo "$MOUNT_MSG" >&2
  [[ "${MOUNT_RC:-0}" == 0 ]] && mounted "${!#}"; return "${MOUNT_RC:-0}"
}
pkill() { echo "PKILL $*"; }
PERF_COUNT=$T/perf-runs
umount() { echo "UMOUNT $1"; rm -f "$T/m.$(basename "$1")"; }
stat() { echo "0:0 drwxr-xr-x"; }

# t <name> [VAR=value ...] <command...>: runs in a subshell with set -e, like the real script.
t() {
  local name="$1"; shift
  echo "--- $name"
  ( while [[ "$1" == *=* ]]; do export "${1?}"; shift; done; set -e; "$@" ) 2>&1 | sed 's/^/    /'
  rm -f "$T"/m.*
}
app_mounted() { mounted "$MNT_APP"; "$@"; }
try_mounted() { mounted "$MNT_TRY"; "$@"; }
accepted() { "$@" && echo accepted; }
bad_env() { echo FS_ID=fs-1 > "$T/bad"; ENV_FILE=$T/bad; load_env; }
perf_limit() { echo 1 > "$PERF_COUNT"; mounted "$MNT_APP"; cmd_perf p3; }
# share: the writer runs as client b (its own env file), the reader as a (looks for from-b.txt).
printf 'FS_ID=fs-0abc\nAP_APP=fsap-0app\nAP_OTHER=fsap-0other\nCLIENT=b\nREGION=us-east-1\n' > "$T/env.b"
as_b() { ENV_FILE=$T/env.b "$@"; }
share_twice() { mounted "$MNT_APP"; as_b cmd_share write t2 >/dev/null; as_b cmd_share write t2; }
share_stale() { mounted "$MNT_APP"; as_b cmd_share write t3 >/dev/null; cmd_share read t3 5; }
share_live() { mounted "$MNT_APP"; ( sleep 0.5; as_b cmd_share write t4 ) & cmd_share read t4 5; wait; }
share_old_format() {
  mounted "$MNT_APP"; ( sleep 0.5; mkdir -p "$MNT_APP/runs/share-t5"
    echo "client=b host=x written_ns=1" > "$MNT_APP/runs/share-t5/from-b.txt" ) & cmd_share read t5 5; wait
}

t "require_efs: not a mount point"                        require_efs "$MNT_APP"
t "require_efs: xfs (the root volume)"     FSTYPE=xfs     app_mounted require_efs "$MNT_APP"
t "require_efs: nfs4 straight to a MT (no TLS)" SRC=172.31.20.5:/ app_mounted require_efs "$MNT_APP"
t "require_efs: nfs4 through the tunnel"                  app_mounted accepted require_efs "$MNT_APP"
t "valid_tag: path traversal"                             valid_tag "../etc"
t "valid_tag: ok"                                         accepted valid_tag s1
t "load_env: incomplete env file"                         bad_env
t "mount app: already mounted"                            app_mounted cmd_mount app
t "mount try: refused"                                    cmd_mount try
t "mount app: TLS + IAM + access point"                   cmd_mount app
t "mount root: TLS + IAM, no access point"                cmd_mount root
t "mount app: MT_IP forces a mount target" MT_IP=172.31.40.7 cmd_mount app
t "try noiam: mounts, then rolled back"                   cmd_try noiam
t "try notls: refused by the server -> POLICY" MOUNT_RC=32 "MOUNT_MSG=mount.nfs4: access denied by server while mounting 127.0.0.1:/" cmd_try notls
t "try blocked: killed by timeout -> NETWORK"   MOUNT_RC=124 cmd_try blocked
t "try blocked: mount's own timeout -> NETWORK" MOUNT_RC=32 "MOUNT_MSG=mount.nfs4: Connection timed out" cmd_try blocked
t "try noiam: helper error -> CLIENT"           MOUNT_RC=1 "MOUNT_MSG=Failed to retrieve AWS security credentials" cmd_try noiam
t "try: target still mounted"                             try_mounted cmd_try notls
t "denied: EACCES counts as POSIX"                        denied "ls a dir with no rights" bash -c 'echo "ls: cannot open directory: Permission denied" >&2; exit 2'
t "denied: EIO is another layer -> FAIL"                  denied "ls on a broken mount" bash -c 'echo "ls: reading directory: Input/output error" >&2; exit 2'
t "denied: success -> FAIL"                               denied "ls that worked" true
t "perf: run limit reached"                               perf_limit
t "perf: PERF_FORCE does not skip the EFS mount check" PERF_FORCE=1 cmd_perf p3
t "clean: app not mounted"                                cmd_clean
t "counter run: n too large"                              app_mounted cmd_counter run c1 5000 nolock
t "counter run: bad mode"                                 app_mounted cmd_counter run c1 10 maybe
t "share: bad sub-command"                                app_mounted cmd_share append s1
t "share write: published_ns after the rename"            app_mounted as_b cmd_share write t1
t "share write: same tag twice -> refused, evidence kept" share_twice
t "share read: file there before the read -> stale"       share_stale
t "share read: published while polling -> observed_ns"    share_live
t "share read: file from another run/format -> refused"   share_old_format
t "perms: other and root not mounted"                     app_mounted cmd_perms
t "perf: bad name"                                        cmd_perf "a b"
