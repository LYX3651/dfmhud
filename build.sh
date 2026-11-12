#!/bin/bash
# build.sh — 本地/CI 出包脚本
# 产物：DFMHUD.tipa（TrollStore 直接安装）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

OUT="out"
APP="DFMHUD.app"
TIP="DFMHUD.tipa"

echo "=== 1) 清理 ==="
rm -rf "$OUT" 2>/dev/null || true
rm -rf .theos 2>/dev/null || true
mkdir -p "$OUT"

echo "=== 2) 检查 theos ==="
if [ -z "${THEOS:-}" ]; then
  export THEOS="$HOME/theos"
fi
if [ ! -d "$THEOS" ]; then
  echo "!! THEOS 不存在: $THEOS"
  echo "   git clone --recursive https://github.com/theos/theos.git $THEOS"
  exit 1
fi
echo "THEOS = $THEOS"

echo "=== 3) kfd（可选）==="
KFD_DIR="third_party/kfd"
if [ ! -d "$KFD_DIR" ]; then
  echo "  kfd 未提供：只编 task_for_pid 后端"
else
  echo "  kfd 已存在：启用 tfp0 后端"
fi

echo "=== 4) 编译 ==="
make clean >/dev/null 2>&1 || true
make -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 4)" package FINALPACKAGE=1

echo "=== 5) 组装 Payload ==="
# theos application.mk 把产物放在 .theos/obj/<target>/<App>.app 或 layout 里
BUILT=$(find .theos/obj -maxdepth 5 -name "$APP" -type d 2>/dev/null | head -1)
if [ -z "$BUILT" ]; then
  BUILT=$(find layout -maxdepth 4 -name "$APP" -type d 2>/dev/null | head -1)
fi
if [ -z "$BUILT" ]; then
  echo "!! 没找到编译产物 $APP"
  echo "   检查 .theos/obj 结构："
  find .theos/obj -maxdepth 4 -type d 2>/dev/null | head -20
  exit 1
fi
echo "built: $BUILT"

rm -rf "$OUT/Payload"
mkdir -p "$OUT/Payload"
cp -R "$BUILT" "$OUT/Payload/$APP"

# 资源（字体等）
if [ -d Resources ]; then
  for f in Resources/*; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    cp "$f" "$OUT/Payload/$APP/"
  done
fi

echo "=== 6) 签名 + 打包 ==="
if ! command -v ldid >/dev/null; then
  echo "!! ldid 缺失。macOS: brew install ldid"
  exit 1
fi
chmod +x tools/pack_tipa.sh
bash tools/pack_tipa.sh "$OUT/Payload/$APP" "$TIP" "entitlements.plist"

echo
echo "=== 完成 ==="
ls -lh "$TIP"
echo
echo "安装：把 $TIP 传到设备，用 TrollStore 打开"
echo "日志：idevicesyslog | grep DFMHUD"
echo "     或 Filza 看 /var/mobile/Library/Caches/dfmhud.log"
