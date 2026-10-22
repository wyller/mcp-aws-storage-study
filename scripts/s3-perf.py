"""Small, capped S3 performance tests for the Day 3 lab (writes: run it after aws-lab).

Uses the default credential chain, so it picks up whatever aws-lab exported. Transfer settings
go through boto3's TransferConfig, so ~/.aws/config is never touched.

  .venv/bin/python -I scripts/s3-perf.py small [--count 100]   # serial vs parallel 1 KiB PUTs
  .venv/bin/python -I scripts/s3-perf.py multipart              # 100 MiB: single PUT vs multipart
  .venv/bin/python -I scripts/s3-perf.py repl-latency           # PUT -> COMPLETED, 1 KiB vs 100 MiB

Objects of "small" and "multipart" go under perf/ (outside the replication filter);
"repl-latency" writes under repl/perf/. Results are appended as JSON lines to
notas/dados/s3-dia3/perf.jsonl.
"""

import argparse
import json
import os
import statistics
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

import boto3
from boto3.s3.transfer import TransferConfig

MAX_SMALL = 300  # ~US$ 0.003 of PUTs per run; the per-prefix limit (3,500 PUT/s) is not the goal
BIG_MIB = 100
MIB = 1024 * 1024

s3 = boto3.client("s3", region_name="us-east-1")
account = boto3.client("sts").get_caller_identity()["Account"]
src = f"lab-s3-repl-src-{account}"
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "notas", "dados", "s3-dia3", "perf.jsonl")


def record(test, **data):
    row = {"test": test, "at": datetime.now(timezone.utc).isoformat(timespec="seconds"), **data}
    print(json.dumps(row))
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "a") as f:
        f.write(json.dumps(row) + "\n")


def timed_put(key, body):
    t = time.perf_counter()
    s3.put_object(Bucket=src, Key=key, Body=body)
    return time.perf_counter() - t


def latency_stats(lat):
    lat = sorted(lat)
    return {
        "p50_ms": round(statistics.median(lat) * 1000, 1),
        "p99_ms": round(lat[min(len(lat) - 1, int(len(lat) * 0.99))] * 1000, 1),
    }


def small(count):
    if count > MAX_SMALL:
        sys.exit(f"--count capped at {MAX_SMALL}")
    body = os.urandom(1024)
    run = int(time.time())
    for mode, workers in (("serial", 1), ("parallel", 16)):
        keys = [f"perf/small/{run}/{mode}/{i:04d}" for i in range(count)]
        t = time.perf_counter()
        with ThreadPoolExecutor(workers) as pool:
            lat = list(pool.map(lambda k: timed_put(k, body), keys))
        total = time.perf_counter() - t
        record("small", mode=mode, workers=workers, count=count, total_s=round(total, 2),
               ops_per_s=round(count / total, 1), **latency_stats(lat))


def big_file():
    f = tempfile.NamedTemporaryFile(prefix="lab-s3-perf-", delete=False)
    for _ in range(BIG_MIB):
        f.write(os.urandom(MIB))
    f.close()
    return f.name


def multipart():
    path = big_file()
    variants = {
        # threshold above the size: one PUT, one TCP stream, no retry of a single part
        "single-put": TransferConfig(multipart_threshold=BIG_MIB * MIB + 1, use_threads=False),
        "default-8MiB-x10": TransferConfig(),
        "32MiB-x4": TransferConfig(multipart_chunksize=32 * MIB, max_concurrency=4),
    }
    try:
        for name, cfg in variants.items():
            t = time.perf_counter()
            s3.upload_file(path, src, f"perf/big/{name}.bin", Config=cfg)
            total = time.perf_counter() - t
            record("multipart", variant=name, mib=BIG_MIB, total_s=round(total, 2),
                   mib_per_s=round(BIG_MIB / total, 1))
    finally:
        os.unlink(path)


def wait_replication(key, timeout=900):
    start = time.perf_counter()
    while time.perf_counter() - start < timeout:
        status = s3.head_object(Bucket=src, Key=key).get("ReplicationStatus", "NONE")
        if status != "PENDING":
            return status, time.perf_counter() - start
        time.sleep(1)
    return "TIMEOUT", time.perf_counter() - start


def repl_latency():
    path = big_file()
    try:
        for name, size in (("1KiB", 1024), (f"{BIG_MIB}MiB", BIG_MIB * MIB)):
            key = f"repl/perf/{name}.bin"
            if size == 1024:
                s3.put_object(Bucket=src, Key=key, Body=os.urandom(1024))
            else:
                s3.upload_file(path, src, key)
            status, secs = wait_replication(key)
            record("repl-latency", object=name, status=status, seconds_after_put=round(secs, 1))
    finally:
        os.unlink(path)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("test", choices=["small", "multipart", "repl-latency"])
    p.add_argument("--count", type=int, default=100)
    a = p.parse_args()
    {"small": lambda: small(a.count), "multipart": multipart, "repl-latency": repl_latency}[a.test]()


if __name__ == "__main__":
    main()
