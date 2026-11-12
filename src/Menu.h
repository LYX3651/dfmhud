// Menu.h — 菜单：UIKit 实现（交互可靠），ImGui 只负责 ESP 绘制层
#pragma once

#import <UIKit/UIKit.h>

namespace dm {

class Menu {
 public:
  static Menu &Shared();

  void Build();          // 懒加载面板
  void Toggle();         // 球 <-> 面板
  bool Visible() const;
  void Show();
  void Hide();

 private:
  Menu() = default;
};

}  // namespace dm

// 真正的面板控制器（Objective-C 侧）
// 这些方法在 Menu.mm 里实现，这里显式声明，避免 performSelector 的未声明警告。
@interface DFMMenuViewController : UIViewController
- (void)showPanel;
- (void)hidePanel;
- (void)onBallTap;
@end
