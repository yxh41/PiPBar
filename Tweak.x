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

#define PIP_BUILD_TAG @"v0.2"
#define PIP_NOTIFY "com.yxh41.pipbar.reload"
#define PIP_NOTIFY_S @"com.yxh41.pipbar.reload"

// —— 偏好（CFPreferences 直读全局 plist；SpringBoard 以 mobile 身份运行，无容器隔离坑）——
static BOOL gEnabled = YES;
static BOOL gShowFrame = YES;
static BOOL gShowButtons = YES;
static BOOL gFileLog = NO;
static BOOL gDebugLog = NO;
static CGFloat gFrameW = 12.0;    // 顶/左右边框宽
static CGFloat gBarH = 40.0;      // 底部控制条高

// Copy 系列返回 +1 引用；ARC 下必须 CFBridgingRelease 交出所有权（否则 -Werror 编不过）
static id pipPref(NSString *key) {
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                    (__bridge CFStringRef)@"com.yxh41.pipbar");
    return v ? CFBridgingRelease(v) : nil;
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

// 造型对齐参考图（安卓 PiP 同款）：黑色圆角「手机壳」——
//   顶部/左右 = gFrameW 同宽，底部 = gBarH 加宽放三颗按钮，外圈圆角贴 PiP 本身的圆角。
// 实现：单层 CAShapeLayer + even-odd 挖洞（外圈圆角矩形 - 内圈圆角矩形），
// 中间完全透明让视频透出来。v0.2 的四条矩形边条没有圆角、贴不上 PiP 的圆角造型。
@interface PIPFrameView : UIView
@property (nonatomic, copy) void (^onTap)(NSInteger tag);
@property (nonatomic, strong) CAShapeLayer *caseLayer;
@end

@implementation PIPFrameView

+ (Class)layerClass {
    return [CAShapeLayer class];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.clipsToBounds = NO;   // 圆角壳不能裁，按钮放大在壳内但图标阴影可能越界
        self.caseLayer = (CAShapeLayer *)self.layer;
        self.caseLayer.fillColor = [UIColor colorWithWhite:0.05 alpha:1.0].CGColor;
        self.caseLayer.fillRule = kCAFillRuleEvenOdd;
        self.caseLayer.masksToBounds = NO;
        [self addButtonWithTag:1 symbol:@"backward.end.fill"];
        [self addButtonWithTag:2 symbol:@"play.fill"];
        [self addButtonWithTag:3 symbol:@"forward.end.fill"];
        // 初始错位无所谓 —— layoutSubviews 按当前 bounds 全量重算
        [self setNeedsLayout];
    }
    return self;
}

- (void)addButtonWithTag:(NSInteger)tag symbol:(NSString *)symbol {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.tag = tag;
    b.tintColor = UIColor.whiteColor;
    UIImage *img = [UIImage systemImageNamed:symbol];
    if (img != nil) {
        // 固定图标大小：跟随系统 Dynamic Type 会忽大忽小
        UIImage *sized = [img imageWithConfiguration:
                          [UIImageSymbolConfiguration configurationWithPointSize:20.0]];
        [b setImage:(sized != nil ? sized : img) forState:UIControlStateNormal];
    } else {
        // SF Symbol 名字漂移时的兜底：不至于是空按钮
        [b setTitle:(tag == 1 ? @"◀◀" : (tag == 2 ? @"▶" : @"▶▶")) forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:15.0];
    }
    [b addTarget:self action:@selector(buttonTapped:) forControlEvents:UIControlEventTouchUpInside];
    // ⚠️ 按钮必须直接挂在 self 上，且给【显式 frame】。
    // v0.2 踩坑：只设 center —— 用 CGRectZero 创建、translatesAutoresizingMask=YES 的视图
    // center 设了尺寸仍是 0×0，三颗按钮全部「存在但不可见」。
    [self addSubview:b];
}

- (void)buttonTapped:(UIButton *)sender {
    if (self.onTap != nil) self.onTap(sender.tag);
}

// 我们是铺满整块视频区的透明覆盖层。若不拦这一刀，命中会落到 self 上，
// PiP 原生的「拖动 / 单击展开 / 双击缩放」就全被吃掉了。
// 按钮是 self 的直接子视图：落在按钮上 hit 返回按钮（放行），其余一律穿透回 Pegasus。
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;
}

