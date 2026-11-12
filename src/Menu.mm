// Menu.mm — UIKit 自绘菜单面板 + 悬浮球
// 不复用派大星任何 UI 代码，结构自建。
#import "Menu.h"
#import "Core.h"
#import "HUD.h"
#import "Mem.h"
#import "UE.h"
#import "Probe.h"

#include <cmath>
#include <string>
#include <vector>

using namespace dm;

// ============================================================
//  主题色
// ============================================================
static UIColor *kAccent()  { return [UIColor colorWithRed:0.24 green:0.62 blue:1.00 alpha:1]; }
static UIColor *kBg()      { return [UIColor colorWithRed:0.07 green:0.08 blue:0.10 alpha:0.97]; }
static UIColor *kCard()    { return [UIColor colorWithRed:0.12 green:0.13 blue:0.16 alpha:1]; }
static UIColor *kText()    { return [UIColor colorWithWhite:0.93 alpha:1]; }
static UIColor *kSub()     { return [UIColor colorWithWhite:0.55 alpha:1]; }

// ============================================================
//  通用控件
// ============================================================
@interface DFMSwitchRow : UIView
@property(nonatomic, copy) NSString *title;
@property(nonatomic, assign) BOOL on;
@property(nonatomic, copy) void (^onChange)(BOOL);
- (instancetype)initWithTitle:(NSString *)t on:(BOOL)on changed:(void (^)(BOOL))cb;
@end

@implementation DFMSwitchRow {
  UILabel *_lab;
  UISwitch *_sw;
}

- (instancetype)initWithTitle:(NSString *)t on:(BOOL)on changed:(void (^)(BOOL))cb {
  self = [super initWithFrame:CGRectMake(0, 0, 320, 44)];
  if (!self) return nil;
  self.title = t;
  self.on = on;
  self.onChange = cb;

  _lab = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, 220, 44)];
  _lab.text = t;
  _lab.textColor = kText();
  _lab.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
  [self addSubview:_lab];

  _sw = [[UISwitch alloc] initWithFrame:CGRectMake(320 - 60, 6, 51, 31)];
  _sw.on = on;
  _sw.onTintColor = kAccent();
  _sw.transform = CGAffineTransformMakeScale(0.85, 0.85);
  [_sw addTarget:self action:@selector(onSwitch) forControlEvents:UIControlEventValueChanged];
  [self addSubview:_sw];

  self.backgroundColor = kCard();
  self.layer.cornerRadius = 8;
  return self;
}

- (void)onSwitch {
  self.on = _sw.on;
  if (self.onChange) self.onChange(_sw.on);
}

@end

// ------------------------------------------------------------
@interface DFMSliderRow : UIView
- (instancetype)initWithTitle:(NSString *)t
                          min:(float)mn
                          max:(float)mx
                        value:(float)v
                      changed:(void (^)(float))cb;
@end

@implementation DFMSliderRow {
  UILabel *_lab, *_val;
  UISlider *_sl;
  void (^_cb)(float);
  NSString *_fmt;
}

- (instancetype)initWithTitle:(NSString *)t
                          min:(float)mn max:(float)mx value:(float)v
                      changed:(void (^)(float))cb {
  self = [super initWithFrame:CGRectMake(0, 0, 320, 62)];
  if (!self) return nil;
  _cb = [cb copy];

  _lab = [[UILabel alloc] initWithFrame:CGRectMake(12, 6, 200, 20)];
  _lab.text = t;
  _lab.textColor = kText();
  _lab.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
  [self addSubview:_lab];

  _val = [[UILabel alloc] initWithFrame:CGRectMake(320 - 80, 6, 68, 20)];
  _val.textColor = kAccent();
  _val.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightSemibold];
  _val.textAlignment = NSTextAlignmentRight;
  [self addSubview:_val];

  _sl = [[UISlider alloc] initWithFrame:CGRectMake(12, 28, 320 - 24, 28)];
  _sl.minimumValue = mn;
  _sl.maximumValue = mx;
  _sl.value = v;
  _sl.minimumTrackTintColor = kAccent();
  [_sl addTarget:self action:@selector(onSlide) forControlEvents:UIControlEventValueChanged];
  [self addSubview:_sl];

  [self updateVal:v];

  self.backgroundColor = kCard();
  self.layer.cornerRadius = 8;
  return self;
}

