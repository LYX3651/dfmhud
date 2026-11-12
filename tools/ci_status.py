# -*- coding: utf-8 -*-
"""查 run 状态 + 拉日志，纯 ASCII 输出"""
import io
import json
import sys
import time
import urllib.request
import zipfile

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

TOKEN = sys.argv[1]
WAIT = int(sys.argv[2]) if len(sys.argv) > 2 else 0
OWNER, REPO = "LYX3651", "dfmhud"
PROXY = "http://127.0.0.1:7897"


def call(method, path, data=None, raw=False):
    body = json.dumps(data).encode() if data is not None else None
    r = urllib.request.Request("https://api.github.com" + path, data=body, method=method)
    r.add_header("Authorization", "token " + TOKEN)
    r.add_header("Content-Type", "application/json")
    o = urllib.request.build_opener(
        urllib.request.ProxyHandler({"http": PROXY, "https": PROXY})
    )
    try:
        b = o.open(r, timeout=60).read()
        if raw:
            return 200, b
        return 200, (json.loads(b) if b else {})
    except urllib.error.HTTPError as e:
        return e.code, e.read()[:400]


def snapshot():
    st, runs = call("GET", "/repos/%s/%s/actions/runs?per_page=3" % (OWNER, REPO))
    if not isinstance(runs, dict):
        print("  runs err", st, runs)
        return None
    items = runs.get("workflow_runs", [])
    if not items:
        print("  no runs")
        return None
    r0 = items[0]
    print("  run #%s id=%s name=%s status=%s concl=%s" % (
        r0.get("run_number"), r0.get("id"), r0.get("name"),
        r0.get("status"), r0.get("conclusion")))
    st, jobs = call("GET", "/repos/%s/%s/actions/runs/%s/jobs" % (OWNER, REPO, r0["id"]))
    if isinstance(jobs, dict):
        for j in jobs.get("jobs", []):
            print("    job %-14s status=%-10s concl=%-10s runner=%r" % (
                j.get("name"), j.get("status"), j.get("conclusion"), j.get("runner_name")))
            for s in j.get("steps", []):
                print("       [%-9s] %s" % (s.get("conclusion"), s.get("name")))
    return r0


def dump_log(rid):
    st, b = call("GET", "/repos/%s/%s/actions/runs/%s/logs" % (OWNER, REPO, rid), raw=True)
    print("\n=== logs status:", st, "bytes:", len(b) if isinstance(b, bytes) else 0)
    if st != 200 or not isinstance(b, bytes):
        print("  ", b[:300] if isinstance(b, bytes) else b)
        return
    try:
        z = zipfile.ZipFile(io.BytesIO(b))
        names = z.namelist()
        print("  entries:", len(names))
        for n in names:
            if "build" in n.lower() or n.endswith(".txt"):
                txt = z.read(n).decode("utf-8", "replace")
                if len(txt) < 200:
                    continue
                print("\n----- %s (tail) -----" % n)
                print(txt[-7000:])
                break
    except Exception as e:
        print("  unzip fail:", e)


r = snapshot()
if WAIT and r and r.get("status") != "completed":
    print("  waiting...")
    for i in range(WAIT):
        time.sleep(15)
        r = snapshot()
        if r and r.get("status") == "completed":
            break
if r:
    dump_log(r["id"])
