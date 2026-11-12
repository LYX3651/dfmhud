#include "Core.h"

#import <UIKit/UIKit.h>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <unistd.h>

namespace dm {

// ======================= 日志 =======================
static std::mutex g_logMutex;
static FILE *g_logFile = nullptr;
static char g_logPath[512] = {0};

void LogInit() {
  // TrollStore 下沙盒被 no-sandbox 放开，优先写这个公共路径，
  // Filza 直接能拿到。失败则退回 app 自己的 Library/Caches。
  const char *candidates[] = {
      "/var/mobile/Library/Caches/dfmhud.log",
      nullptr,
  };

  for (int i = 0; candidates[i]; ++i) {
    FILE *f = fopen(candidates[i], "a+");
    if (f) {
      g_logFile = f;
      snprintf(g_logPath, sizeof(g_logPath), "%s", candidates[i]);
      break;
    }
  }

  if (!g_logFile) {
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    NSString *p = [dir stringByAppendingPathComponent:@"dfmhud.log"];
    snprintf(g_logPath, sizeof(g_logPath), "%s", p.UTF8String);
    g_logFile = fopen(g_logPath, "a+");
  }

  Log("===== DFMHUD start pid=%d uid=%d =====", getpid(), getuid());
}

void Log(const char *fmt, ...) {
  char body[2048];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(body, sizeof(body), fmt, ap);
  va_end(ap);

  // 控制台（idevicesyslog 可见）
  NSLog(@"[DFMHUD] %s", body);

  std::lock_guard<std::mutex> lk(g_logMutex);
  if (g_logFile) {
    fprintf(g_logFile, "%s\n", body);
    fflush(g_logFile);
  }
}

// ======================= 配置 =======================
static Config g_cfg;

Config::Config() { SetDefaults(); }

void Config::SetDefaults() {
  enabled = false;

  drawBox = true;
  drawSkeleton = false;
  drawName = true;
  drawDistance = true;
  drawHealth = true;
  drawLine = false;
  drawWeapon = false;
  drawHeadArmor = false;
  drawTeam = false;
  drawBackEnemy = false;

  drawLoot = false;
  drawBoxLoot = false;
  lootName = true;
  lootValue = false;
  lootLevel = false;

  hideBot = true;
  hideDown = true;
  showTeamMate = true;

  maxDistance = 400.f;
  lootDistance = 120.f;
  boxDistance = 150.f;

  boxThickness = 1.5f;
  boneThickness = 1.2f;
  infoFontSize = 12.f;
  backEnemyRadius = 180.f;

  colorPlayer    = Color(1.00f, 0.25f, 0.25f);  // 红
  colorTeam      = Color(0.30f, 0.85f, 1.00f);  // 青
  colorSkeleton  = Color(0.95f, 0.95f, 0.95f);  // 白
  colorLootHigh  = Color(1.00f, 0.72f, 0.15f);  // 金
  colorLootLow   = Color(0.75f, 0.75f, 0.75f);
  colorHeadArmor = Color(0.55f, 0.35f, 1.00f);  // 紫
  colorBackEnemy = Color(1.00f, 0.45f, 0.10f);  // 橙

  refreshHz = 60;
  liveMode = false;
}

static NSString *CfgPath() {
  NSString *dir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
  return [dir stringByAppendingPathComponent:@"dfmhud.cfg.plist"];
}

void Config::Save() {
  NSDictionary *d = @{
    @"enabled":       @(enabled),
    @"drawBox":       @(drawBox),
    @"drawSkeleton":  @(drawSkeleton),
    @"drawName":      @(drawName),
    @"drawDistance":  @(drawDistance),
    @"drawHealth":    @(drawHealth),
    @"drawLine":      @(drawLine),
    @"drawWeapon":    @(drawWeapon),
    @"drawHeadArmor": @(drawHeadArmor),
    @"drawTeam":      @(drawTeam),
    @"drawBackEnemy": @(drawBackEnemy),
    @"drawLoot":      @(drawLoot),
    @"drawBoxLoot":   @(drawBoxLoot),
    @"lootName":      @(lootName),
    @"lootValue":     @(lootValue),
    @"lootLevel":     @(lootLevel),
    @"hideBot":       @(hideBot),
    @"hideDown":      @(hideDown),
    @"showTeamMate":  @(showTeamMate),
    @"maxDistance":   @(maxDistance),
    @"lootDistance":  @(lootDistance),
    @"boxDistance":   @(boxDistance),
    @"boxThickness":  @(boxThickness),
    @"boneThickness": @(boneThickness),
    @"infoFontSize":  @(infoFontSize),
    @"backEnemyRadius": @(backEnemyRadius),
    @"refreshHz":     @(refreshHz),
    @"liveMode":      @(liveMode),
    @"c_player": @[@(colorPlayer.r), @(colorPlayer.g), @(colorPlayer.b)],
    @"c_team":   @[@(colorTeam.r), @(colorTeam.g), @(colorTeam.b)],
    @"c_bone":   @[@(colorSkeleton.r), @(colorSkeleton.g), @(colorSkeleton.b)],
    @"c_lootHi": @[@(colorLootHigh.r), @(colorLootHigh.g), @(colorLootHigh.b)],
    @"c_lootLo": @[@(colorLootLow.r), @(colorLootLow.g), @(colorLootLow.b)],
    @"c_head":   @[@(colorHeadArmor.r), @(colorHeadArmor.g), @(colorHeadArmor.b)],
    @"c_back":   @[@(colorBackEnemy.r), @(colorBackEnemy.g), @(colorBackEnemy.b)],
  };
  [d writeToFile:CfgPath() atomically:YES];
}

void Config::Load() {
  NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:CfgPath()];
  if (!d) return;

#define RD(k, f) if (d[@#k]) f = [d[@#k] boolValue]
#define RF(k, f) if (d[@#k]) f = [d[@#k] floatValue]
#define RI(k, f) if (d[@#k]) f = [d[@#k] intValue]
  RD(enabled, enabled);
  RD(drawBox, drawBox); RD(drawSkeleton, drawSkeleton); RD(drawName, drawName);
  RD(drawDistance, drawDistance); RD(drawHealth, drawHealth); RD(drawLine, drawLine);
  RD(drawWeapon, drawWeapon); RD(drawHeadArmor, drawHeadArmor);
  RD(drawTeam, drawTeam); RD(drawBackEnemy, drawBackEnemy);
  RD(drawLoot, drawLoot); RD(drawBoxLoot, drawBoxLoot);
  RD(lootName, lootName); RD(lootValue, lootValue); RD(lootLevel, lootLevel);
  RD(hideBot, hideBot); RD(hideDown, hideDown); RD(showTeamMate, showTeamMate);
  RF(maxDistance, maxDistance); RF(lootDistance, lootDistance); RF(boxDistance, boxDistance);
  RF(boxThickness, boxThickness); RF(boneThickness, boneThickness);
  RF(infoFontSize, infoFontSize); RF(backEnemyRadius, backEnemyRadius);
  RI(refreshHz, refreshHz);
  RD(liveMode, liveMode);

  auto rd3 = ^(NSString *k, Color &c) {
    NSArray *a = d[k];
    if (a.count == 3) { c.r = [a[0] floatValue]; c.g = [a[1] floatValue]; c.b = [a[2] floatValue]; }
  };
  rd3(@"c_player", colorPlayer);
  rd3(@"c_team",   colorTeam);
  rd3(@"c_bone",   colorSkeleton);
  rd3(@"c_lootHi", colorLootHigh);
  rd3(@"c_lootLo", colorLootLow);
  rd3(@"c_head",   colorHeadArmor);
  rd3(@"c_back",   colorBackEnemy);
#undef RD
#undef RF
#undef RI
}

Config &Cfg() { return g_cfg; }

// ======================= 目标 =======================
static const TargetApp g_targets[] = {
    {"com.tencent.tmgp.dfm",      "DeltaForceClient", "三角洲行动（国服）"},
    {"com.tencent.tmgp.pubgmhd",  "ShadowTrackerExtra", "和平精英"},
    {"com.tencent.tmgp.codev",    "CODM",             "使命召唤手游"},
};

const TargetApp *Targets() { return g_targets; }
size_t TargetCount() { return sizeof(g_targets) / sizeof(g_targets[0]); }

}  // namespace dm
