// HUD.h — Metal + ImGui 悬浮绘制层
// 形态与派大星一致：独立 app 的 UIWindow（accessibility-window-hosting），
// 在目标游戏之上挂一层透明 Metal 视图。
#pragma once

#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>

#include <functional>
#include <vector>

#include "UE.h"

namespace dm {

// 绘制回调：在 ImGui Frame 内部调用，可以直接发 ImGui 命令
using DrawFn = std::function<void()>;

// ---------- ImGui 全局 ----------
bool ImGuiInit(MTLDevice *device);
void ImGuiShutdown();
void ImGuiNewFrame(MTKView *view);
void ImGuiRender(MTLRenderPassDescriptor *desc, id<MTLCommandBuffer> cb);

// 中文支持：加载 app 内置字体
void ImGuiLoadFont(const char *ttfPath, float sizePx);

// 绘制视图回调桥（HUD.mm 内部）
id<MTLCommandBuffer> HUDNextCommandBuffer();
void HUDRunDraw();
void HUDRunMenu();

// ---------- 悬浮窗 ----------
class HUD {
 public:
  static HUD &Shared();

  void Start(UIWindow *hostWindow);   // 挂到主 window 上
  void Stop();
  void SetVisible(bool v);
  bool Visible() const;

  // 每帧回调（ESP 在这里画）
  void SetDrawCallback(DrawFn fn) { draw_ = std::move(fn); }
  void SetMenuCallback(DrawFn fn) { menu_ = std::move(fn); }

  // 屏幕尺寸 / 缩放
  void UpdateViewport();
  float Width() const;
  float Height() const;

  // 供 ESP 使用
  void SetTargetPid(int pid) { targetPid_ = pid; }
  int  TargetPid() const { return targetPid_; }

 private:
  HUD() = default;
  int targetPid_ = -1;
  DrawFn draw_;
  DrawFn menu_;
};

// ---------- ESP 绘制原语（ImGui 版） ----------
namespace esp {

void DrawBox(float x, float y, float w, float h, float thickness, const Color &c);
void DrawCornerBox(float x, float y, float w, float h, float thickness, const Color &c);
void DrawLine(float x1, float y1, float x2, float y2, float thickness, const Color &c);
void DrawText(float x, float y, float size, const Color &c, const char *fmt, ...);
void DrawHealthBar(float x, float y, float w, float h, float ratio, const Color &c);
void DrawFilledRect(float x, float y, float w, float h, const Color &c);

Vec2 MeasureText(float size, const char *text);

}  // namespace esp

}  // namespace dm
