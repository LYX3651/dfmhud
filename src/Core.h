// Core.h — 共享类型、日志、配置
// 目标：iOS 14.0 – 17.x / arm64 / TrollStore
#pragma once

#import <Foundation/Foundation.h>
#include <cstdint>
#include <string>
#include <vector>

// ---------- 日志 ----------
// 落盘到 /var/mobile/Library/Caches/dfmhud.log（TrollStore 下可写）
// 也能 idevicesyslog 看到（NSLog）
namespace dm {

void LogInit();
void Log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

#define DMLOG(...) ::dm::Log(__VA_ARGS__)

}  // namespace dm

// ---------- 配置 ----------
// 与派大星同构：开关 + 滑条 + 颜色，落盘 plist
namespace dm {

struct Color {
  float r = 1.f, g = 1.f, b = 1.f, a = 1.f;
  Color() = default;
  Color(float R, float G, float B, float A = 1.f) : r(R), g(G), b(B), a(A) {}
};

struct Config {
  bool enabled = false;          // 总开关

  // --- ESP 开关 ---
  bool drawBox = true;           // 方框
  bool drawSkeleton = false;     // 骨骼
  bool drawName = true;          // 名字
  bool drawDistance = true;      // 距离
  bool drawHealth = true;        // 血量
  bool drawLine = false;         // 射线
  bool drawWeapon = false;       // 手持
  bool drawHeadArmor = false;    // 头甲
  bool drawTeam = false;         // 队伍标识
  bool drawBackEnemy = false;    // 背敌

  // --- 物资 ---
  bool drawLoot = false;         // 物资
  bool drawBoxLoot = false;      // 盒子
  bool lootName = true;          // 物资名字
  bool lootValue = false;        // 物资价值
  bool lootLevel = false;        // 物资等级

  // --- 过滤 ---
  bool hideBot = true;           // 人机隐藏
  bool hideDown = true;          // 倒地隐藏
  bool showTeamMate = true;      // 显示队友

  // --- 距离 ---
  float maxDistance = 400.f;     // 人物绘制距离（米）
  float lootDistance = 120.f;    // 物资距离
  float boxDistance = 150.f;     // 盒子距离

  // --- 样式 ---
  float boxThickness = 1.5f;
  float boneThickness = 1.2f;
  float infoFontSize = 12.f;
  float backEnemyRadius = 180.f; // 背敌半径（像素）

  // --- 颜色 ---
  Color colorPlayer;             // 敌人
  Color colorTeam;               // 队友
  Color colorSkeleton;           // 骨骼
  Color colorLootHigh;           // 高级物资
  Color colorLootLow;            // 低级物资
  Color colorHeadArmor;          // 头甲
  Color colorBackEnemy;          // 背敌

  // --- 刷新 ---
  int refreshHz = 60;            // 60 / 90 / 120
  bool liveMode = false;         // 过直播（secure mode）

  Config();
  void SetDefaults();
  void Load();
  void Save();
};

Config &Cfg();

}  // namespace dm

// ---------- 目标 ----------
namespace dm {

struct TargetApp {
  const char *bundleId;
  const char *execName;
  const char *display;
};

// 三服通用（与派大星 com.tencent.tmgp.dfm / pubgmhd / codev 同构）
const TargetApp *Targets();
size_t TargetCount();

}  // namespace dm
