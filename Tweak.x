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

#define PIP_BUILD_TAG @"v0.37"
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
static NSInteger gFrameColor = 1;     // 外框颜色：0 白 / 1 黑 / 2 主题青
static CGFloat gFrameOpacity = 0.55;  // 外框不透明度（plist 存百分数，读时 /100）
static double gSkipSeconds = 10.0;    // 左右快进退步长（秒）
static BOOL gEpisodeSwipe = YES;      // 单指上下滑切上/下一集（全局；App 不支持时静默无效）

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
    if ((v = pipPref(@"SkipSeconds")) != nil) {
        double s = [v doubleValue];
        if (s >= 1.0 && s <= 60.0) gSkipSeconds = s;
    }
    if ((v = pipPref(@"EpisodeSwipe")) != nil) gEpisodeSwipe = [v boolValue];
    if ((v = pipPref(@"FrameColor")) != nil) {
        NSInteger c = [v integerValue];
        if (c >= 0 && c <= 2) gFrameColor = c;
    }
    if ((v = pipPref(@"FrameOpacity")) != nil) {
        double o = [v doubleValue] / 100.0;   // plist 存百分数
        if (o >= 0.1 && o <= 1.0) gFrameOpacity = o;
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
static BOOL gPegasusLogged = NO;   // v0.28：进度改走 Pegasus 播放状态后只打一次确认日志

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
// v0.31：Pegasus 在「解除吸附（FreePIP）」态下可能回报 rate=0 / 占位零 diff，
// 导致播放时钟被「冻结」。这里用「App 实际上报的 elapsed 是否在推进」来反推是否在播，
// 不依赖 Pegasus 可能失真的 rate 字段。
static double gMRLastRawEla = -1;     // 上次 pipAdoptElapsed 收到的原始 MR/Pegasus elapsed
static double gMRLastRawAt = 0;       // 上次收到时的墙上时间
static BOOL gMRAdvancing = NO;        // 由原始 elapsed 的推进速度反推：App 确实在播
// v0.34：点按快进退（seek）宽限期（墙上时间，绝对值）。发 seek 命令后 App 未必立即上报新位置，
// 此刻 MR 仍是陈旧（较小）的 elapsed；宽限期内 pipAdoptElapsed 既不追平也不回拉，保留用户目标位，
// 避免进度条「前进一点又被拉退一点」振荡（用户报「动一点退一点」）。声明须先于 pipAdoptElapsed。
static double gSeekSettleUntil = 0;
// v0.35：seek 目标位（绝对秒数，与墙上时间无关）。用户点按 seek 到该值后 App 未必立刻经 MR 上报新位置；
// 只要 MR 回报的 elapsed 还没追上该目标，就抑制「对称回拉」、保留本地目标位（避免被陈旧 MR 值拉回）。
// 一旦 MR 上报 ≥ 该值（App 真跳过去了）即清零，恢复正常对齐。声明须先于 pipAdoptElapsed。
static double gSeekHoldEla = -1;

// v0.29：进度条统一时间源 —— 以「播放时钟」（wall-clock × rate 累加）为准，
// MediaRemote/Pegasus 的 elapsed 只用于：① 首次锚定 ② 真循环（接近片尾且回到片头）
// ③ 播放时钟明显落后时追平。绝不直接覆盖，否则短视频 App 的陈旧 MR elapsed
// 会让进度条越跑越领先/落后真实画面（用户报「进度条自己走时跟视频走着不一致」）。
static void pipAdoptElapsed(double mrEla, double dur, double rate, double tNow) {
    if (dur > 1.0) gMRDuration = dur;
    if (rate >= 0.0) gMRRate = rate;
    // v0.31：用「原始 elapsed 的推进速度」反推 App 是否真的在播（不依赖 Pegasus 可能失真的 rate）。
    // 短视频/解除吸附态下 Pegasus 常回报 rate=0，但 App 其实在放 ⇒ 这里照样判定为 advancing。
    if (gMRLastRawEla >= 0 && tNow > gMRLastRawAt + 0.1) {
        double speed = (mrEla - gMRLastRawEla) / (tNow - gMRLastRawAt);
        if (speed > 0.3) gMRAdvancing = YES;        // 明显在前进
        else if (speed < 0.05) gMRAdvancing = NO;   // 基本不动（暂停/卡住）⇒ 当作未播，避免空转外推
    }
    double prevRaw = gMRLastRawEla;          // v0.35：拉回前保存上一次 MR elapsed，用于识别「突变回退」毛刺
    gMRLastRawEla = mrEla; gMRLastRawAt = tNow;
    // v0.35：seek hold —— 用户点按 seek 到 gSeekHoldEla 后 App 未必立刻上报新位置；
    // 一旦 MR 回报已 ≥ 该目标（App 真跳过去了），解除 hold，恢复正常对齐。
    if (gSeekHoldEla >= 0 && mrEla >= gSeekHoldEla - 1.0) gSeekHoldEla = -1;
    if (gMRUpdatedAt <= 0) {            // 首次锚定（含刚进入画中画）
        gMRElapsed = mrEla > 0 ? mrEla : 0;
        gMRUpdatedAt = tNow;
        return;
    }
    double selfEla = gMRElapsed + (gMRRate > 0.05 ? (tNow - gMRUpdatedAt) * gMRRate : 0);
    BOOL nearEnd = (selfEla > gMRDuration - 2.0);
    BOOL mrStart = (mrEla < 2.0);
    if (nearEnd && mrStart) {                 // 真循环：片尾 → 片头
        gMRElapsed = mrEla; gMRUpdatedAt = tNow;
        gSeekHoldEla = -1;                     // v0.35：循环即解除 seek hold
    } else if (gSeekSettleUntil > tNow) {
        // v0.34：seek 宽限期内保留用户点按后的目标位，既不追平也不回拉。
        // 发 seek 命令后 App 未必立即上报新位置，此刻 MR 仍是陈旧 elapsed；
        // 若立刻追平/回拉会让进度条「前进一点又被拉退一点」振荡（用户报「动一点退一点」）。
        // 宽限期（1.5s）过后 App 通常已上报新位置，再走正常对齐；若真不响应则回拉兜底。
    } else if (mrEla > selfEla + 1.5) {       // 播放时钟落后（曾被错误暂停等）⇒ 追平
        gMRElapsed = mrEla; gMRUpdatedAt = tNow;
    } else if (selfEla > mrEla + 3.0) {       // ★ v0.31/v0.35：播放时钟明显【领先】真实画面
        // v0.35：以下情形不打断本地走时（避免「钉在陈旧 MR 值 → 爬升 3s → 拉回」的锯齿漂移，
        // 即用户报的「进度条跟着陈旧值反复跳/漂」）：
        //  ① seek 宽限期（gSeekSettleUntil）        ② seek 目标未达成（gSeekHoldEla，App 还没跳到）
        //  ③ MR elapsed 已冻结但 rate 仍报在播（gMRAdvancing==NO && rate>0.05）——
        //     短视频 App 在 PiP 下常见 MR 回报失真（elapsed 卡死不跟视频），此时信 MR 只会把
        //     进度条钉死在陈旧值。保留本地墙钟累加，进度条平滑走时。
        BOOL mrFrozenButPlaying = (gMRAdvancing == NO && gMRRate > 0.05);
        // ④ MR elapsed 突然大幅回退（>2s 且非本插件 seek 所致）= 掉线/重连毛刺（如 pid=0 瞬间 ela=0），
        //    信它只会把进度条钉到 0 再弹回，也按「保留本地走时」处理。
        BOOL mrGlitchBack = (mrEla < prevRaw - 2.0);
        if (gSeekSettleUntil > tNow || gSeekHoldEla >= 0 || mrFrozenButPlaying || mrGlitchBack) {
            // 保留本地目标位/走时，不回拉
        } else {
            gMRElapsed = mrEla; gMRUpdatedAt = tNow;
        }
    }
    // 其余：保留播放时钟，不覆盖（进度条贴合真实画面）
}
static BOOL gSeekBusy = NO;          // 拖动/seek 进行中：暂停外推，别跟用户抢进度
static BOOL gEpisodeFired = NO;      // v0.36：本次竖向滑动是否已触发切集（防手势内重复触发）
static double gDragTargetSec = 0;    // 拖动中的目标秒数
static double gSeekGraceUntil = 0;   // 松手宽限期（墙上时间）：期内 gSeekBusy 保持，心跳不覆盖进度
static double gSeekTargetSec = 0;    // 松手时 seek 的目标秒数（供宽限期后校验 App 是否真的跳过去）

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
    // v0.27：2s → 1s。进度条「自己走」时以 App 上报为准，采样越密越贴合；
    // 1s 一次对 mediaserverd 仍是极轻的负担。
    if (now - gMRQueryAt < 1.0) return;
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
                double tNow = [[NSDate date] timeIntervalSinceReferenceDate];
                // v0.29：进度统一走「播放时钟」，MR elapsed 只做锚定/循环/追平，不直接覆盖
                pipAdoptElapsed(ela, dur, rate, tNow);
                // v0.26：宽限期过后的第一次上报 = 校验 seek 是否真的生效（差值为 0 附近才算成功）
                if (gSeekTargetSec > 0.0) {
                    PIPLog(@"seek 校验：目标 %.2fs，App 实报 %.2fs（差 %+.2fs）",
                           gSeekTargetSec, ela, ela - gSeekTargetSec);
                    gSeekTargetSec = 0.0;
                }
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

// v0.30：外框配色（颜色预设 × 不透明度）
static UIColor *pipFrameFill(void) {
    switch (gFrameColor) {
        case 0: return [UIColor colorWithWhite:1.0 alpha:gFrameOpacity];                       // 白
        case 2: return [UIColor colorWithRed:0.0 green:0.45 blue:0.50 alpha:gFrameOpacity];     // 主题青
        default: return [UIColor colorWithWhite:0.0 alpha:gFrameOpacity];                       // 黑
    }
}
static UIColor *pipFrameEdge(void) {
    return [UIColor colorWithWhite:1.0 alpha:0.18];   // 内沿发丝高光，任何底色上都分隔
}

// v0.32：点按快进退的命中分区 —— 仅视频左右两侧（外 35%）归我们快进退，
// 中间 30% 留作死区交给系统原生 PiP 控制（播放/暂停等）。
// v0.34：顶部 1/3 也死区 —— 系统原生位于画中画上部的两个按钮（播放/暂停等）要能点到。
// 返回 -1=左(快退) / 1=右(快进) / 0=死区（中间横向 + 顶部纵向，均交给系统）。
static NSInteger pipSkipZone(CGPoint p, CGRect vr) {
    if (vr.size.width < 8.0) return 0;
    CGFloat w = vr.size.width;
    CGFloat h = vr.size.height;
    CGFloat leftEdge  = CGRectGetMinX(vr) + w * 0.35;
    CGFloat rightEdge = CGRectGetMaxX(vr) - w * 0.35;
    // 横向中间 30% 死区：交给系统原生 PiP 控制
    if (p.x >= leftEdge && p.x <= rightEdge) return 0;
    // 顶部 1/3 死区：避开系统原生位于画中画上部的两个按钮
    if (p.y < CGRectGetMinY(vr) + h * 0.33) return 0;
    return (p.x < leftEdge) ? -1 : 1;
}

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
// v0.26：自由态（解除吸附）专用关闭按钮 —— 自由态下整块视频被壳接管，
// 原生控制条（播放/还原/关闭）点不到，故在外框右上角加一个关闭入口。
// ⚠️ 实现改为 **纯 CALayer**（底衬圆 + ✕ 描边）+ 一个 tap 手势：
// v0.23~v0.25 用 UIButton 子视图，真机日志证明它拿到了有效 frame（{{320,8},{40,40}}）、
// hidden=NO、也 bringSubviewToFront 过，但屏幕上就是不显示；而本壳的**图层**（进度条轨道/
// 已播段/拇指）在同一环境下稳定渲染 ⇒ 改用与进度条同一条渲染通路，并把手势接进来。
@property (nonatomic, strong) CAShapeLayer *closeBgLayer;    // 半透明圆底衬
@property (nonatomic, strong) CAShapeLayer *closeXLayer;     // 白色 ✕（两条线）
@property (nonatomic, assign) CGRect closeFrame;             // 关闭按钮命中区（本壳坐标系）
@property (nonatomic, strong) UITapGestureRecognizer *closeTap;
// v0.30：点按画中画左半区快退、右半区快进（步长 gSkipSeconds）
@property (nonatomic, strong) UITapGestureRecognizer *skipTap;
// v0.11：外框矩形（本壳坐标系，含底部黑边）—— 供 pointInside 扩展命中区用
@property (nonatomic, assign) CGRect hitRect;
// v0.15：拖动中（此时进度由手指决定，不被心跳覆盖）
@property (nonatomic, assign) BOOL seeking;
@property (nonatomic, assign) CGRect trackRect;
- (void)pipSelfHeal;
- (void)pipRefreshProgress;
// v0.26：必须在 @interface 里声明 —— pipApplyFreeMovePref 是文件级静态函数，
// 位于 @implementation 之前，只认 @interface 里声明过的 selector
- (void)pipLayoutCloseButton;
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
// v0.17：系统 pan 手势是否要被我们吞掉。
// v0.29：快照态（gFreeMove=NO）下，进度条热区内的拖动也要吞掉系统 pan ——
// 否则第一帧系统 pan 先动窗、gSeekBusy 还没置位，窗口会跟着进度条跑（真机反馈）。
static BOOL pipSystemPanHitHotZone(UIPanGestureRecognizer *sender) {
    PIPFrameView *cv = gInstalledFrame;
    if (cv == nil || CGRectGetWidth(cv.trackRect) <= 1.0) return NO;
    CGPoint p = [sender locationInView:cv];
    CGRect hot = CGRectInset(cv.trackRect, -8.0, -20.0);
    return CGRectContainsPoint(hot, p);
}

static BOOL pipShouldBlockSystemPan(UIPanGestureRecognizer *sender) {
    if (gSeekBusy) return YES;   // 正在拖进度条 ⇒ 绝不能让系统拖窗口
    if (gFreeMove) return YES;   // 自由态由我们自己的 pan 负责
    if (pipSystemPanHitHotZone(sender)) return YES;  // v0.29：快照态进度条热区也吞系统 pan
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
    if (gInstalledFrame != nil) [gInstalledFrame pipLayoutCloseButton];   // v0.26：图层显隐随 gFreeMove
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
        [self pipApplyProgressColors];   // v0.32：按外框颜色定初始进度条配色
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
        // v0.30：左右点按快进退（视频主体）
        self.skipTap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                action:@selector(pipSkipTap:)];
        self.skipTap.delegate = self;
        [self addGestureRecognizer:self.skipTap];

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

        // v0.26：关闭按钮改纯图层渲染（圆底衬 + ✕ 描边），加入顺序在最后 ⇒ 位于所有图层之上
        self.closeBgLayer = [CAShapeLayer layer];
        self.closeBgLayer.fillColor = [UIColor colorWithWhite:0.05 alpha:0.7].CGColor;
        self.closeBgLayer.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.92].CGColor;
        self.closeBgLayer.lineWidth = 2.0;
        self.closeBgLayer.hidden = YES;   // 仅自由态显示
        [self.layer addSublayer:self.closeBgLayer];
        self.closeXLayer = [CAShapeLayer layer];
        self.closeXLayer.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.95].CGColor;
        self.closeXLayer.lineWidth = 2.5;
        self.closeXLayer.fillColor = UIColor.clearColor.CGColor;
        self.closeXLayer.lineCap = kCALineCapRound;
        self.closeXLayer.hidden = YES;
        [self.layer addSublayer:self.closeXLayer];
        // 点按：独立 tap 手势，由 gestureRecognizerShouldBegin: 限定只认「落在关闭按钮上」
        self.closeTap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                action:@selector(pipCloseTap:)];
        self.closeTap.delegate = self;
        [self addGestureRecognizer:self.closeTap];

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
            // v0.25：热区必须与手势仲裁（gestureRecognizerShouldBegin:）**完全一致**。
            // 旧代码这里是 (0, -12)，而仲裁用的是 (-8, -20) ⇒ 落在 ±12~±20 这一圈的触摸
            // 既进不了进度条手势（hitTest 已 return nil，手势根本收不到），又被放给系统
            // ⇒ 「拖进度条时窗口跟着动」（真机反馈）。两边统一成 (-8, -20)。
            CGRect hot = CGRectInset(self.trackRect, -8.0, -20.0);
            if (CGRectContainsPoint(hot, point)) return self;
        }
        // v0.32：视频主体 —— 仅左右两侧（外 35%）归本壳接管快进退，
        // 中间 30% 留作死区穿透给系统原生 PiP 控制（播放/暂停等），否则系统自带控制条点不到。
        // 拖动仍由系统 pan（挂在窗口祖先上）接管窗口 ⇒ 既保留拖动换位、又支持点按快进退。
        if (CGRectGetWidth(self.trackRect) > 1.0) {
            UIView *host = gVideoHost;
            if (host != nil) {
                CGRect vr = [host convertRect:host.bounds toView:self];
                if (CGRectContainsPoint(vr, point)) {
                    NSInteger zone = pipSkipZone(point, vr);
                    if (zone != 0) return self;   // 左/右 → 接管快进退
                    return nil;                   // 中间死区 → 穿透给系统原生控制
                }
            }
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
    // v0.26：关闭按钮的 tap —— 只认「自由态 + 落在按钮命中区内」
    if (gr == self.closeTap) {
        if (!gFreeMove || CGRectIsEmpty(self.closeFrame)) return NO;
        return CGRectContainsPoint(self.closeFrame, [gr locationInView:self]);
    }
    if (gr == self.seekPan || gr == self.seekTap) {
        // 进度条手势只在热区内参与；热区外拒绝 begin，把手势位让出来
        if (CGRectGetWidth(self.trackRect) > 1.0) {
            CGRect hot = CGRectInset(self.trackRect, -8.0, -20.0);
            return CGRectContainsPoint(hot, [gr locationInView:self]);
        }
        return NO;
    }
    if (gr == self.skipTap) {
        // 进度条热区交给 seekTap；关闭按钮交给 closeTap；其余（视频主体）才归快进退
        CGPoint p = [gr locationInView:self];
        if (CGRectGetWidth(self.trackRect) > 1.0) {
            CGRect hot = CGRectInset(self.trackRect, -8.0, -20.0);
            if (CGRectContainsPoint(hot, p)) return NO;
        }
        if (gFreeMove && !CGRectIsEmpty(self.closeFrame)
            && CGRectContainsPoint(self.closeFrame, p)) return NO;
        // v0.32：中间死区（交给系统原生控制）不让本手势起手，避免吞掉系统自带控制条的点击
        UIView *host = gVideoHost;
        if (host != nil) {
            CGRect vr = [host convertRect:host.bounds toView:self];
            if (vr.size.width >= 8.0 && pipSkipZone(p, vr) == 0) return NO;
        }
        return YES;
    }
    if (gr == gFreePan) {
        // v0.26：从关闭按钮起手不要拖着窗口跑（按钮优先）
        if (gFreeMove && !CGRectIsEmpty(self.closeFrame)
            && CGRectContainsPoint(self.closeFrame, [gr locationInView:self])) return NO;
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
    [self pipLayoutCloseButton];   // v0.26：图层显隐 + 定位（内部按 gFreeMove 决定）
    [self.closeBgLayer setNeedsDisplay];
    [self.closeXLayer setNeedsDisplay];
    PIPLog(@"close button %@ frame=%@（host=%@ bgHidden=%d）",
           gFreeMove ? @"显示" : @"隐藏", NSStringFromCGRect(self.closeFrame),
           gVideoHost != nil ? NSStringFromClass(gVideoHost.class) : @"nil",
           (int)self.closeBgLayer.hidden);
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
    self.closeBgLayer.hidden = YES;    // v0.26：按钮改图层
    self.closeXLayer.hidden = YES;
    [self setNeedsLayout];
    PIPLog(@"close button tapped → 关闭画中画");
    pipStopPiP();
}

// v0.26：关闭按钮的 tap 手势（UIButton 移除后改由手势承接点按）
- (void)pipCloseTap:(UITapGestureRecognizer *)gr {
    if (!gFreeMove) return;
    if (CGRectIsEmpty(self.closeFrame)) return;
    if (!CGRectContainsPoint(self.closeFrame, [gr locationInView:self])) return;
    [self pipCloseAction:nil];
}

// v0.28：发一条 Pegasus 命令（PGCommand 的类方法工厂 + 交给 PiP VC 的 handleCommand:）。
// 真机 PGCMD-META dump 里有 **commandForCancelPIP** —— 这正是 Pegasus 自己的「关闭画中画」，
// 比 v0.27 用 MediaRemote kMRStop（停播放）更贴合语义。全程判空，缺任一环节返回 NO。
static BOOL pipSendPegasusCommand(NSString *name) {
    Class pg = objc_getClass("PGCommand");
    if (pg == nil) return NO;
    SEL s = NSSelectorFromString(name);
    if (![pg respondsToSelector:s]) return NO;
    id vc = gPegasusVC;
    if (vc == nil || ![vc respondsToSelector:@selector(handleCommand:)]) return NO;
    id (*mk)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    id cmd = mk(pg, s);
    if (cmd == nil) return NO;
    void (*hc)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
    hc(vc, @selector(handleCommand:), cmd);
    return YES;
}

// v0.23：关闭 PiP —— 多候选 selector 降级，覆盖 iOS 版本差异。
// SBPIPController（SpringBoard 私有的 PiP 服务）与 contentVC 上逐个尝试，
// 第一个 respondsToSelector 的就调用；都不认则只打日志，不崩。
static void pipStopPiP(void) {
    // v0.28：优先走 Pegasus 原生关闭（真机 dump 实锤存在）
    if (pipSendPegasusCommand(@"commandForCancelPIP")) {
        PIPLog(@"close PiP via Pegasus commandForCancelPIP");
        return;
    }
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
    // v0.27：真机日志实锤上面 6 个 SpringBoard/内容 VC 的 selector **一个都不响应**
    // （`close PiP：候选 selector 均未响应`）⇒ 点关闭按钮实际只做了「退出自由态」，
    // 看起来就像「干成了别的事」。这里补一条确定可用的通道：
    // MediaRemote 的 **kMRStop = 3** —— 停止播放后画中画自然关闭（与系统原生 ✕ 一致）。
    if (gMRSendCommand != NULL) {
        gMRSendCommand(3, nil);   // kMRStop
        PIPLog(@"close PiP via MediaRemote kMRStop(3)（停止播放 ⇒ 关闭画中画）");
        return;
    }
    PIPLog(@"close PiP：SpringBoard selector 与 MediaRemote 均不可用");
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
    // v0.31：rate 缺失/为 0（FreePIP 解除吸附后 Pegasus 常回报 rate=0）但 App 实际在播时，
    // 用 1.0 兜底外推，避免播放时钟冻结、进度条停住、点按 seek 反复落在同一点。
    double effRate = gMRRate;
    if (effRate < 0.05 && gMRAdvancing) effRate = 1.0;
    if (effRate > 0.05 && gMRUpdatedAt > 0) {
        e += ([[NSDate date] timeIntervalSinceReferenceDate] - gMRUpdatedAt) * effRate;
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
    if (gFreeMove) [self pipLayoutCloseButton];   // v0.26：自由态每帧跟随（图层版）
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

// v0.32：进度条配色随外框反色 —— 外框为白色（0）时改用深色，否则白色；
// 否则白底白条在白色皮肤下完全看不见。thumb / 时间标签同步反色。
- (void)pipApplyProgressColors {
    if (gFrameColor == 0) {
        self.trackLayer.fillColor = [UIColor colorWithWhite:0.0 alpha:0.22].CGColor;
        self.fillLayer.fillColor  = [UIColor colorWithWhite:0.0 alpha:0.85].CGColor;
        self.thumbLayer.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0].CGColor;
        self.timeLabel.textColor = [UIColor colorWithWhite:0.12 alpha:1.0];
    } else {
        self.trackLayer.fillColor = [UIColor colorWithWhite:1.0 alpha:0.22].CGColor;
        self.fillLayer.fillColor  = [UIColor colorWithWhite:1.0 alpha:0.92].CGColor;
        self.thumbLayer.backgroundColor = [UIColor whiteColor].CGColor;
        self.timeLabel.textColor = [UIColor whiteColor];
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
        // v0.28：拖动期间彻底关掉自由拖动 —— 只靠 shouldBegin 的热区判定的话，
        // 手指一旦飘出热区，窗口就可能跟着动（用户持续反馈「拖进度条窗口跟着跑」）。
        if (gFreePan != nil) gFreePan.enabled = NO;
        [self pipRefreshProgress];       // 先显示拇指/时间标签
    }
    if (gr.state == UIGestureRecognizerStateEnded
        || gr.state == UIGestureRecognizerStateCancelled
        || gr.state == UIGestureRecognizerStateFailed) {
        if (self.seeking) {
            double target = gDragTargetSec;
            // v0.27：cur 用「外推后的当前位置」而不是裸 gMRElapsed —— MR 每 2s 才回报一次，
            // gMRElapsed 最多可能落后 2s；后退走的是**相对**的 skipByInterval，基准越旧
            // 落点越偏（真机 `seek 校验` 差 +7.33s / +3.91s 就是这么来的）。
            double cur = [self pipCurrentSeconds];   // 松手瞬间当前播放位置（外推修正）
            if (target < cur - 0.5) {
                // v0.24：后退 seek —— 部分 App 不响应后退方向的 MRMediaRemoteSetElapsedTime，
                // 改用 Pegasus 原生 skipByInterval（负间隔，与系统「快退」同机制）后退到目标位。
                [self pipSeekByInterval:(target - cur)];
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
        // v0.27：宽限期回到 **0.8s**。v0.26 拉到 3.5s 虽止住了来回跳，但代价是这 3.5s 内
        // 进度按「目标位」外推、而 App 实际在别处 ⇒ 用户看到「进度条自己走时跟视频不同步」。
        // 同步优先：只留 0.8s 让 App 处理 seek，之后立刻以 App 上报为准。
        gSeekGraceUntil = [[NSDate date] timeIntervalSinceReferenceDate] + 0.8;
        gSeekTargetSec = gDragTargetSec;   // 用全局量（target 是上面 if 块的局部变量，此处已出作用域）
        if (gFreePan != nil) gFreePan.enabled = gFreeMove;   // v0.28：拖动结束恢复自由态拖动
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
    if (self.closeBgLayer == nil) return;
    UIView *host = gVideoHost;
    if (host == nil || host.window == nil) return;
    CGRect vr = [host convertRect:host.bounds toView:self];
    CGFloat vrW = CGRectGetWidth(vr), vrH = CGRectGetHeight(vr);
    if (vrW < 8.0 || vrH < 8.0) return;

    CGFloat bs = 28.0;   // v0.27：用户反馈 40pt 偏大，缩到 28pt
    CGRect f = CGRectMake(CGRectGetMaxX(vr) - bs - 6.0, CGRectGetMinY(vr) + 6.0, bs, bs);
    self.closeFrame = f;

    BOOL show = gFreeMove;
    self.closeBgLayer.hidden = !show;
    self.closeXLayer.hidden = !show;
    if (!show) return;

    self.closeBgLayer.path =
        [UIBezierPath bezierPathWithRoundedRect:f cornerRadius:bs / 2.0].CGPath;
    // ✕：两条过圆心的短线（纯图层、无字体依赖，任何画面上都看得见）
    CGPoint c = CGPointMake(CGRectGetMidX(f), CGRectGetMidY(f));
    CGFloat r = 5.5;   // v0.27：随按钮缩小（28pt）
    UIBezierPath *xp = [UIBezierPath bezierPath];
    [xp moveToPoint:CGPointMake(c.x - r, c.y - r)];
    [xp addLineToPoint:CGPointMake(c.x + r, c.y + r)];
    [xp moveToPoint:CGPointMake(c.x + r, c.y - r)];
    [xp addLineToPoint:CGPointMake(c.x - r, c.y + r)];
    self.closeXLayer.path = xp.CGPath;
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

// v0.30：左右点按快进退统一入口（前进用 SetElapsedTime，后退用 skipByInterval，均已在 seek 验证）
- (void)pipSeekByInterval:(double)sec {
    if (gMRDuration <= 1.0) return;
    double cur = [self pipCurrentSeconds];
    double target = cur + sec;
    if (target < 0) target = 0;
    if (target > gMRDuration) target = gMRDuration;
    if (sec < 0) {
        [self pipSeekBackByInterval:sec];   // 后退：Pegasus skipByInterval（已验证）
    } else if (gMRSetElapsedTime != NULL) {
        gMRSetElapsedTime(target);
        PIPLog(@"skip +%.1fs → SetElapsedTime %.1f", sec, target);
    } else {
        [self pipSeekBackByInterval:sec];
    }
    // v0.33：前后向 seek 都立即本地校准播放时钟，进度条即时跟随。
    // 后退依赖 App 经 MR 回报真实位置，先本地占位，下一轮 MR 回调再校正（pull-down/catch-up），
    // 避免「点后退进度条不动、只有 App 跳」的脱节（解除吸附态下尤其明显）。
    gMRElapsed = target;
    gMRUpdatedAt = [[NSDate date] timeIntervalSinceReferenceDate];
    // v0.34：开启 seek 宽限期，抑制「对称回拉」把进度条拉回陈旧 MR 位置（动一点退一点）。
    // v0.35：同时记录 seek 目标位 gSeekHoldEla，只有 MR 回报 ≥ 该值（App 真跳过去）才解除 hold，
    // 期间即便 App 响应慢/不响应也不把进度条拉回陈旧值。
    gSeekSettleUntil = gMRUpdatedAt + 1.5;
    gSeekHoldEla = target;
}

// v0.30：点按画中画左半区快退、右半区快进
- (void)pipSkipTap:(UITapGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateEnded) return;
    if (gMRDuration <= 1.0) return;          // 直播/无总时长不跳
    UIView *host = gVideoHost;
    if (host == nil) return;
    CGRect vr = [host convertRect:host.bounds toView:self];
    if (vr.size.width < 8.0) return;
    CGPoint p = [gr locationInView:self];
    if (!CGRectContainsPoint(vr, p)) return; // 只认视频主体（底部条/关闭按钮已被仲裁排除）
    // v0.32：中间死区不快进退（交给系统原生控制），仅左右两侧生效
    NSInteger zone = pipSkipZone(p, vr);
    if (zone == 0) return;
    [self pipSeekByInterval:zone < 0 ? -gSkipSeconds : gSkipSeconds];
    PIPLog(@"skip tap %@ %.0fs", zone < 0 ? @"←后退" : @"前进→", gSkipSeconds);
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
        // v0.30：外框配色（颜色预设 × 不透明度），偏好热更新经 setNeedsLayout 重算
        self.caseLayer.fillColor = pipFrameFill().CGColor;
        self.edgeLayer.strokeColor = pipFrameEdge().CGColor;
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
    [self pipApplyProgressColors];   // v0.32：外框颜色热更新时同步进度条反色
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

// v0.36：单指上下滑切上/下一集。复用系统 PiP 拖动 pan（视频主体 1 指移动会触发），
// 当位移 predominantly 垂直且超过阈值时判定为切集手势 —— 由调用方拦截窗口拖动并发送 MR 命令。
// 水平拖动仍走系统逻辑（移动窗口）。自由态/进度条拖动时调用方已短路，不会进这里。
static BOOL pipIsEpisodeSwipe(UIPanGestureRecognizer *sender, NSInteger *outDir) {
    if (sender.state != UIGestureRecognizerStateChanged) return NO;
    CGPoint t = [sender translationInView:nil];
    CGFloat dy = t.y, dx = fabs(t.x);
    if (fabs(dy) < 24.0) return NO;        // 阈值：垂直位移至少 24pt 才算切集（避免误触）
    if (fabs(dy) <= dx) return NO;         // 必须 predominantly 垂直
    *outDir = (dy < 0) ? 1 : -1;           // 上滑(dy<0)=下一集(+1)  下滑(dy>0)=上一集(-1)
    return YES;
}

static void pipFireEpisode(NSInteger dir) {
    if (gMRSendCommand == NULL) { PIPLog(@"episode skip 失败：MR send 不可用"); return; }
    // MRMediaRemoteCommand 标准枚举：NextTrack=4 / PreviousTrack=5。
    // App 未实现播放列表时返回 NO，静默无效（无副作用）。B站锁屏「下一集」即走此通道。
    int cmd = (dir > 0) ? 4 : 5;
    BOOL ok = gMRSendCommand(cmd, nil);
    PIPLog(@"episode skip %s → MRMediaRemoteSendCommand(%d) ok=%d",
           dir > 0 ? "next" : "prev", cmd, ok);
}

// v0.37 诊断：把 episode 判定逻辑抽成函数，并在判定区内打印轨迹，便于定位「竖滑没效果」。
static NSTimeInterval gEpisodeProbeT = 0;
static BOOL pipHandleEpisodePan(UIPanGestureRecognizer *sender) {
    if (!gEpisodeSwipe) return NO;   // 设置关了
    if (gFreeMove)    return NO;     // 自由态：竖向滑留给自由拖动窗口
    if (gSeekBusy)    return NO;     // 进度条拖动中
    if (sender.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [sender translationInView:nil];
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (now - gEpisodeProbeT > 0.4) {
            gEpisodeProbeT = now;
            PIPLog(@"episode-probe dy=%.1f dx=%.1f fired=%d (gEpi=%d gFree=%d gSeek=%d)",
                   t.y, fabs(t.x), gEpisodeFired, gEpisodeSwipe, gFreeMove, gSeekBusy);
        }
    }
    NSInteger dir = 0;
    if (pipIsEpisodeSwipe(sender, &dir)) {
        if (!gEpisodeFired) { gEpisodeFired = YES; pipFireEpisode(dir); }
        return YES;
    }
    if (sender.state == UIGestureRecognizerStateEnded
        || sender.state == UIGestureRecognizerStateCancelled) {
        gEpisodeFired = NO;
    }
    return NO;
}

// iOS 14+ 的 PiP 拖动入口在 SBPIPInteractionController（FreePIP 也是 hook 这两个地方）
%hook SBPIPInteractionController

- (void)handlePanGesture:(UIPanGestureRecognizer *)sender {
    // v0.36：单指上下滑切集 —— 竖向位移超阈值即拦截系统窗口拖动并发 MR 下一/上一集命令。
    if (pipHandleEpisodePan(sender)) { PIPLog(@"episode consumed (vertical swipe)"); return; }
    if (pipShouldBlockSystemPan(sender)) {
        PIPLog(@"system pan blocked: free=%d seek=%d hot=%d",
               gFreeMove, gSeekBusy, pipSystemPanHitHotZone(sender));
        return;
    }
    %orig;
}

%end

%hook SBPIPContainerViewController

// v0.17：吞掉系统的 PiP 拖动 pan。
// 背景：v0.11 扩展 hitRect 让窗口在底部黑边「可命中」后，挂在交互控制器上的 pan
// 手势会连同子视图（我们的壳）上的触摸一起收到 ⇒ 拖进度条时画中画跟着跑。
// FreePIP（sohsatoh）解决同一问题的做法就是在这里 %orig 前加条件放行。
- (void)_handlePanGesture:(UIPanGestureRecognizer *)sender {
    // v0.36：单指上下滑切集（同 handlePanGesture 逻辑，两套交互控制器都要覆盖）
    if (pipHandleEpisodePan(sender)) { PIPLog(@"episode consumed (vertical swipe)"); return; }
    if (pipShouldBlockSystemPan(sender)) {
        PIPLog(@"system pan blocked: free=%d seek=%d hot=%d",
               gFreeMove, gSeekBusy, pipSystemPanHitHotZone(sender));
        return;
    }
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
        // ⚠️ v0.25 修正：这里的 self 是 **SBPIPContainerViewController**（容器），它不响应
        // handleCommand:；真正能收 Pegasus 命令的是 content（真机日志实锤 contentVC=
        // PGPictureInPictureViewController）。v0.24 错写成 self ⇒ 后退 skipByInterval 兜底
        // 全部报「PGPictureInPictureViewController 实例不可用」⇒ 后退 seek 彻底失效。
        gPegasusVC = content;     // content 即 PGPictureInPictureViewController
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
            // v0.27：为「关闭画中画」找真正的 SpringBoard API —— 现有 6 个候选 selector
            // 全部不响应，只能先把 SBPIPController 的方法表 dump 出来，下轮按真名接入。
            Class pipCtl = objc_getClass("SBPIPController");
            if (pipCtl != nil) {
                pipDumpMethods(pipCtl, @"SBPIPCTL");
                pipDumpMethods(objc_getMetaClass("SBPIPController"), @"SBPIPCTL-META");
            }
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
            // ★ v0.28：进度条改以 **Pegasus 自己的播放状态** 为准。
            // 真机证据：MediaRemote 的 ElapsedTime 对短视频 App 更新极稀疏 ——
            // 日志 01:33:45 ela=1.5 → 01:33:50 ela=1.8（rate=1.00，5 秒只走了 0.3s）。
            // 拿这种陈旧值做「+ 线性外推」，进度条必然越跑越领先真实画面 ⇒ 用户看到
            // 「进度条自己走时跟视频不同步」。Pegasus 是画中画本体，它的时间才是准的。
            // 用 -1 作「未找到」哨兵，避免依赖 math.h 的 isnan/fabs
            double pDur = -1.0, pEla = -1.0, pRate = -1.0;
            for (id k in d) {
                id v = d[k];
                if (![v respondsToSelector:@selector(doubleValue)]) continue;
                NSString *lk = [[k description] lowercaseString];
                if ([lk isEqualToString:@"playbackrate"]) {
                    pRate = [v doubleValue];
                } else if ([lk isEqualToString:@"duration"]
                           || [lk isEqualToString:@"itemduration"]) {
                    pDur = [v doubleValue];
                } else if ([lk isEqualToString:@"elapsedtime"]
                           || [lk isEqualToString:@"currenttime"]
                           || [lk isEqualToString:@"elapsed"]) {
                    pEla = [v doubleValue];
                }
            }
            if (!gSeekBusy) {   // 用户在拖进度条时不覆盖，避免回跳
                if (pDur > 0.5) gMRDuration = pDur;
                if (pRate >= 0.0) gMRRate = pRate;
                if (pEla >= 0.0) {
                    double tNow = [[NSDate date] timeIntervalSinceReferenceDate];
                    // v0.29：Pegasus 的 elapsed 也走统一播放时钟逻辑（锚定/循环/追平，不直接覆盖）
                    pipAdoptElapsed(pEla, gMRDuration, gMRRate, tNow);
                }
                if (!gPegasusLogged) {
                    gPegasusLogged = YES;
                    PIPLog(@"进度改用 Pegasus 播放状态（dur=%.2f ela=%.2f rate=%.2f）keys={%@}",
                           gMRDuration, gMRElapsed, gMRRate,
                           [d.allKeys componentsJoinedByString:@","]);
                }
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
