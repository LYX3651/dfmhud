# -*- coding: utf-8 -*-
"""详细诊断一个 run：为什么没跑起来"""
import json
import sys
import urllib.request

TOKEN = sys.argv[1]
RID = sys.argv[2] if len(sys.argv) > 2 else ""
OWNER, REPO = "LYX3651", "dfmhud"
PROXY = "http://127.0.0.1:7897"


def get(path):
    r = urllib.request.Request("https://api.github.com" + path)
    r.add_header("Authorization", "token " + TOKEN)
    o = urllib.request.build_opener(
        urllib.request.ProxyHandler({"http": PROXY, "https": PROXY})
    )
    try:
        raw = o.open(r, timeout=40).read()
        return 200, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        return e.code, e.read()[:400].decode(errors="replace")


if not RID:
    st, runs = get("/repos/%s/%s/actions/runs?per_page=1" % (OWNER, REPO))
    RID = str(runs["workflow_runs"][0]["id"])
    print("latest run:", RID)

st, r = get("/repos/%s/%s/actions/runs/%s" % (OWNER, REPO, RID))
print("\n=== RUN ===")
for k in ["status", "conclusion", "created_at", "updated_at", "run_attempt"]:
    print("  %-14s %s" % (k, r.get(k)))
print("  html:", r.get("html_url"))

st, jobs = get("/repos/%s/%s/actions/runs/%s/jobs" % (OWNER, REPO, RID))
print("\n=== JOBS ===", jobs.get("total_count"))
for j in jobs.get("jobs", []):
    print("  %s | concl=%s | started=%s" % (j.get("name"), j.get("conclusion"), j.get("started_at")))
    print("    runner=%r labels=%s" % (j.get("runner_name"), j.get("labels")))
    for s in j.get("steps", []):
        print("      [%s] %s" % (s.get("conclusion"), s.get("name")))

# 试着拉原始日志
st, log = get("/repos/%s/%s/actions/runs/%s/logs" % (OWNER, REPO, RID))
print("\n=== LOGS ===", st)
if st == 200 and isinstance(log, dict):
    print(" (binary zip)")
else:
    print(" ", str(log)[:400])
