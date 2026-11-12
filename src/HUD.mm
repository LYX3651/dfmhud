// HUD.mm — Metal + ImGui 悬浮层实现
#import "HUD.h"
#import "Core.h"
#import "Overlay.h"

#import <QuartzCore/QuartzCore.h>
#include <objc/message.h>
#include <unistd.h>

#include "imgui.h"
#include "imgui_impl_metal.h"

#include <cstdarg>
#include <cfloat>
#include <cstdio>
#include <mutex>

using namespace dm;

namespace dm {

// ---- 模块内静态状态（单一实现，不跨 TU）----
namespace {
std::mutex g_mtx;
UIWindow *g_win = nullptr;
id<MTLDevice> g_device = nil;
id<MTLCommandQueue> g_queue = nil;

float g_w = 0.f, g_h = 0.f;
bool g_visible = false;
DrawFn g_draw;
DrawFn g_menu;
id g_driver = nil;   // 强持 MTKViewDelegate
}  // namespace

// 给绘制视图取命令缓冲
static id<MTLCommandBuffer> NextCommandBuffer() {
  return g_queue ? [g_queue commandBuffer] : nil;
}

}  // namespace dm

// ============================================================
//  MTKView 子类：自己驱动 ImGui
//  （HUD.h 已声明 HUDNextCommandBuffer / HUDRunDraw / HUDRunMenu）
//  Objective-C 类不能放在 C++ namespace 里，所以先关掉再开。
//
//  注意：MTKView.delegate 是 weak 属性，不能把 view 自己设成 delegate，
//  否则视图一离开强引用就没了。现在由一个强持有的 driver 对象担任。
// ============================================================
@class DFMDrawView;

@interface DFMDrawDriver : NSObject <MTKViewDelegate>
@property(nonatomic, strong) DFMDrawView *view;
@end

@interface DFMDrawView : MTKView
@end

@implementation DFMDrawView

- (BOOL)isUserInteractionEnabled { return NO; }
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e { return nil; }

@end

@implementation DFMDrawDriver

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
  dm::HUD::Shared().UpdateViewport();
}

- (void)drawInMTKView:(MTKView *)view {
  if (!dm::HUD::Shared().Visible()) return;

  id<MTLCommandBuffer> cb = dm::HUDNextCommandBuffer();
  if (!cb) return;

  dm::ImGuiNewFrame(view);
  dm::HUDRunDraw();
  dm::HUDRunMenu();

  MTLRenderPassDescriptor *rpd = view.currentRenderPassDescriptor;
  if (!rpd) return;

  dm::ImGuiRender(rpd, cb);
  if (view.currentDrawable) [cb presentDrawable:view.currentDrawable];
  [cb commit];
}

@end

namespace dm {

// 上面 @implementation 里用到的桥
id<MTLCommandBuffer> HUDNextCommandBuffer() { return NextCommandBuffer(); }
void HUDRunDraw() { if (g_draw) g_draw(); }
void HUDRunMenu() { if (g_menu) g_menu(); }

HUD &HUD::Shared() {
  static HUD *inst = new HUD();
  return *inst;
}

void HUD::SetDrawCallback(DrawFn fn) { g_draw = std::move(fn); }
void HUD::SetMenuCallback(DrawFn fn) { g_menu = std::move(fn); }

// ============================================================
//  ImGui 全局
// ============================================================
bool ImGuiInit(MTLDevice *device) {
  if (!device) return false;

  IMGUI_CHECKVERSION();
  ImGui::CreateContext();
  ImGuiIO &io = ImGui::GetIO();
  io.IniFilename = nullptr;
  io.LogFilename = nullptr;

  ImGui::StyleColorsDark();
  ImGuiStyle &st = ImGui::GetStyle();
  st.WindowRounding = 10.f;
  st.ChildRounding = 8.f;
  st.FrameRounding = 6.f;
  st.GrabRounding = 6.f;
  st.ScrollbarRounding = 6.f;
  st.TabRounding = 6.f;
  st.WindowBorderSize = 0.f;
  st.WindowPadding = ImVec2(12, 12);
  st.ItemSpacing = ImVec2(8, 7);
  st.Colors[ImGuiCol_WindowBg] = ImVec4(0.06f, 0.07f, 0.09f, 0.94f);

  if (!ImGui_ImplMetal_Init(device)) {
    DMLOG("[hud] ImGui_ImplMetal_Init 失败");
    return false;
  }
  DMLOG("[hud] ImGui 初始化完成");
  return true;
}

void ImGuiShutdown() {
  ImGui_ImplMetal_Shutdown();
  ImGui::DestroyContext();
}

void ImGuiLoadFont(const char *ttfPath, float sizePx) {
  ImGuiIO &io = ImGui::GetIO();
  io.Fonts->Clear();

  ImFontConfig cfg;
  cfg.OversampleH = 2;
  cfg.OversampleV = 2;
  cfg.PixelSnapH = true;

  ImFont *f = nullptr;
  if (ttfPath && *ttfPath && access(ttfPath, R_OK) == 0) {
    f = io.Fonts->AddFontFromFileTTF(ttfPath, sizePx, &cfg,
                                     io.Fonts->GetGlyphRangesChineseSimplifiedCommon());
  }
  if (!f) {
    f = io.Fonts->AddFontDefault();
    DMLOG("[hud] 中文字体缺失，用默认字体（中文会缺字）");
  }
}

void ImGuiNewFrame(MTKView *view) {
  ImGui_ImplMetal_NewFrame(view.currentRenderPassDescriptor);

  ImGuiIO &io = ImGui::GetIO();
  io.DisplaySize = ImVec2((float)view.drawableSize.width, (float)view.drawableSize.height);
  io.DisplayFramebufferScale = ImVec2(1.f, 1.f);

  static double last = 0;
  const double now = CACurrentMediaTime();
  io.DeltaTime = (last > 0) ? (float)(now - last) : (1.f / 60.f);
  last = now;

  ImGui::NewFrame();
}

void ImGuiRender(MTLRenderPassDescriptor *desc, id<MTLCommandBuffer> cb) {
  ImGui::Render();
  id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:desc];
  ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cb, enc);
  [enc endEncoding];
}

