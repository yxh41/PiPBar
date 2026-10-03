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
#import <dlfcn.h>

#define PIP_BUILD_TAG @"v0.24"
#define PIP_NOTIFY "com.yxh41.pipbar.reload"
#define PIP_NOTIFY_S @"com.yxh41.pipbar.reload"

// —— 偏好（CFPreferences 直读全局 plist；SpringBoard 以 mobile 身份运行，无容器隔离坑）——
static BOOL gEnabled = YES;
static BOOL gShowFrame = YES;
static BOOL gFileLog = YES;       // 默认开：日志是排障生命线，别让用户摸黑
static BOOL gDebugLog = NO;
static CGFloat gFrameW = 8.0;     // 顶/左右边框宽（用户反馈 12 太粗 → 默认 8）
static CGFloat gBarH = 40.0;      // 底部控制条高
static BOOL gExtendHit = YES;        // 扩展命中区：让壳外/底部黑边也能接收触摸（按钮放黑边的前提）
static BOOL gShowBarProgress = YES;  // 显示底部可拖动进度条
static BOOL gFreePending = NO;       // FreeMove 偏好暂存（gFreeMove 声明在后面）

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
    if ((v = pipPref(@"FileLog")) != nil) gFileLog = [v boolValue];
    if ((v = pipPref(@"DebugLog")) != nil) gDebugLog = [v boolValue];
    if ((v = pipPref(@"ExtendHit")) != nil) gExtendHit = [v boolValue];
    if ((v = pipPref(@"ShowProgress")) != nil) gShowBarProgress = [v boolValue];
    // gFreeMove 声明在后面（与 FreePIP 手势实现放在一起），故在 pipApplyFrameState 前补读
    if ((v = pipPref(@"FreeMove")) != nil) gFreePending = [v boolValue];
    if ((v = pipPref(@"FrameWidth")) != nil) {
        CGFloat f = [v floatValue];
        // v0.18：下限由 2 放宽到 0（0 = 不显示顶/左右边框）。
        // 此前硬编码 f >= 2.0 会把用户拉到 0 的值直接丢弃，导致「调 0 了仍有边框」。
        if (f >= 0.0 && f <= 30.0) gFrameW = f;
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

@interface SBPIPInteractionController : NSObject
@end

@interface PGPictureInPictureViewController : UIViewController
- (void)handleCommand:(id)arg1;
@end

static BOOL gPlaying = YES;   // 最近一次已知的播放状态

// content VC 弱引用：loadView 时几何还全是 0（host 会回退成全屏 content.view），
// 每次布局时重解析真正的视频宿主。切歌校验的回退分支也要用它，故声明在此处。
static __weak UIViewController *gContentVC = nil;
static __weak id gPegasusVC = nil;     // PGPictureInPictureViewController 实例（loadView 捕获），用于发 Pegasus 命令（skipByInterval 等）

#pragma mark - MediaRemote 切歌通道（kMRNextTrack / kMRPreviousTrack）

// 为什么需要它：系统画中画（Pegasus）只提供 skipByInterval / skipToLive / skipPreroll，
// 30 个命令工厂里**没有 track/next/previous**（真机 PGCMD-META 实锤）——所以画中画自己
// 切不了歌。但锁屏的「上/下一曲」按钮走的是 mediaserverd 的 MediaRemote 通道，
// 那里有 kMRNextTrack(4) / kMRPreviousTrack(5)，由系统路由到 App 的
// MPRemoteCommandCenter nextTrack/previousTrack handler —— 走这条能真正切歌。
// 私有框架运行时 dlopen + dlsym 取函数指针（不链接符号，跨版本安全）。
// 常量出处：Cykey/ios-reversed-headers · MediaRemote/MediaRemote.h
static void *gMRLib = NULL;                                   // NULL=未试；-1=试过失败
static Boolean (*gMRSendCommand)(int, id) = NULL;
static void (*gMRGetNowPlayingInfo)(dispatch_queue_t, void (^)(CFDictionaryRef)) = NULL;
static void (*gMRKeepAlive)(void) = NULL;
static void (*gMRGetAppPID)(dispatch_queue_t, void (^)(int)) = NULL;
static void (*gMRSetElapsedTime)(double) = NULL;   // ★ 拖动进度条：官方 seek 接口
static BOOL (*gMRGetPlaybackSpeed)(void) = NULL;

// 能力判据
static BOOL gMRIsMusicApp = NO;      // kMRMediaRemoteNowPlayingInfoIsMusicApp
static BOOL gMRHasPlaylist = NO;     // TotalTrackCount > 1
static BOOL gMRProhibitsSkip = NO;   // kMRMediaRemoteNowPlayingInfoProhibitsSkip（DRM 禁止跳）
static NSString *gMRTitle = nil;
static NSString *gMRUniqueID = nil; // 用于切歌后校验是否真的换了条目
static int gMRAppPID = 0;            // MediaRemote 当前 NowPlaying 客户端的 pid（>0 = 系统认得这个 App）
static double gMRQueryAt = 0;
static NSString *gMRLastKeys = nil;  // 上次打印的 now playing 键集（变化时才打日志）
// v0.15 进度条状态：MediaRemote 每秒回报进度（实测抖音 keys 里带 Duration/ElapsedTime）
static double gMRDuration = 0;       // 总时长（秒）；0 = 未知/直播流 ⇒ 隐藏进度条
static double gMRElapsed = 0;        // 当前进度（秒）
static double gMRUpdatedAt = 0;      // 上次更新的墙上时间（用于线性外推，避免每秒跳一下）
static double gMRRate = 0;           // playbackRate（1=播放中 0=暂停）
static BOOL gSeekBusy = NO;          // 拖动/seek 进行中：暂停外推，别跟用户抢进度
static double gDragTargetSec = 0;    // 拖动中的目标秒数
static double gSeekGraceUntil = 0;   // 松手宽限期（墙上时间）：期内 gSeekBusy 保持，心跳不覆盖进度

// v0.12：切歌「试探 → 校验 → 回退」状态机

static NSString *const kMRKeyIsMusicApp   = @"kMRMediaRemoteNowPlayingInfoIsMusicApp";
static NSString *const kMRKeyTotalTracks  = @"kMRMediaRemoteNowPlayingInfoTotalTrackCount";
static NSString *const kMRKeyProhibitsSkip = @"kMRMediaRemoteNowPlayingInfoProhibitsSkip";
static NSString *const kMRKeyTitle        = @"kMRMediaRemoteNowPlayingInfoTitle";
static NSString *const kMRKeyUniqueID     = @"kMRMediaRemoteNowPlayingInfoUniqueIdentifier";
static NSString *const kMRKeyContentItem  = @"kMRMediaRemoteNowPlayingInfoContentItemIdentifier";
static NSString *const kMRKeyDuration     = @"kMRMediaRemoteNowPlayingInfoDuration";
static NSString *const kMRKeyElapsed      = @"kMRMediaRemoteNowPlayingInfoElapsedTime";
static NSString *const kMRKeyRate         = @"kMRMediaRemoteNowPlayingInfoPlaybackRate";

static void pipEnsureMediaRemote(void) {
    if (gMRLib != NULL) return;   // 已加载或已标记失败
    gMRLib = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
                    RTLD_LAZY);
    if (gMRLib == NULL) {
        PIPLog(@"MR dlopen 失败: %s", dlerror() ?: "(null)");
        gMRLib = (void *)-1;       // 标记失败，不再重试
        return;
    }
    gMRSendCommand =
        (Boolean (*)(int, id))dlsym(gMRLib, "MRMediaRemoteSendCommand");
    gMRGetNowPlayingInfo =
        (void (*)(dispatch_queue_t, void (^)(CFDictionaryRef)))dlsym(gMRLib, "MRMediaRemoteGetNowPlayingInfo");
    // ⚠️ 真机实测 iOS 16.4.1 上 MRMediaRemoteKeepAlive 的 dlsym 返回 NULL（符号已不可用）。
    // 所以不能依赖它：探测不到就探测不到，改由「强制切歌」档让用户自行验证 App 是否支持。
    gMRKeepAlive = (void (*)(void))dlsym(gMRLib, "MRMediaRemoteKeepAlive");
    if (gMRKeepAlive != NULL) gMRKeepAlive();
    gMRGetAppPID = (void (*)(dispatch_queue_t, void (^)(int)))dlsym(gMRLib, "MRMediaRemoteGetNowPlayingApplicationPID");
    // v0.15：拖动进度条所需的两个符号（★ 官方 seek 接口，能真正定位播放位置）
    gMRSetElapsedTime = (void (*)(double))dlsym(gMRLib, "MRMediaRemoteSetElapsedTime");
    gMRGetPlaybackSpeed = (BOOL (*)(void))dlsym(gMRLib, "MRMediaRemoteGetNowPlayingApplicationPlaybackState");
    PIPLog(@"MR loaded: send=%p getInfo=%p keepAlive=%p getPID=%p\n"
           "        seek(setElapsedTime)=%p getPlaybackState=%p（keepAlive=0x0 属 iOS 16 正常）",
           (void *)gMRSendCommand, (void *)gMRGetNowPlayingInfo,
           (void *)gMRKeepAlive, (void *)gMRGetAppPID,
           (void *)gMRSetElapsedTime, (void *)gMRGetPlaybackSpeed);
}

