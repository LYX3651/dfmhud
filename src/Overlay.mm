// Overlay.mm — 跨 App 悬浮窗口实现
#import "Overlay.h"
#import "Core.h"

#import <objc/runtime.h>
#import <dlfcn.h>
#include <string>

using namespace dm;

namespace dm {

namespace {

// ---- SpringBoard 侧私有 API ----
// SBSAccessibilityWindowHostingController 提供：
//   - (void)registerWindowWithContextID:(unsigned)ctx atLevel:(double)level;
// 我们无法在第三方 App 里直接 new 这个类（它在 SpringBoard 进程），
// 但可以通过 accessibility-window-hosting entitlement + 私有框架
// （SpringBoardServices / AccessibilityUtilities）走这条路。
//
// 实测最稳的方式：加载 AccessibilityUtilities，用 AXUIElement 的
// server 通道；退而求其次用 SBS 的 mach 服务。
//
// 这里实现"探测 + 尽力而为"，任何一步失败都返回 false 让上层降级。

using RegisterFn = void (*)(id self, SEL cmd, unsigned ctx, double level);

bool TryLoadSpringBoardHosting() {
  // 相关私有框架候选
  static const char *kFW[] = {
      "/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
      "/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities",
      "/System/Library/PrivateFrameworks/AccessibilityUIUtilities.framework/AccessibilityUIUtilities",
  };
  int loaded = 0;
  for (const char *p : kFW) {
    if (dlopen(p, RTLD_NOW | RTLD_GLOBAL)) ++loaded;
  }
  DMLOG("[overlay] 私有框架加载 %d/%zu", loaded, sizeof(kFW) / sizeof(kFW[0]));

  // 探测托管控制器类是否可达
  Class cls = objc_getClass("SBSAccessibilityWindowHostingController");
  if (!cls) {
    DMLOG("[overlay] 找不到 SBSAccessibilityWindowHostingController");
    return false;
  }

  SEL sel = sel_registerName("registerWindowWithContextID:atLevel:");
  if (!class_respondsToSelector(object_getClass(cls), sel)) {
    DMLOG("[overlay] 类不响应 registerWindowWithContextID:atLevel:");
    return false;
  }

  DMLOG("[overlay] 托管 API 可用");
  return true;
}

// 把窗口注册到系统合成层
// contextID 来自当前 window 的 CAContext
bool HostWindow(UIWindow *win) {
  Class cls = objc_getClass("SBSAccessibilityWindowHostingController");
  SEL sel = sel_registerName("registerWindowWithContextID:atLevel:");
  if (!cls || !class_respondsToSelector(object_getClass(cls), sel)) return false;

  id controller = ((id (*)(id, SEL))objc_msgSend)((id)cls, sel_registerName("sharedInstance"));
  if (!controller) {
    controller = ((id (*)(id, SEL))objc_msgSend)((id)cls, sel_registerName("new"));
  }
  if (!controller) {
    DMLOG("[overlay] 托管控制器实例化失败");
    return false;
  }

  // 取窗口的 CAContext id
  unsigned ctx = 0;
  @try {
    id layer = win.layer;
    id caCtx = ((id (*)(id, SEL))objc_msgSend)(layer, sel_registerName("context"));
    if (caCtx) {
      ctx = (unsigned)((unsigned long long (*)(id, SEL))objc_msgSend)(
          caCtx, sel_registerName("contextId"));
    }
  } @catch (NSException *e) {
    DMLOG("[overlay] 取 CAContext 异常: %s", e.reason.UTF8String);
    return false;
  }

  if (!ctx) {
    DMLOG("[overlay] CAContext id = 0");
    return false;
  }

  DMLOG("[overlay] 注册 contextID=%u", ctx);
  @try {
    ((void (*)(id, SEL, unsigned, double))objc_msgSend)(
        controller, sel, ctx, (double)(UIWindowLevelAlert + 1000.f));
    return true;
  } @catch (NSException *e) {
    DMLOG("[overlay] 注册异常: %s", e.reason.UTF8String);
    return false;
  }
}

}  // namespace

Overlay &Overlay::Shared() {
  static Overlay *o = new Overlay();
  return *o;
}

OverlayMode Overlay::Acquire() {
  if (probed_) return mode_;
  probed_ = true;

  if (TryLoadSpringBoardHosting()) {
    mode_ = OverlayMode::Accessibility;
    DMLOG("[overlay] 模式 = Accessibility（可跨 App）");
  } else {
    mode_ = OverlayMode::Simple;
    DMLOG("[overlay] 模式 = Simple（仅本 App 前台可见）");
  }
  return mode_;
}

const char *Overlay::ModeName() const {
  return mode_ == OverlayMode::Accessibility ? "Accessibility" : "Simple";
}

// 供 HUD 注册窗口用
bool OverlayHostWindow(UIWindow *win) {
  return HostWindow(win);
}

}  // namespace dm
