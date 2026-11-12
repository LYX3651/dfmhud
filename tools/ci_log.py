# -*- coding: utf-8 -*-
"""拉取指定 run 的完整日志，过滤到失败步骤"""
import io
import json
import re
import sys
import urllib.request
import zipfile

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

TOKEN = sys.argv[1]
RID = sys.argv[2]
PAT = sys.argv[3] if len(sys.argv) > 3 else None
OWNER, REPO = "LYX3651", "dfmhud"
PROXY = "http://127.0.0.1:7897"

r = urllib.request.Request(
    "https://api.github.com/repos/%s/%s/actions/runs/%s/logs" % (OWNER, REPO, RID)
)
r.add_header("Authorization", "token " + TOKEN)
o = urllib.request.build_opener(urllib.request.ProxyHandler({"http": PROXY, "https": PROXY}))
b = o.open(r, timeout=90).read()
z = zipfile.ZipFile(io.BytesIO(b))

txt = ""
for n in z.namelist():
    if n.endswith(".txt"):
        txt += "\n===== %s =====\n" % n + z.read(n).decode("utf-8", "replace")

# 去 ANSI + 时间戳
txt = re.sub(r"\x1b\[[0-9;]*m", "", txt)
txt = re.sub(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+Z ", "", txt, flags=re.M)

if PAT:
    idx = [m.start() for m in re.finditer(PAT, txt)]
    if idx:
        s = max(0, idx[0] - 3000)
        print(txt[s:idx[0] + 6000])
    else:
        print("pattern not found, dumping tail")
        print(txt[-8000:])
else:
    print(txt[-12000:])
