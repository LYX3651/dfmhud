# -*- coding: utf-8 -*-
"""git add/commit/push（带代理和凭据）"""
import os
import subprocess
import sys

TOKEN = sys.argv[1]
MSG = sys.argv[2] if len(sys.argv) > 2 else "update"
OWNER, REPO = "LYX3651", "dfmhud"
PROXY = "http://127.0.0.1:7897"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

env = dict(os.environ)
env["HTTPS_PROXY"] = PROXY
env["HTTP_PROXY"] = PROXY
env["GIT_TERMINAL_PROMPT"] = "0"
env["GIT_ASKPASS"] = "echo"

remote = "https://%s:%s@github.com/%s/%s.git" % (OWNER, TOKEN, OWNER, REPO)

cmds = [
    ["git", "add", "-A"],
    ["git", "-c", "user.name=%s" % OWNER,
     "-c", "user.email=%s@users.noreply.github.com" % OWNER,
     "commit", "-m", MSG],
    ["git", "remote", "set-url", "origin", remote],
    ["git", "push", "origin", "main", "--force"],
]

for c in cmds:
    p = subprocess.run(c, cwd=ROOT, capture_output=True, text=True, env=env)
    out = (p.stdout + p.stderr).strip().replace(TOKEN, "<redacted>")
    print("$ %s -> rc=%d" % (" ".join(c[:2]), p.returncode))
    if out:
        print("  " + out[:500].replace("\n", "\n  "))
