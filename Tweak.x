// PiPBar — 画中画增强（外框 + 底部控制条）
// 目标环境：iPhone 12 Pro / iOS 16.4.1 / roothide / arm64e
// 作用进程：SpringBoard（系统画中画的宿主）
//
// v0.2 变更（真机截图校准）：
//   * 真机截图证明：把边条贴在 contentViewController.view 上会**伸到 PiP 可见区外面**
//     （该 view 是含 chrome 的容器，比可见视频大）。v0.2 改为运行时选挂载层：
//     优先 _contentView（PGLayerHostView，真正的视频区域）→ _contentClippingView →
//     _containerView → 回退 contentVC.view，并把各候选的 class/frame 打进日志。
//   * 边条/按钮全部改到 layoutSubviews 里按**当前 bounds**重算，初始 frame 不再有意义
//     （v0.1 用 init 时的 bounds 布局，bounds 后变就错位 —— 截图里"伸出去"的另一诱因）。
//   * 新增设置面板（PreferenceLoader，plist-only bundle，无编译）：
//     启用 / 显示外框 / 显示按钮 / 外框宽度 / 底部高度 / 文件日志 / 调试日志。
//     所有 specifier 带 PostNotification=darwin 通知，翻开关立即热生效（无需 respring）。
//   * 新增文件日志（/var/mobile/Library/Logs/PiPBar.log，256KB 自动截断），
//     用户不用连电脑，Filza 直接翻 —— 与 MapAdKiller 的 FileLog 同思路。
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

static id pipPref(NSString *key) {
    return CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                     (__bridge CFStringRef)@"com.yxh41.pipbar");
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

@interface PIPFrameView : UIView
@property (nonatomic, copy) void (^onTap)(NSInteger tag);
@property (nonatomic, strong) UIView *topBar, *leftBar, *rightBar, *bottomBar;
@end

@implementation PIPFrameView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.clipsToBounds = NO;
        UIColor *bar = [UIColor colorWithWhite:0.10 alpha:1.0];
        self.topBar = [[UIView alloc] initWithFrame:CGRectZero];
        self.leftBar = [[UIView alloc] initWithFrame:CGRectZero];
        self.rightBar = [[UIView alloc] initWithFrame:CGRectZero];
        self.bottomBar = [[UIView alloc] initWithFrame:CGRectZero];
        for (UIView *b in [NSArray arrayWithObjects:self.topBar, self.leftBar,
                           self.rightBar, self.bottomBar, nil]) {
            b.backgroundColor = bar;
            [self addSubview:b];
        }
        [self addButtonWithTag:1 symbol:@"backward.end.fill"];
        [self addButtonWithTag:2 symbol:@"play.fill"];
        [self addButtonWithTag:3 symbol:@"forward.end.fill"];
        // 初始就是错位也无所谓 —— layoutSubviews 按当前 bounds 全量重算
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
        [b setImage:img forState:UIControlStateNormal];
    } else {
        // SF Symbol 名字漂移时的兜底：不至于是空按钮
        [b setTitle:(tag == 1 ? @"◀◀" : (tag == 2 ? @"▶" : @"▶▶")) forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:15.0];
    }
    [b addTarget:self action:@selector(buttonTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.bottomBar addSubview:b];
}

- (void)buttonTapped:(UIButton *)sender {
    if (self.onTap != nil) self.onTap(sender.tag);
}

// 全部按【当前 bounds + 当前偏好】重算 —— 偏好热更新也走这里（setNeedsLayout）
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = CGRectGetWidth(self.bounds);
    CGFloat h = CGRectGetHeight(self.bounds);
    CGFloat sw = gFrameW, bh = gBarH;
    if (w <= 0.0 || h <= 0.0) return;

    self.hidden = !gShowFrame;
    self.topBar.hidden = self.leftBar.hidden = self.rightBar.hidden = !gShowFrame;

    self.topBar.frame = CGRectMake(0, 0, w, sw);
    CGFloat midH = h - sw - bh;
    self.leftBar.frame = CGRectMake(0, sw, sw, midH > 0.0 ? midH : 0.0);
    self.rightBar.frame = CGRectMake(w - sw, sw, sw, midH > 0.0 ? midH : 0.0);
    self.bottomBar.frame = CGRectMake(0, h - bh, w, bh);

    // 三颗按钮均分在底部控制条：0.20 / 0.50 / 0.80 宽度处
    CGFloat xs[3] = {0.20, 0.50, 0.80};
    NSUInteger i = 0;
    for (UIView *v in self.bottomBar.subviews) {
        if (i > 2) break;
        v.hidden = !gShowButtons;
        v.center = CGPointMake(w * xs[i], bh / 2.0);
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
        if (depth < 3) {
            for (UIView *sv in [v.subviews reverseObjectEnumerator]) {
                [stack addObject:@[sv, @(depth + 1)]];
            }
        }
    }
    PIPLog(@"HIER %@:\n%@", where, [lines componentsJoinedByString:@"\n"]);
}

// 找「可见视频区域」：优先私有 ivar（KVC），逐个回退；把每个候选都打进日志
static UIView *pipPickHostView(UIViewController *content) {
    UIView *v = content.view;
    if (v == nil) return nil;
    NSArray<NSString *> *candidates = @[@"_contentView", @"_contentClippingView", @"_containerView"];
    for (NSString *name in candidates) {
        @try {
            id cand = [content valueForKey:name];
            if ([cand isKindOfClass:[UIView class]]) {
                UIView *cv = (UIView *)cand;
                PIPLog(@"HOST candidate %@ -> %@ frame=%@",
                       name, NSStringFromClass(cv.class), NSStringFromCGRect(cv.frame));
                if (CGRectGetWidth(cv.bounds) > 1.0) return cv;
            }
        } @catch (NSException *e) {
            PIPLog(@"HOST candidate %@ 不可用: %@", name, e.name);
        }
    }
    PIPLog(@"HOST fallback -> contentViewController.view");
    return v;
}

#pragma mark - 偏好热生效

static PIPFrameView *gInstalledFrame = nil;   // 弱需求：同一时刻只有一个 PiP 实例，直接强引用可接受
static NSString *gInstalledHostDesc = nil;

static void pipApplyFrameState(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        PIPFrameView *f = gInstalledFrame;
        if (f == nil) return;
        f.hidden = !gEnabled || !gShowFrame;
        for (UIView *v in f.bottomBar.subviews) v.hidden = !gShowButtons;
        [f setNeedsLayout];
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

%end

%ctor {
    pipReadPrefs();
    %init;
    // 设置面板翻任何开关都会 post 这个 darwin 通知 → 立即重读偏好并热更新外框（无需 respring）
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        pipDarwinCallback, CFSTR(PIP_NOTIFY), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
    PIPLog(@"loaded for SpringBoard | build=" PIP_BUILD_TAG
           " enabled=%d frame=%d buttons=%d w=%.0f barh=%.0f filelog=%d",
           gEnabled, gShowFrame, gShowButtons, (double)gFrameW, (double)gBarH, gFileLog);
}
