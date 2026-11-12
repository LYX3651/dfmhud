# -*- coding: utf-8 -*-
"""把仓库设为 public 并重跑 workflow"""
import json
import sys
import time
import urllib.request

TOKEN = sys.argv[1]
OWNER, REPO = "LYX3651", "dfmhud"
PROXY = "http://127.0.0.1:7897"


def call(method, path, data=None):
    body = json.dumps(data).encode() if data is not None else None
    url = "https://api.github.com" + path
    r = urllib.request.Request(url, data=body, method=method)
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


print("=== 1) 设为 public ===")
st, r = call("PATCH", "/repos/%s/%s" % (OWNER, REPO), {"private": False})
print("  status=%s private=%s" % (st, r.get("private") if isinstance(r, dict) else r))

time.sleep(3)

print("=== 2) 重跑 workflow ===")
st, r = call("POST", "/repos/%s/%s/actions/workflows/build.yml/dispatches" % (OWNER, REPO),
             {"ref": "main"})
print("  dispatch status=%s  %s" % (st, "" if st in (204, 200) else str(r)[:200]))

time.sleep(10)

print("=== 3) 查新 run ===")
st, runs = call("GET", "/repos/%s/%s/actions/runs?per_page=3" % (OWNER, REPO))
for w in (runs.get("workflow_runs", []) if isinstance(runs, dict) else []):
    print("  #%s id=%s event=%s status=%s" % (w.get("run_number"), w.get("id"),
                                              w.get("event"), w.get("status")))