// 拉一次 NowPlaying 信息（异步；只取需要的几个标量，不持有 CFDictionary ⇒ 无所有权坑）
static void pipMRRefresh(void) {
    if (gMRGetNowPlayingInfo == NULL) return;
    double now = [[NSDate date] timeIntervalSinceReferenceDate];
    if (now - gMRQueryAt < 2.0) return;   // 2 秒一次足够，拖动时也别刷爆 mediaserverd
    gMRQueryAt = now;

    if (gMRGetAppPID != NULL) {
        gMRGetAppPID(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(int pid) {
            dispatch_async(dispatch_get_main_queue(), ^{ gMRAppPID = pid; });
        });
    }

    gMRGetNowPlayingInfo(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                         ^(CFDictionaryRef info) {
        BOOL music = NO, hasList = NO, prohibit = NO;
        NSString *title = nil, *uid = nil;
        NSString *keys = nil;
        double dur = 0, ela = 0, rate = 0;
        if (info != NULL) {
            NSDictionary *d = (__bridge NSDictionary *)info;
            music    = [d[kMRKeyIsMusicApp] boolValue];
            hasList  = [d[kMRKeyTotalTracks] doubleValue] > 1.0;
            prohibit = [d[kMRKeyProhibitsSkip] boolValue];
            title    = d[kMRKeyTitle];
            // 短视频类 App（抖音等）没有 UniqueIdentifier，但有 ContentItemIdentifier ——
            // 校验切歌是否生效时它才是可靠的「条目身份」标识。
            uid      = d[kMRKeyUniqueID] ?: d[kMRKeyContentItem];
            keys     = [d.allKeys componentsJoinedByString:@","];
            // v0.15：进度条数据源（实测抖音 keys 里确实带这三个）
            dur      = [d[kMRKeyDuration] doubleValue];
            ela      = [d[kMRKeyElapsed] doubleValue];
            rate     = [d[kMRKeyRate] doubleValue];
        }
        NSString *kt = keys, *ti = title, *ui = uid;   // block 捕获（ARC 强引用）
        dispatch_async(dispatch_get_main_queue(), ^{
            gMRIsMusicApp = music; gMRHasPlaylist = hasList;
            gMRProhibitsSkip = prohibit; gMRTitle = ti; gMRUniqueID = ui;
            if (!gSeekBusy) {           // 用户正在拖进度条 ⇒ 不覆盖，避免回跳
                gMRDuration = dur; gMRElapsed = ela; gMRRate = rate;
                gMRUpdatedAt = [[NSDate date] timeIntervalSinceReferenceDate];
                // 进度条由心跳每帧 pipRefreshProgress 更新（它会读上面这几个全局量），
                // 这里不碰 UI —— gInstalledFrame 在本函数之后才声明，不能在此引用。
            }
            // v0.12：首次拿到（或变化时）打印原始键集 + pid —— 用来判定
            // 「MediaRemote 到底看不看得见这个 App」这个根本问题
            // ⚠️ 判重必须用 isEqualToString:（两侧都给非 nil），否则 keys 为 nil 时
            // [nil isEqualToString:] 返回 NO ⇒ 判重永远失效 ⇒ 每 2 秒刷屏（曾刷出 3.4MB 日志）
            if (![kt ?: @"" isEqualToString:(gMRLastKeys ?: @"")]) {
                gMRLastKeys = kt;
                PIPLog(@"MR info: pid=%d music=%d list=%d prohibit=%d dur=%.1f ela=%.1f rate=%.2f title=%@ uid=%@ keys={%@}",
                       gMRAppPID, music, hasList, prohibit, dur, ela, rate,
                       ti ?: @"-", ui ?: @"-", kt ?: @"(空)");
            }
        });
    });
}

// v0.16 注：原先的 pipMRCanTrackSkip / pipSendTrackSkip / pipVerifyTrackSkip
// （切歌试探与回退状态机）已随「移除三颗按钮」一并删除 —— 实测短视频类 App 不实现
// nextTrack handler，切歌能力不具备，保留即为死代码。

#pragma mark - 外框 + 按钮条