- (void)updateVal:(float)v {
  if (_sl.maximumValue - _sl.minimumValue > 50)
    _val.text = [NSString stringWithFormat:@"%.0f", v];
  else
    _val.text = [NSString stringWithFormat:@"%.1f", v];
}

- (void)onSlide {
  [self updateVal:_sl.value];
  if (_cb) _cb(_sl.value);
}

@end

// ------------------------------------------------------------
@interface DFMTabButton : UIButton
@end
@implementation DFMTabButton
@end

// ============================================================
//  菜单主面板
// ============================================================
@implementation DFMMenuViewController {
  UIView *_panel;
  UIScrollView *_scroll;
  NSMutableArray<UIView *> *_pages;
  NSArray<NSString *> *_tabNames;
  NSMutableArray<DFMTabButton *> *_tabButtons;
  int _curTab;

  // 悬浮球
  UIButton *_ball;
  CGPoint _ballCenter;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = [UIColor clearColor];

  _curTab = 0;
  _tabNames = @[@"战斗", @"物资", @"显示", @"系统"];
  _tabButtons = [NSMutableArray array];
  _pages = [NSMutableArray array];

  [self buildPanel];
  [self buildTabs];
  [self buildPages];
  [self buildBall];
  [self switchTab:0];

  _panel.hidden = YES;
}

// ---------- 面板容器 ----------
- (void)buildPanel {
  // 竖屏下用屏幕宽度的 78%，最多 360
  CGRect sb = [UIScreen mainScreen].bounds;
  const CGFloat pw = MIN(360, sb.size.width * 0.80);
  const CGFloat ph = MIN(520, sb.size.height * 0.62);

  _panel = [[UIView alloc] initWithFrame:CGRectMake((sb.size.width - pw) / 2,
                                                   (sb.size.height - ph) / 2 - 40,
                                                   pw, ph)];
  _panel.backgroundColor = kBg();
  _panel.layer.cornerRadius = 16;
  _panel.layer.masksToBounds = NO;
  _panel.layer.borderWidth = 1;
  _panel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.08].CGColor;
  _panel.layer.shadowColor = [UIColor blackColor].CGColor;
  _panel.layer.shadowOpacity = 0.5;
  _panel.layer.shadowRadius = 18;
  [self.view addSubview:_panel];

  // 标题
  UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 10, pw - 80, 26)];
  title.text = @"DFMHUD";
  title.textColor = kText();
  title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
  [_panel addSubview:title];

  UILabel *ver = [[UILabel alloc] initWithFrame:CGRectMake(16, 32, pw - 80, 16)];
  ver.text = @"iOS 14 – 17 · TrollStore";
  ver.textColor = kSub();
  ver.font = [UIFont systemFontOfSize:10];
  [_panel addSubview:ver];

  // 关闭按钮
  UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
  close.frame = CGRectMake(pw - 44, 12, 32, 32);
  [close setTitle:@"✕" forState:UIControlStateNormal];
  [close setTitleColor:kSub() forState:UIControlStateNormal];
  close.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightMedium];
  [close addTarget:self action:@selector(hidePanel) forControlEvents:UIControlEventTouchUpInside];
  [_panel addSubview:close];

  // 滚动区
  _scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 96, pw, ph - 96)];
  _scroll.showsVerticalScrollIndicator = YES;
  _scroll.contentInset = UIEdgeInsetsMake(6, 12, 18, 12);
  [_panel addSubview:_scroll];

  // 拖动手势
  UIPanGestureRecognizer *pan =
      [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
  [_panel addGestureRecognizer:pan];
}

- (void)onPan:(UIPanGestureRecognizer *)g {
  CGPoint t = [g translationInView:self.view];
  _panel.center = CGPointMake(_panel.center.x + t.x, _panel.center.y + t.y);
  [g setTranslation:CGPointZero inView:self.view];
}

