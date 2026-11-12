# -*- coding: utf-8 -*-
"""在 GitHub PAT 创建页点击 Generate，并抓取生成的 token"""
import asyncio
import json
import urllib.request

import websockets


async def main():
    tabs = json.loads(urllib.request.urlopen("http://127.0.0.1:9222/json/list", timeout=8).read())
    pages = [t for t in tabs if t.get("type") == "page"]
    page = None
    for t in pages:
        if "tokens/new" in t.get("url", "") or "settings/tokens" in t.get("url", ""):
            page = t
            break
    if not page:
        print("NO TOKEN PAGE. pages:")
        for t in pages:
            print("   ", t.get("url", "")[:100])
        return

    print("using tab:", page.get("url", "")[:100])
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
        # 1) 确认 scopes 已勾
        r = await send(
            "Runtime.evaluate",
            expression="""JSON.stringify({
                url: location.href,
                checks: [...document.querySelectorAll('input[type=checkbox]')]
                          .filter(c=>c.checked)
                          .map(c=>c.value||c.name),
                hasGen: !!document.querySelector('button[type=submit]')
            })""",
            returnByValue=True,
        )
        print("STATE1:", r["result"]["result"]["value"])

        # 2) 点击生成按钮
        r = await send(
            "Runtime.evaluate",
            expression="""
              (() => {
                const btns = [...document.querySelectorAll('button[type=submit], button')];
                const gen = btns.find(b => /Generate token/i.test(b.textContent));
                if (!gen) return JSON.stringify({ok:false, buttons: btns.map(b=>b.textContent.trim()).slice(0,10)});
                gen.click();
                return JSON.stringify({ok:true, clicked: gen.textContent.trim()});
              })()
            """,
            returnByValue=True,
        )
        print("CLICK:", r["result"]["result"]["value"])
        await asyncio.sleep(6)

        # 3) 抓 token
        r = await send(
            "Runtime.evaluate",
            expression="""JSON.stringify({
                url: location.href,
                token: (document.querySelector('#new-oauth-token, .token, code')||{}).textContent||null,
                body: document.body.innerText.slice(0,600)
            })""",
            returnByValue=True,
        )
        print("AFTER:", r["result"]["result"]["value"][:1500])
    finally:
        await ws.close()


asyncio.run(main())
