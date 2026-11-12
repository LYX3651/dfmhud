// Probe.h — 运行时自检：把"哪一层断了"直接暴露到 UI/日志
// 这个模块的意义：TrollStore 环境下没有 lldb，只能靠面包屑定位。
#pragma once

#include <string>
#include <vector>

namespace dm {

struct ProbeResult {
  const char *name;
  bool ok;
  std::string detail;
};

// 跑一遍全链路自检，结果打印到日志并返回
std::vector<ProbeResult> RunProbes();

// 把自检结果拼成多行文本（菜单"系统"页显示用）
std::string ProbeReport();

}  // namespace dm
