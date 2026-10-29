#!/usr/bin/env bash
# Run from anywhere: bash terraform/efs/tests/visibility-local.sh terraform/efs/files/lab-efs-visibility.py
# Local run of the visibility experiment on a temp directory (no AWS, no NFS): a short schedule,
# writer and reader as two processes, then the analysis. Plus the guards (stale runs, limits, mount).
set -u
py="$1"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fast=(--root "$T" --allow-local --a-iter 5 --a-period 0.2 --b-iter 2 --b-slot 1.0 --b-publish-after 0.3 --prep-margin 0.5 --warmup 0.3)
t() { echo "--- $1"; }
start() { python3 -I -c 'import time; print(f"{time.time() + 1.5:.3f}")'; }

t "full run: writer + reader, then analyze"
s=$(start)
python3 -I "$py" writer r1 "$s" --client a "${fast[@]}" > "$T/w.json" &
python3 -I "$py" reader r1 "$s" --client b "${fast[@]}" > "$T/r.json"
wait
python3 -I "$py" analyze "$T/w.json" "$T/r.json" > "$T/an.json"
python3 -I - "$T/an.json" <<'EOF'
import json, sys
a = json.load(open(sys.argv[1]))
want = {"A": 5, "B-stat": 2, "B-open": 2, "B-listdir": 2}
got = {k: v["n"] for k, v in a["groups"].items()}
print("    groups:", got, "| not observed:", a["not_observed"], "| not reported:", a["not_reported"])
print("    A p50 %.2f ms, B-stat max %.2f ms (local disk: no NFS cache)" % (a["groups"]["A"]["p50_ms"], a["groups"]["B-stat"]["max_ms"]))
ok = got == want and not a["not_observed"] and not a["not_reported"] and all(
    -5 < r["delta_ms"] < 100 for g in a["groups"].values() for r in g["raw"])
print("    " + ("PASS" if ok else "FAIL") + "  every event observed once, sha256 matched, deltas small")
EOF

t "writer again on the same run: refused, evidence kept"
python3 -I "$py" writer r1 "$(start)" --client a "${fast[@]}" 2>&1 | sed 's/^/    /'

t "reader on a stale run directory: refused"
python3 -I "$py" reader r1 "$(start)" --client b "${fast[@]}" 2>&1 | sed 's/^/    /'

t "reader started after the scheduled start: refused"
python3 -I "$py" reader r2 "$(python3 -I -c 'import time; print(time.time() - 1)')" --client b "${fast[@]}" 2>&1 | sed 's/^/    /'

t "over the limits: refused"
python3 -I "$py" writer r3 "$(start)" --root "$T" --allow-local --b-iter 9 2>&1 | sed 's/^/    /'

t "not on an EFS mount (no --allow-local): refused"
python3 -I "$py" writer r4 "$(start)" --root "$T" 2>&1 | sed 's/^/    /'

t "bad run name: refused"
python3 -I "$py" writer "../x" "$(start)" --root "$T" --allow-local 2>&1 | sed 's/^/    /'
