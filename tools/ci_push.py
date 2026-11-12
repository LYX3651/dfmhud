# -*- coding: utf-8 -*-
"""建仓库 -> push -> 等 Actions -> 下 artifact

用法: python ci_push.py <token> [repo_name]
"""
import json
import os
import subprocess
import sys
import time
import urllib.request

TOKEN = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("GH_TOKEN", "")
REPO = sys.argv[2] if len(sys.argv) > 2 else "dfmhud"
PROXY = "http://127.0.0.1:7897"
OWNER = "LYX3651"
API = "https://api.github.com"


def req(method, path, data=None, accept="application/vnd.github+json"):
    url = path if path.startswith("http") else API + path
    body = json.dumps(data).encode() if data is not None else None
    r = urllib.request.Request(url, data=body, method=method)
    r.add_header("Authorization", "token " + TOKEN)
    r.add_header("Accept", accept)
    r.add_header("Content-Type", "application/json")
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({"http": PROXY, "https": PROXY})
    )
    try:
        with opener.open(r, timeout=40) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"raw": raw[:400].decode(errors="replace")}


def main():
    print("=== 1) 确认账号 ===")
    st, me = req("GET", "/user")
    print("  status=%s login=%s" % (st, me.get("login")))
    owner = me.get("login") or OWNER

    print("=== 2) 建仓库 ===")
    st, repo = req(
        "POST",
        "/user/repos",
        {"name": REPO, "description": "iOS 14-17 TrollStore HUD", "private": True, "auto_init": False},
    )
    if st == 201:
        print("  created:", repo.get("full_name"))
    elif st == 422:
        print("  已存在，复用")
        st2, repo = req("GET", "/repos/%s/%s" % (owner, REPO))
        print("  ->", repo.get("full_name"), st2)
    else:
        print("  FAIL", st, str(repo)[:300])
        return 1

    clone = repo.get("clone_url")
    print("  clone_url:", clone)

    print("=== 3) git init + commit + push ===")
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    print("  workdir:", root)

    remote = "https://%s:%s@github.com/%s/%s.git" % (owner, TOKEN, owner, REPO)

    cmds = [
        ["git", "init", "-b", "main"],
        ["git", "add", "-A"],
        ["git", "-c", "user.name=%s" % owner, "-c", "user.email=%s@users.noreply.github.com" % owner,
         "commit", "-m", "DFMHUD: iOS 14-17 TrollStore HUD"],
        ["git", "remote", "remove", "origin"],
        ["git", "remote", "add", "origin", remote],
        ["git", "push", "-u", "origin", "main", "--force"],
    ]
    env = dict(os.environ)
    env["HTTPS_PROXY"] = PROXY
    env["HTTP_PROXY"] = PROXY
    env["GIT_TERMINAL_PROMPT"] = "0"
    for c in cmds:
        p = subprocess.run(c, cwd=root, capture_output=True, text=True, env=env)
        out = (p.stdout + p.stderr).strip().replace(TOKEN, "<redacted>")
        print("  $ %s -> rc=%d" % (" ".join(c[:3]), p.returncode))
        if out:
            print("     ", out[:400])
        if p.returncode != 0 and c[1] != "remote":
            print("  !! 失败，中止")
            return 1

    print("=== 4) 等待 Actions 启动 ===")
    for i in range(20):
        time.sleep(6)
        st, runs = req("GET", "/repos/%s/%s/actions/runs?per_page=5" % (owner, REPO))
        items = runs.get("workflow_runs", [])
        if items:
            r0 = items[0]
            print("  run #%s id=%s status=%s" % (r0.get("run_number"), r0.get("id"), r0.get("status")))
            if r0.get("status") in ("queued", "in_progress"):
                print("  RUN_ID=%s" % r0.get("id"))
                break
        else:
            print("  (暂无 run，等待 %d)" % i)
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