@interface PIPFrameView : UIView <UIGestureRecognizerDelegate>
@property (nonatomic, strong) CAShapeLayer *caseLayer;
@property (nonatomic, strong) CAShapeLayer *edgeLayer;
@property (nonatomic, strong) CAShapeLayer *barLayer;
// v0.15 进度条：轨道 / 已播放 / 拖动拇指 / 时间标签 / 拖动手势
@property (nonatomic, strong) CAShapeLayer *trackLayer;
@property (nonatomic, strong) CAShapeLayer *fillLayer;
@property (nonatomic, strong) CALayer *thumbLayer;
@property (nonatomic, strong) UILabel *timeLabel;
@property (nonatomic, strong) UIPanGestureRecognizer *seekPan;
@property (nonatomic, strong) UITapGestureRecognizer *seekTap;
// v0.23：自由态（解除吸附）专用关闭按钮 —— 自由态下整块视频被壳接管，
// 原生控制条（播放/还原/关闭）点不到，故在外框右上角加一个关闭入口。
@property (nonatomic, strong) UIButton *closeButton;
// v0.11：外框矩形（本壳坐标系，含底部黑边）—— 供 pointInside 扩展命中区用
@property (nonatomic, assign) CGRect hitRect;
// v0.15：拖动中（此时进度由手指决定，不被心跳覆盖）
@property (nonatomic, assign) BOOL seeking;
@property (nonatomic, assign) CGRect trackRect;
- (void)pipSelfHeal;
- (void)pipRefreshProgress;
@end

@class PIPFrameView;   // 前置声明：下面的文件级静态指针在 @interface 之前，需先告诉编译器类型
static UIView *pipPickHostView(UIViewController *content);   // 前向声明（layoutSubviews 里复用）

// 视频宿主（弱引用）：壳要「包在视频外面」，必须随时知道视频矩形在哪。
static __weak UIView *gVideoHost = nil;

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

// v0.16：FreePIP 式长按解吸 —— 系统 PiP 用 NSLayoutConstraint 把窗口钉在屏幕边缘，
// 拖动时会被"吸"回边缘。FreePIP（sohsatoh，GPL-3，此处仅参考机制、代码独立实现）
// 的做法是：长按切换 locked，用 CGAffineTransform 接管位移与缩放。
// 我们照此实现：长按视频区切换「吸附/自由」，自由态下可任意拖动、双指缩放。
static BOOL gFreeMove = NO;          // NO=系统吸附（默认） YES=自由摆放
static UIPanGestureRecognizer *gFreePan = nil;
static UIPinchGestureRecognizer *gFreePinch = nil;
static UILongPressGestureRecognizer *gFreeLongPress = nil;

// v0.17：系统 pan 手势是否要被我们吞掉。
// 根因（v0.16 真机反馈「拖进度条时画中画跟着动」）：v0.11 扩展了 hitRect 让窗口在
// 黑边区域可命中，而**挂在窗口/交互控制器上的 pan 手势同样会收到投递到子视图的触摸**
// ⇒ 我们在进度条上拖动时，系统仍在拖窗口。FreePIP 解决同一问题的办法就是 hook 掉
// handlePanGesture:（仅在需要时放行 %orig）。
static BOOL pipShouldBlockSystemPan(void) {
    if (gSeekBusy) return YES;   // 正在拖进度条 ⇒ 绝不能让系统拖窗口
    if (gFreeMove) return YES;   // 自由态由我们自己的 pan 负责
    return NO;
}

// 自由态的变换目标：必须是 PiP content view（PGHitTestExtendableView）而不是内层
// PGLayerHostView —— 内层由 Auto Layout 驱动、每帧重置，transform 写了也没用。
static UIView *pipFreeTransformTarget(void) {
    UIViewController *c = gContentVC;
    return c != nil ? c.view : nil;
}

// 消费暂存的 FreeMove 偏好（必须在 gFreeMove 声明之后调用）
static void pipApplyFreeMovePref(void) {
    if (gFreeMove == gFreePending) return;
    gFreeMove = gFreePending;
    if (gFreePan != nil) gFreePan.enabled = gFreeMove;
    if (gFreePinch != nil) gFreePinch.enabled = gFreeMove;
    if (gInstalledFrame != nil) gInstalledFrame.closeButton.hidden = !gFreeMove; // v0.23
    PIPLog(@"free-move %@（来自设置）", gFreeMove ? @"开" : @"关");
}

// —— 命中区扩展（v0.11）——
// 根因（v0.5 三按钮点不到、v0.9 按钮不敢放黑边的共同根因）：PiP 窗口的 hitTest
// 只在自己 bounds 内分发，壳画在窗口外的部分（顶部/侧边/底部黑边）虽然**能渲染**
// （clipsToBounds=NO），但**收不到触摸**。
// 破解：swizzle 画布（PGHitTestExtendableView）与 PiP 窗口（PGHostedWindow）的
// -pointInside:withEvent:，让「落在壳的外框矩形内」也算命中 —— 于是壳的 hitTest
// 能被调用到，按钮放在底部黑边也照样可点。只影响我们壳所占的那块区域，
// 其余区域一律走原实现（不劫持任何系统手势）。
static BOOL (*pipOrigPointInside)(id, SEL, CGPoint, UIEvent *) = NULL;
static Class gHitSwizzled[4];
static BOOL (*gHitOrig[4])(id, SEL, CGPoint, UIEvent *) = {NULL, NULL, NULL, NULL};
static int gHitSwizzleCount = 0;

static BOOL pipHitInsideFrame(id self, CGPoint point) {
    if (!gExtendHit) return NO;
    PIPFrameView *f = gInstalledFrame;
    if (f == nil || f.hidden || f.hitRect.size.width < 1.0) return NO;
    if (![f isDescendantOfView:(UIView *)self]) return NO;
    CGRect hr = [f convertRect:f.hitRect toView:(UIView *)self];
    return CGRectContainsPoint(hr, point);
}

// 取该对象应走的原实现（按类精确匹配，继承来的用 UIView 的）
static BOOL (*pipOrigForObject(id obj))(id, SEL, CGPoint, UIEvent *) {
    Class c = object_getClass(obj);
    for (int i = 0; i < gHitSwizzleCount; i++) {
        if (gHitSwizzled[i] == c && gHitOrig[i] != NULL) return gHitOrig[i];
    }
    return pipOrigPointInside;
}

static BOOL pipPIPPointInside(id self, SEL _cmd, CGPoint point, UIEvent *event) {
    BOOL (*orig)(id, SEL, CGPoint, UIEvent *) = pipOrigForObject(self);
    if (orig != NULL && orig(self, _cmd, point, event)) return YES;
    return pipHitInsideFrame(self, point);
}

