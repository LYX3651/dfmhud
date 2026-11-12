# DFMHUD — iOS 14–17 通用悬浮 HUD

TrollStore 安装的独立悬浮窗 App，跨进程读取 UE 引擎客户端并绘制 ESP。
**不使用注入、不需要越狱、不需要改游戏包。**

## 与派大星的区别

| 项 | 派大星.RS.R | 本项目 |
|---|---|---|
| 系统支持 | 14（实测 14/15/16/17） | **14.0 – 17.x，同一份二进制** |
| 内核原语 | kfd 写死 offset | kfd + 运行时反射，**偏移不硬编码** |
| 版本适配 | 每版重编 | **特征码 + 反射链，自适应** |
| UI | 自绘 UIKit | 自绘 UIKit（重写，不复用） |
| 代码 | TrollSpeed-1 商业混淆 | 全明文源码 |

## 架构

```
┌─────────────────────────────────────────────┐
│  DFMHUD.app（TrollStore 独立 App）           │
│                                             │
│  ┌─────────────┐   ┌──────────────────┐     │
│  │ MenuWindow  │   │  HUDWindow       │     │
│  │ UIKit 菜单  │   │  MTKView+ImGui   │     │
│  │ level +2000 │   │  level +1000     │     │
│  └─────────────┘   └──────────────────┘     │
│                                             │
│  ┌──────────────────────────────────────┐   │
│  │ 采集线程（pthread）                   │   │
│  │  Mem.mm  → task_for_pid / kfd        │   │
│  │  UE.cpp  → GObjects/GNames 反射      │   │
│  │  ESP.cpp → W2S + 筛选 + 绘制数据     │   │
│  └──────────────────────────────────────┘   │
└─────────────────────────────────────────────┘
              │ mach_vm_read_overwrite
              ▼
      ┌───────────────────┐
      │  com.tencent.tmgp │
      │  .dfm 游戏进程     │
      └───────────────────┘
```

关键点：**HUD 在独立进程里跑，只读游戏内存，不改游戏代码**。
所以不存在「注入检测」「完整性校验」这类问题——游戏里根本没有我们的代码。

## 为什么能跨 iOS 14–17

三层自适应，没有一层依赖固定版本号：

1. **内存层**：先试 `task_for_pid`（TrollStore entitlements 直接给），失败切 kfd 的三种 PUAF（landa / physpuppet / smith），哪档能过用哪档。
2. **反射层**：`GObjects` / `GNames` 用**特征码扫描**定位，拿到地址后用「能不能正确解出类名」反向验证 profile 对不对（`UE.cpp:Init()` 里那段 3/3 校验）。
3. **字段层**：属性偏移优先走 `FindPropertyOffset`（沿 UClass.Children 链找同名 UProperty），只有找不到才用候选常量兜底。

第 2、3 层是重点。派大星选择每版硬编码，所以一更新就失效；这里选择运行时自解。

## 目录

```
Makefile               theos 工程（application.mk）
entitlements.plist     23 项提权（TrollStore 下生效）
Resources/Info.plist   NSPrincipalClass = HUDMainApplication
build.sh               本地/CI 出包
.github/workflows/     GitHub Actions 自动出 tipa
src/
  App.mm               入口 + 采集线程
  Core.h/.mm           日志 / 配置 / 目标表
  Mem.h/.mm            跨进程内存 + 模块 + 特征码
  UE.h/.cpp            UE4/UE5 反射层
  HUD.h/.mm            Metal + ImGui 悬浮层
  ESP.h/.cpp           实体筛选 + W2S + 绘制
  Menu.h/.mm           UIKit 菜单
third_party_imgui/     ImGui 1.91.8（含 metal backend）
```

## 构建

本机（Windows）没有 iOS SDK，走 CI：

```bash
git add -A && git commit -m "init" && git push
# GitHub Actions → build-tipa → 下载 DFMHUD-tipa artifact
```

macOS 本地：

```bash
brew install ldid
git clone --recursive https://github.com/theos/theos.git ~/theos
export THEOS=~/theos
./build.sh
```

产物 `DFMHUD.tipa`，传设备用 TrollStore 打开安装。

## 首次运行会看到

1. App 启动，屏幕左侧出现蓝色圆形悬浮球「D」
2. 点球 → 弹出菜单，四个 Tab：战斗 / 物资 / 显示 / 系统
3. 「系统」Tab 里能看到实时状态：
   ```
   后端     task_for_pid
   目标 PID 12345
   UE 就绪  是
   引擎     ++UE4+Release-4.26
   GObjects 0x1040a8000
   GNames   0x1040b2000
   ```
4. 打开「启用绘制」，ESP 出图

## 排错

| 现象 | 原因 | 处理 |
|---|---|---|
| 球不出现 | HUD 启动失败 | 看 `dfmhud.log` 有无 "启动完成" |
| 后端 = none | entitlements 没生效 | 确认 ldid 用了 `-Sentitlements.plist` |
| 目标 PID = -1 | 游戏没开 / 进程名不对 | 改 `Core.mm` 的 `g_targets` |
| UE 就绪 = 否 | 特征码没命中 | 日志会打「GObjects 特征码全部未命中」，需按客户端补 |
| ESP 不出图 | 相机没拿到 | 看 `GetCameraPOV` 的候选偏移（`0x430`） |

## 已知限制（诚实说明）

- **特征码是通用 UE 模式，不是这个客户端的实测值**。三角洲 iOS 版的 `GObjects` 装载序列如果被改过（腾讯常改），`UE.cpp` 里三个 pattern 会全 miss，日志会明确报出来。这时需要按实际客户端补一条 pattern——用 IDA 打开主二进制搜 `GObjects` 引用即可。
- **骨骼绘制未实现**（`GetBoneLocation` 返回 false）。要真正出骨骼线，需要目标客户端的 `BoneArray` 偏移 + 骨骼索引表，这必须靠真机 dump，代码里已留好接口。
- **kfd 需要手动 clone**，CI 里 `continue-on-error` 所以不拉也能编过（只是没有内核后端）。
- **物资等级/价值**靠类名关键词猜（`LootLevelOf`），不是读游戏内真实数据。
- 未做反检测。派大星那套 `enableSecureMode`（过直播）这里只留了配置项没接实现。

## 下一步该做的

按优先级：

1. **补 GObjects 特征码** —— 用 IDA/Ghidra 打开游戏主二进制，找 `GObjects` 的访问点，把 ARM64 指令序列写成 pattern 加进 `UE.cpp` 的 `kGObjectsPatterns`。
2. **补属性偏移** —— 跑一次后看日志里哪些 `FindPropertyOffset` 返回 -1，把这些字段的候选偏移补进兜底值。
3. **骨骼** —— dump `USkeletalMeshComponent::BoneArray`，填 `GetBoneLocation`。
4. **过直播** —— 接 `CAFilter` 或 ReplayKit 层拦截。

前两项做完 ESP 就能稳定出图。
