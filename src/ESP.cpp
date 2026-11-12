// ESP.cpp — 实体收集 + 世界转屏幕 + 绘制
#include "ESP.h"
#include "HUD.h"
#include "Core.h"
#include "Mem.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <chrono>
#include <mutex>
#include <vector>

namespace dm {
namespace esp {

namespace {

Stats g_stats{};
std::mutex g_mtx;

// 缓存上一帧结果，避免 UI 线程和采集线程抢
std::vector<ue::PlayerInfo> g_players;
std::vector<ue::LootInfo> g_loot;
ue::CameraPOV g_pov{};
ue::Matrix g_matrix{};
bool g_haveCam = false;

// 缓存目标进程的模块与类名，避免每帧重扫
struct ClassCache {
  uint64_t playerStateClass = 0;
  uint64_t characterClass = 0;
  uint64_t lootClass = 0;
  bool built = false;
};
ClassCache g_classes;

inline float Dist2D(float x1, float y1, float x2, float y2) {
  const float dx = x2 - x1, dy = y2 - y1;
  return sqrtf(dx * dx + dy * dy);
}

// 判断一个 actor 是不是"人"
bool LooksLikePlayer(uint64_t actor) {
  if (!actor) return false;

  // 优先按类名层级判断：Character / Pawn / PlayerCharacter
  if (ue::IsA(actor, "Character")) return true;
  if (ue::IsA(actor, "Pawn")) return true;

  // 兜底：有 PlayerState 且能读到位置
  if (ue::ReadUObjectProp(actor, "PlayerState") != 0) return true;
  return false;
}

// 判断是不是可拾取物
bool LooksLikeLoot(uint64_t actor) {
  if (!actor) return false;
  const std::string cls = ue::UObjectShortName(actor);
  if (cls.empty()) return false;

  // 供拾取物通常是 BP_xxx_Pickup_C / xxx_Pickup_C
  if (cls.find("Pickup") != std::string::npos) return true;
  if (cls.find("AirDrop") != std::string::npos) return true;
  if (cls.find("InventoryBox") != std::string::npos) return true;
  if (cls.find("WeaponBox") != std::string::npos) return true;
  return false;
}

// 物资分级：按类名里能识别的关键词
int LootLevelOf(const std::string &cls) {
  static const struct { const char *kw; int lv; } kMap[] = {
      {"Helmet_Lv3", 3}, {"Armor_Lv3", 3}, {"Bag_Lv3", 3},
      {"MZJ_8X", 4}, {"MZJ_6X", 3}, {"MZJ_4X", 2}, {"MZJ_3X", 1},
      {"Ammo_50BMG", 3}, {"Ammo_300Magnum", 3},
      {"AirDropBox", 5}, {"AirDropPlane", 5},
      {"Sniper", 3}, {"AMR", 4}, {"M200", 3},
  };
  for (const auto &e : kMap) {
    if (cls.find(e.kw) != std::string::npos) return e.lv;
  }
  return 0;
}

}  // namespace

Stats &GetStats() { return g_stats; }

// ============================================================
//  采集
// ============================================================
void Collect() {
  auto t0 = std::chrono::steady_clock::now();

  g_stats = Stats{};
  if (!ue::Ready()) {
    // 尝试初始化一次
    if (!ue::Init()) return;
  }

  ue::CameraPOV pov;
  if (!ue::GetCameraPOV(pov)) return;
  g_pov = pov;
  g_haveCam = ue::GetViewMatrix(g_matrix);

  auto actors = ue::GetActors();
  g_stats.actors = (int)actors.size();
  if (actors.empty()) return;

  std::vector<ue::PlayerInfo> players;
  std::vector<ue::LootInfo> loot;
  players.reserve(64);
  loot.reserve(256);

  const Config &cfg = Cfg();
  const float maxDist = cfg.maxDistance;
  const float lootDist = cfg.lootDistance;
  const float boxDist = cfg.boxDistance;

  for (uint64_t a : actors) {
    if (!a) continue;

    if (LooksLikePlayer(a)) {
      ue::PlayerInfo pi;
      if (ue::ExtractPlayer(a, pov.location, pi)) {
        // 过滤
        if (pi.distance > maxDist) continue;
        if (cfg.hideBot && pi.isBot) continue;
        if (cfg.hideDown && pi.isDown) continue;
        players.push_back(std::move(pi));
      }
      continue;
    }

    if (cfg.drawLoot || cfg.drawBoxLoot) {
      if (LooksLikeLoot(a)) {
        ue::LootInfo li;
        if (ue::ExtractLoot(a, pov.location, li)) {
          const bool isBox = li.name.find("Box") != std::string::npos ||
                             li.name.find("InventoryBox") != std::string::npos;
          if (isBox && !cfg.drawBoxLoot) continue;
          if (!isBox && !cfg.drawLoot) continue;
          if (li.distance > (isBox ? boxDist : lootDist)) continue;
          li.level = LootLevelOf(li.name.empty() ? li.category : li.name);
          loot.push_back(std::move(li));
        }
      }
    }
  }

  // 按距离排序，近的优先（也便于截断）
  std::sort(players.begin(), players.end(),
            [](const ue::PlayerInfo &a, const ue::PlayerInfo &b) { return a.distance < b.distance; });
  std::sort(loot.begin(), loot.end(),
            [](const ue::LootInfo &a, const ue::LootInfo &b) { return a.distance < b.distance; });

  {
    std::lock_guard<std::mutex> lk(g_mtx);
    g_players = std::move(players);
    g_loot = std::move(loot);
  }

  g_stats.players = (int)g_players.size();
  g_stats.loot = (int)g_loot.size();

  auto t1 = std::chrono::steady_clock::now();
  g_stats.frameMs = std::chrono::duration<float, std::milli>(t1 - t0).count();
}

// ============================================================
//  绘制
// ============================================================
static void DrawPlayers() {
  const Config &cfg = Cfg();
  const float W = HUD::Shared().Width();
  const float H = HUD::Shared().Height();
  if (W < 2 || H < 2) return;

  const float cx = W * 0.5f;
  const float cy = H * 0.5f;

  for (const auto &p : g_players) {
    ue::Vec2 feet, head;
    if (!ue::WorldToScreen(p.location, feet, g_pov, g_matrix, W, H)) continue;
    if (!ue::WorldToScreen(p.headPos, head, g_pov, g_matrix, W, H)) continue;

    // 屏幕外剔除
    if (feet.x < -200 || feet.x > W + 200 || feet.y < -200 || feet.y > H + 200) continue;

    float h = feet.y - head.y;
    if (h < 6.f) {
      // 顶上还有半个头，用距离估个高度
      h = std::max(8.f, 800.f / std::max(p.distance, 1.f));
    }
    const float w = h * 0.48f;
    const float x = feet.x - w * 0.5f;
    const float y = head.y;

    const Color &cc = p.isTeammate ? cfg.colorTeam : cfg.colorPlayer;

    // 方框
    if (cfg.drawBox) {
      esp::DrawBox(x - 1, y - 1, w + 2, h + 2, cfg.boxThickness + 1.f,
                   Color(0, 0, 0, 0.85f));
      esp::DrawBox(x, y, w, h, cfg.boxThickness, cc);
    }

    // 血条（左侧）
    if (cfg.drawHealth && p.maxHealth > 0) {
      const float ratio = p.health / p.maxHealth;
      esp::DrawHealthBar(x - 6.f, y, 3.5f, h, ratio, Color(0.3f, 1.f, 0.3f));
    }

    // 名字
    if (cfg.drawName) {
      const char *nm = p.name.empty() ? (p.isBot ? "BOT" : "") : p.name.c_str();
      if (nm[0]) {
        ue::Vec2 sz = esp::MeasureText(cfg.infoFontSize, nm);
        esp::DrawText(feet.x - sz.x * 0.5f, y - sz.y - 3.f, cfg.infoFontSize, cc, "%s", nm);
      }
    }

    // 距离
    if (cfg.drawDistance) {
      char buf[32];
      snprintf(buf, sizeof(buf), "%dm", (int)p.distance);
      ue::Vec2 sz = esp::MeasureText(cfg.infoFontSize - 1.f, buf);
      esp::DrawText(feet.x - sz.x * 0.5f, feet.y + 2.f, cfg.infoFontSize - 1.f, cc, "%s", buf);
    }

    // 手持武器
    if (cfg.drawWeapon && !p.weapon.empty()) {
      ue::Vec2 sz = esp::MeasureText(cfg.infoFontSize - 1.f, p.weapon.c_str());
      esp::DrawText(feet.x - sz.x * 0.5f, feet.y + cfg.infoFontSize + 3.f,
                    cfg.infoFontSize - 1.f, Color(0.9f, 0.9f, 0.5f), "%s", p.weapon.c_str());
    }

    // 射线
    if (cfg.drawLine) {
      esp::DrawLine(cx, 2.f, feet.x, feet.y, 1.0f, cc);
    }

    // 背敌指示（画面外但靠近身后）
    if (cfg.drawBackEnemy) {
      const bool onScreen = (feet.x >= 0 && feet.x <= W && feet.y >= 0 && feet.y <= H);
      if (!onScreen) {
        const float ang = atan2f(feet.y - cy, feet.x - cx);
        const float r = cfg.backEnemyRadius;
        const float bx = cx + cosf(ang) * r;
        const float by = cy + sinf(ang) * r;
        esp::DrawFilledRect(bx - 4, by - 4, 8, 8, cfg.colorBackEnemy);
      }
    }

    ++g_stats.drawn;
  }
}

static void DrawLoot() {
  const Config &cfg = Cfg();
  const float W = HUD::Shared().Width();
  const float H = HUD::Shared().Height();
  if (W < 2 || H < 2) return;

  for (const auto &l : g_loot) {
    ue::Vec2 s;
    if (!ue::WorldToScreen(l.location, s, g_pov, g_matrix, W, H)) continue;
    if (s.x < 0 || s.x > W || s.y < 0 || s.y > H) continue;

    const bool high = l.level >= 3;
    const Color &c = high ? cfg.colorLootHigh : cfg.colorLootLow;

    // 小方块标记
    esp::DrawFilledRect(s.x - 2.5f, s.y - 2.5f, 5.f, 5.f, c);

    if (cfg.lootName && !l.name.empty()) {
      esp::DrawText(s.x + 6.f, s.y - 6.f, cfg.infoFontSize - 2.f, c, "%s", l.name.c_str());
    }
    if (cfg.lootValue && l.value > 0) {
      esp::DrawText(s.x + 6.f, s.y + 8.f, cfg.infoFontSize - 2.f,
                    Color(1.f, 0.85f, 0.2f), "$%d", l.value);
    }
    if (cfg.lootLevel && l.level > 0) {
      esp::DrawText(s.x + 6.f, s.y + 22.f, cfg.infoFontSize - 2.f,
                    Color(0.7f, 1.f, 0.7f), "Lv%d", l.level);
    }
    if (cfg.drawDistance) {
      esp::DrawText(s.x + 6.f, s.y + 36.f, cfg.infoFontSize - 3.f,
                    Color(0.8f, 0.8f, 0.8f), "%dm", (int)l.distance);
    }
  }
}

static void DrawStatus() {
  const float W = HUD::Shared().Width();
  const Config &cfg = Cfg();
  const Stats &s = g_stats;

  esp::DrawText(12.f, 40.f, 13.f, Color(0.6f, 1.f, 0.6f),
                "Actor %d | Player %d | Loot %d | %.2fms",
                s.actors, s.players, s.loot, s.frameMs);
  esp::DrawText(12.f, 58.f, 12.f, Color(0.5f, 0.7f, 1.f),
                "Backend: %s  PID: %d",
                BackendName(Available()), TargetPid());
  (void)W;
  (void)cfg;
}

void RenderFrame() {
  const Config &cfg = Cfg();
  if (!cfg.enabled) return;

  std::lock_guard<std::mutex> lk(g_mtx);
  if (!g_haveCam) return;

  DrawLoot();
  DrawPlayers();
  DrawStatus();
}

}  // namespace esp
}  // namespace dm