// 注意：class_getInstanceMethod 对「未自身实现」的类会返回【继承来的】Method，
// 直接 method_setImplementation 会污染 UIView —— 故这里先判断是否自身实现：
//   自身实现 → method_setImplementation（保留原语义，存进 gHitOrig）
//   继承而来 → class_addMethod 覆盖一份（UIView 原实现保持不变）
static void pipSwizzlePointInsideOn(Class cls) {
    if (cls == Nil) return;
    for (int i = 0; i < gHitSwizzleCount; i++) {
        if (gHitSwizzled[i] == cls) return;
    }
    if (gHitSwizzleCount >= 4) return;

    SEL sel = @selector(pointInside:withEvent:);
    const char *types = "c@:@?";   // BOOL (self, _cmd, CGPoint, UIEvent*)
    BOOL own = NO;
    unsigned int n = 0;
    Method *ms = class_copyMethodList(cls, &n);
    for (unsigned int i = 0; i < n; i++) {
        if (sel_isEqual(method_getName(ms[i]), sel)) { own = YES; break; }
    }
    free(ms);

    if (own) {
        Method m = class_getInstanceMethod(cls, sel);
        gHitOrig[gHitSwizzleCount] = (BOOL (*)(id, SEL, CGPoint, UIEvent *))method_getImplementation(m);
        method_setImplementation(m, (IMP)pipPIPPointInside);
    } else {
        class_addMethod(cls, sel, (IMP)pipPIPPointInside, types);
        gHitOrig[gHitSwizzleCount] = NULL;   // 走 pipOrigPointInside（UIView 原实现）
    }
    gHitSwizzled[gHitSwizzleCount++] = cls;
    PIPLog(@"hit swizzle: %@（自身实现=%d）", NSStringFromClass(cls), own);
}

// 造型对齐参考图（安卓 PiP 同款）：黑色圆角「手机壳」**套在视频外面**——
//   视频矩形不动，壳画在容器层、向外扩：顶/左右 = gFrameW，底部 = gBarH。
// 实现：CAShapeLayer even-odd（外圈圆角矩形挖掉【视频矩形】这个洞）+ 内沿发丝高光 + 投影。
// 注意：shadowPath 必须只用外圈路径 —— v0.4 用带洞路径当 shadowPath，投影顺着洞
// 投进视频区，画面像蒙了层黑遮罩（v0.5 用户反馈实锤）。
// （@interface PIPFrameView 已上移到命中区 swizzle 之前声明）

// v0.16：三颗按钮已移除（实测抖音等短视频 App 不实现 nextTrack/previousTrack，
// 切歌不可用 ⇒ 改用系统自带控制条），故 play/pause 图标缓存函数一并移除。

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
        // v0.15 进度条：轨道（半透明细线）+ 已播放段（白色高亮）
        self.trackLayer = [CAShapeLayer layer];
        self.trackLayer.fillColor = [UIColor colorWithWhite:1.0 alpha:0.22].CGColor;
        self.trackLayer.masksToBounds = NO;
        [self.layer addSublayer:self.trackLayer];
        self.fillLayer = [CAShapeLayer layer];
        self.fillLayer.fillColor = [UIColor colorWithWhite:1.0 alpha:0.92].CGColor;
        self.fillLayer.masksToBounds = NO;
        [self.layer addSublayer:self.fillLayer];
        self.thumbLayer = [CALayer layer];
        self.thumbLayer.backgroundColor = UIColor.whiteColor.CGColor;
        self.thumbLayer.cornerRadius = 5.5;
        self.thumbLayer.hidden = YES;      // 平时隐藏，拖动/点按时才显示
        self.thumbLayer.masksToBounds = YES;
        [self.layer addSublayer:self.thumbLayer];
        // 时间标签：拖动时显示「1:23 / 5:07」
        self.timeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.timeLabel.font = [UIFont monospacedDigitSystemFontOfSize:11.0 weight:UIFontWeightMedium];
        self.timeLabel.textColor = UIColor.whiteColor;
        self.timeLabel.textAlignment = NSTextAlignmentCenter;
        self.timeLabel.hidden = YES;
        [self addSubview:self.timeLabel];
        // 拖动 / 点按手势（挂在壳上，靠 trackRect 判定是否落在进度条上）
        self.seekPan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                action:@selector(pipSeekGesture:)];
        self.seekTap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                action:@selector(pipSeekGesture:)];
        // v0.18：进度条手势优先级高于自由拖动 —— 自由态下整块视频都命中本壳，
        // 两个 pan 会互相抢（用户反馈「解除吸附后进度条就拖不动」）。
        // delegate 放行 seekPan、拦下 gFreePan，即可两者共存。
        self.seekPan.delegate = self;
        self.seekTap.delegate = self;
        [self addGestureRecognizer:self.seekPan];
        [self addGestureRecognizer:self.seekTap];

        // v0.16：FreePIP 式长按解吸 + 自由拖动 + 双指缩放
        gFreeLongPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                                        action:@selector(pipToggleFree:)];
        gFreeLongPress.minimumPressDuration = 0.45;
        gFreeLongPress.delegate = self;   // v0.22：长按后同指续拖需要 simultaneous 放行
        [self addGestureRecognizer:gFreeLongPress];
        gFreePan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pipFreePan:)];
        gFreePan.enabled = NO;    // 仅自由态启用，避免与系统 PiP 拖动打架
        gFreePan.delegate = self;
        [self addGestureRecognizer:gFreePan];
        gFreePinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(pipFreePinch:)];
        gFreePinch.enabled = NO;
        gFreePinch.delegate = self;
        [self addGestureRecognizer:gFreePinch];

        // v0.23：自由态关闭按钮（右上角）。默认隐藏，仅 gFreeMove 时显示。
        self.closeButton = [UIButton buttonWithType:UIButtonTypeCustom];
        [self.closeButton setTitle:@"✕" forState:UIControlStateNormal];
        self.closeButton.titleLabel.font = [UIFont systemFontOfSize:18.0 weight:UIFontWeightMedium];
        [self.closeButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        self.closeButton.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
        self.closeButton.layer.cornerRadius = 18.0;
        self.closeButton.clipsToBounds = YES;
        self.closeButton.hidden = YES;   // 仅自由态显示
        [self.closeButton addTarget:self action:@selector(pipCloseAction:)
                    forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:self.closeButton];

        // v0.16：三颗按钮已移除（切歌通道对短视频 App 无效，改用系统自带控制条）
        [self setNeedsLayout];
    }
    return self;
}



