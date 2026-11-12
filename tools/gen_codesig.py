# coding: utf-8
"""gen_codesig.py — 给 .tipa 内每个可执行体重新生成 CodeResources

Windows 上没有 codesign，TrollStore 装包时会校验 _CodeSignature/CodeResources
（虽然 CoreTrust 绕过签名，但 CodeResources 缺失/不匹配会造成 Error 303）。
本脚本按 Mach-O + 资源文件算哈希，生成与原版同构的 plist。
"""
import hashlib
import os
import plistlib
import sys


def sha1_of(path):
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.digest()


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main(app_dir):
    app_dir = os.path.abspath(app_dir)
    if not os.path.isdir(app_dir):
        sys.exit("not a dir: %s" % app_dir)

    files = {}
    files2 = {}

    for root, dirs, names in os.walk(app_dir):
        # 跳过签名目录本身
        dirs[:] = [d for d in dirs if d != "_CodeSignature"]
        for n in names:
            p = os.path.join(root, n)
            rel = os.path.relpath(p, app_dir)
            if rel.startswith("_CodeSignature"):
                continue
            files[rel] = sha1_of(p)
            files2[rel] = sha256_of(p)

    # 主可执行体单列
    exe = None
    ip = os.path.join(app_dir, "Info.plist")
    if os.path.isfile(ip):
        with open(ip, "rb") as f:
            info = plistlib.load(f)
        exe = info.get("CFBundleExecutable")

    doc = {
        "files": files,
        "files2": files2,
        "rules": {
            "^Resources/": True,
            "^Info\\.plist$": {"omit": True, "weight": 20.0},
            ".*\\.lproj/": {"optional": True, "weight": 1000.0},
            ".*\\.lproj/locversion.plist$": {"omit": True, "weight": 1100.0},
            "^": {"weight": 10.0},
            "^.*": True,
        },
        "rules2": {
            ".*\\.dSYM($|/)": {"weight": 11.0},
            "^Info\\.plist$": {"omit": True, "weight": 20.0},
            "^(Frameworks|SharedFrameworks|PlugIns|Plug-ins|XPCServices|Helpers|MacOS|Library/(Automator|Spotlight|LoginItems))/": {
                "nested": True,
                "weight": 10.0,
            },
            ".*\\.lproj/": {"optional": True, "weight": 1000.0},
            "^": {"weight": 20.0},
            "^[^/]+$": {"nested": True, "weight": 10.0},
            ".*": True,
        },
    }

    if exe:
        doc["files2"]["Info.plist"] = {
            "cdhash": "",
            "hash2": sha256_of(ip),
        }

    sd = os.path.join(app_dir, "_CodeSignature")
    os.makedirs(sd, exist_ok=True)
    out = os.path.join(sd, "CodeResources")
    with open(out, "wb") as f:
        plistlib.dump(doc, f, fmt=plistlib.FMT_XML)

    print("wrote %s (%d files)" % (out, len(files)))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: gen_codesig.py <App.app>")
    main(sys.argv[1])
