# -*- coding: utf-8 -*-
"""轮询 Actions run 状态，结束后下载 artifact"""
import json
import os
import sys
import time
import urllib.request
import zipfile

TOKEN = sys.argv[1]
OWNER, REPO = "LYX3651", "dfmhud"
PROXY = "http://127.0.0.1:7897"
API = "https://api.github.com"


def req(method, path, raw_out=None):
    url = path if path.startswith("http") else API + path
    r = urllib.request.Request(url, method=method)
    r.add_header("Authorization", "token " + TOKEN)
    r.add_header("Accept", "application/vnd.github+json")
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({"http": PROXY, "https": PROXY})
    )
    try:
        with opener.open(r, timeout=60) as resp:
            data = resp.read()
            if raw_out:
                open(raw_out, "wb").write(data)
                return resp.status, {"saved": raw_out, "bytes": len(data)}
            return resp.status, (json.loads(data) if data else {})
    except urllib.error.HTTPError as e:
        return e.code, {"err": e.read()[:300].decode(errors="replace")}


def main():
    print("=== 找 run ===")
    st, runs = req("GET", "/repos/%s/%s/actions/runs?per_page=3" % (OWNER, REPO))
    items = runs.get("workflow_runs", [])
    if not items:
        print("  没有 run"); return 1
    run = items[0]
    rid = run["id"]
    print("  run id=%s number=%s" % (rid, run.get("run_number")))

    print("=== 轮询 ===")
    last = None
    for i in range(100):
        st, r = req("GET", "/repos/%s/%s/actions/runs/%s" % (OWNER, REPO, rid))
        status, concl = r.get("status"), r.get("conclusion")
        if (status, concl) != last:
            print("  [%3ds] status=%-10s conclusion=%s" % (i * 8, status, concl))
            last = (status, concl)
        if status == "completed":
            break
        time.sleep(8)

    print("=== 最终 ===")
    print("  status=%s conclusion=%s" % (status, concl))
    print("  html=%s" % r.get("html_url"))

    if concl != "success":
        print("=== 拉日志 ===")
        st, arts = req("GET", "/repos/%s/%s/actions/runs/%s/artifacts" % (OWNER, REPO, rid))
        for a in arts.get("artifacts", []):
            print("  artifact: %s (%d B)" % (a["name"], a["size_in_bytes"]))
        # 取 job 日志
        st, jobs = req("GET", "/repos/%s/%s/actions/runs/%s/jobs" % (OWNER, REPO, rid))
        for j in jobs.get("jobs", []):
            print("\n--- job: %s -> %s ---" % (j.get("name"), j.get("conclusion")))
            for s in j.get("steps", []):
                print("   [%s] %s" % (s.get("conclusion"), s.get("name")))
            jid = j.get("id")
            st, log = req("GET", "/repos/%s/%s/actions/jobs/%s/logs" % (OWNER, REPO, jid),
                          raw_out="/tmp/job.log")
            if st == 200:
                txt = open("/tmp/job.log", "rb").read().decode("utf-8", "replace")
                tail = txt[-6000:]
                print("=== 日志尾部 ===")
                print(tail)
        return 1

    print("=== 下载 artifact ===")
    st, arts = req("GET", "/repos/%s/%s/actions/runs/%s/artifacts" % (OWNER, REPO, rid))
    for a in arts.get("artifacts", []):
        print("  %s (%d B, expired=%s)" % (a["name"], a["size_in_bytes"], a.get("expired")))
        if a["name"] != "DFMHUD-tipa":
            continue
        st, info = req("GET", "/repos/%s/%s/actions/artifacts/%s/zip" % (OWNER, REPO, a["id"]),
                       raw_out="/tmp/dfmhud_art.zip")
        print("  download:", st, info)
        if st == 200:
            out = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                               "..", "DFMHUD.tipa")
            out = os.path.abspath(out)
            with zipfile.ZipFile("/tmp/dfmhud_art.zip") as z:
                print("  zip entries:", z.namelist())
                for n in z.namelist():
                    if n.endswith(".tipa"):
                        with z.open(n) as src, open(out, "wb") as dst:
                            dst.write(src.read())
                        print("  saved ->", out, os.path.getsize(out), "bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
