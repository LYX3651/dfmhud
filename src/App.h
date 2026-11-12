// App.h — 应用入口：HUDMainApplication + Delegate
#pragma once

#import <UIKit/UIKit.h>

// 与派大星同构：Info.plist 的 NSPrincipalClass = HUDMainApplication
// 这样 app 启动后不会真的把主界面盖出来，只挂悬浮层。
@interface HUDMainApplication : UIApplication
@end

@interface HUDMainApplicationDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
