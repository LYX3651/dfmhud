#!/bin/bash
# linux-check.sh —— 在 ubuntu runner 上验证系统 clang 能否直接产 arm64 Mach-O
set -e

echo "=== clang 能力 ==="
clang --version
clang --print-targets 2>/dev/null | grep -i aarch64 | head -3 || true

echo
echo "=== 最小 Mach-O 测试（不依赖 iOS SDK）==="
cat > /tmp/t.c <<'EOF'
int add(int a, int b) { return a + b; }
int main(void) { return add(1, 2); }
EOF

# 用 freestanding + aarch64-apple-ios 三元组，不需要 sysroot 就能出 .o
clang -target arm64-apple-ios14.0 -c /tmp/t.c -o /tmp/t.o && echo "compile OK"
file /tmp/t.o
xxd -l 16 /tmp/t.o

echo
echo "=== 带 iOS SDK 编译 ==="
SDK=$(find "$HOME/theos/sdks" -maxdepth 1 -name "iPhoneOS*.sdk" | head -1)
echo "SDK=$SDK"
if [ -n "$SDK" ]; then
  ls "$SDK" | head -5
  echo "--- 试编一个引用 Foundation 的 .m ---"
  cat > /tmp/f.m <<'EOF'
#import <Foundation/Foundation.h>
int main(void){ @autoreleasepool { NSLog(@"hi"); } return 0; }
EOF
  clang -target arm64-apple-ios14.0 -isysroot "$SDK" -fobjc-arc \
        -c /tmp/f.m -o /tmp/f.o && echo "Foundation compile OK"
  file /tmp/f.o
else
  echo "没有 SDK"
fi
