// PiPBar — 画中画增强（外框 + 底部控制条）
// 目标环境：iPhone 12 Pro / iOS 16.4.1 / roothide / arm64e
// 作用进程：SpringBoard（系统画中画的宿主）
//
// 机制路线（独立实现，仅参考 FreePIP 的公开机制结论，未复用其 GPL 代码）：
//   * 系统画中画由 SpringBoard 进程承载：
//       SBPIPContainerViewController（SpringBoard.framework）
//         └─ contentViewController = PGPictureInPictureViewController（Pegasus.framework）
//   * v0.1 范围：
//       a) 在 PiP 内容视图上叠一层「外框」：顶部/左右宽 kFrameSide，底部 kFrameBottom
//          放三颗按钮（上一曲 / 播放暂停 / 下一曲）——即安卓样式的 PiP 控制条；
//       b) 播放/暂停走 Pegasus 命令通道：PGCommand +commandForSetPlaying: →
//          PGPictureInPictureViewController handleCommand:（iOS 17 运行时头已确认存在）；
//       c) 内置嗅探日志：dump PiP 类的方法列表 + 打印系统控制命令的 playbackAction 值，
//          用真机日志定位「上一曲/下一曲」的 action 码，v0.2 再接通这两个按钮。
//
// 已知未知数（等真机日志校准，别拍脑袋改）：
//   * PGCommand playbackAction 枚举值（播放/暂停/快进快退确定存在，上一曲/下一曲待确认）
//   * 外框圆角与系统 PiP 圆角的对齐（iOS 17 头有 defaultContentCornerRadius，16.4.1 待验证）

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define PIP_BUILD_TAG @"v0.1"
#define PIPLog(fmt, ...) NSLog(@"[PiPBar " PIP_BUILD_TAG "] " fmt, ##__VA_ARGS__)

// —— 布局常量（真机验证后再调；改宽度只动这里）——
// 注：每个常量都必须真正被用到 —— -Werror 连「未使用的 const」都不放行（v0.1 第二次构建踩过）。
static const CGFloat kFrameSide = 12.0;    // 顶部 / 左右边框宽
static const CGFloat kFrameBottom = 40.0;  // 底部（按钮条）高

// —— Pegasus / SpringBoard 私有类（iOS 17 运行时头，16.4.1 待日志确认；全部判空防御）——
// 注意：这些声明不只是给编译器看的 —— %hook 展开后会直接向 self 发消息，
// 没有 @interface 就是 forward declaration，-Werror 下直接编译失败（v0.1 首构建踩过）。
@interface SBPIPContainerViewController : UIViewController
- (UIViewController *)contentViewController;
@end

@interface PGCommand : NSObject
+ (id)commandForSetPlaying:(BOOL)arg1;
- (long long)playbackAction;
- (NSDictionary *)dictionaryRepresentation;
@end

@interface PGPictureInPictureViewController : UIViewController
- (void)handleCommand:(id)arg1;
@end

static BOOL gPlaying = YES;   // 最近一次已知的播放状态（v0.1 用按钮自己翻转，够用）

#pragma mark - 外框 + 按钮条

@interface PIPFrameView : UIView
@property (nonatomic, copy) void (^onTap)(NSInteger tag);
@property (nonatomic, strong) UIView *bottomBar;
@end

@implementation PIPFrameView

// 造型（用户参考图：手机壳式外框）——
//   顶部 / 左右 = kFrameSide 细边，底部 = kFrameBottom 加宽放按钮；
//   中间镂空不遮视频，边条颜色深灰模拟壳。
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.clipsToBounds = NO;
        CGFloat w = CGRectGetWidth(frame);
        CGFloat h = CGRectGetHeight(frame);
        UIColor *bar = [UIColor colorWithWhite:0.10 alpha:1.0];

        UIView *top = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, kFrameSide)];
        top.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
        UIView *left = [[UIView alloc] initWithFrame:CGRectMake(0, kFrameSide, kFrameSide,
                                                                h - kFrameSide - kFrameBottom)];
        left.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleHeight;
        UIView *right = [[UIView alloc] initWithFrame:CGRectMake(w - kFrameSide, kFrameSide, kFrameSide,
                                                                 h - kFrameSide - kFrameBottom)];
        right.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleHeight;
        self.bottomBar = [[UIView alloc] initWithFrame:CGRectMake(0, h - kFrameBottom, w, kFrameBottom)];
        self.bottomBar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;

        for (UIView *b in [NSArray arrayWithObjects:top, left, right, self.bottomBar, nil]) {
            b.backgroundColor = bar;
            [self addSubview:b];
        }

        [self addButtonWithTag:1 symbol:@"backward.end.fill"];
        [self addButtonWithTag:2 symbol:@"play.fill"];
        [self addButtonWithTag:3 symbol:@"forward.end.fill"];
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

// 三颗按钮均分在底部控制条：0.20 / 0.50 / 0.80 宽度处
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat cy = CGRectGetHeight(self.bottomBar.bounds) / 2.0;
    CGFloat xs[3] = {0.20, 0.50, 0.80};
    NSUInteger i = 0;
    for (UIView *v in self.bottomBar.subviews) {
        if (i > 2) break;
        v.center = CGPointMake(CGRectGetWidth(self.bottomBar.bounds) * xs[i], cy);
        i++;
    }
}

@end

#pragma mark - 嗅探（日志驱动：v0.2 拿这份日志把上一曲/下一曲接通）

// dump 类上与「播放控制」相关的方法，只挑关键词，避免整包方法刷爆日志
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

#pragma mark - Hooks

%hook SBPIPContainerViewController

- (void)loadView {
    %orig;
    @try {
        UIViewController *content = nil;
        if ([self respondsToSelector:@selector(contentViewController)]) {
            content = [self contentViewController];
        }
        if (content == nil || content.view == nil) {
            PIPLog(@"loadView: contentViewController 不可用（iOS 版本漂移?）");
            return;
        }
        UIView *v = content.view;

        Class frameCls = objc_getClass("PIPFrameView");
        if (frameCls == nil) return;

        // 防重复安装（loadView 可能因重建被再次调用）
        for (UIView *sub in [v subviews]) {
            if ([sub isKindOfClass:frameCls]) {
                [sub removeFromSuperview];
                break;
            }
        }

        PIPFrameView *frame = [[frameCls alloc] initWithFrame:v.bounds];
        frame.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        __weak UIViewController *weakContent = content;
        frame.onTap = ^(NSInteger tag) {
            UIViewController *c = weakContent;
            if (c == nil) return;
            if (tag == 2) {
                // 播放/暂停：Pegasus 命令通道（iOS 17 头确认，16.4.1 真机验证中）
                // 注意：PGCommand 不能直接写 [PGCommand commandForSetPlaying:] ——
                // 那会产生链接期类符号 _OBJC_CLASS_$_PGCommand，而 Pegasus 不参与链接，
                // 直接 Undefined symbols（v0.1 第三次构建踩过）。必须运行时取类。
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
                // 上一曲(1) / 下一曲(3)：action 码待嗅探，v0.2 接通
                PIPLog(@"button tag=%ld — 等待嗅探结果（见 CMD/SNIFF 日志）", (long)tag);
            }
        };

        [v addSubview:frame];
        PIPLog(@"frame installed on %@ view=%@", NSStringFromClass(content.class),
               NSStringFromCGRect(v.bounds));

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
// 日志里就有对应的 playbackAction 值，这就是 v0.2 接上一曲/下一曲的依据。
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
    PIPLog(@"loaded for SpringBoard | build=" PIP_BUILD_TAG);
    %init;
}
