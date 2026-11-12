// Probe.cpp — 全链路自检
#include "Probe.h"
#include "Core.h"
#include "Mem.h"
#include "UE.h"

#import <UIKit/UIKit.h>
#include <mach/mach.h>
#include <cstdarg>
#include <cstdio>
#include <string>

namespace dm {

namespace {

std::vector<ProbeResult> g_last;

void Add(std::vector<ProbeResult> &v, const char *name, bool ok, const std::string &det) {
  v.push_back({name, ok, det});
  DMLOG("[probe] %-24s %s  %s", name, ok ? "OK  " : "FAIL", det.c_str());
}

std::string Fmt(const char *f, ...) {
  char b[512];
  va_list ap;
  va_start(ap, f);
  vsnprintf(b, sizeof(b), f, ap);
  va_end(ap);
  return std::string(b);
}

}  // namespace

std::vector<ProbeResult> RunProbes() {
  std::vector<ProbeResult> v;
  DMLOG("[probe] ===== 自检开始 =====");

  // 1) 自身进程权限
  {
    mach_port_t tp = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), getpid(), &tp);
    if (tp != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), tp);
    Add(v, "self task_for_pid", kr == KERN_SUCCESS,
        Fmt("kr=%d(0x%x)", kr, kr));
  }

  // 2) 后端
  {
    Backend b = Available();
    if (b == Backend::None) b = InitBackend() ? Available() : Backend::None;
    Add(v, "backend", b != Backend::None, BackendName(b));
  }

  // 3) 目标进程
  {
    Proc target;
    std::string names;
    for (size_t i = 0; i < TargetCount(); ++i) {
      Proc p = FindProc(Targets()[i].execName);
      if (!names.empty()) names += ",";
      names += Targets()[i].execName;
      names += p ? "(found)" : "(none)";
      if (!target && p) target = p;
    }
    Add(v, "target proc", (bool)target,
        target ? Fmt("pid=%d %s", target.pid, target.name.c_str()) : names);
  }

  // 4) attach
  {
    if (!Attached()) {
      Proc target;
      for (size_t i = 0; i < TargetCount(); ++i) {
        target = FindProc(Targets()[i].execName);
        if (target) break;
      }
      if (target) Attach(target);
    }
    Add(v, "attach", Attached(), Attached() ? Fmt("pid=%d", TargetPid()) : "not attached");
  }

  // 5) 模块枚举
  {
    auto mods = ListModules();
    Module main;
    for (const auto &m : mods) {
      if (m.path.find(".app/") != std::string::npos) { main = m; break; }
    }
    if (!main && !mods.empty()) main = mods[0];
    Add(v, "modules", !mods.empty(),
        main ? Fmt("%zu imgs, main=%s base=%#llx", mods.size(),
                   main.path.c_str(), (unsigned long long)main.base)
             : Fmt("%zu imgs", mods.size()));
  }

  // 6) UE 初始化
  {
    bool ok = ue::Ready();
    if (!ok) ok = ue::Init();
    Add(v, "UE init", ok, ok ? "ready" : "特征码未命中");
  }

  // 7) GObjects / GNames
  {
    const auto &t = ue::T();
    Add(v, "GObjects/GNames", t.gObjects && t.gNames,
        Fmt("obj=%#llx names=%#llx profileOff=%#x/%#x",
            (unsigned long long)t.gObjects, (unsigned long long)t.gNames,
            t.offObjectsNum, t.offObjectsPtr));
  }

  // 8) UWorld
  {
    uint64_t w = ue::GetWorld();
    Add(v, "UWorld", w != 0, Fmt("%#llx", (unsigned long long)w));
  }

  // 9) Actors
  {
    auto actors = ue::GetActors();
    Add(v, "Actors", !actors.empty(), Fmt("%zu actors", actors.size()));
  }

  // 10) 相机
  {
    ue::CameraPOV pov;
    bool ok = ue::GetCameraPOV(pov);
    Add(v, "Camera", ok,
        ok ? Fmt("loc=(%.0f,%.0f,%.0f) fov=%.0f yaw=%.0f",
                 pov.location.x, pov.location.y, pov.location.z, pov.fov, pov.rotation.yaw)
           : "GetCameraPOV 失败");
  }

  // 11) 提权 entitlements 是否真的生效（读一个本不该能读的路径）
  {
    const char *p = "/var/mobile/Library/Preferences/com.apple.springboard.plist";
    FILE *f = fopen(p, "rb");
    Add(v, "no-sandbox 生效", f != nullptr, f ? p : Fmt("无法打开 %s", p));
    if (f) fclose(f);
  }

  // 12) 跨 App 悬浮能力
  {
    Class cls = NSClassFromString(@"SBSAccessibilityWindowHostingController");
    Add(v, "跨App悬浮 API", cls != nil,
        cls ? NSStringFromClass(cls).UTF8String : "SBSAccessibilityWindowHostingController 不可达");
  }

  DMLOG("[probe] ===== 自检结束：%d 项 =====", (int)v.size());
  g_last = v;
  return v;
}

std::string ProbeReport() {
  if (g_last.empty()) RunProbes();
  std::string s;
  for (const auto &r : g_last) {
    char line[640];
    snprintf(line, sizeof(line), "%s %-20s %s\n", r.ok ? "[OK]  " : "[FAIL]", r.name,
             r.detail.c_str());
    s += line;
  }
  return s;
}

}  // namespace dm
