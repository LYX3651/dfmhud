#include "Mem.h"
#include "Core.h"

#import <Foundation/Foundation.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/vm_region.h>
#include <libproc.h>
#include <sys/sysctl.h>
#include <unistd.h>

#include <algorithm>
#include <cctype>
#include <cstring>
#include <dlfcn.h>
#include <mutex>

#ifdef JB_HAVE_KFD
// kfd 的公开 API 在不同分支里签名不一致（有的叫 kfd_init，有的叫
// kfd_open / dynamic_kfd_init），所以这里全部走 dlsym 延迟绑定，
// 编译期不依赖具体头文件，运行期找得到就用。
typedef int (*kfd_init_fn)(int puaf_method, uint64_t kaddr);
typedef uint64_t (*kfd_kread_fn)(uint64_t addr, void *out, uint64_t len);
typedef int (*kfd_kwrite_fn)(uint64_t addr, const void *in, uint64_t len);
typedef uint64_t (*kfd_get_kbase_fn)(void);
typedef int (*kfd_puaf_fn)(void);

struct KfdApi {
  kfd_init_fn init = nullptr;
  kfd_kread_fn kread = nullptr;
  kfd_kwrite_fn kwrite = nullptr;
  kfd_get_kbase_fn kbase = nullptr;
  int puafLanda = 1, puafPhyspuppet = 3, puafSmith = 4;
  bool ok = false;
};

KfdApi g_kfd;

// PUAF 方法编号在不同 kfd 版本里不一样，这里靠名字表探测
bool LoadKfd() {
  if (g_kfd.ok) return true;

  void *h = dlopen("kfd", RTLD_NOW);
  if (!h) h = dlopen("@executable_path/Frameworks/libkfd.dylib", RTLD_NOW);
  if (!h) h = dlopen("@executable_path/libkfd.dylib", RTLD_NOW);
  if (!h) {
    DMLOG("[mem] dlopen(kfd) 失败: %s", dlerror());
    // 静态链接进二进制的情况，dlsym(RTLD_DEFAULT) 也能找到
    h = RTLD_DEFAULT;
  }

  g_kfd.init   = (kfd_init_fn)dlsym(h, "kfd_init");
  if (!g_kfd.init) g_kfd.init = (kfd_init_fn)dlsym(h, "dynamic_kfd_init");
  g_kfd.kread  = (kfd_kread_fn)dlsym(h, "kfd_kread");
  g_kfd.kwrite = (kfd_kwrite_fn)dlsym(h, "kfd_kwrite");
  g_kfd.kbase  = (kfd_get_kbase_fn)dlsym(h, "kfd_get_kernel_base");

  if (!g_kfd.init) {
    DMLOG("[mem] kfd 符号缺失（kfd_init 未找到）");
    return false;
  }
  g_kfd.ok = true;
  DMLOG("[mem] kfd 符号加载成功");
  return true;
}
#endif