// ---------- Tab ----------
- (void)buildTabs {
  const CGFloat pw = _panel.bounds.size.width;
  const CGFloat w = (pw - 24) / _tabNames.count;
  for (NSUInteger i = 0; i < _tabNames.count; ++i) {
    DFMTabButton *b = [DFMTabButton buttonWithType:UIButtonTypeSystem];
    b.frame = CGRectMake(12 + w * i, 56, w, 34);
    [b setTitle:_tabNames[i] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    b.tag = (NSInteger)i;
    b.layer.cornerRadius = 8;
    [b addTarget:self action:@selector(onTab:) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:b];
    [_tabButtons addObject:b];
  }
}

- (void)onTab:(DFMTabButton *)b { [self switchTab:(int)b.tag]; }

- (void)switchTab:(int)i {
  _curTab = i;
  for (NSUInteger k = 0; k < _tabButtons.count; ++k) {
    DFMTabButton *b = _tabButtons[k];
    const BOOL sel = ((int)k == i);
    b.backgroundColor = sel ? kAccent() : kCard();
    [b setTitleColor:sel ? [UIColor whiteColor] : kSub() forState:UIControlStateNormal];
  }
  for (NSUInteger k = 0; k < _pages.count; ++k) {
    _pages[k].hidden = ((int)k != i);
  }
  _scroll.contentOffset = CGPointZero;
}

// ---------- 页面 ----------
- (void)buildPages {
  for (NSUInteger i = 0; i < _tabNames.count; ++i) {
    UIView *page = [[UIView alloc] initWithFrame:_scroll.bounds];
    page.backgroundColor = [UIColor clearColor];
    [self populatePage:page index:(int)i];
    [_scroll addSubview:page];
    [_pages addObject:page];
    page.hidden = YES;
  }
  [self layoutPages];
}

- (void)layoutPages {
  const CGFloat w = _scroll.bounds.size.width;
  CGFloat maxH = 0;
  for (UIView *p in _pages) {
    CGFloat y = 0;
    for (UIView *v in p.subviews) {
      if ([v isKindOfClass:[UILabel class]] && v.tag != 9001) {
        v.frame = CGRectMake(0, y, w, 40);
        y += 40;
        continue;
      }
      if ([v isKindOfClass:[UILabel class]]) {
        v.frame = CGRectMake(4, y + 8, w, 22);
        y += 38;
        continue;
      }
      v.frame = CGRectMake(0, y, w, v.frame.size.height ?: 44);
      y += v.frame.size.height + 8;
    }
    maxH = MAX(maxH, y);
    p.frame = CGRectMake(0, 0, w, y);
  }
  _scroll.contentSize = CGSizeMake(w, maxH);
}

- (UILabel *)sectionLabel:(NSString *)t {
  UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
  l.text = t;
  l.textColor = kSub();
  l.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
  l.tag = 9001;
  return l;
}

- (void)addSwitch:(UIView *)page title:(NSString *)t key:(NSString *)key {
  Config &c = Cfg();
  BOOL cur = NO;
  if ([key isEqualToString:@"enabled"])          cur = c.enabled;
  else if ([key isEqualToString:@"drawBox"])     cur = c.drawBox;
  else if ([key isEqualToString:@"drawSkeleton"]) cur = c.drawSkeleton;
  else if ([key isEqualToString:@"drawName"])    cur = c.drawName;
  else if ([key isEqualToString:@"drawDistance"]) cur = c.drawDistance;
  else if ([key isEqualToString:@"drawHealth"])  cur = c.drawHealth;
  else if ([key isEqualToString:@"drawLine"])    cur = c.drawLine;
  else if ([key isEqualToString:@"drawWeapon"])  cur = c.drawWeapon;
  else if ([key isEqualToString:@"drawHeadArmor"]) cur = c.drawHeadArmor;
  else if ([key isEqualToString:@"drawTeam"])    cur = c.drawTeam;
  else if ([key isEqualToString:@"drawBackEnemy"]) cur = c.drawBackEnemy;
  else if ([key isEqualToString:@"drawLoot"])    cur = c.drawLoot;
  else if ([key isEqualToString:@"drawBoxLoot"]) cur = c.drawBoxLoot;
  else if ([key isEqualToString:@"lootName"])    cur = c.lootName;
  else if ([key isEqualToString:@"lootValue"])   cur = c.lootValue;
  else if ([key isEqualToString:@"lootLevel"])   cur = c.lootLevel;
  else if ([key isEqualToString:@"hideBot"])     cur = c.hideBot;
  else if ([key isEqualToString:@"hideDown"])    cur = c.hideDown;
  else if ([key isEqualToString:@"showTeamMate"]) cur = c.showTeamMate;
  else if ([key isEqualToString:@"liveMode"])    cur = c.liveMode;

  DFMSwitchRow *row = [[DFMSwitchRow alloc] initWithTitle:t on:cur changed:^(BOOL on) {
    Config &cc = Cfg();
    if ([key isEqualToString:@"enabled"])           cc.enabled = on;
    else if ([key isEqualToString:@"drawBox"])      cc.drawBox = on;
    else if ([key isEqualToString:@"drawSkeleton"]) cc.drawSkeleton = on;
    else if ([key isEqualToString:@"drawName"])     cc.drawName = on;
    else if ([key isEqualToString:@"drawDistance"]) cc.drawDistance = on;
    else if ([key isEqualToString:@"drawHealth"])   cc.drawHealth = on;
    else if ([key isEqualToString:@"drawLine"])     cc.drawLine = on;
    else if ([key isEqualToString:@"drawWeapon"])   cc.drawWeapon = on;
    else if ([key isEqualToString:@"drawHeadArmor"]) cc.drawHeadArmor = on;
    else if ([key isEqualToString:@"drawTeam"])     cc.drawTeam = on;
    else if ([key isEqualToString:@"drawBackEnemy"]) cc.drawBackEnemy = on;
    else if ([key isEqualToString:@"drawLoot"])     cc.drawLoot = on;
    else if ([key isEqualToString:@"drawBoxLoot"])  cc.drawBoxLoot = on;
    else if ([key isEqualToString:@"lootName"])     cc.lootName = on;
    else if ([key isEqualToString:@"lootValue"])    cc.lootValue = on;
    else if ([key isEqualToString:@"lootLevel"])    cc.lootLevel = on;
    else if ([key isEqualToString:@"hideBot"])      cc.hideBot = on;
    else if ([key isEqualToString:@"hideDown"])     cc.hideDown = on;
    else if ([key isEqualToString:@"showTeamMate"]) cc.showTeamMate = on;
    else if ([key isEqualToString:@"liveMode"])     cc.liveMode = on;
    cc.Save();
  }];
  row.frame = CGRectMake(0, 0, _scroll.bounds.size.width, 44);
  [page addSubview:row];
}

- (void)addSlider:(UIView *)page title:(NSString *)t min:(float)mn max:(float)mx
            value:(float)v changed:(void (^)(float))cb {
  DFMSliderRow *row = [[DFMSliderRow alloc] initWithTitle:t min:mn max:mx value:v changed:^(float nv) {
    cb(nv);
    Cfg().Save();
  }];
  row.frame = CGRectMake(0, 0, _scroll.bounds.size.width, 62);
  [page addSubview:row];
}

- (void)populatePage:(UIView *)page index:(int)i {
  Config &c = Cfg();

  if (i == 0) {  // 战斗
    [page addSubview:[self sectionLabel:@"总开关"]];
    [self addSwitch:page title:@"启用绘制" key:@"enabled"];

    [page addSubview:[self sectionLabel:@"ESP"]];
    [self addSwitch:page title:@"方框" key:@"drawBox"];
    [self addSwitch:page title:@"骨骼" key:@"drawSkeleton"];
    [self addSwitch:page title:@"名字" key:@"drawName"];
    [self addSwitch:page title:@"距离" key:@"drawDistance"];
    [self addSwitch:page title:@"血量" key:@"drawHealth"];
    [self addSwitch:page title:@"射线" key:@"drawLine"];
    [self addSwitch:page title:@"手持武器" key:@"drawWeapon"];
    [self addSwitch:page title:@"头甲" key:@"drawHeadArmor"];
    [self addSwitch:page title:@"队伍标识" key:@"drawTeam"];
    [self addSwitch:page title:@"背敌提示" key:@"drawBackEnemy"];

    [page addSubview:[self sectionLabel:@"过滤"]];
    [self addSwitch:page title:@"隐藏人机" key:@"hideBot"];
    [self addSwitch:page title:@"隐藏倒地" key:@"hideDown"];
    [self addSwitch:page title:@"显示队友" key:@"showTeamMate"];

    [page addSubview:[self sectionLabel:@"距离"]];
    [self addSlider:page title:@"人物绘制距离" min:50 max:800 value:c.maxDistance
            changed:^(float v) { Cfg().maxDistance = v; }];
    [self addSlider:page title:@"背敌半径" min:60 max:400 value:c.backEnemyRadius
            changed:^(float v) { Cfg().backEnemyRadius = v; }];

  } else if (i == 1) {  // 物资
    [page addSubview:[self sectionLabel:@"物资"]];
    [self addSwitch:page title:@"物资绘制" key:@"drawLoot"];
    [self addSwitch:page title:@"盒子绘制" key:@"drawBoxLoot"];
    [self addSwitch:page title:@"物资名字" key:@"lootName"];
    [self addSwitch:page title:@"物资价值" key:@"lootValue"];
    [self addSwitch:page title:@"物资等级" key:@"lootLevel"];

    [page addSubview:[self sectionLabel:@"距离"]];
    [self addSlider:page title:@"物资绘制距离" min:20 max:400 value:c.lootDistance
            changed:^(float v) { Cfg().lootDistance = v; }];
    [self addSlider:page title:@"盒子绘制距离" min:20 max:400 value:c.boxDistance
            changed:^(float v) { Cfg().boxDistance = v; }];

  } else if (i == 2) {  // 显示
    [page addSubview:[self sectionLabel:@"样式"]];
    [self addSlider:page title:@"方框粗细" min:0.5f max:4.f value:c.boxThickness
            changed:^(float v) { Cfg().boxThickness = v; }];
    [self addSlider:page title:@"骨骼粗细" min:0.5f max:4.f value:c.boneThickness
            changed:^(float v) { Cfg().boneThickness = v; }];
    [self addSlider:page title:@"信息字体" min:8.f max:24.f value:c.infoFontSize
            changed:^(float v) { Cfg().infoFontSize = v; }];

    [page addSubview:[self sectionLabel:@"刷新"]];
    [self addSlider:page title:@"刷新频率 (Hz)" min:30 max:120 value:(float)c.refreshHz
            changed:^(float v) { Cfg().refreshHz = (int)v; }];

  } else {  // 系统
    [page addSubview:[self sectionLabel:@"运行状态"]];

    UILabel *st = [[UILabel alloc] initWithFrame:CGRectZero];
    st.numberOfLines = 0;
    st.textColor = kText();
    st.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    st.text = [self statusText];
    [page addSubview:st];

    [page addSubview:[self sectionLabel:@"诊断"]];

    UIButton *probe = [UIButton buttonWithType:UIButtonTypeSystem];
    [probe setTitle:@"跑全链路自检" forState:UIControlStateNormal];
    probe.backgroundColor = kCard();
    probe.layer.cornerRadius = 8;
    probe.frame = CGRectMake(0, 0, _scroll.bounds.size.width, 44);
    [probe addTarget:self action:@selector(onProbe) forControlEvents:UIControlEventTouchUpInside];
    [page addSubview:probe];

    [page addSubview:[self sectionLabel:@"过直播"]];
    [self addSwitch:page title:@"直播模式（隐藏绘制）" key:@"liveMode"];

    [page addSubview:[self sectionLabel:@"操作"]];

    UIButton *ref = [UIButton buttonWithType:UIButtonTypeSystem];
    [ref setTitle:@"重新连接目标" forState:UIControlStateNormal];
    ref.backgroundColor = kCard();
    ref.layer.cornerRadius = 8;
    ref.frame = CGRectMake(0, 0, _scroll.bounds.size.width, 44);
    [ref addTarget:self action:@selector(onReconnect) forControlEvents:UIControlEventTouchUpInside];
    [page addSubview:ref];

    UIButton *reset = [UIButton buttonWithType:UIButtonTypeSystem];
    [reset setTitle:@"恢复默认设置" forState:UIControlStateNormal];
    reset.backgroundColor = kCard();
    reset.layer.cornerRadius = 8;
    reset.frame = CGRectMake(0, 0, _scroll.bounds.size.width, 44);
    [reset addTarget:self action:@selector(onReset) forControlEvents:UIControlEventTouchUpInside];
    [page addSubview:reset];
  }
}

- (NSString *)statusText {
  NSMutableString *s = [NSMutableString string];
  [s appendFormat:@"后端     %s\n", BackendName(Available())];
  [s appendFormat:@"目标 PID %d\n", TargetPid()];
  [s appendFormat:@"UE 就绪  %s\n", ue::Ready() ? "是" : "否"];
  [s appendFormat:@"引擎     %s\n", ue::T().engineVersion.empty() ? "-" : ue::T().engineVersion.c_str()];
  [s appendFormat:@"GObjects %#llx\n", (unsigned long long)ue::T().gObjects];
  [s appendFormat:@"GNames   %#llx", (unsigned long long)ue::T().gNames];
  return s;
}

- (void)onReconnect {
  DMLOG("[menu] 手动重连");
  Detach();
  ue::Refresh();
}

- (void)onProbe {
  DMLOG("[menu] 手动自检");
  RunProbes();
  // 弹窗展示结果
  std::string rep = ProbeReport();
  UIAlertController *ac =
      [UIAlertController alertControllerWithTitle:@"自检结果"
                                         message:[NSString stringWithUTF8String:rep.c_str()]
                                  preferredStyle:UIAlertControllerStyleAlert];
  [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
  [self presentViewController:ac animated:YES completion:nil];
}

- (void)onReset {
  Cfg().SetDefaults();
  Cfg().Save();
  [self rebuild];
}

- (void)rebuild {
  for (UIView *v in _scroll.subviews) [v removeFromSuperview];
  [_pages removeAllObjects];
  [self buildPages];
  [self switchTab:_curTab];
}

// ---------- 悬浮球 ----------
- (void)buildBall {
  const CGFloat d = 46;
  _ball = [UIButton buttonWithType:UIButtonTypeCustom];
  _ball.frame = CGRectMake(0, 0, d, d);
  _ballCenter = CGPointMake(48, [UIScreen mainScreen].bounds.size.height * 0.5);
  _ball.center = _ballCenter;
  _ball.backgroundColor = kAccent();
  _ball.layer.cornerRadius = d / 2;
  _ball.layer.shadowColor = [UIColor blackColor].CGColor;
  _ball.layer.shadowOpacity = 0.45;
  _ball.layer.shadowRadius = 8;
  [_ball setTitle:@"D" forState:UIControlStateNormal];
  [_ball setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
  _ball.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBlack];
  [_ball addTarget:self action:@selector(onBallTap) forControlEvents:UIControlEventTouchUpInside];

  UIPanGestureRecognizer *pan =
      [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onBallPan:)];
  [_ball addGestureRecognizer:pan];

  [self.view addSubview:_ball];
}

- (void)onBallPan:(UIPanGestureRecognizer *)g {
  CGPoint t = [g translationInView:self.view];
  _ball.center = CGPointMake(_ball.center.x + t.x, _ball.center.y + t.y);
  [g setTranslation:CGPointZero inView:self.view];
  if (g.state == UIGestureRecognizerStateEnded) {
    // 吸边
    CGRect sb = [UIScreen mainScreen].bounds;
    const CGFloat x = (_ball.center.x < sb.size.width / 2) ? 30 : sb.size.width - 30;
    [UIView animateWithDuration:0.25 animations:^{
      self->_ball.center = CGPointMake(x, self->_ball.center.y);
    }];
  }
}

- (void)onBallTap { [self showPanel]; }

- (void)showPanel { _panel.hidden = NO; _ball.hidden = YES; }

- (void)hidePanel {
  _panel.hidden = YES;
  _ball.hidden = NO;
}

- (BOOL)prefersStatusBarHidden { return YES; }

@end

// ============================================================
//  Menu 门面
// ============================================================
namespace dm {

namespace {
DFMMenuViewController *g_vc = nil;
UIWindow *g_win = nil;
}

Menu &Menu::Shared() {
  static Menu *m = new Menu();
  return *m;
}

void Menu::Build() {
  if (g_vc) return;

  @autoreleasepool {
    UIWindowScene *scene = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
      if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
    }

    CGRect b = [UIScreen mainScreen].bounds;
    if (@available(iOS 13.0, *)) {
      g_win = scene ? [[UIWindow alloc] initWithWindowScene:scene] : [[UIWindow alloc] initWithFrame:b];
    } else {
      g_win = [[UIWindow alloc] initWithFrame:b];
    }

    g_win.frame = b;
    g_win.backgroundColor = [UIColor clearColor];
    // 比 HUD 还高，保证能点到
    g_win.windowLevel = UIWindowLevelAlert + 2000.f;

    g_vc = [[DFMMenuViewController alloc] init];
    g_win.rootViewController = g_vc;
    g_win.hidden = NO;

    DMLOG("[menu] 面板已创建");
  }
}

void Menu::Toggle() {
  if (!g_vc) Build();
  if (!g_vc) return;
  [g_vc onBallTap];
}

bool Menu::Visible() const { return g_vc && !g_vc.view.hidden; }

void Menu::Show() {
  if (!g_vc) Build();
  if (!g_vc) return;
  [g_vc showPanel];
}

void Menu::Hide() {
  if (!g_vc) return;
  [g_vc hidePanel];
}

}  // namespace dm
