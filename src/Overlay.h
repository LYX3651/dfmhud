// Overlay.h — 真正能盖在别的 App 之上的窗口
//
// 关键问题：普通 UIWindow 只在自己 App 前台时可见，切到游戏就没了。
// 派大星用的是 com.apple.springboard.accessibility-window-hosting 这个
// entitlement，对应的私有类是 SBSAccessibilityWindowHostingController
// （SpringBoard 侧），通过它把自己的窗口注册到系统合成层。
//
// 本文件给两条路：
//   A. AccessibilityHost —— 走 SpringBoard 托管（能跨 App，最接近派大星）
//   B. SimpleWindow      —— 普通高 level 窗口（只在 App 前台，用于调试/兜底）
#pragma once

#import <UIKit/UIKit.h>

namespace dm {

enum class OverlayMode {
  Accessibility,   // 跨 App（需要 entitlement 生效）
  Simple,          // 仅本 App 前台
};

class Overlay {
 public:
  static Overlay &Shared();

  // 返回实际使用的模式；请求 Accessibility 失败会自动降级
  OverlayMode Acquire();
  OverlayMode Current() const { return mode_; }

  // 是否需要用户把 app 切回前台（Simple 模式下为 true）
  bool NeedsForeground() const { return mode_ == OverlayMode::Simple; }

  const char *ModeName() const;

 private:
  Overlay() = default;
  OverlayMode mode_ = OverlayMode::Simple;
  bool probed_ = false;
};

// 把窗口托管到系统合成层（跨 App 可见）。成功返回 true。
bool OverlayHostWindow(UIWindow *win);

}  // namespace dm
