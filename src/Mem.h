// Mem.h — 跨进程内存读写：task_for_pid 优先 + kfd(tfp0) 兜底
// 目标：iOS 14.0 – 17.x，TrollStore，无越狱
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace dm {

struct Proc {
  int pid = -1;
  std::string name;
  std::string path;
  explicit operator bool() const { return pid > 0; }
};

struct Module {
  std::string path;
  uint64_t base = 0;    // __TEXT 运行时基址
  uint64_t size = 0;    // 覆盖到最后一个 segment 结束
  explicit operator bool() const { return base != 0; }
};

// 后端类型，用来判断当前走的是哪条路
enum class Backend {
  None,
  TaskForPid,   // 有 task_for_pid 权限（TrollStore + entitlements）
  Kfd,          // kfd 拿到 tfp0（A12X 上需要 PUAF 触发）
};

// ---------- 生命周期 ----------
Backend Available();                 // 当前可用的后端
bool InitBackend();                  // 探测并初始化（优先 task_for_pid）
void Shutdown();

// ---------- 进程 ----------
std::vector<Proc> ListProcs();
Proc FindProc(const char *execName);           // 按可执行名模糊匹配
Proc FindProcByBundle(const char *bundleId);   // 按 bundle id 找

bool Attach(const Proc &p);   // 拿 task port
void Detach();
bool Attached();
int  TargetPid();

// ---------- 读写 ----------
bool Read(uint64_t addr, void *out, size_t len);
bool Write(uint64_t addr, const void *data, size_t len);
bool Patch(uint64_t addr, const void *data, size_t len);  // 改页保护后写回

// ---------- 便捷 ----------
template <typename T>
inline T ReadV(uint64_t addr, T fb = T{}) {
  T v{};
  return Read(addr, &v, sizeof(T)) ? v : fb;
}

template <typename T>
inline bool WriteV(uint64_t addr, const T &v) {
  return Write(addr, &v, sizeof(T));
}

// 多级指针
inline uint64_t Deref(uint64_t addr, size_t off = 0) {
  if (!addr) return 0;
  return ReadV<uint64_t>(addr + off, 0);
}

// 读 C 字符串（目标进程内）
std::string ReadStr(uint64_t addr, size_t maxLen = 256);

// ---------- 模块 ----------
std::vector<Module> ListModules();
Module FindModule(const char *needle);   // 子串匹配，如 "DeltaForceClient"

// 在模块内做字节特征扫描，pattern 形如 "48 8B 05 ?? ?? ?? ?? C3"
std::vector<uint64_t> ScanPattern(const Module &m, const char *pattern, size_t limit = 32);
uint64_t ScanOne(const Module &m, const char *pattern);

// ---------- 诊断 ----------
const char *BackendName(Backend b);

}  // namespace dm