// 整层透明铺在容器上：只有摸到按钮/进度条才接管，其余穿透（保住 PiP 原生拖动/单击/双击手势）
// v0.16 自由摆放态例外：此时壳必须接收视频区的拖动/长按/双指，否则无法移动窗口。
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self) {
        if (gFreeMove) return self;      // 自由态：接管视频区手势
        // v0.15：进度条命中区（trackRect 上下各扩 12pt 方便手指点中）也算命中，
        // 否则会被上面的「穿透」逻辑吞掉，拖不动。
        if (CGRectGetWidth(self.trackRect) > 1.0) {
            CGRect hot = CGRectInset(self.trackRect, 0, -12.0);
            if (CGRectContainsPoint(hot, point)) return self;
        }
        return nil;
    }
    return hit;
}

// v0.11：本壳画到窗口外（底部黑边）的那部分默认收不到触摸 —— 这里把 hitRect
// 也算作命中，使「壳的 hitTest 能被调用到」，按钮放黑边才可点。
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if ([super pointInside:point withEvent:event]) return YES;
    if (self.hidden || self.hitRect.size.width < 1.0) return NO;
    return CGRectContainsPoint(self.hitRect, point);
}

// 自愈：安装瞬间父 bounds 可能是 0，autoresize 救不回来 —— 每次布局先对齐父 bounds
- (void)pipSelfHeal {
    UIView *sup = self.superview;
    if (sup != nil && CGRectGetWidth(sup.bounds) > 1.0 && CGRectGetHeight(sup.bounds) > 1.0
        && !CGRectEqualToRect(self.frame, sup.bounds)) {
        self.frame = sup.bounds;   // 触发下一轮 layoutSubviews，届时已相等，不会死循环
    }
}

#pragma mark - v0.22 手势仲裁（按落点分家）

// v0.22 修复：v0.18 的仲裁把 gFreePan/gFreePinch **无条件 return NO** —— 自由拖动
// 从 v0.18 起就是死的；而自由态下系统 pan 又被 pipShouldBlockSystemPan 拦掉，
// 结果长按解吸后窗口谁都拖不动（真机日志 system pan blocked 刷屏数百行）。
// 新规则：进度条热区内归进度条，热区外归自由拖动，互不侵占。
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gr {
    if (gr == gFreeLongPress) return YES;
    if (gr == self.seekPan || gr == self.seekTap) {
        // 进度条手势只在热区内参与；热区外拒绝 begin，把手势位让出来
        if (CGRectGetWidth(self.trackRect) > 1.0) {
            CGRect hot = CGRectInset(self.trackRect, -8.0, -20.0);
            return CGRectContainsPoint(hot, [gr locationInView:self]);
        }
        return NO;
    }
    if (gr == gFreePan) {
        // 热区内让给进度条（避免「拖进度条窗口跟着跑」），其余放行
        if (CGRectGetWidth(self.trackRect) > 1.0) {
            CGRect hot = CGRectInset(self.trackRect, -8.0, -20.0);
            if (CGRectContainsPoint(hot, [gr locationInView:self])) return NO;
        }
        return YES;
    }
    if (gr == gFreePinch) return YES;
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

#pragma mark - v0.16 FreePIP 式长按解吸

// 长按视频区：切换「系统吸附」↔「自由摆放」
- (void)pipToggleFree:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    gFreeMove = !gFreeMove;
    gFreePan.enabled = gFreeMove;
    gFreePinch.enabled = gFreeMove;
    self.closeButton.hidden = !gFreeMove;   // v0.23：仅自由态显示关闭按钮
    [self pipLayoutCloseButton];            // 立即定位，避免依赖 layoutSubviews 时机导致不出现
    // 自由态需要能接到拖动 ⇒ hitTest 必须放行视频区
    self.userInteractionEnabled = YES;
    [self setNeedsLayout];
    [gInstalledFrame setNeedsLayout];
    PIPLog(@"free-move %@（长按切换；%@）", gFreeMove ? @"开：可自由拖动/双指缩放" : @"关：交回系统吸附",
           gFreeMove ? @"再长按恢复吸附" : @"长按可随时解除吸附");
}

// v0.23：关闭按钮动作。自由态下原生控制条被壳挡住点不到，故这里直接关掉 PiP。
- (void)pipCloseAction:(id)sender {
    // 先退出自由态（顺手把原生控制条释放出来，万一 PiP 没关成功还能手动关）
    gFreeMove = NO;
    if (gFreePan != nil) gFreePan.enabled = NO;
    if (gFreePinch != nil) gFreePinch.enabled = NO;
    self.closeButton.hidden = YES;
    [self setNeedsLayout];
    PIPLog(@"close button tapped → 关闭画中画");
    pipStopPiP();
}

// v0.23：关闭 PiP —— 多候选 selector 降级，覆盖 iOS 版本差异。
// SBPIPController（SpringBoard 私有的 PiP 服务）与 contentVC 上逐个尝试，
// 第一个 respondsToSelector 的就调用；都不认则只打日志，不崩。
static void pipStopPiP(void) {
    NSArray *sels = @[@"invalidatePictureInPicture",
                     @"stopPictureInPicture",
                     @"_stopPictureInPicture",
                     @"_dismissPictureInPicture",
                     @"cancelPictureInPicture",
                     @"dismissPictureInPicture"];
    NSMutableArray *objs = [NSMutableArray array];
    Class ctl = objc_getClass("SBPIPController");
    if (ctl != nil && [ctl respondsToSelector:@selector(sharedInstance)]) {
        // 用 objc_msgSend 强转，规避 -Warc-performSelector-leaks（动态 selector 编译器未知返回值）
        id (*getInst)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        id inst = getInst(ctl, @selector(sharedInstance));
        if (inst != nil) [objs addObject:inst];
    }
    if (gContentVC != nil) [objs addObject:gContentVC];
    void (*sendMsg)(id, SEL) = (void (*)(id, SEL))objc_msgSend;
    for (id o in objs) {
        for (NSString *name in sels) {
            SEL s = NSSelectorFromString(name);
            if ([o respondsToSelector:s]) {
                sendMsg(o, s);
                PIPLog(@"close PiP via [%@ %@]", NSStringFromClass([o class]), name);
                return;
            }
        }
    }
    PIPLog(@"close PiP：候选 selector 均未响应（iOS 版本漂移？）");
}

// 自由态拖动：把位移量累加到 PiP content view 的 transform 上。
// ⚠️ v0.17 修正：v0.16 加在内层 gVideoHost(PGLayerHostView) 上完全无效 ——
// 该层由 Auto Layout 驱动、每帧被重置，transform 写了立刻被抹掉（用户反馈「长按无效」）。
// FreePIP 的原始做法正是加在 pictureInPictureViewController.view 这一层。
- (void)pipFreePan:(UIPanGestureRecognizer *)gr {
    UIView *target = pipFreeTransformTarget();
    if (!gFreeMove || target == nil) return;
    CGPoint t = [gr translationInView:target.superview];
    [gr setTranslation:CGPointZero inView:target.superview];
    target.transform = CGAffineTransformTranslate(target.transform, t.x, t.y);
}

