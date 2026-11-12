#!/bin/bash
# repack.py 的 shell 版：把 theos 产出的 .app 打成 TrollStore 可装的 .tipa
#
# 关键坑（派大星包里踩过的）：
#   1. zip 文件名必须置 UTF-8 标志位（flag_bits & 0x800），否则中文路径
#      或非 ASCII 名会让 TrollStore 报 Error 303
#   2. Payload/ 下必须只有 `<Name>.app`
#   3. 主二进制要先 ldid 再算 CodeResources
set -euo pipefail

APP_DIR="$1"       # 例如 out/Payload/DFMHUD.app
OUT_TIPA="$2"      # 例如 DFMHUD.tipa
ENT="${3:-entitlements.plist}"

PY=$(command -v python3 || command -v python)
[ -z "$PY" ] && { echo "需要 python"; exit 1; }

APP_NAME=$(basename "$APP_DIR")
PAYLOAD=$(dirname "$APP_DIR")

echo "== 1) 签主二进制 =="
EXE=$(PYTHONPATH= "$PY" -c "import plistlib,sys;print(plistlib.load(open(sys.argv[1],'rb'))['CFBundleExecutable'])" "$APP_DIR/Info.plist")
ldid -S"$ENT" "$APP_DIR/$EXE"
ldid -S "$APP_DIR/$EXE"      # 再补一次，确保 entitlements 落在主二进制
echo "   $EXE signed"

echo "== 2) 签 Frameworks 里所有 dylib =="
if [ -d "$APP_DIR/Frameworks" ]; then
  find "$APP_DIR/Frameworks" -name "*.dylib" -print0 | while IFS= read -r -d '' f; do
    ldid -S "$f" && echo "   $(basename "$f")"
  done
fi

echo "== 3) 生成 CodeResources =="
"$PY" tools/gen_codesig.py "$APP_DIR"

echo "== 4) 打包（保留原名字节 + UTF-8 标志）=="
rm -f "$OUT_TIPA"
"$PY" - "$PAYLOAD" "$OUT_TIPA" <<'PYEOF'
import os, sys, zipfile
payload, out = sys.argv[1], sys.argv[2]

entries = []
for root, dirs, files in os.walk(payload):
    dirs.sort()
    rel = os.path.relpath(root, payload)
    prefix = "" if rel == "." else rel.replace(os.sep, "/") + "/"
    if rel != ".":
        entries.append((prefix, None))
    for f in sorted(files):
        entries.append((prefix + f, os.path.join(root, f)))

with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for name, path in entries:
        if path is None:
            zi = zipfile.ZipInfo(name)
            zi.external_attr = (0o40755 << 16) | 0x10
            zi.flag_bits |= 0x800
            z.writestr(zi, b"")
        else:
            st = os.stat(path)
            zi = zipfile.ZipInfo(name, time.localtime(st.st_mtime)[:6])
            zi.external_attr = (st.st_mode & 0xFFFF) << 16
            zi.flag_bits |= 0x800
            zi.compress_type = zipfile.ZIP_DEFLATED
            with open(path, "rb") as f:
                z.writestr(zi, f.read())

print("packed ->", out, os.path.getsize(out), "bytes")
PYEOF

echo
echo "== 完成 =="
ls -lh "$OUT_TIPA"
"$PY" - "$OUT_TIPA" <<'PYEOF'
import zipfile, sys
z = zipfile.ZipFile(sys.argv[1])
bad = z.testzip()
print("zip ok:", bad is None)
print("entries:", len(z.namelist()))
print("EFLAG ok:", all(i.flag_bits & 0x800 for i in z.infolist()))
print("top:", z.namelist()[0])
PYEOF
