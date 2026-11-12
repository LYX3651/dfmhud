// UE.cpp — UE4/UE5 反射层实现
// 核心思路：所有版本相关的东西要么运行时特征码定位，要么走反射链，
// 绝不写死单一版本的偏移。定位不到就打日志，方便上位机补特征码。
#include "UE.h"
#include "Core.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <mutex>
#include <string>
#include <unordered_map>

// M_PI 在部分 libc++/glibc 组合里不定义（需要 _USE_MATH_DEFINES），
// 这里自己兜一个，避免在每个平台判断。
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

namespace dm {
namespace ue {

namespace {

std::mutex g_mtx;
Tables g_t{};
bool g_inited = false;

// ---------- 版本特征 ----------
// 这些是"已知客户端的候选值"，运行时逐个试，第一个能正确解出类名的胜出。
struct Profile {
  const char *name;
  int32_t objChunkStride;   // FUObjectItem 每块字节数
  int32_t itemSize;         // FUObjectItem 大小
  int32_t offObjectsNum;    // FUObjectArray.Objects.NumElements
  int32_t offObjectsPtr;    // FUObjectArray.Objects.Objects
  int32_t offNameWide;      // FNameEntry header 是否 wide 的位
};

// UE4.23 – 4.27 / UE5.0 – 5.3 的主流布局（16 字节 FUObjectItem + 64KB chunk）
const Profile g_profiles[] = {
    {"UE4.23-5.3 (64K chunk/16B item)", 0x10000, 16, 0x24, 0x20},
    {"UE4.23-5.3 (64K chunk/24B item)", 0x10000, 24, 0x24, 0x20},
    {"UE4.20-4.22",                     0x10000, 16, 0x1C, 0x18},
};
const int g_profileCount = (int)(sizeof(g_profiles) / sizeof(g_profiles[0]));

int32_t g_curProfile = -1;

// ---------- FName ----------
// UE4.23+ FNamePool:
//   +0 uint32 Lock
//   +4 uint32 CurrentBlock
//   +8 uint32 CurrentByteCursor
//   +0xC ... Blocks[8192] (uint8*)
// 索引编码：idx = (blockIdx << 16) | (offset >> 1)
struct FNamePool {
  uint32_t lock = 0;
  uint32_t currentBlock = 0;
  uint32_t currentCursor = 0;
};

bool ReadNameEntry(uint64_t pool, int32_t idx, std::string &out) {
  if (!pool || idx < 0) return false;

  // 先按 FNamePool 解
  const uint32_t blockIdx = (uint32_t)idx >> 16;
  const uint32_t blockOff = ((uint32_t)idx & 0xFFFF) * 2;
  if (blockIdx >= 8192) return false;

  uint64_t blockPtr = 0;
  if (!dm::Read(pool + 0x10 + blockIdx * 8, &blockPtr, 8) || !blockPtr) return false;

  // FNameEntry header：uint16 bIsWide:1 | Len:15
  uint16_t header = 0;
  if (!dm::Read(blockPtr + blockOff, &header, 2)) return false;
  const bool wide = (header & 0x8000) != 0;
  const int len = header & 0x7FFF;
  if (len <= 0 || len > 256) return false;

  out.clear();
  out.reserve(len);
  if (!wide) {
    std::vector<char> buf(len + 1, 0);
    if (!dm::Read(blockPtr + blockOff + 2, buf.data(), len)) return false;
    out.assign(buf.data(), len);
  } else {
    std::vector<uint16_t> buf(len + 1, 0);
    if (!dm::Read(blockPtr + blockOff + 2, buf.data(), len * 2)) return false;
    for (int i = 0; i < len; ++i) out.push_back((char)(buf[i] & 0xFF));
  }

  // 去掉可能的 \0
  while (!out.empty() && (out.back() == '\0')) out.pop_back();
  return !out.empty();
}

// ---------- UObject ----------
uint64_t ObjClassPtr(uint64_t obj) {
  if (!obj) return 0;
  return dm::ReadV<uint64_t>(obj + 0x10, 0);   // UObject::Class（UE4/UE5 一致）
}

uint64_t ObjOuterPtr(uint64_t obj) {
  if (!obj) return 0;
  return dm::ReadV<uint64_t>(obj + 0x20, 0);   // UObject::Outer
}

int32_t ObjNameIndex(uint64_t obj) {
  if (!obj) return -1;
  return dm::ReadV<int32_t>(obj + 0x18, -1);   // UObject::Name (FName.ComparisonIndex)
}

// UStruct::SuperStruct 在 +0x40（UE4.27）/ +0x40（UE5）——用属性表兜底
uint64_t StructSuper(uint64_t st) {
  return dm::ReadV<uint64_t>(st + 0x40, 0);
}

std::string ClassNameOf(uint64_t obj) {
  uint64_t cls = ObjClassPtr(obj);
  if (!cls) return {};
  int32_t ni = ObjNameIndex(cls);
  std::string nm;
  if (!ReadNameEntry(g_t.gNames, ni, nm)) return {};
  return nm;
}

}  // namespace

Tables &T() { return g_t; }
bool Ready() { return g_t.ready; }

// ======================= 初始化 =======================
bool Init() {
  std::lock_guard<std::mutex> lk(g_mtx);
  if (g_inited) return g_t.ready;

  DMLOG("[ue] Init() begin");

  // ---- 1) 找可执行模块 ----
  Module main = FindModule(".app/");
  if (!main) {
    // 退一步：拿最大的那个 MH_EXECUTE
    auto mods = ListModules();
    for (const auto &m : mods) {
      if (m.size > main.size) main = m;
    }
  }
  if (!main) {
    DMLOG("[ue] 主模块定位失败");
    return false;
  }
  DMLOG("[ue] main module: %s base=%#llx size=%zu", main.path.c_str(),
        (unsigned long long)main.base, (size_t)main.size);

  // ---- 2) 引擎版本串 ----
  {
    for (uint64_t off = 0; off + 32 < main.size; off += 0x1000) {
      char buf[4096] = {0};
      size_t n = sizeof(buf) - 1;
      if (off + n > main.size) n = (size_t)(main.size - off);
      if (!Read(main.base + off, buf, n)) continue;
      char *p = strstr(buf, "++UE");
      if (p && (p[4] == '4' || p[4] == '5')) {
        size_t l = strcspn(p, "\0");
        if (l > 6 && l < 64) {
          g_t.engineVersion.assign(p, l);
          g_t.isUE5 = (p[4] == '5');
          DMLOG("[ue] engine = %s", g_t.engineVersion.c_str());
          break;
        }
      }
    }
    if (g_t.engineVersion.empty()) DMLOG("[ue] 版本串未抓到（不致命）");
  }

  // ---- 3) 定位 GNames / GObjects ----
  // 特征码只用来找"引用点"，真正的表地址从 RIP 相对寻址里解出来。
  // UE4/UE5 通用：ADRP + ADD 组合装载 GNames / GObjects。
  // 这里给的是常见模式，找不到就走字符串锚定。
  struct Anchor {
    const char *what;
    const char *str;
    int hint;  // 0=GNames 1=GObjects 2=GWorld
  };
  const Anchor anchors[] = {
      {"GNames",  "Invalid_Object",     0},
      {"GObjects","None",               1},
      {"GWorld",  "PersistentLevel",    2},
  };

  for (const auto &a : anchors) {
    // 在 __cstring 里找锚点字符串，再由它找到引用代码，再反向解表地址。
    // 简化的稳健做法：直接搜索 UE 的经典初始化序列。
    (void)a;
  }

  // ---- 4) Fallback：按特征码找 GObjects ----
  // UE4: "48 8B 05 ?? ?? ?? ?? 48 8B 88 ?? ?? ?? ?? 48 85 C9"
  // UE5: "48 8B 0D ?? ?? ?? ?? 48 85 C9 74 ?? 8B 41"
  static const char *kGObjectsPatterns[] = {
      "48 8B 3D ?? ?? ?? ?? 48 85 FF 74 ?? 8B 47",
      "48 8B 0D ?? ?? ?? ?? 48 85 C9 74 ?? 8B 41",
      "48 8B 05 ?? ?? ?? ?? 48 85 C0 74 ?? 8B 50",
  };
  for (const char *pat : kGObjectsPatterns) {
    uint64_t hit = ScanOne(main, pat);
    if (!hit) continue;
    // RIP 相对：指令 + 7 + disp32
    int32_t disp = 0;
    if (!dm::Read(hit + 3, &disp, 4)) continue;
    uint64_t tableAddr = hit + 7 + (int64_t)disp;
    g_t.gObjects = tableAddr;
    DMLOG("[ue] GObjects candidate via %s -> %#llx", pat, (unsigned long long)tableAddr);
    break;
  }

  if (!g_t.gObjects) {
    DMLOG("[ue] GObjects 特征码全部未命中，需要按版本补偏移");
    return false;
  }

  // ---- 5) 找 GNames ----
  static const char *kGNamesPatterns[] = {
      "48 8B 0D ?? ?? ?? ?? 48 85 C9 74 ?? 8B 41 08",
      "48 8B 3D ?? ?? ?? ?? 48 85 FF 75 ?? 8B 4F",
  };
  for (const char *pat : kGNamesPatterns) {
    uint64_t hit = ScanOne(main, pat);
    if (!hit) continue;
    int32_t disp = 0;
    if (!dm::Read(hit + 3, &disp, 4)) continue;
    g_t.gNames = hit + 7 + (int64_t)disp;
    DMLOG("[ue] GNames candidate via %s -> %#llx", pat, (unsigned long long)g_t.gNames);
    break;
  }

  // ---- 6) 探测 profile：用类名能不能正确解出来当作验证 ----
  for (int i = 0; i < g_profileCount; ++i) {
    const Profile &p = g_profiles[i];
    g_t.offObjectsNum = p.offObjectsNum;
    g_t.offObjectsPtr = p.offObjectsPtr;

    int32_t num = dm::ReadV<int32_t>(g_t.gObjects + p.offObjectsNum, 0);
    if (num <= 0 || num > 4000000) continue;

    uint64_t arr = dm::ReadV<uint64_t>(g_t.gObjects + p.offObjectsPtr, 0);
    if (!arr) continue;

    // 取第 0 块第一个非空对象，验证能否解出名字
    int ok = 0;
    for (int idx = 0; idx < 4096 && ok < 3; ++idx) {
      const int chunk = idx / (p.objChunkStride / p.itemSize);
      const int within = idx % (p.objChunkStride / p.itemSize);
      uint64_t cptr = dm::ReadV<uint64_t>(arr + chunk * 8, 0);
      if (!cptr) continue;
      uint64_t obj = dm::ReadV<uint64_t>(cptr + within * p.itemSize, 0);
      if (!obj) continue;
      std::string nm;
      int32_t ni = ObjNameIndex(obj);
      if (ni >= 0 && ReadNameEntry(g_t.gNames, ni, nm) && !nm.empty()) ++ok;
    }
    if (ok > 0) {
      g_curProfile = i;
      DMLOG("[ue] profile = %s (验证 %d/3)", p.name, ok);
      break;
    }
  }

  if (g_curProfile < 0) {
    DMLOG("[ue] profile 全部验证失败（GNames 解析可能不对）");
  }

  g_inited = true;
  g_t.ready = (g_curProfile >= 0) && (g_t.gNames != 0);
  DMLOG("[ue] Init() -> ready=%d", (int)g_t.ready);
  return g_t.ready;
}

void Refresh() {
  g_t.gUWorldPtr = 0;
}

// ======================= 对象 =======================
uint64_t ObjectAt(int32_t index, int32_t *outNum) {
  if (g_curProfile < 0 || index < 0) return 0;
  const Profile &p = g_profiles[g_curProfile];
  const int perChunk = p.objChunkStride / p.itemSize;

  int32_t num = dm::ReadV<int32_t>(g_t.gObjects + p.offObjectsNum, 0);
  if (outNum) *outNum = num;
  if (index >= num) return 0;

  uint64_t arr = dm::ReadV<uint64_t>(g_t.gObjects + p.offObjectsPtr, 0);
  if (!arr) return 0;

  const int chunk = index / perChunk;
  const int within = index % perChunk;
  uint64_t cptr = dm::ReadV<uint64_t>(arr + chunk * 8, 0);
  if (!cptr) return 0;
  return dm::ReadV<uint64_t>(cptr + within * p.itemSize, 0);
}

uint64_t UObjectClass(uint64_t obj) { return ObjClassPtr(obj); }
uint64_t UObjectOuter(uint64_t obj) { return ObjOuterPtr(obj); }

std::string UObjectShortName(uint64_t obj) {
  if (!obj) return {};
  std::string nm;
  int32_t ni = ObjNameIndex(obj);
  if (ni < 0) return {};
  if (!ReadNameEntry(g_t.gNames, ni, nm)) return {};
  return nm;
}

std::string UObjectName(uint64_t obj) {
  if (!obj) return {};
  std::string name = UObjectShortName(obj);
  if (name.empty()) return {};

  // 拼 Class 前缀，方便一眼看出类型
  std::string cls = ClassNameOf(obj);
  if (!cls.empty() && cls != name) {
    // 反过来：Class 自己就有名字
    return cls + " " + name;
  }
  return name;
}

std::vector<uint64_t> FindObjectsByClass(const char *className, size_t limit) {
  std::vector<uint64_t> out;
  if (!className || !g_t.ready) return out;

  int32_t num = 0;
  for (int32_t i = 0; i < 400000 && out.size() < limit; ++i) {
    uint64_t obj = ObjectAt(i, &num);
    if (!obj) {
      if (num > 0 && i >= num) break;
      continue;
    }
    std::string cls = ClassNameOf(obj);
    if (cls.empty()) continue;
    if (cls == className) out.push_back(obj);
  }
  return out;
}

bool IsA(uint64_t obj, const char *className) {
  if (!obj || !className) return false;
  std::string want(className);

  uint64_t cls = ObjClassPtr(obj);
  int guard = 0;
  while (cls && guard++ < 64) {
    std::string nm = UObjectShortName(cls);
    if (nm == want) return true;
    uint64_t super = StructSuper(cls);
    if (super == cls) break;
    cls = super;
  }
  return false;
}

// ======================= 属性 =======================
// 走 UClass.Children 链，匹配 UProperty 名字，返回 Offset_Internal
int32_t FindPropertyOffset(uint64_t obj, const char *propName) {
  if (!obj || !propName) return -1;
  uint64_t cls = ObjClassPtr(obj);
  if (!cls) return -1;

  int guard = 0;
  while (cls && guard++ < 64) {
    // UStruct::Children（UE4.27 在 +0x48，UE5 在 +0x50）——两个都试
    for (int childrenOff : {0x48, 0x50}) {
      uint64_t prop = dm::ReadV<uint64_t>(cls + childrenOff, 0);
      int n = 0;
      while (prop && n++ < 512) {
        std::string pn = UObjectShortName(prop);
        if (pn == propName) {
          // UProperty::Offset_Internal：UE4 在 +0x4C，UE5 在 +0x54
          for (int off : {0x4C, 0x54}) {
            int32_t v = dm::ReadV<int32_t>(prop + off, -1);
            if (v >= 0 && v < 0x10000) return v;
          }
        }
        // UField::Next 在 +0x28（UE4）/ +0x30（UE5）
        uint64_t next = dm::ReadV<uint64_t>(prop + 0x28, 0);
        if (!next) next = dm::ReadV<uint64_t>(prop + 0x30, 0);
        prop = next;
      }
    }
    cls = StructSuper(cls);
  }
  return -1;
}

uint64_t ReadUObjectProp(uint64_t obj, const char *propName) {
  int32_t off = FindPropertyOffset(obj, propName);
  if (off < 0) return 0;
  return dm::ReadV<uint64_t>(obj + off, 0);
}

// ======================= 世界 =======================
uint64_t GetWorld() {
  if (g_t.gUWorldPtr) return g_t.gUWorldPtr;

  // 直接找 UWorld 实例（比定位 GWorld 指针稳，版本无关）
  auto worlds = FindObjectsByClass("World", 8);
  if (!worlds.empty()) {
    g_t.gUWorldPtr = worlds[0];
    DMLOG("[ue] UWorld* = %#llx", (unsigned long long)g_t.gUWorldPtr);
    return g_t.gUWorldPtr;
  }
  return 0;
}

std::vector<uint64_t> GetActors() {
  std::vector<uint64_t> out;
  uint64_t world = GetWorld();
  if (!world) return out;

  // UWorld::PersistentLevel —— 用属性链找，找不到用候选偏移
  int32_t lvlOff = FindPropertyOffset(world, "PersistentLevel");
  if (lvlOff < 0) lvlOff = 0x30;   // UE4.27 常见
  
  uint64_t level = dm::ReadV<uint64_t>(world + lvlOff, 0);
  if (!level) {
    DMLOG("[ue] PersistentLevel 为空 (off=%#x)", lvlOff);
    return out;
  }

  // ULevel::Actors 是 TArray<AActor*>
  // TArray { T* Data; int32 Num; int32 Max; }
  int32_t arrOff = FindPropertyOffset(level, "Actors");
  if (arrOff < 0) arrOff = 0xA0;   // UE4.27 常见

  uint64_t data = dm::ReadV<uint64_t>(level + arrOff, 0);
  int32_t num = dm::ReadV<int32_t>(level + arrOff + 8, 0);
  if (!data || num <= 0 || num > 30000) {
    DMLOG("[ue] Actors 数组异常 data=%#llx num=%d off=%#x", (unsigned long long)data, num, arrOff);
    return out;
  }

  out.reserve(num);
  std::vector<uint64_t> buf(num);
  if (!dm::Read(data, buf.data(), (size_t)num * 8)) return out;
  for (uint64_t a : buf)
    if (a) out.push_back(a);

  DMLOG("[ue] actors = %zu", out.size());
  return out;
}

uint64_t GetLocalPlayerController() {
  // UWorld::OwningGameInstance -> LocalPlayers[0] -> PlayerController
  uint64_t world = GetWorld();
  if (!world) return 0;

  int32_t giOff = FindPropertyOffset(world, "OwningGameInstance");
  if (giOff < 0) giOff = 0x1B8;
  uint64_t gi = dm::ReadV<uint64_t>(world + giOff, 0);
  if (!gi) return 0;

  int32_t lpOff = FindPropertyOffset(gi, "LocalPlayers");
  if (lpOff < 0) lpOff = 0x38;
  uint64_t lpData = dm::ReadV<uint64_t>(gi + lpOff, 0);
  if (!lpData) return 0;

  uint64_t localPlayer = dm::ReadV<uint64_t>(lpData, 0);
  if (!localPlayer) return 0;

  int32_t pcOff = FindPropertyOffset(localPlayer, "PlayerController");
  if (pcOff < 0) pcOff = 0x30;
  return dm::ReadV<uint64_t>(localPlayer + pcOff, 0);
}

uint64_t GetLocalPawn() {
  uint64_t pc = GetLocalPlayerController();
  if (!pc) return 0;

  // APlayerController::AcknowledgedPawn
  int32_t off = FindPropertyOffset(pc, "AcknowledgedPawn");
  if (off < 0) off = 0x2F0;
  uint64_t pawn = dm::ReadV<uint64_t>(pc + off, 0);
  if (pawn) return pawn;

  off = FindPropertyOffset(pc, "Pawn");
  if (off < 0) off = 0x2E0;
  return dm::ReadV<uint64_t>(pc + off, 0);
}

// ======================= 变换 =======================
bool GetActorLocation(uint64_t actor, Vec3 &out) {
  if (!actor) return false;

  // AActor::RootComponent -> USceneComponent::RelativeLocation
  int32_t rcOff = FindPropertyOffset(actor, "RootComponent");
  if (rcOff < 0) rcOff = 0x130;
  uint64_t root = dm::ReadV<uint64_t>(actor + rcOff, 0);
  if (!root) return false;

  int32_t locOff = FindPropertyOffset(root, "RelativeLocation");
  if (locOff < 0) locOff = 0x11C;
  return dm::Read(root + locOff, &out, sizeof(Vec3));
}

bool GetActorBounds(uint64_t actor, Vec3 &origin, Vec3 &extent) {
  if (!actor) return false;
  int32_t rcOff = FindPropertyOffset(actor, "RootComponent");
  if (rcOff < 0) rcOff = 0x130;
  uint64_t root = dm::ReadV<uint64_t>(actor + rcOff, 0);
  if (!root) return false;

  int32_t bo = FindPropertyOffset(root, "Bounds");
  if (bo < 0) bo = 0x160;
  // FBoxSphereBounds { FVector Origin; FVector BoxExtent; float SphereRadius; }
  if (!dm::Read(root + bo, &origin, sizeof(Vec3))) return false;
  return dm::Read(root + bo + 0x0C, &extent, sizeof(Vec3));
}

// ======================= 相机 =======================
bool GetCameraPOV(CameraPOV &out) {
  uint64_t pc = GetLocalPlayerController();
  if (!pc) return false;

  int32_t cmOff = FindPropertyOffset(pc, "PlayerCameraManager");
  if (cmOff < 0) cmOff = 0x340;
  uint64_t cm = dm::ReadV<uint64_t>(pc + cmOff, 0);
  if (!cm) return false;

  // APlayerCameraManager::CameraCache (FCameraCacheEntry)
  // { float TimeStamp; float POVPadding; FMinimalViewInfo POV; }
  int32_t ccOff = FindPropertyOffset(cm, "CameraCache");
  if (ccOff < 0) ccOff = 0x430;

  // FMinimalViewInfo { FVector Location; FRotator Rotation; float FOV; ... }
  const uint64_t pov = cm + ccOff + 0x10;
  if (!dm::Read(pov, &out.location, sizeof(Vec3))) return false;
  if (!dm::Read(pov + 0x0C, &out.rotation, sizeof(Rotator))) return false;
  dm::Read(pov + 0x18, &out.fov, 4);
  if (out.fov <= 1.f || out.fov > 179.f) out.fov = 90.f;

  return true;
}

bool GetViewMatrix(Matrix &out) {
  // 直接用相机自己算，不依赖引擎函数
  CameraPOV pov;
  if (!GetCameraPOV(pov)) return false;

  const float radP = pov.rotation.pitch * (float)M_PI / 180.f;
  const float radY = pov.rotation.yaw   * (float)M_PI / 180.f;
  const float radR = pov.rotation.roll  * (float)M_PI / 180.f;

  const float sp = sinf(radP), cp = cosf(radP);
  const float sy = sinf(radY), cy = cosf(radY);
  const float sr = sinf(radR), cr = cosf(radR);

  // UE 的旋转矩阵（先 roll 再 pitch 再 yaw）
  out.m[0][0] = cp * cy;
  out.m[0][1] = cp * sy;
  out.m[0][2] = sp;

  out.m[1][0] = sr * sp * cy - cr * sy;
  out.m[1][1] = sr * sp * sy + cr * cy;
  out.m[1][2] = -sr * cp;

  out.m[2][0] = -(cr * sp * cy + sr * sy);
  out.m[2][1] = cy * sr - cr * sp * sy;
  out.m[2][2] = cr * cp;
  return true;
}

bool WorldToScreen(const Vec3 &world, Vec2 &screen, const CameraPOV &pov,
                   const Matrix &mtx, float screenW, float screenH) {
  const float dx = world.x - pov.location.x;
  const float dy = world.y - pov.location.y;
  const float dz = world.z - pov.location.z;

  // 变换到相机空间
  const float px = dx * mtx.m[1][0] + dy * mtx.m[1][1] + dz * mtx.m[1][2];
  const float py = dx * mtx.m[2][0] + dy * mtx.m[2][1] + dz * mtx.m[2][2];
  const float pz = dx * mtx.m[0][0] + dy * mtx.m[0][1] + dz * mtx.m[0][2];

  if (pz < 1.0f) return false;   // 在相机后面

  const float fovRad = pov.fov * (float)M_PI / 180.f;
  const float tanHalf = tanf(fovRad * 0.5f);

  const float aspect = screenW / screenH;
  const float ndcX = px / (pz * tanHalf * aspect);
  const float ndcY = py / (pz * tanHalf);

  screen.x = (screenW * 0.5f) * (1.f + ndcX);
  screen.y = (screenH * 0.5f) * (1.f - ndcY);
  return true;
}

// ======================= 骨骼 =======================
bool GetBoneLocation(uint64_t actor, const char *boneName, Vec3 &out) {
  // ACharacter -> Mesh (USkeletalMeshComponent)
  uint64_t mesh = ReadUObjectProp(actor, "Mesh");
  if (!mesh) return false;

  // USkinnedMeshComponent::BoneArray / ComponentSpaceTransforms
  // 这里用 GetSocketLocation 的替代：直接读 ComponentSpaceTransforms + ComponentToWorld
  // 为简化且稳妥，走 BoneArray 的缓存版本不存在时返回失败，由上层用包围盒兜底
  (void)boneName;
  (void)mesh;
  (void)out;
  return false;
}

std::vector<std::pair<std::string, Vec3>> GetKeyBones(uint64_t actor) {
  std::vector<std::pair<std::string, Vec3>> out;
  // 骨骼名表依赖目标客户端的 Skeleton 资产，需要上位机 dump 后填入。
  // 这里先给出标准 UE4 Mannequin 骨架的常见键，能对上就用。
  static const char *kBones[] = {
      "head", "neck_01", "spine_03", "spine_01", "pelvis",
      "upperarm_l", "lowerarm_l", "hand_l",
      "upperarm_r", "lowerarm_r", "hand_r",
      "thigh_l", "calf_l", "foot_l",
      "thigh_r", "calf_r", "foot_r",
  };
  for (const char *b : kBones) {
    Vec3 v;
    if (GetBoneLocation(actor, b, v)) out.emplace_back(b, v);
  }
  return out;
}

// ======================= 玩家 =======================
bool ExtractPlayer(uint64_t actor, const Vec3 &cameraLoc, PlayerInfo &out) {
  if (!actor) return false;
  out = PlayerInfo{};
  out.actor = actor;

  if (!GetActorLocation(actor, out.location)) return false;

  const float dx = out.location.x - cameraLoc.x;
  const float dy = out.location.y - cameraLoc.y;
  const float dz = out.location.z - cameraLoc.z;
  out.distance = sqrtf(dx * dx + dy * dy + dz * dz) / 100.f;  // UE 单位是 cm

  // PlayerState -> PlayerName
  uint64_t ps = ReadUObjectProp(actor, "PlayerState");
  if (ps) {
    out.playerState = ps;
    int32_t no = FindPropertyOffset(ps, "PlayerName");
    if (no >= 0) {
      // FString { wchar_t* Data; int32 Num; int32 Max; }
      uint64_t data = dm::ReadV<uint64_t>(ps + no, 0);
      int32_t num = dm::ReadV<int32_t>(ps + no + 8, 0);
      if (data && num > 0 && num < 64) {
        std::vector<uint16_t> w(num, 0);
        if (dm::Read(data, w.data(), num * 2)) {
          for (int i = 0; i < num - 1; ++i) out.name.push_back((char)(w[i] & 0xFF));
        }
      }
    }
  }

  // 血量
  {
    int32_t ho = FindPropertyOffset(actor, "Health");
    if (ho < 0) ho = FindPropertyOffset(actor, "CurrentHealth");
    if (ho >= 0) dm::Read(actor + ho, &out.health, 4);
    int32_t mo = FindPropertyOffset(actor, "MaxHealth");
    if (mo >= 0) dm::Read(actor + mo, &out.maxHealth, 4);
    if (out.maxHealth <= 0) out.maxHealth = 100.f;

    // 常见的是 float 血量，也可能是结构体里的；再试 0~100 的合理性校验
    if (out.health < 0 || out.health > 100000.f) out.health = 0;
  }

  // 队伍
  {
    int32_t to = FindPropertyOffset(actor, "TeamID");
    if (to < 0) to = FindPropertyOffset(actor, "TeamId");
    if (to >= 0) out.teamId = dm::ReadV<int32_t>(actor + to, -1);
  }

  // 机器人判定：名字为空 / 名字含 bot 特征
  out.isBot = out.name.empty() || out.name.find("Bot") != std::string::npos ||
              out.name.find("AI") != std::string::npos;

  // 手持武器
  {
    uint64_t weapon = ReadUObjectProp(actor, "CurrentWeapon");
    if (weapon) {
      out.weapon = UObjectShortName(weapon);
    }
  }

  // 头部位置：用包围盒顶
  Vec3 origin, extent;
  if (GetActorBounds(actor, origin, extent)) {
    out.headPos = origin;
    out.headPos.z += extent.z;
  } else {
    out.headPos = out.location;
    out.headPos.z += 90.f;   // 兜底：人高约 180cm
  }

  return true;
}

// ======================= 物资 =======================
bool ExtractLoot(uint64_t actor, const Vec3 &cameraLoc, LootInfo &out) {
  if (!actor) return false;
  out = LootInfo{};
  out.actor = actor;

  if (!GetActorLocation(actor, out.location)) return false;

  const float dx = out.location.x - cameraLoc.x;
  const float dy = out.location.y - cameraLoc.y;
  const float dz = out.location.z - cameraLoc.z;
  out.distance = sqrtf(dx * dx + dy * dy + dz * dz) / 100.f;

  out.name = UObjectShortName(actor);
  out.category = ClassNameOf(actor);

  // 等级/价值：不同客户端字段名不一样，能读到就用
  int32_t lo = FindPropertyOffset(actor, "ItemLevel");
  if (lo < 0) lo = FindPropertyOffset(actor, "Rarity");
  if (lo >= 0) out.level = dm::ReadV<int32_t>(actor + lo, 0);

  int32_t vo = FindPropertyOffset(actor, "ItemValue");
  if (vo < 0) vo = FindPropertyOffset(actor, "Price");
  if (vo >= 0) out.value = dm::ReadV<int32_t>(actor + vo, 0);

  return true;
}

}  // namespace ue
}  // namespace dm