// ============================================================
//  HUD 生命周期
// ============================================================
void HUD::Start(UIWindow *hostWindow) {
  std::lock_guard<std::mutex> lk(g_mtx);
  if (g_win) return;

  g_device = MTLCreateSystemDefaultDevice();
  if (!g_device) {
    DMLOG("[hud] 无 Metal 设备，HUD 不可用");
    return;
  }
  g_queue = [g_device newCommandQueue];

  if (!ImGuiInit(g_device)) return;

  // 自己建一个 window 挂到最上层
  UIWindowScene *scene = nil;
  for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
    if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
  }

  CGRect bounds = [UIScreen mainScreen].bounds;
  if (@available(iOS 13.0, *)) {
    if (scene) g_win = [[UIWindow alloc] initWithWindowScene:scene];
    else      g_win = [[UIWindow alloc] initWithFrame:bounds];
  } else {
    g_win = [[UIWindow alloc] initWithFrame:bounds];
  }

  g_win.frame = bounds;
  g_win.backgroundColor = [UIColor clearColor];
  g_win.windowLevel = UIWindowLevelAlert + 1000.f;  // 压在最上面
  g_win.rootViewController = [[UIViewController alloc] init];
  g_win.rootViewController.view.backgroundColor = [UIColor clearColor];
  g_win.rootViewController.view.userInteractionEnabled = NO;
  g_win.hidden = NO;

  DFMDrawView *view = [[DFMDrawView alloc] initWithFrame:bounds device:g_device];

  // delegate 必须被强持有（MTKView.delegate 是 weak）
  DFMDrawDriver *driver = [[DFMDrawDriver alloc] init];
  driver.view = view;
  view.delegate = driver;
  g_driver = driver;   // 强引用，保证活到 Stop()

  view.opaque = NO;
  view.backgroundColor = [UIColor clearColor];
  view.layer.opaque = NO;
  view.layer.backgroundColor = [UIColor clearColor].CGColor;
  view.framebufferOnly = YES;
  view.enableSetNeedsDisplay = NO;
  view.paused = NO;
  view.clearColor = MTLClearColorMake(0, 0, 0, 0);
  view.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
  view.preferredFramesPerSecond = dm::Cfg().refreshHz;
  view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  view.userInteractionEnabled = NO;

  [g_win.rootViewController.view addSubview:view];

  g_w = bounds.size.width;
  g_h = bounds.size.height;

  NSString *fp = [[NSBundle mainBundle] pathForResource:@"LXGWWenKai-Light" ofType:@"ttf"];
  if (!fp) fp = [[NSBundle mainBundle] pathForResource:@"NotoSansSC" ofType:@"ttf"];
  ImGuiLoadFont(fp ? fp.UTF8String : nullptr, 18.f * (float)[UIScreen mainScreen].scale);

  // 关键：把窗口注册到系统合成层，才能盖在游戏之上
  OverlayMode m = Overlay::Shared().Acquire();
  if (m == OverlayMode::Accessibility) {
    if (OverlayHostWindow(g_win)) {
      DMLOG("[hud] 已托管到 SpringBoard");
    } else {
      DMLOG("[hud] 托管失败，降级为普通窗口");
    }
  }

  g_visible = true;
  DMLOG("[hud] 启动完成 %.0fx%.0f level=%.0f mode=%s", g_w, g_h, g_win.windowLevel,
        Overlay::Shared().ModeName());
}

void HUD::Stop() {
  std::lock_guard<std::mutex> lk(g_mtx);
  if (g_win) {
    for (UIView *v in g_win.rootViewController.view.subviews) {
      if ([v isKindOfClass:[DFMDrawView class]]) {
        MTKView *mv = (MTKView *)v;
        [mv setDelegate:nil];   // 先断开，避免 delegate 回调到已拆的视图
        mv.paused = YES;
        [v removeFromSuperview];
      }
    }
    g_win.hidden = YES;
    g_win = nil;
  }
  g_driver = nil;   // 释放 delegate，必须在视图拆掉之后
  ImGuiShutdown();
  g_visible = false;
}