// 全部按【当前 bounds + 当前偏好】重算 —— 偏好热更新也走这里（setNeedsLayout）
// 挂在他人图层上时 bounds 可能在安装瞬间还是 0（autoresize 救不回来）。
// 所以把「贴合父视图」放进 layoutSubviews 自愈 —— 每次布局先看一眼父 bounds。
- (void)layoutSubviews {
    [super layoutSubviews];

    UIView *sup = self.superview;
    if (sup != nil && CGRectGetWidth(sup.bounds) > 1.0 && CGRectGetHeight(sup.bounds) > 1.0
        && !CGRectEqualToRect(self.frame, sup.bounds)) {
        self.frame = sup.bounds;          // 触发下一轮 layoutSubviews，届时已相等，不会死循环
        return;
    }

    CGFloat w = CGRectGetWidth(self.bounds);
    CGFloat h = CGRectGetHeight(self.bounds);
    CGFloat sw = gFrameW, bh = gBarH;
    if (w <= 0.0 || h <= 0.0) return;
    if (h < sw + bh + 4.0) {              // 视频太小放不下壳，宁可不画也不画成糊的
        self.caseLayer.path = nil;
        for (UIView *v in self.subviews) {
            if ([v isKindOfClass:[UIButton class]]) v.hidden = YES;
        }
        return;
    }

    self.hidden = !gEnabled || (!gShowFrame && !gShowButtons);

    // —— 圆角壳：圆角优先取宿主自己的 cornerRadius，取不到用 18 ——
    CGFloat r = sup.layer.cornerRadius;
    if (r < 2.0 || r > 40.0) r = 18.0;
    CGFloat ri = r - sw > 2.0 ? r - sw : 2.0;   // 内圈圆角随边宽收窄

    self.caseLayer.hidden = !gShowFrame;
    if (gShowFrame) {
        CGRect inner = CGRectMake(sw, sw, w - sw * 2.0, h - sw - bh);
        if (inner.size.width > 4.0 && inner.size.height > 4.0) {
            UIBezierPath *outer = [UIBezierPath bezierPathWithRoundedRect:self.bounds
                                                             cornerRadius:r];
            UIBezierPath *innerP = [UIBezierPath bezierPathWithRoundedRect:inner
                                                              cornerRadius:ri];
            [outer appendPath:innerP];   // even-odd：中间挖空，视频透出来
            self.caseLayer.path = outer.CGPath;
        }
    } else {
        self.caseLayer.path = nil;
    }

    // —— 底部控制条上的三颗按钮：0.20 / 0.50 / 0.80 宽度处，显式 56x44 实体尺寸 ——
    CGFloat xs[3] = {0.20, 0.50, 0.80};
    CGFloat btnW = 56.0, btnH = 44.0;
    CGFloat by = h - bh + (bh - btnH) / 2.0;
    if (by < h - btnH) by = h - btnH;
    NSUInteger i = 0;
    for (UIView *v in self.subviews) {
        if (![v isKindOfClass:[UIButton class]]) continue;
        CGFloat cx = w * xs[i];
        v.hidden = !gShowButtons;
        v.frame = CGRectMake(cx - btnW / 2.0, by, btnW, btnH);   // 必须 frame，不是 center（v0.2 踩坑）
        i++;
    }
}

@end

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

    PIPLog(@"HOST contentVC=%@ view=%@ frame=%@",
           NSStringFromClass(content.class), NSStringFromClass(v.class), NSStringFromCGRect(v.frame));

    UIView *strong = pipScanForVideoHost(v, YES);
    if (strong != nil) {
        PIPLog(@"HOST <- scan(strong) %@ frame=%@", NSStringFromClass(strong.class),
               NSStringFromCGRect(strong.frame));
        return strong;
    }

    NSArray<NSString *> *candidates = @[@"_contentView", @"_contentClippingView", @"_containerView"];
    for (NSString *name in candidates) {
        @try {
            id cand = [content valueForKey:name];
            if ([cand isKindOfClass:[UIView class]]) {
                UIView *cv = (UIView *)cand;
                PIPLog(@"HOST candidate %@ -> %@ frame=%@",
                       name, NSStringFromClass(cv.class), NSStringFromCGRect(cv.frame));
                CGFloat cw = CGRectGetWidth(cv.bounds), rw = CGRectGetWidth(v.bounds);
                // 只接受「明显比容器小」的：跟容器一样宽的说明不是被裁的视频层
                if (cw > 1.0 && (rw <= 0.0 || cw < rw - 1.0)) return cv;
            }
        } @catch (NSException *e) {
            PIPLog(@"HOST candidate %@ 不可用: %@", name, e.name);
        }
    }

    UIView *weak = pipScanForVideoHost(v, NO);
    if (weak != nil) {
        PIPLog(@"HOST <- scan(weak) %@ frame=%@", NSStringFromClass(weak.class),
               NSStringFromCGRect(weak.frame));
        return weak;
    }

    PIPLog(@"HOST fallback -> contentViewController.view（若仍伸出去，请回传 HIER 日志）");
    return v;
}

#pragma mark - 偏好热生效

static PIPFrameView *gInstalledFrame = nil;   // 弱需求：同一时刻只有一个 PiP 实例，直接强引用可接受
static NSString *gInstalledHostDesc = nil;

static void pipApplyFrameState(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        PIPFrameView *f = gInstalledFrame;
        if (f == nil) return;
        [f setNeedsLayout];   // hidden 逻辑全在 layoutSubviews 里按当前偏好算
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

        UIView *host = pipPickHostView(content);
        if (host == nil) return;
        pipInitPegasusOnce();   // content 已实例化 ⇒ Pegasus 必然已加载，此时挂它的钩子最稳
        pipDumpHierarchy(content.view, @"CONTENT-TREE");

        Class frameCls = objc_getClass("PIPFrameView");
        if (frameCls == nil) return;

        // 防重复安装
        for (UIView *sub in [host subviews]) {
            if ([sub isKindOfClass:frameCls]) {
                [sub removeFromSuperview];
                break;
            }
        }

        PIPFrameView *frame = [[frameCls alloc] initWithFrame:host.bounds];
        frame.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

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
                } else {
                    PIPLog(@"PGCommand/commandForSetPlaying: 不可用（类没加载或选择子漂移）");
                }
            } else {
                // 上一曲(1) / 下一曲(3)：action 码待嗅探，v0.3 接通
                PIPLog(@"button tag=%ld — 等待嗅探结果（见 CMD/SNIFF 日志）", (long)tag);
            }
        };

        [host addSubview:frame];
        gInstalledFrame = frame;
        gInstalledHostDesc = [NSString stringWithFormat:@"%@ on %@",
                              NSStringFromClass(frame.class), NSStringFromClass(host.class)];
        PIPLog(@"frame installed host=%@ frame=%@ (w=%.0f barh=%.0f)",
               gInstalledHostDesc, NSStringFromCGRect(frame.frame),
               (double)gFrameW, (double)gBarH);

        static BOOL gSniffed = NO;
        if (!gSniffed) {
            gSniffed = YES;
            pipDumpMethods(content.class, @"PIP-CONTENT");
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
                gPlaying = [rate doubleValue] > 0.0;
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
