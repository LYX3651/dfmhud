# -*- coding: utf-8 -*-
"""检查 GitHub 登录状态：打开首页并读 meta[name=user-login]"""
import asyncio
import json
import urllib.request

import websockets


async def main():
    tabs = json.loads(urllib.request.urlopen("http://127.0.0.1:9222/json/list", timeout=8).read())
    page = next((t for t in tabs if t.get("type") == "page"), None)
    if not page:
        req = urllib.request.Request("http://127.0.0.1:9222/json/new?https://github.com/", method="PUT")
        page = json.loads(urllib.request.urlopen(req, timeout=10).read())

    ws = await websockets.connect(page["webSocketDebuggerUrl"], max_size=32 * 1024 * 1024)
    mid = 0

    async def send(method, **params):
        nonlocal mid
        mid += 1
        await ws.send(json.dumps({"id": mid, "method": method, "params": params}))
        while True:
            r = json.loads(await asyncio.wait_for(ws.recv(), timeout=30))
            if r.get("id") == mid:
                return r

    try:
        await send("Page.enable")
        await send("Page.navigate", url="https://github.com/")
        await asyncio.sleep(7)
        r = await send(
            "Runtime.evaluate",
            expression="""JSON.stringify({
                url: location.href,
                userLogin: (document.querySelector('meta[name=user-login]')||{}).content||null,
                hasSignIn: !!document.querySelector('a[href="/login"]'),
                avatarAlt: (document.querySelector('img.avatar')||{}).alt||null
            })""",
            returnByValue=True,
        )
        print("RESULT:", r["result"]["result"]["value"])
    finally:
        await ws.close()


asyncio.run(main())
