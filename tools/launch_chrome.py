# -*- coding: utf-8 -*-
"""用主 profile 目录带 CDP 启动 Chrome，并验证登录态"""
import ctypes
import json
import subprocess
import sys
import time
import urllib.request

k32 = ctypes.WinDLL("kernel32", use_last_error=True)
k32.GetShortPathNameW.argtypes = [ctypes.c_wchar_p, ctypes.c_wchar_p, ctypes.c_uint]
k32.GetShortPathNameW.restype = ctypes.c_uint

SRC = r"C:\Users\LYX\AppData\Local\Google\Chrome\User Data"
buf = ctypes.create_unicode_buffer(1024)
n = k32.GetShortPathNameW(SRC, buf, 1024)
short = buf.value if n else SRC
print("short path:", short, "| space in path:", " " in short)

CHROME = r"C:\Program Files\Google\Chrome\Application\chrome.exe"
args = [
    CHROME,
    "--remote-debugging-port=9222",
    "--user-data-dir=" + short,
    "--no-first-run",
    "--no-default-browser-check",
]
print("launching...")
subprocess.Popen(args, close_fds=True)
time.sleep(14)

try:
    v = json.loads(urllib.request.urlopen("http://127.0.0.1:9222/json/version", timeout=6).read())
    print("CDP OK:", v.get("Browser"))
except Exception as e:
    print("CDP FAIL:", e)
    sys.exit(1)

# 列出 tabs
try:
    tabs = json.loads(urllib.request.urlopen("http://127.0.0.1:9222/json/list", timeout=6).read())
    pages = [t for t in tabs if t.get("type") == "page"]
    print("pages:", len(pages))
    for t in pages[:8]:
        print("   ", t.get("url", "")[:90])
except Exception as e:
    print("list fail:", e)