namespace dm {

namespace {

std::mutex g_mtx;
mach_port_t g_task = MACH_PORT_NULL;
int g_pid = -1;
Backend g_backend = Backend::None;

inline size_t PageSz() { return static_cast<size_t>(vm_page_size); }

// ---- 读 Mach-O 头（走 Read，所以远程也适用）----
bool ReadHeader(uint64_t base, struct mach_header_64 &mh) {
  if (!base) return false;
  if (!Read(base, &mh, sizeof(mh))) return false;
  return mh.magic == MH_MAGIC_64;
}

// image 从 __TEXT 起始算的大小
uint64_t ImageSpan(uint64_t base) {
  struct mach_header_64 mh{};
  if (!ReadHeader(base, mh)) return 0;
  if (mh.ncmds == 0 || mh.ncmds > 8192) return 0;

  uint64_t textVmaddr = 0, end = 0;
  bool haveText = false;

  uint64_t cmd = base + sizeof(struct mach_header_64);
  for (uint32_t i = 0; i < mh.ncmds; ++i) {
    struct load_command lc{};
    if (!Read(cmd, &lc, sizeof(lc)) || lc.cmdsize < sizeof(lc)) break;
    if (lc.cmd == LC_SEGMENT_64) {
      struct segment_command_64 seg{};
      if (Read(cmd, &seg, sizeof(seg)) && seg.vmsize) {
        if (seg.vmaddr + seg.vmsize > end) end = seg.vmaddr + seg.vmsize;
        if (!haveText && strncmp(seg.segname, "__TEXT", 16) == 0) {
          textVmaddr = seg.vmaddr;
          haveText = true;
        }
      }
    }
    cmd += lc.cmdsize;
  }
  if (!haveText || end <= textVmaddr) return 0;
  return end - textVmaddr;
}

std::string ImagePath(uint64_t base) {
  struct mach_header_64 mh{};
  if (!ReadHeader(base, mh)) return {};
  uint64_t cmd = base + sizeof(struct mach_header_64);
  for (uint32_t i = 0; i < mh.ncmds; ++i) {
    struct load_command lc{};
    if (!Read(cmd, &lc, sizeof(lc)) || lc.cmdsize < sizeof(lc)) break;
    if (lc.cmd == LC_ID_DYLIB) {
      struct dylib_command dc{};
      if (Read(cmd, &dc, sizeof(dc)) && dc.dylib.name.offset < lc.cmdsize) {
        char buf[1024] = {0};
        if (Read(cmd + dc.dylib.name.offset, buf, sizeof(buf) - 1)) return std::string(buf);
      }
    }
    cmd += lc.cmdsize;
  }
  return {};
}

int HexVal(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

struct Pat {
  std::vector<uint8_t> v, m;
};

bool ParsePat(const char *s, Pat &p) {
  if (!s) return false;
  std::string t;
  for (const char *q = s; *q; ++q)
    if (!isspace((unsigned char)*q)) t.push_back(*q);
  if (t.size() < 4 || (t.size() % 2)) return false;
  for (size_t i = 0; i < t.size(); i += 2) {
    if (t[i] == '?' && t[i + 1] == '?') {
      p.v.push_back(0); p.m.push_back(0);
      continue;
    }
    int hi = HexVal(t[i]), lo = HexVal(t[i + 1]);
    if (hi < 0 || lo < 0) return false;
    p.v.push_back((uint8_t)((hi << 4) | lo));
    p.m.push_back(0xFF);
  }
  return true;
}

}  // namespace

// ======================= 后端 =======================
const char *BackendName(Backend b) {
  switch (b) {
    case Backend::TaskForPid: return "task_for_pid";
    case Backend::Kfd:        return "kfd(tfp0)";
    default:                  return "none";
  }
}

Backend Available() { return g_backend; }

bool InitBackend() {
  if (g_backend != Backend::None) return true;

  // 1) 先试 task_for_pid（TrollStore + entitlements 直接可用，最稳）
  mach_port_t self = mach_task_self();
  mach_port_t tp = MACH_PORT_NULL;
  kern_return_t kr = task_for_pid(self, getpid(), &tp);
  if (kr == KERN_SUCCESS) {
    if (tp != MACH_PORT_NULL) mach_port_deallocate(self, tp);
    g_backend = Backend::TaskForPid;
    DMLOG("[mem] backend = task_for_pid (self ok)");
    return true;
  }
  DMLOG("[mem] task_for_pid(self) failed kr=%d(0x%x) -> try kfd", kr, kr);

#ifdef JB_HAVE_KFD
  // 2) kfd 兜底：A12X / iOS 14.8.1 上通常 landa+physpuppet 可命中
  if (LoadKfd()) {
    const int methods[] = {g_kfd.puafLanda, g_kfd.puafPhyspuppet, g_kfd.puafSmith};
    const char *names[] = {"landa", "physpuppet", "smith"};
    for (int i = 0; i < 3; ++i) {
      // 第二参数是不依赖内核 slide 的提示地址，0 表示让 kfd 自己找
      int r = g_kfd.init(methods[i], 0);
      if (r == 0) {
        g_backend = Backend::Kfd;
        DMLOG("[mem] backend = kfd via %s", names[i]);
        return true;
      }
      DMLOG("[mem] kfd %s failed r=%d", names[i], r);
    }
    DMLOG("[mem] kfd 三种 PUAF 全部失败");
  }
#else
  DMLOG("[mem] kfd 未编译进本包");
#endif

  return false;
}

void Shutdown() {
  Detach();
  g_backend = Backend::None;
}

// ======================= 进程 =======================
std::vector<Proc> ListProcs() {
  std::vector<Proc> out;
  int n = proc_listallpids(nullptr, 0);
  if (n <= 0) return out;
  std::vector<pid_t> pids(n + 32);
  n = proc_listallpids(pids.data(), (int)(pids.size() * sizeof(pid_t)));
  if (n <= 0) return out;
  pids.resize(n);

  char path[PROC_PIDPATHINFO_MAXSIZE];
  for (pid_t p : pids) {
    if (p <= 0) continue;
    memset(path, 0, sizeof(path));
    if (proc_pidpath(p, path, sizeof(path)) <= 0) continue;
    Proc pr;
    pr.pid = p;
    pr.path = path;
    size_t slash = pr.path.rfind('/');
    pr.name = (slash == std::string::npos) ? pr.path : pr.path.substr(slash + 1);
    out.push_back(pr);
  }
  return out;
}

Proc FindProc(const char *execName) {
  if (!execName || !*execName) return {};
  for (const auto &p : ListProcs()) {
    if (p.name == execName) return p;
    // 兜底：包含匹配（有些客户端名带后缀）
    if (p.name.find(execName) != std::string::npos) return p;
  }
  return {};
}

Proc FindProcByBundle(const char *bundleId) {
  if (!bundleId || !*bundleId) return {};
  // bundle id -> 容器路径 -> 可执行名
  const TargetApp *list = Targets();
  for (size_t i = 0; i < TargetCount(); ++i) {
    if (strcmp(list[i].bundleId, bundleId) != 0) continue;
    return FindProc(list[i].execName);
  }
  return {};
}

bool Attach(const Proc &p) {
  std::lock_guard<std::mutex> lk(g_mtx);
  Detach();
  if (!p) return false;

  mach_port_t task = MACH_PORT_NULL;
  kern_return_t kr = task_for_pid(mach_task_self(), p.pid, &task);
  if (kr != KERN_SUCCESS) {
    DMLOG("[mem] task_for_pid(%d) failed kr=%d(0x%x)", p.pid, kr, kr);
    return false;
  }
  g_task = task;
  g_pid = p.pid;
  DMLOG("[mem] attached pid=%d (%s)", p.pid, p.name.c_str());
  return true;
}

void Detach() {
  if (g_task != MACH_PORT_NULL && g_task != mach_task_self()) {
    mach_port_deallocate(mach_task_self(), g_task);
  }
  g_task = MACH_PORT_NULL;
  g_pid = -1;
}

bool Attached() { return g_task != MACH_PORT_NULL; }
int TargetPid() { return g_pid; }

// ======================= 读写 =======================
bool Read(uint64_t addr, void *out, size_t len) {
  // 未 attach 时退化为读自己（方便单进程调试）
  mach_port_t t = g_task;
  if (t == MACH_PORT_NULL) t = mach_task_self();
  if (!out || !len) return false;

  mach_vm_size_t got = 0;
  kern_return_t kr = mach_vm_read_overwrite(
      t, (mach_vm_address_t)addr, (mach_vm_size_t)len,
      (mach_vm_address_t)out, &got);
  return kr == KERN_SUCCESS && got == len;
}

bool Write(uint64_t addr, const void *data, size_t len) {
  mach_port_t t = g_task;
  if (t == MACH_PORT_NULL) t = mach_task_self();
  if (!data || !len) return false;
  kern_return_t kr = mach_vm_write(t, (mach_vm_address_t)addr,
                                   (vm_offset_t)const_cast<void *>(data),
                                   (mach_msg_type_number_t)len);
  return kr == KERN_SUCCESS;
}

bool Patch(uint64_t addr, const void *data, size_t len) {
  mach_port_t t = g_task;
  if (t == MACH_PORT_NULL) t = mach_task_self();
  if (!data || !len) return false;

  const size_t pg = PageSz();
  const uint64_t start = addr & ~(uint64_t)(pg - 1);
  const size_t pages = ((addr - start) + len + pg - 1) / pg;

  // 取原保护
  mach_vm_address_t region = (mach_vm_address_t)start;
  mach_vm_size_t rsize = 0;
  vm_region_basic_info_data_64_t info{};
  mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
  mach_port_t obj = MACH_PORT_NULL;
  vm_prot_t orig = VM_PROT_READ | VM_PROT_EXECUTE;
  if (mach_vm_region(t, &region, &rsize, VM_REGION_BASIC_INFO_64,
                     (vm_region_info_t)&info, &cnt, &obj) == KERN_SUCCESS) {
    orig = info.protection;
  }
  if (obj != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), obj);