void HUD::SetVisible(bool v) {
  std::lock_guard<std::mutex> lk(g_mtx);
  g_visible = v;
  if (g_win) {
    for (UIView *sub in g_win.rootViewController.view.subviews) {
      if ([sub isKindOfClass:[MTKView class]]) ((MTKView *)sub).paused = !v;
    }
  }
}

bool HUD::Visible() const { return g_visible; }

void HUD::UpdateViewport() {
  for (UIView *sub in g_win.rootViewController.view.subviews) {
    if ([sub isKindOfClass:[MTKView class]]) {
      CGSize s = ((MTKView *)sub).drawableSize;
      g_w = (float)s.width;
      g_h = (float)s.height;
      return;
    }
  }
}

float HUD::Width() const { return g_w; }
float HUD::Height() const { return g_h; }

// ============================================================
//  ESP 绘制原语
// ============================================================
namespace esp {

static inline ImU32 ToU32(const Color &c) {
  return IM_COL32((int)(c.r * 255), (int)(c.g * 255), (int)(c.b * 255), (int)(c.a * 255));
}

void DrawBox(float x, float y, float w, float h, float thickness, const Color &c) {
  ImGui::GetBackgroundDrawList()->AddRect(ImVec2(x, y), ImVec2(x + w, y + h),
                                          ToU32(c), 0.f, 0, thickness);
}

void DrawCornerBox(float x, float y, float w, float h, float thickness, const Color &c) {
  ImDrawList *dl = ImGui::GetBackgroundDrawList();
  const ImU32 col = ToU32(c);
  const float cx = w * 0.28f;
  const float cy = h * 0.28f;

  dl->AddLine(ImVec2(x, y), ImVec2(x + cx, y), col, thickness);
  dl->AddLine(ImVec2(x, y), ImVec2(x, y + cy), col, thickness);

  dl->AddLine(ImVec2(x + w, y), ImVec2(x + w - cx, y), col, thickness);
  dl->AddLine(ImVec2(x + w, y), ImVec2(x + w, y + cy), col, thickness);

  dl->AddLine(ImVec2(x, y + h), ImVec2(x + cx, y + h), col, thickness);
  dl->AddLine(ImVec2(x, y + h), ImVec2(x, y + h - cy), col, thickness);

  dl->AddLine(ImVec2(x + w, y + h), ImVec2(x + w - cx, y + h), col, thickness);
  dl->AddLine(ImVec2(x + w, y + h), ImVec2(x + w, y + h - cy), col, thickness);
}

void DrawLine(float x1, float y1, float x2, float y2, float thickness, const Color &c) {
  ImGui::GetBackgroundDrawList()->AddLine(ImVec2(x1, y1), ImVec2(x2, y2), ToU32(c), thickness);
}

void DrawText(float x, float y, float size, const Color &c, const char *fmt, ...) {
  char buf[512];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);

  ImDrawList *dl = ImGui::GetBackgroundDrawList();
  ImFont *font = ImGui::GetFont();
  const float s = size / font->FontSize;

  // 描边提升可读性
  dl->AddText(font, font->FontSize * s, ImVec2(x + 1, y + 1), IM_COL32(0, 0, 0, 200), buf);
  dl->AddText(font, font->FontSize * s, ImVec2(x, y), ToU32(c), buf);
}

void DrawHealthBar(float x, float y, float w, float h, float ratio, const Color &c) {
  if (ratio < 0) ratio = 0;
  if (ratio > 1) ratio = 1;

  ImDrawList *dl = ImGui::GetBackgroundDrawList();
  dl->AddRectFilled(ImVec2(x, y), ImVec2(x + w, y + h), IM_COL32(0, 0, 0, 170), 2.f);

  Color cc = c;
  if (ratio < 0.3f)      { cc.r = 1.f; cc.g = 0.15f; cc.b = 0.15f; }
  else if (ratio < 0.6f) { cc.r = 1.f; cc.g = 0.75f; cc.b = 0.10f; }

  const float fh = (h - 2.f) * ratio;
  dl->AddRectFilled(ImVec2(x + 1, y + h - 1 - fh), ImVec2(x + w - 1, y + h - 1), ToU32(cc), 2.f);
}

void DrawFilledRect(float x, float y, float w, float h, const Color &c) {
  ImGui::GetBackgroundDrawList()->AddRectFilled(ImVec2(x, y), ImVec2(x + w, y + h), ToU32(c));
}

Vec2 MeasureText(float size, const char *text) {
  ImFont *font = ImGui::GetFont();
  const float s = size / font->FontSize;
  ImVec2 sz = font->CalcTextSizeA(font->FontSize * s, FLT_MAX, 0.f, text);
  return Vec2{sz.x, sz.y};
}

}  // namespace esp
}  // namespace dm