// 自由态缩放：以 PiP content view 自身中心缩放（clamp 0.5x ~ 2.5x，避免缩到看不见）
- (void)pipFreePinch:(UIPinchGestureRecognizer *)gr {
    UIView *target = pipFreeTransformTarget();
    if (!gFreeMove || target == nil) return;
    CGFloat s = gr.scale;
    gr.scale = 1.0;
    CGAffineTransform cur = target.transform;
    CGFloat curScale = sqrt(cur.a * cur.a + cur.c * cur.c);
    if (curScale < 0.01) curScale = 1.0;
    CGFloat next = MAX(0.5, MIN(2.5, curScale * s));
    CGFloat factor = next / curScale;
    target.transform = CGAffineTransformScale(cur, factor, factor);
}

#pragma mark - v0.15 进度条

// 秒 → mm:ss
static NSString *pipTimeText(double sec) {
    if (sec < 0 || sec != sec) return @"--:--";
    NSInteger s = (NSInteger)sec;
    if (s >= 3600) {
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld",
                (long)(s / 3600), (long)((s % 3600) / 60), (long)(s % 60)];
    }
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(s / 60), (long)(s % 60)];
}

// 当前应显示的进度秒数：拖动中由手指决定；否则用上报值 + 线性外推（避免每秒跳一格）
- (double)pipCurrentSeconds {
    if (self.seeking) return CGRectGetWidth(self.trackRect) > 0 ? gDragTargetSec : 0;
    if (gMRDuration <= 0) return 0;
    double e = gMRElapsed;
    if (gMRRate > 0.05 && gMRUpdatedAt > 0) {
        e += ([[NSDate date] timeIntervalSinceReferenceDate] - gMRUpdatedAt) * gMRRate;
    }
    if (e < 0) e = 0;
    if (e > gMRDuration) e = gMRDuration;
    return e;
}

