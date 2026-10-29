#!/usr/bin/env python3
"""lab-efs-visibility: controlled cross-client visibility test for the Day 5 EFS lab (stdlib only).

Shipped by `scripts/efs-lab.sh visibility` over SSM on each run (never installed); one copy per client:
  python3 -I lab-efs-visibility.py writer|reader <run> <start_epoch> --client a|b [options]
  python3 -I lab-efs-visibility.py analyze <writer.json> <reader.json>      (locally, no AWS)

Both sides follow the same wall-clock schedule from <start_epoch>, so SSM delivery happens before the
measurement, never inside it. Nothing connects the two clients but the file system.

Phase A, a known file: the writer rewrites known.dat once per slot (open, write "seq=i", close); the
reader re-opens and reads it every 10 ms. Each open revalidates the file (close-to-open), so this is
the data visibility of a file both clients already know.
Phase B, new names: per slot the writer renames one new file into each of three directories; the
reader looks for it with stat, open and listdir, one directory per method, so one method never
refreshes the cache another is being measured on. The reader starts looking before the file exists,
like the share test did, so a negative lookup gets cached.

Instants: published_ns on the writer (after close or rename returns), observed_ns on the reader
(after the poll that first saw it). Both are time.time_ns() of their own client, so a difference
carries the offset between the two clocks; chrony's state on both sides bounds it.
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import threading
import time

METHODS = ("stat", "open", "listdir")
LIMITS = {"a_iter": 50, "b_iter": 5, "duration_s": 480}


def now():
    return time.time_ns()


def sleep_until(t_ns):
    delay = (t_ns - now()) / 1e9
    if delay > 0:
        time.sleep(delay)


def die(msg):
    print("ERROR: " + msg, file=sys.stderr)
    sys.exit(1)


def pct(values, p):
    if not values:
        return None
    s = sorted(values)
    k = (len(s) - 1) * p / 100.0
    lo = int(k)
    hi = min(lo + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (k - lo)


def latency(ns_values):
    us = [v / 1000.0 for v in ns_values]
    return {"count": len(us), "p50_us": pct(us, 50), "p99_us": pct(us, 99), "max_us": max(us) if us else None}


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def chrony():
    """chronyc -c tracking: 4 = system time offset (s), 10 = root delay, 11 = root dispersion."""
    try:
        out = subprocess.run(["chronyc", "-c", "tracking"], capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError) as e:
        return {"error": str(e)}
    f = out.split(",")
    try:
        return {"raw": out, "reference": f[1], "stratum": int(f[2]), "system_time_s": float(f[4]),
                "root_delay_s": float(f[10]), "root_dispersion_s": float(f[11])}
    except (IndexError, ValueError):
        return {"raw": out}


def require_efs(path):
    """The run directory must live on NFS 4 served through the local TLS tunnel (Day 1 lesson)."""
    best = None
    with open("/proc/self/mounts") as m:
        for line in m:
            src, target, fstype = line.split()[:3]
            if (path + "/").startswith(target.rstrip("/") + "/") and (best is None or len(target) > len(best[1])):
                best = (src, target, fstype)
    if not best or best[2] != "nfs4" or not best[0].startswith("127.0.0.1:"):
        die("%s is not on an EFS mount through the TLS tunnel (found %s)" % (path, best))


def write_new(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)


def schedule(a):
    a_end = a.start_ns + int(a.a_iter * a.a_period * 1e9)
    b0 = a_end + int(2e9)
    return a_end, b0


def writer(a):
    base = a.dir
    if os.path.exists(base):
        die("%s already exists: use a new run name (evidence of earlier runs is kept)" % base)
    os.makedirs(os.path.join(base, ".tmp"))
    for m in METHODS:
        os.mkdir(os.path.join(base, "b-" + m))
    known = os.path.join(base, "known.dat")
    write_new(known, b"seq=-1\n")
    ready = now()
    if ready > a.start_ns - int(a.prep_margin * 1e9):
        die("prepared %.1f s before the start, less than the %.1f s margin: the reader could look too early"
            % ((a.start_ns - ready) / 1e9, a.prep_margin))
    events = []
    for i in range(a.a_iter):
        sleep_until(a.start_ns + int((i + 0.5) * a.a_period * 1e9))
        t0 = now()
        fd = os.open(known, os.O_WRONLY | os.O_TRUNC)
        os.write(fd, ("seq=%d\n" % i).encode())
        os.close(fd)
        events.append({"phase": "A", "i": i, "write_start_ns": t0, "published_ns": now()})
    _, b0 = schedule(a)
    for j in range(a.b_iter):
        sleep_until(b0 + int((j * a.b_slot + a.b_publish_after) * 1e9))
        for m in METHODS:
            data = os.urandom(4096)
            tmp = os.path.join(base, ".tmp", "%s-%d" % (m, j))
            write_new(tmp, data)
            os.rename(tmp, os.path.join(base, "b-" + m, "new-%d" % j))
            events.append({"phase": "B", "method": m, "i": j, "published_ns": now(), "sha256": sha256(data)})
    return {"prepared_ns": ready, "events": events}


def poll_new(a, method, j, deadline, out, lat):
    d = os.path.join(a.dir, "b-" + method)
    name = "new-%d" % j
    path = os.path.join(d, name)
    first = now()
    polls = 0
    interval = a.b_poll * (2 if method == "listdir" else 1)
    while now() < deadline:
        polls += 1
        t0 = now()
        if method == "stat":
            try:
                os.stat(path)
                found = True
            except FileNotFoundError:
                found = False
        elif method == "open":
            try:
                os.close(os.open(path, os.O_RDONLY))
                found = True
            except FileNotFoundError:
                found = False
        else:
            found = name in os.listdir(d)
        t1 = now()
        lat.append(t1 - t0)
        if found:
            with open(path, "rb") as f:
                digest = sha256(f.read())
            out.append({"phase": "B", "method": method, "i": j, "first_poll_ns": first, "observed_ns": t1,
                        "polls": polls, "sha256": digest})
            return
        time.sleep(interval)
    out.append({"phase": "B", "method": method, "i": j, "first_poll_ns": first, "observed_ns": None, "polls": polls})


def reader(a):
    # Never touch the run directory before the writer has prepared it: a lookup of a name that does
    # not exist yet would itself be cached, and the warm-up would fail for 30-60 s.
    sleep_until(a.start_ns - int(a.warmup * 1e9))
    if now() > a.start_ns:
        die("reader started after the scheduled start")
    known = os.path.join(a.dir, "known.dat")
    try:
        with open(known, "rb") as f:
            initial = f.read()
        leftovers = [m for m in METHODS if os.listdir(os.path.join(a.dir, "b-" + m))]
    except FileNotFoundError as e:
        die("run directory not visible at warm-up (%s): writer late or failed" % e)
    # Anything but the writer's fresh state means an earlier run: measuring it would be a false pass.
    if initial != b"seq=-1\n" or leftovers:
        die("run directory is not fresh (known.dat %r, files in %s): stale, use a new run name" % (initial, leftovers))
    events, lat_a = [], []
    seen = set()
    a_end, b0 = schedule(a)
    sleep_until(a.start_ns)
    while now() < a_end + int(1.5e9):
        t0 = now()
        fd = os.open(known, os.O_RDONLY)
        data = os.read(fd, 64)
        os.close(fd)
        t1 = now()
        lat_a.append(t1 - t0)
        m = re.match(rb"seq=(\d+)", data)
        if m and int(m.group(1)) not in seen:
            seen.add(int(m.group(1)))
            events.append({"phase": "A", "i": int(m.group(1)), "observed_ns": t1})
        time.sleep(a.a_poll)
    lat_b = {m: [] for m in METHODS}
    for j in range(a.b_iter):
        slot = b0 + int(j * a.b_slot * 1e9)
        sleep_until(slot)
        # Stop a little before the next slot, so a miss never overlaps the next publish.
        deadline = slot + int((a.b_slot - min(1.0, a.b_slot * 0.2)) * 1e9)
        found = []
        threads = [threading.Thread(target=poll_new, args=(a, m, j, deadline, found, lat_b[m])) for m in METHODS]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        events.extend(found)
    lats = {"A_open_read_close": latency(lat_a)}
    lats.update({"B_" + m: latency(v) for m, v in lat_b.items()})
    return {"events": events, "latency": lats}


def analyze(writer_json, reader_json):
    w = json.load(open(writer_json))
    r = json.load(open(reader_json))
    pub = {(e["phase"], e.get("method"), e["i"]): e for e in w["events"]}
    rows = {}
    missing = []
    for e in r["events"]:
        k = (e["phase"], e.get("method"), e["i"])
        p = pub.get(k)
        if p is None:
            continue
        if e["observed_ns"] is None:
            missing.append(k)
            continue
        if e.get("sha256") and e["sha256"] != p["sha256"]:
            missing.append(k + ("sha256 differs",))
            continue
        rows.setdefault((e["phase"], e.get("method")), []).append({
            "i": e["i"], "delta_ms": (e["observed_ns"] - p["published_ns"]) / 1e6,
            "searching_ms": (e["observed_ns"] - e["first_poll_ns"]) / 1e6 if "first_poll_ns" in e else None})
    never = [k for k in pub if k not in {(e["phase"], e.get("method"), e["i"]) for e in r["events"]}]

    def bound(c):
        return abs(c.get("system_time_s", 0)) + c.get("root_dispersion_s", 0) + c.get("root_delay_s", 0) / 2

    clock_ms = max(bound(w.get("chrony_before", {})) + bound(r.get("chrony_before", {})),
                   bound(w.get("chrony_after", {})) + bound(r.get("chrony_after", {}))) * 1e3
    result = {"run": w.get("run"), "writer": w.get("client"), "reader": r.get("client"),
              "clock_offset_bound_ms": clock_ms, "groups": {}, "not_observed": [list(k) for k in missing],
              "not_reported": [list(k) for k in never], "reader_op_latency_us": r.get("latency")}
    for (phase, method), v in sorted(rows.items(), key=lambda x: (x[0][0], x[0][1] or "")):
        d = [x["delta_ms"] for x in v]
        result["groups"]["%s%s" % (phase, "-" + method if method else "")] = {
            "n": len(d), "p50_ms": pct(d, 50), "p99_ms": pct(d, 99), "min_ms": min(d), "max_ms": max(d),
            "raw": sorted(v, key=lambda x: x["i"])}
    return result


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("role", choices=("writer", "reader", "analyze"))
    p.add_argument("run")
    p.add_argument("start", help="start, epoch seconds (analyze: the reader JSON)")
    p.add_argument("--client", default="?")
    p.add_argument("--root", default="/mnt/efs-app/runs")
    p.add_argument("--a-iter", type=int, default=20)
    p.add_argument("--a-period", type=float, default=1.0)
    p.add_argument("--a-poll", type=float, default=0.01)
    p.add_argument("--b-iter", type=int, default=3)
    p.add_argument("--b-slot", type=float, default=65.0, help="longer than acdirmax (60 s)")
    p.add_argument("--b-publish-after", type=float, default=3.0)
    p.add_argument("--b-poll", type=float, default=0.01)
    p.add_argument("--prep-margin", type=float, default=10.0)
    p.add_argument("--warmup", type=float, default=5.0)
    p.add_argument("--allow-local", action="store_true", help="tests only: skip the EFS mount check")
    a = p.parse_args()
    if a.role == "analyze":
        print(json.dumps(analyze(a.run, a.start), indent=1))
        return
    if not re.fullmatch(r"[a-z0-9-]{1,20}", a.run):
        die("run name: lowercase letters, digits and '-', up to 20 characters")
    duration = a.a_iter * a.a_period + 2 + a.b_iter * a.b_slot
    if a.a_iter > LIMITS["a_iter"] or a.b_iter > LIMITS["b_iter"] or duration > LIMITS["duration_s"]:
        die("over the limits %s (duration %.0f s)" % (LIMITS, duration))
    if a.a_poll < 0.005 or a.b_poll < 0.005:
        die("poll intervals below 5 ms")
    a.start_ns = int(float(a.start) * 1e9)
    a.dir = os.path.join(a.root, "vis-" + a.run)
    if not a.allow_local:
        require_efs(a.root)
    out = {"role": a.role, "run": a.run, "client": a.client, "host": os.uname().nodename,
           "start_ns": a.start_ns, "received_ns": now(), "chrony_before": chrony(),
           "config": {k: v for k, v in vars(a).items() if k not in ("start_ns",)}}
    out.update(writer(a) if a.role == "writer" else reader(a))
    out["chrony_after"] = chrony()
    out["finished_ns"] = now()
    print(json.dumps(out))


if __name__ == "__main__":
    main()
