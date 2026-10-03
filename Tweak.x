// PiPBar — 画中画增强（外框 + 底部控制条）
// 目标环境：iPhone 12 Pro / iOS 16.4.1 / roothide / arm64e
// 作用进程：SpringBoard（系统画中画的宿主）
//
// v0.2 变更（回应用户「设置里没有 / 日志在哪 / 你画的是什么」三条）：
//   * 【画歪】真实机截图：边条贴在 contentViewController.view 上会**伸到 PiP 可见区外面**
//     （该 view 是含 chrome 的容器，比可见视频大）。v0.2 按三级策略挑挂载层：
//       ① 递归扫描找 PGLayerHost*（真正的视频宿主矩形，不依赖 iOS 16/17 会漂移的 ivar 名）
//       ② KVC ivar（_contentView / _contentClippingView / _containerView，只收明显比容器窄的）
//       ③ 扫描带子图层的 Content*/Host* 视图 → ④ 回退 contentVC.view
//     每一步都把 class/frame 打进日志，错了能一眼看出该换哪级。
//   * 【贴不住】layoutSubviews 自愈：父视图 bounds 在安装瞬间常是 0（autoresize 救不回来），
//     现在每次布局先把自己对齐到父 bounds，并按**当前 bounds + 当前偏好**全量重算四条边条。
//   * 【吃掉手势】我们是铺满视频区的透明覆盖层，会把 PiP 原生「拖动/单击展开/双击缩放」
//     全吃掉。新增 hitTest 覆写：只有落在边条/按钮上的触摸才接管，其余穿透回去。
//   * 新增设置面板（PreferenceLoader，plist-only bundle，无编译）：
//     启用 / 显示外框 / 显示按钮 / 外框宽度 / 底部高度 / 文件日志 / 调试日志。
//     所有 specifier 带 PostNotification=darwin 通知，翻开关立即热生效（无需 respring）。
//   * 新增文件日志（/var/mobile/Library/Logs/PiPBar.log，256KB 自动截断），
//     用户不用连电脑，Filza 直接翻 —— 与 MapAdKiller 的 FileLog 同思路。
//   * Pegasus 钩子拆成独立 %group：Pegasus.framework 可能懒加载，跟 SBPIP 挤在同一组时
//     一旦 ctor 时它还没进内存，整组 %init 一起落空。改为 content VC 实例化后补挂。
//
// 机制路线（独立实现，仅参考 FreePIP 的公开机制结论，未复用其 GPL 代码）：
//   SpringBoard 进程：SBPIPContainerViewController → PGPictureInPictureViewController(Pegasus)
//   播放/暂停：PGCommand +commandForSetPlaying: → handleCommand:（运行时解析类，别链接符号）

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreFoundation/CoreFoundation.h>

#define PIP_BUILD_TAG @"v0.8"
#define PIP_NOTIFY "com.yxh41.pipbar.reload"
#define PIP_NOTIFY_S @"com.yxh41.pipbar.reload"

// —— 偏好（CFPreferences 直读全局 plist；SpringBoard 以 mobile 身份运行，无容器隔离坑）——
static BOOL gEnabled = YES;
static BOOL gShowFrame = YES;
static BOOL gShowButtons = YES;
static BOOL gFileLog = YES;       // 默认开：日志是排障生命线，别让用户摸黑
static BOOL gDebugLog = NO;
static CGFloat gFrameW = 8.0;     // 顶/左右边框宽（用户反馈 12 太粗 → 默认 8）
static CGFloat gBarH = 40.0;      // 底部控制条高

// roothide per-app 容器隔离：Settings 里 CFPreferences 写的域，SpringBoard 读不到
// （MapAdKiller/Oback 双双踩实）。范式同款：全局 plist 文件直读，两个进程命中同一物理文件。
// 写入侧在 PiPBarSettingsController（PiPBarPrefsBridge.h 镜像写）。
#define PIP_GLOBAL_PLIST "/var/mobile/Library/Preferences/com.yxh41.pipbar.plist"

static id pipPref(NSString *key) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:@PIP_GLOBAL_PLIST];
    return d[key];
}

static void pipReadPrefs(void) {
    id v;
    if ((v = pipPref(@"Enabled")) != nil) gEnabled = [v boolValue];
    if ((v = pipPref(@"ShowFrame")) != nil) gShowFrame = [v boolValue];
    if ((v = pipPref(@"ShowButtons")) != nil) gShowButtons = [v boolValue];
    if ((v = pipPref(@"FileLog")) != nil) gFileLog = [v boolValue];
    if ((v = pipPref(@"DebugLog")) != nil) gDebugLog = [v boolValue];
    if ((v = pipPref(@"FrameWidth")) != nil) {
        CGFloat f = [v floatValue];
        if (f >= 2.0 && f <= 30.0) gFrameW = f;
    }
    if ((v = pipPref(@"BarHeight")) != nil) {
        CGFloat f = [v floatValue];
        if (f >= 20.0 && f <= 100.0) gBarH = f;
    }
}

