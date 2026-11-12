# -*- coding: utf-8 -*-
"""列出所有 workflow 及其最近 run，并触发 probe"""
import json
import sys
import time
import urllib.request

TOKEN = sys.argv[1]
OWNER, REPO = "LYX3651", "dfmhud"
PROXY = "http://127.0.0.1:7897"


def call(method, path, data=None):
    body = json.dumps(data).encode() if data is not None else None
    r = urllib.request.Request("https://api.github.com" + path, data=body, method=method)
    r.add_header("Authorization", "token " + TOKEN)
    r.add_header("Content-Type", "application/json")
    o = urllib.request.build_opener(
        urllib.request.ProxyHandler({"http": PROXY, "https": PROXY})
    )
    try:
        raw = o.open(r, timeout=45).read()
        return 200, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        return e.code, e.read()[:400].decode(errors="replace")


print("=== workflows ===")
st, wf = call("GET", "/repos/%s/%s/actions/workflows" % (OWNER, REPO))
for w in (wf.get("workflows", []) if isinstance(wf, dict) else []):
    print("  id=%-12s %-14s %s" % (w.get("id"), w.get("name"), w.get("path")))

print("\n=== 触发 probe ===")
for wid in (wf.get("workflows", []) if isinstance(wf, dict) else []):
    if "probe" in (wid.get("path") or ""):
        st, r = call("POST", "/repos/%s/%s/actions/workflows/%s/dispatches" % (OWNER, REPO, wid["id"]),
                     {"ref": "main"})
        print("  dispatch probe -> %s %s" % (st, "" if st in (200, 204) else str(r)[:150]))

time.sleep(20)

print("\n=== 最近 runs ===")
st, runs = call("GET", "/repos/%s/%s/actions/runs?per_page=5" % (OWNER, REPO))
for w in (runs.get("workflow_runs", []) if isinstance(runs, dict) else []):
    print("  #%s %-10s status=%-10s concl=%s" % (
        w.get("run_number"), (w.get("name") or "")[:10], w.get("status"), w.get("conclusion")))
    if w.get("status") not in ("completed",):
        continue
    st, jobs = call("GET", "/repos/%s/%s/actions/runs/%s/jobs" % (OWNER, REPO, w["id"]))
    for j in (jobs.get("jobs", []) if isinstance(jobs, dict) else []):
        print("      job %-18s concl=%-10s runner=%r labels=%s" % (
            j.get("name"), j.get("conclusion"), j.get("runner_name"), j.get("labels")))
