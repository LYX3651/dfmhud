// App.mm — 应用入口与生命周期
#import "App.h"
#import "Core.h"
#import "HUD.h"
#import "ESP.h"
#import "Mem.h"
#import "UE.h"
#import "Menu.h"

#include <algorithm>
#include <dlfcn.h>
#include <pthread.h>
#include <unistd.h>

using namespace dm;

// ============================================================
//  HUDMainApplication
//  覆盖 sendEvent，让 HUD 窗口不抢触摸
// ============================================================
@implementation HUDMainApplication

- (void)sendEvent:(UIEvent *)event {
  [super sendEvent:event];
}

@end

// ============================================================
//  后台采集线程
// ============================================================
namespace {

pthread_t g_collectThread;
volatile bool g_running = false;

void *CollectThreadMain(void *) {
  DMLOG("[worker] 采集线程启动");

  // 等 HUD 与目标都就绪
  usleep(500 * 1000);

  int failCount = 0;

  while (g_running) {
    @autoreleasepool {
      if (!Cfg().enabled) {
        usleep(200 * 1000);
        continue;
      }

      // 1) 确保后端就绪
      if (Available() == Backend::None) {
        if (!InitBackend()) {
          usleep(1000 * 1000);
          continue;
        }
      }

      // 2) 确保 attach 到目标
      if (!Attached()) {
        Proc target;
        for (size_t i = 0; i < TargetCount(); ++i) {
          target = FindProc(Targets()[i].execName);
          if (target) break;
        }
        if (!target) {
          // 目标没起来，安静等待
          usleep(800 * 1000);
          continue;
        }
        if (!Attach(target)) {
          DMLOG("[worker] attach 失败，1s 后重试");
          usleep(1000 * 1000);
          continue;
        }
        ue::Refresh();
      }

      // 3) UE 层初始化（只成功一次）
      if (!ue::Ready()) {
        if (!ue::Init()) {
          if (++failCount % 20 == 1) {
            DMLOG("[worker] UE 初始化未完成（第 %d 次）", failCount);
          }
          usleep(1000 * 1000);
          continue;
        }
        failCount = 0;
      }

      // 4) 采集一帧
      esp::Collect();

      // 按刷新率 sleep
      const int hz = std::max(15, std::min(120, Cfg().refreshHz));
      usleep((useconds_t)(1000000 / hz));
    }
  }

  DMLOG("[worker] 采集线程退出");
  return nullptr;
}

}  // namespace

// ============================================================
//  Delegate
// ============================================================
@implementation HUDMainApplicationDelegate

- (BOOL)application:(UIApplication *)app
    didFinishLaunchingWithOptions:(NSDictionary *)opts {
  LogInit();
  DMLOG("[app] didFinishLaunching");

  Cfg().Load();

  // 建一个空 window 占位（HUD 自己会另建浮层 window）
  self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
  self.window.rootViewController = [[UIViewController alloc] init];
  self.window.rootViewController.view.backgroundColor = [UIColor clearColor];
  self.window.backgroundColor = [UIColor clearColor];
  self.window.windowLevel = UIWindowLevelNormal;
  [self.window makeKeyAndVisible];

  // 启动 HUD
  HUD::Shared().Start(self.window);

  // 菜单
  Menu::Shared().Build();

  // 绘制回调：只画 ESP（菜单走 UIKit，不占 ImGui 输入）
  HUD::Shared().SetDrawCallback([]() {
    esp::RenderFrame();
  });

  // 起采集线程
  g_running = true;
  pthread_create(&g_collectThread, nullptr, CollectThreadMain, nullptr);

  // 预热：探测后端（不等 attach）
  InitBackend();
  DMLOG("[app] backend at launch = %s", BackendName(Available()));

  return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)app {
  DMLOG("[app] didBecomeActive");
}

- (void)applicationWillTerminate:(UIApplication *)app {
  DMLOG("[app] willTerminate");
  g_running = false;
  Cfg().Save();
  HUD::Shared().Stop();
}

@end

// ============================================================
//  main（TrollStore 下直接由系统拉起 app 本体）
// ============================================================
int main(int argc, char *argv[]) {
  @autoreleasepool {
    return UIApplicationMain(argc, argv,
                             NSStringFromClass([HUDMainApplication class]),
                             NSStringFromClass([HUDMainApplicationDelegate class]));
  }
}
