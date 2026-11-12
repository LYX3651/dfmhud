// ESP.h — 世界到屏幕 + 实体筛选 + 绘制装配
#pragma once

#include <vector>

#include "Core.h"
#include "UE.h"

namespace dm {
namespace esp {

// 一帧的渲染统计（调试用）
struct Stats {
  int actors = 0;
  int players = 0;
  int drawn = 0;
  int loot = 0;
  float frameMs = 0;
};

Stats &GetStats();

// 每帧调用：拉数据 + 画
void RenderFrame();

// 只拉数据不画（给调试/日志用）
void Collect();

}  // namespace esp
}  // namespace dm