  if (mach_vm_protect(t, (vm_address_t)start, (vm_size_t)(pages * pg), FALSE,
                      VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) {
    return false;
  }
  bool ok = Write(addr, data, len);
  mach_vm_protect(t, (vm_address_t)start, (vm_size_t)(pages * pg), FALSE, orig);
  return ok;
}

std::string ReadStr(uint64_t addr, size_t maxLen) {
  if (!addr) return {};
  std::vector<char> buf(maxLen + 1, 0);
  if (!Read(addr, buf.data(), maxLen)) return {};
  buf[maxLen] = 0;
  return std::string(buf.data());
}

// ======================= 模块 =======================
std::vector<Module> ListModules() {
  std::vector<Module> out;
  mach_port_t t = g_task;
  if (t == MACH_PORT_NULL) {
    // 自己进程：直接走 dyld
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; ++i) {
      const mach_header *h = _dyld_get_image_header(i);
      if (!h) continue;
      const char *nm = _dyld_get_image_name(i);
      Module m;
      m.base = (uint64_t)h;
      m.size = ImageSpan(m.base);
      m.path = nm ? nm : "";
      if (m.size) out.push_back(m);
    }
    return out;
  }

  // 远程：遍历 region 找 MH_MAGIC_64
  mach_vm_address_t addr = 0;
  while (out.size() < 1024) {
    mach_vm_size_t size = 0;
    vm_region_basic_info_data_64_t info{};
    mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t obj = MACH_PORT_NULL;
    kern_return_t kr = mach_vm_region(t, &addr, &size, VM_REGION_BASIC_INFO_64,
                                      (vm_region_info_t)&info, &cnt, &obj);
    if (obj != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), obj);
    if (kr != KERN_SUCCESS || size == 0) break;