// —— 日志：syslog 恒开（量小），文件日志受 FileLog 开关控制 ——
static void pipFileWrite(NSString *line) {
    if (!gFileLog) return;
    @try {
        NSString *dir = @"/var/mobile/Library/Logs";
        NSString *path = [dir stringByAppendingPathComponent:@"PiPBar.log"];
        NSFileManager *fm = NSFileManager.defaultManager;
        NSDictionary *attr = [fm attributesOfItemAtPath:path error:nil];
        if (attr != nil && [attr fileSize] > 256 * 1024) {
            [fm removeItemAtPath:path error:nil];   // 超限即截断（从头记），不做轮转，够用
        }
        if (![fm fileExistsAtPath:dir]) [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        NSString *out = [NSString stringWithFormat:@"%@ %@\n",
                         [df stringFromDate:[NSDate date]], line];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (fh == nil) {
            [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:[out dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (NSException *e) { /* 文件日志失败不影响主流程 */ }
}

#define PIPLog(fmt, ...) do { \
    NSString *l = [NSString stringWithFormat:fmt, ##__VA_ARGS__]; \
    NSLog(@"[PiPBar " PIP_BUILD_TAG "] %@", l); \
    pipFileWrite(l); \
} while (0)

// —— Pegasus / SpringBoard 私有类（@interface 只给编译器看类型；类一律运行时解析）——
@interface SBPIPContainerViewController : UIViewController
- (UIViewController *)contentViewController;
@end

@interface PGCommand : NSObject
- (long long)playbackAction;
- (NSDictionary *)dictionaryRepresentation;
@end

@interface PGPictureInPictureViewController : UIViewController
- (void)handleCommand:(id)arg1;
@end

static BOOL gPlaying = YES;   // 最近一次已知的播放状态

#pragma mark - 外框 + 按钮条

@class PIPFrameView;   // 前置声明：下面的文件级静态指针在 @interface 之前，需先告诉编译器类型
static UIView *pipPickHostView(UIViewController *content);   // 前向声明（layoutSubviews 里复用）

// 视频宿主（弱引用）：壳要「包在视频外面」，必须随时知道视频矩形在哪。
static __weak UIView *gVideoHost = nil;
// content VC 弱引用：loadView 时几何还全是 0（host 会回退成全屏 content.view），
// 每次布局时重解析真正的视频宿主。
static __weak UIViewController *gContentVC = nil;

static BOOL gExpandedUI = NO;              // PiP 展开成大窗时把壳和按钮都收起来
static PIPFrameView *gInstalledFrame = nil;   // 当前壳（reload 与 play/pause 图标刷新都要用，前置声明）
// 显示链心跳（无卡顿版）：只在「画布局部视频矩形」真变化时才 setNeedsLayout。
// 拖动时窗口移动、但画布局部几何不变 ⇒ 不重画 ⇒ 不卡；只有 resize/expand 才重画。
static CADisplayLink *gSyncLink = nil;
static CGRect gLastVR = (CGRect){{0,0},{0,0}};
// 真「视频宿主」判定：类名含 PGLayerHost* 才是可见视频矩形本身。
// ⚠️ v0.8 关键教训：fallback 容器 PGHitTestExtendableView 是【全屏】的，
// 装完第一帧就有尺寸 —— 「有尺寸」≠「找对了」，绝不能以有尺寸为由停找真宿主。
static BOOL pipHostIsReal(UIView *host) {
    return host != nil && [NSStringFromClass(host.class)
                          rangeOfString:@"PGLayerHost"].location != NSNotFound;
}
// tick 节流重扫期间静默 pipPickHostView 的逐条日志（否则 12Hz 刷屏）；
// 真宿主找到/变化时由 tick 统一打一行。
static BOOL gPickQuiet = NO;
#define PIP_PICK_LOG(fmt, ...) do { if (!gPickQuiet) PIPLog(fmt, ##__VA_ARGS__); } while (0)
static int gTickN = 0;   // 真宿主未找到时的重扫节流计数（每 5 帧 ≈ 12Hz）

// 造型对齐参考图（安卓 PiP 同款）：黑色圆角「手机壳」**套在视频外面**——
//   视频矩形不动，壳画在容器层、向外扩：顶/左右 = gFrameW，底部 = gBarH。
// 实现：CAShapeLayer even-odd（外圈圆角矩形挖掉【视频矩形】这个洞）+ 内沿发丝高光 + 投影。
// 注意：shadowPath 必须只用外圈路径 —— v0.4 用带洞路径当 shadowPath，投影顺着洞
// 投进视频区，画面像蒙了层黑遮罩（v0.5 用户反馈实锤）。
@interface PIPFrameView : UIView
@property (nonatomic, strong) CAShapeLayer *caseLayer;
@property (nonatomic, strong) CAShapeLayer *edgeLayer;
@property (nonatomic, strong) CAShapeLayer *barLayer;
@property (nonatomic, copy) void (^onTap)(NSInteger tag);
- (void)pipSelfHeal;
@end

// 缓存图标：play/pause 随播放状态切换（v0.3 用户反馈「播放暂停不会变化」）
static UIImage *pipIcon(BOOL playing) {
    static UIImage *playImg, *pauseImg;
    if (playImg == nil) {
        playImg  = [UIImage systemImageNamed:@"play.fill"];
        pauseImg = [UIImage systemImageNamed:@"pause.fill"];
    }
    // 固定 15pt：小而精致；不跟 Dynamic Type 忽大忽小
    UIImage *base = playing ? pauseImg : playImg;
    if (base == nil) return nil;
    UIImage *sized = [base imageWithConfiguration:
                      [UIImageSymbolConfiguration configurationWithPointSize:15.0]];
    return sized != nil ? sized : base;
}

// —— 按钮宿主（v0.6 重大简化）——
// v0.5 把按钮放独立悬浮 UIWindow：真机两轮都没渲染出来（iOS 16 无 windowScene 的
// 窗口大概率不显示），30fps 心跳还造成拖动卡顿。v0.6 按钮直接做成壳的子视图、
// 叠在【视频底部内侧】（窗口边界内 ⇒ 触摸必然可达、渲染必然可见），拖动跟随是
// 原生视图树行为，零同步成本。底部黑边（lip）在窗口外，纯装饰、不承担按钮。

@implementation PIPFrameView

+ (Class)layerClass {
    return [CAShapeLayer class];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.clipsToBounds = NO;      // 壳在视频外面，经常超出画布 bounds，绝不能裁
        self.caseLayer = (CAShapeLayer *)self.layer;
        self.caseLayer.fillColor = [UIColor colorWithWhite:0.07 alpha:1.0].CGColor;
        self.caseLayer.fillRule = kCAFillRuleEvenOdd;
        self.caseLayer.masksToBounds = NO;
        // v0.6：投影彻底删除 —— shadowPath 是无洞外圈矩形，剪影把整个视频区罩住，
        // 35% 黑从透明洞透出来 = 均匀蒙灰（「画面像蒙了一层灰」真凶）。
        // 质感改由：近黑壳 + 内沿发丝高光 + 圆角承担。
        self.edgeLayer = [CAShapeLayer layer];
        self.edgeLayer.fillColor = nil;
        self.edgeLayer.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;
        self.edgeLayer.lineWidth = 1.0;
        self.edgeLayer.masksToBounds = NO;
        [self.layer addSublayer:self.edgeLayer];
        // 按钮底衬条：叠在视频底部的半透明黑条（圆角胶囊）
        self.barLayer = [CAShapeLayer layer];
        self.barLayer.fillColor = [UIColor colorWithWhite:0.0 alpha:0.38].CGColor;
        self.barLayer.masksToBounds = NO;
        [self.layer addSublayer:self.barLayer];
        // 三颗按钮：壳的子视图（壳实测渲染位置正确；按钮在窗口边界内 ⇒ 必然可点）
        [self pipAddButtonWithTag:1 icon:@"backward.end.fill" fallback:@"◀◀"];
        [self pipAddButtonWithTag:2 icon:nil fallback:@"▶"];   // play/pause 图标 layoutSubviews 里按状态设
        [self pipAddButtonWithTag:3 icon:@"forward.end.fill" fallback:@"▶▶"];
        [self setNeedsLayout];
    }
    return self;
}

- (void)pipAddButtonWithTag:(NSInteger)tag icon:(NSString *)icon fallback:(NSString *)fb {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.tag = tag;
    b.tintColor = UIColor.whiteColor;
    UIImage *base = icon != nil ? [UIImage systemImageNamed:icon] : nil;
    if (base != nil) {
        UIImage *sized = [base imageWithConfiguration:
                          [UIImageSymbolConfiguration configurationWithPointSize:15.0]];
        [b setImage:(sized != nil ? sized : base) forState:UIControlStateNormal];
    } else {
        [b setTitle:fb forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:12.0];
    }
    [b addTarget:self action:@selector(pipButtonTapped:)
 forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:b];
}

- (void)pipButtonTapped:(UIButton *)sender {
    if (self.onTap != nil) self.onTap(sender.tag);
}

// 整层透明铺在容器上：只有摸到按钮才接管，其余穿透（保住 PiP 原生拖动/单击/双击手势）
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;
}

// 自愈：安装瞬间父 bounds 可能是 0，autoresize 救不回来 —— 每次布局先对齐父 bounds
- (void)pipSelfHeal {
    UIView *sup = self.superview;
    if (sup != nil && CGRectGetWidth(sup.bounds) > 1.0 && CGRectGetHeight(sup.bounds) > 1.0
        && !CGRectEqualToRect(self.frame, sup.bounds)) {
        self.frame = sup.bounds;   // 触发下一轮 layoutSubviews，届时已相等，不会死循环
    }
}

// 全部按【当前视频矩形 + 当前偏好】重算 —— 偏好热更新也走这里（setNeedsLayout）
- (void)layoutSubviews {
    [super layoutSubviews];
    [self pipSelfHeal];

    CGFloat sw = gFrameW, bh = gBarH;
    UIView *host = gVideoHost;
    UIView *sup = self.superview;
    // v0.8：只要还不是真视频宿主（PGLayerHost*）就继续解析 ——
    // v0.7 只在 host 无尺寸时重扫，而 fallback 全屏容器装完就有尺寸 ⇒ 重扫停摆 ⇒
    // 壳锁死在全屏容器上（外框消失真凶）。这里保留逐条日志（layoutSubviews 非每帧路径）
    if (gContentVC != nil && !pipHostIsReal(host)) {
        UIView *h = pipPickHostView(gContentVC);
        if (h != nil) { host = h; gVideoHost = h; }
    }
    if (sup == nil || host == nil || host.window == nil) return;

    // 视频矩形换算到本画布坐标 —— 壳就是绕着它向外扩的
    CGRect vr = [host convertRect:host.bounds toView:self];
    CGFloat vrW = CGRectGetWidth(vr), vrH = CGRectGetHeight(vr);
    if (vrW < 8.0 || vrH < 8.0) return;

    // v0.8：全屏判定收紧 —— 旧「>60% 屏宽」会把放大档 PiP（约 2/3~9/10 屏宽，
    // 用户截图实锤）误判成全屏而整壳隐藏。只有宽、高同时 ≈ 屏幕才算全屏播放。
    CGSize scr = [UIScreen mainScreen].bounds.size;
    gExpandedUI = vrW > scr.width * 0.95 && vrH > scr.height * 0.95;
    self.hidden = !gEnabled || (!gShowFrame && !gShowButtons) || gExpandedUI;

    CGRect outer = CGRectMake(CGRectGetMinX(vr) - sw, CGRectGetMinY(vr) - sw,
                              vrW + sw * 2.0, vrH + sw + bh);

    // 圆角：内洞贴视频自身圆角，外圈随边宽外扩
    CGFloat innerR = host.layer.cornerRadius;
    if (innerR < 2.0 || innerR > 40.0) innerR = 16.0;
    CGFloat outerR = innerR + sw;

    self.caseLayer.hidden = !gShowFrame || gExpandedUI;
    self.edgeLayer.hidden = !gShowFrame || gExpandedUI;
    if (gShowFrame && !gExpandedUI && outer.size.width > 8.0 && outer.size.height > 8.0) {
        UIBezierPath *op = [UIBezierPath bezierPathWithRoundedRect:outer cornerRadius:outerR];
        UIBezierPath *ip = [UIBezierPath bezierPathWithRoundedRect:vr cornerRadius:innerR];
        [op appendPath:ip];   // even-odd：视频矩形挖空，画面原样透出
        self.caseLayer.path = op.CGPath;
        self.caseLayer.shadowPath = nil;   // v0.6：无投影（蒙灰根因已删）
        self.edgeLayer.path = ip.CGPath;   // 发丝高光勾在洞口一圈
    } else {
        self.caseLayer.path = nil;
        self.edgeLayer.path = nil;
    }

    // —— 按钮条：叠在视频底部【内侧】（窗口边界内 = 触摸可达）——
    BOOL showBar = gShowButtons && !gExpandedUI;
    CGFloat barH = 36.0, inset = 6.0;
    CGRect barRect = CGRectZero;
    self.barLayer.hidden = !showBar;
    if (showBar) {
        barRect = CGRectMake(CGRectGetMinX(vr) + inset, CGRectGetMaxY(vr) - barH - inset,
                             vrW - inset * 2.0, barH);
        self.barLayer.path =
            [UIBezierPath bezierPathWithRoundedRect:barRect
                                       cornerRadius:barH / 2.0].CGPath;
    } else {
        self.barLayer.path = nil;
    }

    CGFloat xs[3] = {0.22, 0.50, 0.78};
    CGFloat btnW = 44.0, btnH = 30.0;
    CGFloat by = CGRectGetMinY(barRect) + (barH - btnH) / 2.0;
    NSUInteger i = 0;
    for (UIView *v in self.subviews) {
        if (![v isKindOfClass:[UIButton class]]) continue;
        CGFloat cx = CGRectGetMinX(barRect) + CGRectGetWidth(barRect) * xs[i];
        v.frame = CGRectMake(cx - btnW / 2.0, by, btnW, btnH);   // 必须 frame，不是 center（v0.2 踩坑）
        v.hidden = !showBar;
        if (v.tag == 2) [(UIButton *)v setImage:pipIcon(gPlaying) forState:UIControlStateNormal];
        i++;
    }
}

@end

#pragma mark - 显示链心跳（无卡顿版）

// v0.6 误删 CADisplayLink 心跳 → host 重解析只留在 layoutSubviews，
// 而 PiP 视频层尺寸变化时**不触发父 view 重布局** → layoutSubviews 不被调用
// → pipPickHostView 永不运行 → host 卡在零尺寸 → 外框永不重画
// （日志 videoRect={{0,0},{0,0}} 实锤）。
// v0.7 加回心跳，但只在「视频矩形真变化」时才 setNeedsLayout：
//   拖动时窗口移动、画布局部几何不变 ⇒ 不重画 ⇒ 不卡；只有 resize/expand 才重画。
@interface PIPSyncSink : NSObject
+ (void)tick:(CADisplayLink *)link;
@end

@implementation PIPSyncSink
+ (void)tick:(CADisplayLink *)link {
    (void)link;
    PIPFrameView *f = gInstalledFrame;
    if (f == nil) { gLastVR = (CGRect){{0,0},{0,0}}; return; }
    if (!gShowFrame && !gShowButtons) { gLastVR = (CGRect){{0,0},{0,0}}; return; }
    // v0.8 关键修复：只要还不是真视频宿主（PGLayerHost*）就节流重扫。
    // v0.7 只在 host 无尺寸时重扫 —— 但 fallback 全屏容器 PGHitTestExtendableView
    // 装完第一帧就有尺寸 ⇒ 重扫停摆 ⇒ 壳锁死在全屏容器上 ⇒ gExpandedUI 误判 ⇒ 整壳隐藏
    //（真机日志实锤：装壳后再无第二条 HOST 行）。静默扫描防刷屏，找到/变化才打一行。
    UIView *host = gVideoHost;
    if (gContentVC != nil && !pipHostIsReal(host) && (gTickN++ % 5) == 0) {
        gPickQuiet = YES;
        UIView *h = pipPickHostView(gContentVC);
        gPickQuiet = NO;
        if (h != nil && h != host) {
            gVideoHost = h;
            host = h;
            if (pipHostIsReal(h)) {
                PIPLog(@"HOST tick re-pick -> %@ frame=%@",
                       NSStringFromClass(h.class), NSStringFromCGRect(h.frame));
            }
        }
    }
    if (host == nil || host.window == nil) return;
    // 当前视频矩形（本画布坐标），与 layoutSubviews 算法完全一致
    CGRect vr = [host convertRect:host.bounds toView:f];
    // vr 真变化才重画：拖动时窗口移动但 host 相对 f 的几何不变 ⇒ 不重画 ⇒ 不卡
    if (!CGRectEqualToRect(vr, gLastVR)) {
        gLastVR = vr;
        [f setNeedsLayout];   // 触发 layoutSubviews：按新几何重算外框/按钮
    }
}
@end

static void pipEnsureSyncLink(void) {
    if (gSyncLink != nil) return;
    // 以类对象为 target：类对象永不被释放，规避 CADisplayLink 对 target 的强引用循环
    gSyncLink = [CADisplayLink displayLinkWithTarget:[PIPSyncSink class]
                                            selector:@selector(tick:)];
    [gSyncLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    PIPLog(@"sync link started (no-jank heartbeat)");
}

#pragma mark - 嗅探（日志驱动：v0.3 拿这份日志把上一曲/下一曲接通）

static void pipDumpMethods(Class c, NSString *where) {
    if (c == nil) return;
    unsigned int n = 0;
    Method *ms = class_copyMethodList(c, &n);
    if (ms == NULL) return;
    NSArray<NSString *> *kws = @[@"command", @"play", @"skip", @"next", @"previous",
                                 @"track", @"chrome", @"controls", @"restore", @"pause"];
    NSMutableArray<NSString *> *hits = [NSMutableArray array];
    for (unsigned int i = 0; i < n; i++) {
        NSString *sel = NSStringFromSelector(method_getName(ms[i]));
        NSString *low = [sel lowercaseString];
        for (NSString *k in kws) {
            if ([low containsString:k]) { [hits addObject:sel]; break; }
        }
    }
    free(ms);
    PIPLog(@"SNIFF %@ (%@) %lu 条: %@", where, NSStringFromClass(c),
           (unsigned long)hits.count, [hits componentsJoinedByString:@" | "]);
}

// 视图层级 dump（4 层）：真机截图证明 v0.1 挂错了层 —— 用它定位「可见视频区域」到底是哪层
static void pipDumpHierarchy(UIView *root, NSString *where) {
    if (!gDebugLog || root == nil) return;
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSMutableArray<NSArray *> *stack = [NSMutableArray arrayWithObject:@[root, @0]];
    while (stack.count > 0 && lines.count < 40) {
        NSArray *item = stack.lastObject;
        [stack removeLastObject];
        UIView *v = item[0];
        NSUInteger depth = [item[1] unsignedIntegerValue];
        NSMutableString *s = [NSMutableString string];
        for (NSUInteger i = 0; i < depth; i++) [s appendString:@"  "];
        [s appendFormat:@"%@ %@", NSStringFromClass(v.class), NSStringFromCGRect(v.frame)];
        if (v.isHidden) [s appendString:@" [hidden]"];
        [lines addObject:s];
        if (depth < 6) {
            for (UIView *sv in [v.subviews reverseObjectEnumerator]) {
                [stack addObject:@[sv, @(depth + 1)]];
            }
        }
    }
    PIPLog(@"HIER %@:\n%@", where, [lines componentsJoinedByString:@"\n"]);
}

// 策略 B：递归扫描。不依赖 ivar 名（iOS 16 vs 17 会漂移），靠两类信号找视频层：
//   强信号 = 类名含 PGLayerHost（Pegasus 的远端图层宿主，就是可见视频矩形本身）
//   弱信号 = 类名含 Content/Host 且自己带了子图层
// 两者都按「面积最大」取胜 —— PiP 里视频层一定是最大的那个。
static UIView *pipScanForVideoHost(UIView *root, BOOL strongOnly) {
    if (root == nil) return nil;
    UIView *best = nil;
    CGFloat bestArea = 0.0;
    NSMutableArray<NSArray *> *stack = [NSMutableArray arrayWithObject:@[root, @0]];
    NSUInteger seen = 0;
    while (stack.count > 0 && seen < 300) {
        NSArray *item = stack.lastObject;
        [stack removeLastObject];
        UIView *v = item[0];
        NSUInteger depth = [item[1] unsignedIntegerValue];
        seen++;
        NSString *cn = NSStringFromClass(v.class);
        CGSize sz = v.bounds.size;
        CGFloat area = sz.width * sz.height;
        BOOL ok = (area > 1.0) && !v.isHidden && v.alpha > 0.01 && area > bestArea;
        if (ok) {
            BOOL host = [cn rangeOfString:@"PGLayerHost"].location != NSNotFound;
            BOOL contentish = ([cn rangeOfString:@"Content"].location != NSNotFound ||
                               [cn rangeOfString:@"Host"].location != NSNotFound) &&
                              v.layer.sublayers.count > 0;
            if (host || (!strongOnly && contentish)) {
                best = v;
                bestArea = area;
            }
        }
        if (depth < 6) {
            for (UIView *sv in v.subviews) [stack addObject:@[sv, @(depth + 1)]];
        }
    }
    return best;
}

// 策略优先级：强信号扫描 → KVC ivar → 弱信号扫描 → contentVC.view（v0.1 的老位置）
static UIView *pipPickHostView(UIViewController *content) {
    UIView *v = content.view;
    if (v == nil) return nil;

    PIP_PICK_LOG(@"HOST contentVC=%@ view=%@ frame=%@",
           NSStringFromClass(content.class), NSStringFromClass(v.class), NSStringFromCGRect(v.frame));

    UIView *strong = pipScanForVideoHost(v, YES);
    if (strong != nil) {
        PIP_PICK_LOG(@"HOST <- scan(strong) %@ frame=%@", NSStringFromClass(strong.class),
               NSStringFromCGRect(strong.frame));
        return strong;
    }

    NSArray<NSString *> *candidates = @[@"_contentView", @"_contentClippingView", @"_containerView"];
    for (NSString *name in candidates) {
        @try {
            id cand = [content valueForKey:name];
            if ([cand isKindOfClass:[UIView class]]) {
                UIView *cv = (UIView *)cand;
                PIP_PICK_LOG(@"HOST candidate %@ -> %@ frame=%@",
                       name, NSStringFromClass(cv.class), NSStringFromCGRect(cv.frame));
                CGFloat cw = CGRectGetWidth(cv.bounds), rw = CGRectGetWidth(v.bounds);
                // 只接受「明显比容器小」的：跟容器一样宽的说明不是被裁的视频层
                if (cw > 1.0 && (rw <= 0.0 || cw < rw - 1.0)) return cv;
            }
        } @catch (NSException *e) {
            PIP_PICK_LOG(@"HOST candidate %@ 不可用: %@", name, e.name);
        }
    }

    UIView *weak = pipScanForVideoHost(v, NO);
    if (weak != nil) {
        PIP_PICK_LOG(@"HOST <- scan(weak) %@ frame=%@", NSStringFromClass(weak.class),
               NSStringFromCGRect(weak.frame));
        return weak;
    }

    PIP_PICK_LOG(@"HOST fallback -> contentViewController.view（若仍伸出去，请回传 HIER 日志）");
    return v;
}

#pragma mark - 偏好热生效

static NSString *gInstalledHostDesc = nil;

static void pipApplyFrameState(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        PIPFrameView *f = gInstalledFrame;
        if (f == nil) return;
        [f setNeedsLayout];          // 壳的 hidden/几何/按钮全在 layoutSubviews 里按当前偏好算
        PIPLog(@"reload applied: enabled=%d frame=%d buttons=%d w=%.0f barh=%.0f",
               gEnabled, gShowFrame, gShowButtons, (double)gFrameW, (double)gBarH);
    });
}

static void pipDarwinCallback(CFNotificationCenterRef center, void *observer,
                              CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    pipReadPrefs();
    pipApplyFrameState();
}

#pragma mark - Hooks

// Pegasus 单独成组：Pegasus.framework 可能是懒加载的，跟 SBPIP 放在同一个默认组里，
// 一旦 ctor 时它还没进内存，整组 %init 会一起落空（SBPIP 也跟着不生效）。
static void pipInitPegasusOnce(void);

%hook SBPIPContainerViewController

- (void)loadView {
    %orig;
    @try {
        pipReadPrefs();
        UIViewController *content = nil;
        if ([self respondsToSelector:@selector(contentViewController)]) {
            content = [self contentViewController];
        }
        if (content == nil || content.view == nil) {
            PIPLog(@"loadView: contentViewController 不可用（iOS 版本漂移?）");
            return;
        }
        if (!gEnabled) {
            PIPLog(@"loadView: 已停用，跳过安装");
            return;
        }

        UIView *videoHost = pipPickHostView(content);
        if (videoHost == nil) return;
        gVideoHost = videoHost;   // 壳的矩形参照物（弱引用，几何就绪前会在 tick 里重解析）
        gContentVC = content;     // 供 tick 每帧重解析真正的视频宿主
        pipInitPegasusOnce();   // content 已实例化 ⇒ Pegasus 必然已加载，此时挂它的钩子最稳
        pipDumpHierarchy(content.view, @"CONTENT-TREE");

        Class frameCls = objc_getClass("PIPFrameView");
        if (frameCls == nil) return;

        // 壳的画布 = contentVC.view（容器层）：画布够大，壳才能包在视频【外面】。
        // v0.3 的错误：壳装在视频层自身上，只能往里盖（内框），视频边缘被吃掉。
        UIView *canvas = content.view;

        // 防重复安装（防的是同画布上的旧壳；换画布时旧壳随旧画布销毁）
        for (UIView *sub in [canvas subviews]) {
            if ([sub isKindOfClass:frameCls]) {
                [sub removeFromSuperview];
                break;
            }
        }

        PIPFrameView *frame = [[frameCls alloc] initWithFrame:canvas.bounds];
        frame.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        // 按钮点击逻辑（v0.6：按钮在壳上，不再有独立窗口）
        __weak UIViewController *weakContent = content;
        frame.onTap = ^(NSInteger tag) {
            UIViewController *c = weakContent;
            if (c == nil) return;
            if (tag == 2) {
                // 播放/暂停：Pegasus 命令通道。PGCommand 必须运行时解析（链接符号坑，v0.1 踩过）
                Class cmdCls = objc_getClass("PGCommand");
                SEL sel = sel_registerName("commandForSetPlaying:");
                if (cmdCls != nil && [cmdCls respondsToSelector:sel]) {
                    gPlaying = !gPlaying;
                    id (*setPlaying)(id, SEL, BOOL) = (id (*)(id, SEL, BOOL))objc_msgSend;
                    id cmd = setPlaying(cmdCls, sel, gPlaying);
                    [(PGPictureInPictureViewController *)c handleCommand:cmd];
                    PIPLog(@"play/pause -> setPlaying=%d", gPlaying);
                    [gInstalledFrame setNeedsLayout];   // 立即换 play/pause 图标
                } else {
                    PIPLog(@"PGCommand/commandForSetPlaying: 不可用（类没加载或选择子漂移）");
                }
            } else {
                // 上一曲(1) / 下一曲(3)：PGCMD-META 实锤构造器
                // commandForPlaybackAction:associatedDoubleValue:，系统快退/快进 = action=1 + ±10 秒
                Class cmdCls = objc_getClass("PGCommand");
                SEL mk = sel_registerName("commandForPlaybackAction:associatedDoubleValue:");
                if (cmdCls != nil && [cmdCls respondsToSelector:mk]) {
                    double off = (tag == 1) ? -10.0 : 10.0;   // 上一曲=-10s，下一曲=+10s
                    id (*build)(id, SEL, long long, double) =
                        (id (*)(id, SEL, long long, double))objc_msgSend;
                    id cmd = build(cmdCls, mk, 1LL, off);
                    [(PGPictureInPictureViewController *)c handleCommand:cmd];
                    PIPLog(@"seek -> action=1 offset=%.0f", off);
                } else {
                    PIPLog(@"PGCommand/commandForPlaybackAction:associatedDoubleValue: 不可用");
                }
            }
        };

        [canvas addSubview:frame];
        [canvas bringSubviewToFront:frame];
        gInstalledFrame = frame;
        pipEnsureSyncLink();   // v0.7：无卡顿心跳，保证 host 解析就绪后外框持续重画
        gInstalledHostDesc = [NSString stringWithFormat:@"%@ over %@ (video=%@)",
                              NSStringFromClass(frame.class), NSStringFromClass(canvas.class),
                              NSStringFromClass(videoHost.class)];
        PIPLog(@"frame installed outer video=%@ canvas=%@ videoRect=%@ (w=%.0f barh=%.0f)",
               NSStringFromClass(videoHost.class), NSStringFromClass(canvas.class),
               NSStringFromCGRect([videoHost convertRect:videoHost.bounds toView:canvas]),
               (double)gFrameW, (double)gBarH);

        static BOOL gSniffed = NO;
        if (!gSniffed) {
            gSniffed = YES;
            pipDumpMethods(content.class, @"PIP-CONTENT");
            pipDumpMethods(objc_getClass("PGCommand"), @"PGCMD");
            // class_copyMethodList 只列实例方法；+commandForXxx: 是类方法，得 dump 元类
            pipDumpMethods(objc_getMetaClass("PGCommand"), @"PGCMD-META");
        }
    } @catch (NSException *e) {
        PIPLog(@"install failed: %@", e);
    }
}

%end

// 系统控制（含我们自己发的）都会过这里 —— 用户点一下系统播放/暂停/快进快退，
// 日志里就有对应的 playbackAction 值，这就是接上一曲/下一曲的依据。
%group PegasusHooks

%hook PGPictureInPictureViewController

- (void)handleCommand:(id)cmd {
    @try {
        if ([cmd respondsToSelector:@selector(playbackAction)]) {
            PIPLog(@"CMD playbackAction=%lld dict=%@",
                   (long long)[cmd playbackAction], [cmd dictionaryRepresentation]);
        } else {
            PIPLog(@"CMD %@", cmd);
        }
    } @catch (NSException *e) {
        PIPLog(@"CMD log failed: %@", e);
    }
    %orig;
}

- (void)updatePlaybackStateWithDiff:(id)diff {
    %orig;
    // 播放状态 diff：拿 playbackRate 判断当前是否在播（首次会全量打印，之后只打变化）
    @try {
        if ([diff isKindOfClass:[NSDictionary class]]) {
            NSDictionary *d = (NSDictionary *)diff;
            id rate = d[@"playbackRate"];
            if (rate != nil) {
                BOOL nowPlaying = [rate doubleValue] > 0.0;
                if (nowPlaying != gPlaying) {
                    gPlaying = nowPlaying;
                    [gInstalledFrame setNeedsLayout];   // 同步 play/pause 图标
                }
                PIPLog(@"STATE diff=%@", d);
            }
        }
    } @catch (NSException *e) {
        PIPLog(@"STATE log failed: %@", e);
    }
}

%end   // %hook PGPictureInPictureViewController
%end   // %group PegasusHooks —— 组与钩子各要一个 %end，嵌套不能省

static BOOL gPegasusReady = NO;
static void pipInitPegasusOnce(void) {
    if (gPegasusReady) return;
    if (objc_getClass("PGPictureInPictureViewController") == nil) return;
    gPegasusReady = YES;
    %init(PegasusHooks);
    PIPLog(@"Pegasus hooks installed");
}

%ctor {
    pipReadPrefs();
    %init;
    pipInitPegasusOnce();   // 若已加载则此刻挂上；否则等 PiP 起来由 loadView 补挂
    // 设置面板翻任何开关都会 post 这个 darwin 通知 → 立即重读偏好并热更新外框（无需 respring）
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        pipDarwinCallback, CFSTR(PIP_NOTIFY), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
    PIPLog(@"loaded for SpringBoard | build=" PIP_BUILD_TAG
           " enabled=%d frame=%d buttons=%d w=%.0f barh=%.0f filelog=%d",
           gEnabled, gShowFrame, gShowButtons, (double)gFrameW, (double)gBarH, gFileLog);
}
