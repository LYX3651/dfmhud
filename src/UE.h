// UE.h — Unreal Engine 4/5 运行时反射层
// 设计原则：**不硬编码版本偏移**，全部靠运行时特征码定位 + 反射取值。
// 这样才能同时吃 iOS 14 – 17 的各版本客户端。
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "Mem.h"

namespace dm {
namespace ue {

// ---------- 基础结构 ----------
struct Vec2 { float x = 0, y = 0; };
struct Vec3 { float x = 0, y = 0, z = 0; };
struct Vec4 { float x = 0, y = 0, z = 0, w = 0; };

// 旋转（UE 的 FRotator：pitch/yaw/roll，单位度）
struct Rotator { float pitch = 0, yaw = 0, roll = 0; };

// 相机缓存
struct CameraPOV {
  Vec3 location;
  Rotator rotation;
  float fov = 90.f;
};

// 世界到屏幕的投影矩阵（行主序 4x4）
struct Matrix {
  float m[4][4] = {};
};

// ---------- 全局表 ----------
struct Tables {
  uint64_t gObjects = 0;    // TUObjectArray 地址
  uint64_t gNames = 0;      // FNamePool 地址
  uint64_t gWorld = 0;      // GWorld 指针所在地址（读一次得 UWorld*）
  uint64_t gEngine = 0;
  uint64_t gUWorldPtr = 0;  // GWorld 解引用后的值缓存

  // 运行时探测出来的偏移（不写死）
  int32_t offObjectsNum = 0;     // FUObjectArray + ObjectsNum
  int32_t offObjectsPtr = 0;     // FUObjectArray + Objects（chunk 指针数组）
  int32_t offNameEntry = 0;      // FNameEntry 内的字符串偏移
  int32_t offUWorldLevel = 0;    // UWorld -> PersistentLevel
  int32_t offActorRoot = 0;      // AActor -> RootComponent / RootComponentIndex
  int32_t offCompLocation = 0;   // USceneComponent -> RelativeLocation

  bool ready = false;
  std::string engineVersion;     // 从 ++UE4+Release-x.y 抓
  bool isUE5 = false;
};

Tables &T();

// ---------- 初始化 ----------
// 在目标进程已 Attach 后调用。返回是否定位成功。
bool Init();
void Refresh();      // 重连/换图后刷新 GWorld
bool Ready();

// ---------- 对象 ----------
// UObject* 基本操作
uint64_t UObjectClass(uint64_t obj);
uint64_t UObjectOuter(uint64_t obj);
std::string UObjectName(uint64_t obj);        // 完整路径名（Class Outer.Name）
std::string UObjectShortName(uint64_t obj);   // 只要 Name

// 通过 GObjects 按索引拿对象
uint64_t ObjectAt(int32_t index, int32_t *outNum = nullptr);

// 遍历所有对象，按类名过滤
std::vector<uint64_t> FindObjectsByClass(const char *className, size_t limit = 4096);

// 判断类名是否继承自某类（沿 SuperStruct 走）
bool IsA(uint64_t obj, const char *className);

// 属性读取（按名字找 UProperty 偏移，UE4/UE5 通用）
int32_t FindPropertyOffset(uint64_t obj, const char *propName);
uint64_t ReadUObjectProp(uint64_t obj, const char *propName);

// ---------- 世界 ----------
uint64_t GetWorld();                       // UWorld*
std::vector<uint64_t> GetActors();         // 关卡内全部 Actor
uint64_t GetLocalPlayerController();
uint64_t GetLocalPawn();

// ---------- 变换 ----------
bool GetActorLocation(uint64_t actor, Vec3 &out);
bool GetActorBounds(uint64_t actor, Vec3 &origin, Vec3 &extent);

// ---------- 相机 / 投影 ----------
bool GetCameraPOV(CameraPOV &out);
bool GetViewMatrix(Matrix &out);

// W2S：优先用相机自己算，绕过引擎函数
bool WorldToScreen(const Vec3 &world, Vec2 &screen, const CameraPOV &pov,
                   const Matrix &mtx, float screenW, float screenH);

// ---------- 骨骼 ----------
// 返回骨骼名 -> 世界坐标。needBones 为空则返回全部。
bool GetBoneLocation(uint64_t actor, const char *boneName, Vec3 &out);
std::vector<std::pair<std::string, Vec3>> GetKeyBones(uint64_t actor);

// ---------- 目标信息 ----------
struct PlayerInfo {
  uint64_t actor = 0;
  uint64_t playerState = 0;
  Vec3 location;
  Vec3 headPos;
  float distance = 0;
  float health = 0;
  float maxHealth = 100;
  bool isBot = false;
  bool isDown = false;
  bool isTeammate = false;
  int teamId = -1;
  std::string name;
  std::string weapon;
};

// 从 Actor 抽取玩家信息，失败返回 false
bool ExtractPlayer(uint64_t actor, const Vec3 &cameraLoc, PlayerInfo &out);

// ---------- 物资 ----------
struct LootInfo {
  uint64_t actor = 0;
  Vec3 location;
  float distance = 0;
  std::string name;
  std::string category;
  int level = 0;
  int value = 0;
};

bool ExtractLoot(uint64_t actor, const Vec3 &cameraLoc, LootInfo &out);

}  // namespace ue
}  // namespace dm