    if (info.protection & VM_PROT_READ) {
      struct mach_header_64 mh{};
      if (Read(addr, &mh, sizeof(mh)) && mh.magic == MH_MAGIC_64 &&
          (mh.filetype == MH_EXECUTE || mh.filetype == MH_DYLIB || mh.filetype == MH_BUNDLE)) {
        Module m;
        m.base = addr;
        m.size = ImageSpan(m.base);
        m.path = ImagePath(m.base);
        if (m.size) out.push_back(m);
      }
    }
    addr += size;
  }
  return out;
}

Module FindModule(const char *needle) {
  if (!needle || !*needle) return {};
  for (const auto &m : ListModules()) {
    if (m.path.find(needle) != std::string::npos) return m;
  }
  return {};
}

// ======================= 特征码扫描 =======================
std::vector<uint64_t> ScanPattern(const Module &m, const char *pattern, size_t limit) {
  std::vector<uint64_t> out;
  Pat p;
  if (!ParsePat(pattern, p) || !m.size || !limit) return out;

  const size_t kChunk = 1 << 20;
  const size_t ov = p.v.size();
  std::vector<uint8_t> buf(kChunk + ov);

  for (uint64_t off = 0; off + ov <= m.size; off += kChunk) {
    size_t len = (size_t)std::min<uint64_t>(kChunk + ov, m.size - off);
    if (!Read(m.base + off, buf.data(), len)) continue;
    if (len < ov) break;

    const bool last = (off + kChunk) >= m.size;
    size_t starts = len - ov + 1;
    size_t scanStarts = last ? starts : std::min(starts, kChunk);

    for (size_t i = 0; i < scanStarts; ++i) {
      bool hit = true;
      for (size_t j = 0; j < ov; ++j) {
        if (p.m[j] && buf[i + j] != p.v[j]) { hit = false; break; }
      }
      if (hit) {
        out.push_back(m.base + off + i);
        if (out.size() >= limit) return out;
      }
    }
  }
  return out;
}

uint64_t ScanOne(const Module &m, const char *pattern) {
  auto v = ScanPattern(m, pattern, 1);
  return v.empty() ? 0 : v[0];
}

}  // namespace dm