// 只更新进度条三件套（不触发布局，放在心跳里每帧跑也便宜）
- (void)pipRefreshProgress {
    // 松手宽限：gSeekBusy 在宽限期内保持 YES，心跳不会用「旧上报进度」覆盖用户刚拖到的位置
    // （避免「松手瞬间被旧进度拽回」——尤其在 App 对后退 seek 响应慢/不响应时最明显）。
    if (gSeekBusy && [[NSDate date] timeIntervalSinceReferenceDate] > gSeekGraceUntil) {
        gSeekBusy = NO;
    }
    // v0.23：关闭按钮位置每帧跟随视频矩形（不依赖 layoutSubviews 时机，确保解除吸附立即出现）
    if (!self.closeButton.hidden) [self pipLayoutCloseButton];
    BOOL haveDur = (gMRDuration > 1.0);
    // ⚠️ v0.15 真机修复：首帧 layoutSubviews 时 gMRDuration 还是 0 ⇒ trackRect 被置零；
    // 之后 MediaRemote 探到时长（dur=23.3）也不再触发布局 ⇒ 进度条永远不显示。
    // 这里做懒初始化：数据到位后主动补一次布局。
    if (haveDur && CGRectGetWidth(self.trackRect) < 1.0) {
        [self setNeedsLayout];
    }
    BOOL show = haveDur && !gExpandedUI && gEnabled && gShowBarProgress;
    self.trackLayer.hidden = !show;
    self.fillLayer.hidden = !show;
    if (!show) {
        self.thumbLayer.hidden = YES;
        self.timeLabel.hidden = YES;
        return;
    }
    CGFloat w = CGRectGetWidth(self.trackRect);
    if (w < 1.0) return;

    double cur = [self pipCurrentSeconds];
    CGFloat ratio = (CGFloat)(cur / gMRDuration);
    if (ratio < 0) ratio = 0;
    if (ratio > 1) ratio = 1;
    CGFloat fw = w * ratio;

    CGRect tr = self.trackRect;
    self.fillLayer.path =
        [UIBezierPath bezierPathWithRoundedRect:CGRectMake(tr.origin.x, tr.origin.y, fw, CGRectGetHeight(tr))
                                    cornerRadius:CGRectGetHeight(tr) / 2.0].CGPath;
    // 拇指：拖动/点按时才显示
    self.thumbLayer.hidden = !self.seeking;
    if (self.seeking) {
        CGFloat d = 11.0;
        self.thumbLayer.frame = CGRectMake(tr.origin.x + fw - d / 2.0,
                                           CGRectGetMidY(tr) - d / 2.0, d, d);
    }
    // 时间标签：拖动时显示在进度条上方
    self.timeLabel.hidden = !self.seeking;
    if (self.seeking) {
        self.timeLabel.text = [NSString stringWithFormat:@"%@ / %@",
                               pipTimeText(cur), pipTimeText(gMRDuration)];
        CGSize sz = [self.timeLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
        CGFloat tw = MAX(sz.width + 12.0, 74.0), th = 18.0;
        CGFloat tx = CGRectGetMinX(tr) + fw - tw / 2.0;
        tx = MAX(CGRectGetMinX(tr) - 14.0, MIN(tx, CGRectGetMaxX(tr) + 14.0 - tw));
        self.timeLabel.frame = CGRectMake(tx, CGRectGetMinY(tr) - th - 4.0, tw, th);
    }
}

// 拖动/点按 → 计算目标秒数 → 拖动中实时显示，松手才真正 seek
- (void)pipSeekGesture:(UIGestureRecognizer *)gr {
    CGFloat w = CGRectGetWidth(self.trackRect);
    if (w < 1.0 || gMRDuration <= 0) return;
    CGPoint p = [gr locationInView:self];
    // v0.20：热区从 ±14pt 放宽到 **±20pt**。进度条本身只有 3pt 高，
    // 原热区虽加了 14pt 上下，但用户反馈「很难拉动」—— 手指按不准 3pt 细线。
    // 进度条位于底部黑边内，±20pt 不会侵入视频画面区。
    CGRect hot = CGRectInset(self.trackRect, -8.0, -20.0);
    if (!CGRectContainsPoint(hot, p)) return;

    if (gr.state == UIGestureRecognizerStateBegan) {
        self.seeking = YES;
        gSeekBusy = YES;
        [self pipRefreshProgress];       // 先显示拇指/时间标签
    }
    if (gr.state == UIGestureRecognizerStateEnded
        || gr.state == UIGestureRecognizerStateCancelled
        || gr.state == UIGestureRecognizerStateFailed) {
        if (self.seeking) {
            double target = gDragTargetSec;
            double cur = gMRElapsed;   // 松手瞬间当前播放位置
            if (target < cur - 0.5) {
                // v0.24：后退 seek —— 部分 App 不响应后退方向的 MRMediaRemoteSetElapsedTime，
                // 改用 Pegasus 原生 skipByInterval（负间隔，与系统「快退」同机制）后退到目标位。
                [self pipSeekBackByInterval:(target - cur)];
                PIPLog(@"seek(back) -> target=%.2fs / %.2fs（%.0f%%）",
                       target, gMRDuration, gMRDuration > 0 ? target / gMRDuration * 100.0 : 0);
            } else {
                // 前进 / 不动：官方 SetElapsedTime（已验证可用）
                if (gMRSetElapsedTime != NULL) {
                    gMRSetElapsedTime(target);
                    PIPLog(@"seek -> elapsed=%.2fs / %.2fs（%.0f%%）",
                           target, gMRDuration, gMRDuration > 0 ? target / gMRDuration * 100.0 : 0);
                } else {
                    PIPLog(@"MRMediaRemoteSetElapsedTime 不可用，无法 seek");
                }
            }
            gMRElapsed = target;   // 立即本地校准，避免拉回旧位置
            gMRUpdatedAt = [[NSDate date] timeIntervalSinceReferenceDate];
        }
        self.seeking = NO;
        // 进入宽限期：gSeekBusy 保持，心跳暂不覆盖进度（给 App 处理 seek 的时间，避免松手被旧进度拽回）
        gSeekGraceUntil = [[NSDate date] timeIntervalSinceReferenceDate] + 1.2;
        [self pipRefreshProgress];
        return;
    }

    // 拖动中：x → ratio → 秒
    CGFloat r = (p.x - CGRectGetMinX(self.trackRect)) / w;
    if (r < 0) r = 0;
    if (r > 1) r = 1;
    gDragTargetSec = r * gMRDuration;
    [self pipRefreshProgress];
}

// v0.23：关闭按钮布局（集中一处，layoutSubviews / pipRefreshProgress / pipToggleFree 都会调）
// 用 gVideoHost 把视频矩形换算到本画布坐标，钉在右上角 8pt 内；自由态 hitTest 会先命中它。
- (void)pipLayoutCloseButton {
    if (self.closeButton == nil || self.closeButton.hidden) return;
    UIView *host = gVideoHost;
    if (host == nil || host.window == nil) return;
    CGRect vr = [host convertRect:host.bounds toView:self];
    CGFloat vrW = CGRectGetWidth(vr), vrH = CGRectGetHeight(vr);
    if (vrW < 8.0 || vrH < 8.0) return;
    CGFloat bs = 36.0;
    self.closeButton.frame = CGRectMake(CGRectGetMaxX(vr) - bs - 8.0,
                                        CGRectGetMinY(vr) + 8.0, bs, bs);
    [self bringSubviewToFront:self.closeButton];
}

// v0.24：后退 seek 兜底 —— Pegasus 原生 skipByInterval（action=1，负间隔=后退）。
// 部分 App 对后退方向的 MRMediaRemoteSetElapsedTime 无响应，但系统「快退」按钮走的是
// 同一套 skipByInterval，故用它把进度退到目标位。运行时全部判空，缺任何环节即静默跳过。
- (void)pipSeekBackByInterval:(double)delta {
    if (delta >= 0) return;            // 仅处理后退（负间隔）
    Class pg = objc_getClass("PGCommand");
    if (pg == nil) { PIPLog(@"skipByInterval 兜底失败：PGCommand 类不存在"); return; }
    SEL factory = NSSelectorFromString(@"commandForPlaybackAction:associatedDoubleValue:");
    if (![pg respondsToSelector:factory]) { PIPLog(@"skipByInterval 兜底失败：factory 未响应"); return; }
    id vc = gPegasusVC;
    if (vc == nil || ![vc respondsToSelector:@selector(handleCommand:)]) {
        PIPLog(@"skipByInterval 兜底失败：PGPictureInPictureViewController 实例不可用"); return;
    }
    // commandForPlaybackAction:1(long long) associatedDoubleValue:delta(double)
    id (*mk)(id, SEL, long long, double) = (id (*)(id, SEL, long long, double))objc_msgSend;
    id cmd = mk(pg, factory, 1LL, (double)delta);
    if (cmd == nil) { PIPLog(@"skipByInterval 兜底失败：构造命令返回 nil"); return; }
    void (*hc)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
    hc(vc, @selector(handleCommand:), cmd);
    PIPLog(@"skipByInterval 兜底：后退 %.2fs（action=1）", delta);
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

    // v0.23：自由态关闭按钮 — 钉在视频右上角（外框内）。位置统一定在 pipLayoutCloseButton
    [self pipLayoutCloseButton];

    // v0.8：全屏判定收紧 —— 旧「>60% 屏宽」会把放大档 PiP（约 2/3~9/10 屏宽，
    // 用户截图实锤）误判成全屏而整壳隐藏。只有宽、高同时 ≈ 屏幕才算全屏播放。
    CGSize scr = [UIScreen mainScreen].bounds.size;
    gExpandedUI = vrW > scr.width * 0.95 && vrH > scr.height * 0.95;
    self.hidden = !gEnabled || (!gShowFrame && !gShowBarProgress) || gExpandedUI;

    CGRect outer = CGRectMake(CGRectGetMinX(vr) - sw, CGRectGetMinY(vr) - sw,
                              vrW + sw * 2.0, vrH + sw + bh);
    // 命中区 = 整个外框（含底部黑边）—— 供 pointInside 扩展用
    self.hitRect = outer;
    // 圆角：内洞贴视频自身圆角，外圈随边宽外扩
    CGFloat innerR = host.layer.cornerRadius;
    if (innerR < 2.0 || innerR > 40.0) innerR = 16.0;
    CGFloat outerR = innerR + sw;

    // sw==0（外框宽度拉到 0）时：顶/左右边框消失，但**底部黑边 + 进度条照常**。
    // v0.18 误用 `sw >= 0.5` 一刀切把整圈壳都关掉 ⇒ 用户反馈「外边框又没了」。
    // 正确做法：壳照常绘制（覆盖整个黑边区），只是向外扩的 sw=0 ⇒ 顶/左右无边框。
    BOOL wantCase = gShowFrame && !gExpandedUI;
    self.caseLayer.hidden = !wantCase;
    self.edgeLayer.hidden = !wantCase;
    if (wantCase && outer.size.width > 8.0 && outer.size.height > 8.0) {
        UIBezierPath *op = [UIBezierPath bezierPathWithRoundedRect:outer cornerRadius:outerR];
        UIBezierPath *ip = [UIBezierPath bezierPathWithRoundedRect:vr cornerRadius:innerR];
        [op appendPath:ip];   // even-odd：视频矩形挖空，画面原样透出
        self.caseLayer.path = op.CGPath;
        self.caseLayer.shadowPath = nil;   // v0.6：无投影（蒙灰根因已删）
        // sw==0 时不画内沿高光（否则 even-odd 外圈与内洞重合，边缘会留一圈发丝描边）
        self.edgeLayer.path = (sw >= 0.5) ? ip.CGPath : nil;
    } else {
        self.caseLayer.path = nil;
        self.edgeLayer.path = nil;
    }

    // —— 底部黑边（v0.16）：只放进度条，三颗按钮已移除（切歌不可用，改用系统控制条）——
    CGFloat inset = 8.0;
    CGFloat chin = MAX(bh, 22.0);
    BOOL showProg = gShowBarProgress && gMRDuration > 1.0 && gEnabled && !gExpandedUI;
    if (showProg) {
        // 进度条居中于黑边，横向近乎铺满；上下留出可点按的热区
        // v0.20：轨道由 3pt 加粗到 5pt（用户反馈「很难拉动」）—— 3pt 细线在
        // PiP 这种小尺寸下几乎点不准，加粗后肉眼可见、手指也容易命中。
        CGFloat trackH = 5.0;
        CGFloat ty = CGRectGetMaxY(vr) + chin / 2.0 - trackH / 2.0;
        self.trackRect = CGRectMake(CGRectGetMinX(vr) + inset, ty,
                                    vrW - inset * 2.0, trackH);
        self.trackLayer.path =
            [UIBezierPath bezierPathWithRoundedRect:self.trackRect
                                       cornerRadius:trackH / 2.0].CGPath;
    } else {
        self.trackRect = CGRectZero;
        self.trackLayer.path = nil;
    }
    self.barLayer.hidden = YES;   // 胶囊底衬随按钮一起退场
    [self pipRefreshProgress];

    // 按钮已移除：把残留的 UIButton 一并清掉（防御：老版本装过的话）
    for (UIView *v in self.subviews) {
        if ([v isKindOfClass:[UIButton class]]) [v removeFromSuperview];
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
    if (!gShowFrame && !gShowBarProgress) { gLastVR = (CGRect){{0,0},{0,0}}; return; }
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
    // v0.10：切歌能力探测（2 秒节流，内部已限频；只是读 mediaserverd 的 now playing 标量）
    pipEnsureMediaRemote();
    pipMRRefresh();
    // v0.15：每帧轻量刷新进度条（只改三个 layer 的 path/frame，不做布局，开销极小）
    [gInstalledFrame pipRefreshProgress];

    // v0.11：装壳时若还没进窗口（canvas.window == nil），这里补 swizzle PiP 窗口
    if (gExtendHit && gInstalledFrame != nil) {
        UIWindow *w = gInstalledFrame.window;
        if (w != nil) pipSwizzlePointInsideOn(w.class);
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
        PIPLog(@"reload applied: enabled=%d frame=%d progress=%d w=%.0f barh=%.0f",
               gEnabled, gShowFrame, gShowBarProgress, (double)gFrameW, (double)gBarH);
    });
}

static void pipDarwinCallback(CFNotificationCenterRef center, void *observer,
                              CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    pipReadPrefs();
    pipApplyFreeMovePref();   // 「长按解除吸附」开关热生效
    pipApplyFrameState();
}

#pragma mark - Hooks

// Pegasus 单独成组：Pegasus.framework 可能是懒加载的，跟 SBPIP 放在同一个默认组里，
// 一旦 ctor 时它还没进内存，整组 %init 会一起落空（SBPIP 也跟着不生效）。
static void pipInitPegasusOnce(void);

// iOS 14+ 的 PiP 拖动入口在 SBPIPInteractionController（FreePIP 也是 hook 这两个地方）
%hook SBPIPInteractionController

- (void)handlePanGesture:(UIPanGestureRecognizer *)sender {
    if (pipShouldBlockSystemPan()) { PIPLog(@"system pan blocked (drag/seek)"); return; }
    %orig;
}

%end

%hook SBPIPContainerViewController

// v0.17：吞掉系统的 PiP 拖动 pan。
// 背景：v0.11 扩展 hitRect 让窗口在底部黑边「可命中」后，挂在交互控制器上的 pan
// 手势会连同子视图（我们的壳）上的触摸一起收到 ⇒ 拖进度条时画中画跟着跑。
// FreePIP（sohsatoh）解决同一问题的做法就是在这里 %orig 前加条件放行。
- (void)_handlePanGesture:(UIPanGestureRecognizer *)sender {
    if (pipShouldBlockSystemPan()) { PIPLog(@"system pan blocked (drag/seek)"); return; }
    %orig;
}

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
        gPegasusVC = self;        // self 即 PGPictureInPictureViewController，发 Pegasus 命令用
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

        // v0.16：三颗按钮已移除（切歌不可用，改用系统控制条）；
        // 进度条与长按解吸都在 PIPFrameView 内部处理，无需外部 block。
        [canvas addSubview:frame];
        [canvas bringSubviewToFront:frame];
        gInstalledFrame = frame;
        pipEnsureSyncLink();   // v0.7：无卡顿心跳，保证 host 解析就绪后外框持续重画
        pipApplyFreeMovePref();   // v0.16：应用「长按解除吸附」初始偏好

        // v0.11：命中区扩展 —— 壳画在窗口外（底部黑边）也能收触摸，按钮才敢放黑边。
        // 捕获 UIView 的原始 pointInside 作为兜底原实现，再分别 swizzle 画布与 PiP 窗口。
        if (pipOrigPointInside == NULL) {
            Method um = class_getInstanceMethod([UIView class], @selector(pointInside:withEvent:));
            if (um != NULL) {
                pipOrigPointInside = (BOOL (*)(id, SEL, CGPoint, UIEvent *))method_getImplementation(um);
            }
        }
        pipSwizzlePointInsideOn(canvas.class);
        UIWindow *win = canvas.window;
        if (win != nil) {
            pipSwizzlePointInsideOn(win.class);
            PIPLog(@"hit canvas=%@ win=%@ winBounds=%@ winFrame=%@",
                   NSStringFromClass(canvas.class), NSStringFromClass(win.class),
                   NSStringFromCGRect(win.bounds), NSStringFromCGRect(win.frame));
        } else {
            PIPLog(@"hit canvas=%@ win=nil（尚未入窗口，稍后由 tick 补 swizzle）",
                   NSStringFromClass(canvas.class));
        }
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
                    // v0.17：按钮已移除，播放状态变化时不再需要刷新图标；
                    // 仅保留状态本身（供未来可能的 UI 使用）
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
           " enabled=%d frame=%d progress=%d w=%.0f barh=%.0f filelog=%d",
           gEnabled, gShowFrame, gShowBarProgress, (double)gFrameW, (double)gBarH, gFileLog);
}
