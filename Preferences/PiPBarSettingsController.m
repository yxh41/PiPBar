//
//  PiPBarSettingsController.m
//  由 Root.plist 描述所有开关，域统一为 com.yxh41.pipbar。
//  不依赖 Cephei：直接读写全局 plist 文件（见 PiPBarPrefsBridge.h），
//  与 Tweak.x 的 pipPref 命中同一物理文件，绕开 roothide per-app NSUserDefaults 容器隔离。
//
//  v0.11 滑块方案（两轮真机失败后的最终形态）：
//   失败史：① 改 spec.name + reload → 拖动被 reload 打断、数值不刷新；
//           ② 改用 cellForSpecifier: 找 UISlider 挂 target → roothide 下
//              PSSliderCell 拖动时【不回调 setPreferenceValue:】，且 cellForSpecifier
//              在该环境不可靠，绑定根本没发生（数值永远不变、拖动无效果）。
//   最终：直接遍历 tableView 里【所有 cell】，递归找 UISlider，用滑块自身的
//        minimumValue 认领归属（外框宽度 min=4 / 底部高度 min=28，区间不重叠），
//        用关联对象记住所属 cell —— 拖动时直接改【该 cell 自己的 textLabel】，
//        数值与滑块同处一行、跟手即时显示，且完全不依赖 roothide 的回调链路。
//

#import "PiPBarSettingsController.h"
#import <UIKit/UIKit.h>
#import <Preferences/PSSpecifier.h>
#import <objc/runtime.h>
#import "PiPBarPrefsBridge.h"

@interface PSListController (PIPSetPrefForward)
- (void)setPreferenceValue:(id)value forSpecifier:(PSSpecifier *)specifier;
- (UITableView *)tableView;
@end

@interface PSSpecifier (PIPSetProp)
- (id)propertyForKey:(NSString *)key;
@end

// 关联对象 key
static const void *kPiPSliderBoundKey = &kPiPSliderBoundKey;   // 已挂 target 标记
static const void *kPiPSliderPrefKey  = &kPiPSliderPrefKey;    // 属于哪个偏好项
static const void *kPiPSliderCellKey  = &kPiPSliderCellKey;    // 记住所属 cell（弱）

// 设置面板自己的文件日志（独立文件，方便与 tweak 日志一起回传）
static void pipPrefsLogImpl(NSString *line) {
    @try {
        NSString *path = @"/var/mobile/Library/Logs/PiPBarPrefs.log";
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"HH:mm:ss";
        NSString *out = [NSString stringWithFormat:@"%@ %@\n", [df stringFromDate:[NSDate date]], line];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (fh == nil) {
            [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:[out dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
        NSLog(@"[PiPBarPrefs] %@", line);
    } @catch (NSException *e) { /* 忽略 */ }
}

// 变参包装（与 tweak 侧 PIPLog 同风格）
#define pipPrefsLog(fmt, ...) pipPrefsLogImpl([NSString stringWithFormat:fmt, ##__VA_ARGS__])

@implementation PiPBarSettingsController {
    NSTimeInterval _lastNotify;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

#pragma mark - 全局 plist 镜像（tweak 读同一物理文件）

- (void)pipMirrorPref:(NSString *)key value:(id)value throttle:(BOOL)throttle {
    if (key == nil) return;
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:kPIPGlobalPlist];
    if (d == nil) d = [NSMutableDictionary dictionary];
    if (value) d[key] = value; else [d removeObjectForKey:key];
    [d writeToFile:kPIPGlobalPlist atomically:YES];

    BOOL post = YES;
    if (throttle) {
        NSTimeInterval now = [[NSDate date] timeIntervalSinceReferenceDate];
        post = (now - _lastNotify) > 0.12;
    }
    if (post) {
        _lastNotify = [[NSDate date] timeIntervalSinceReferenceDate];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             (__bridge CFStringRef)kPIPReloadNotify,
                                             NULL, NULL, YES);
    }
}

#pragma mark - 滑块：扫描表格 + 认领 + 即时标题

- (NSString *)pipBaseNameForKey:(NSString *)key {
    if ([key isEqualToString:@"FrameWidth"]) return @"外框宽度（顶/左右）";
    if ([key isEqualToString:@"BarHeight"])  return @"底部高度（黑边）";
    return nil;
}

// 递归收集所有 UITableViewCell
- (void)pipCollectCells:(UIView *)root into:(NSMutableArray *)out {
    if (root == nil) return;
    if ([root isKindOfClass:[UITableViewCell class]]) { [out addObject:root]; return; }
    for (UIView *v in root.subviews) [self pipCollectCells:v into:out];
}

// 递归找 UISlider
- (UISlider *)pipFindSliderIn:(UIView *)root {
    if (root == nil) return nil;
    if ([root isKindOfClass:[UISlider class]]) return (UISlider *)root;
    for (UIView *v in root.subviews) {
        UISlider *s = [self pipFindSliderIn:v];
        if (s != nil) return s;
    }
    return nil;
}

// 认领归属：外框宽度 min=4，底部高度 min=28 —— 区间不重叠，可据此判定
- (NSString *)pipKeyForSlider:(UISlider *)sl {
    if (sl.minimumValue <= 20.0) return @"FrameWidth";
    return @"BarHeight";
}

- (void)pipBindSliders {
    UITableView *tv = nil;
    @try { tv = [self tableView]; } @catch (NSException *e) { tv = nil; }
    if (tv == nil) { pipPrefsLog(@"bind: tableView 为 nil"); return; }

    NSMutableArray *cells = [NSMutableArray array];
    [self pipCollectCells:tv into:cells];
    int bound = 0;
    for (UITableViewCell *cell in cells) {
        UISlider *sl = [self pipFindSliderIn:cell];
        if (sl == nil) continue;
        if (objc_getAssociatedObject(sl, kPiPSliderBoundKey) != nil) continue;

        NSString *key = [self pipKeyForSlider:sl];
        if (key == nil) continue;

        objc_setAssociatedObject(sl, kPiPSliderPrefKey, key, OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(sl, kPiPSliderCellKey, cell, OBJC_ASSOCIATION_ASSIGN);
        [sl addTarget:self action:@selector(pipSliderChanged:)
              forControlEvents:UIControlEventValueChanged];
        objc_setAssociatedObject(sl, kPiPSliderBoundKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        bound++;

        // 进页面先把当前值写进标题（用户一进来就能看到数值）
        [self pipUpdateTitleForSlider:sl key:key value:sl.value];
        pipPrefsLog(@"bind: %@ 滑块已挂 target（min=%.0f max=%.0f value=%.0f）",
                    key, (double)sl.minimumValue, (double)sl.maximumValue, (double)sl.value);
    }
    pipPrefsLog(@"bind: 扫描到 cell=%d，本轮新绑定=%d", (int)cells.count, bound);
}

// 数值显示：直接改【滑块所在 cell 自己的】标题文字 —— 与滑块同一行、跟手即时
- (void)pipUpdateTitleForSlider:(UISlider *)sl key:(NSString *)key value:(CGFloat)f {
    NSString *base = [self pipBaseNameForKey:key];
    if (base == nil) return;
    UITableViewCell *cell = objc_getAssociatedObject(sl, kPiPSliderCellKey);
    NSString *txt = [NSString stringWithFormat:@"%@：%.0f pt", base, f];
    if (cell != nil && ![cell.textLabel.text isEqualToString:txt]) {
        cell.textLabel.text = txt;
        [cell setNeedsLayout];
    }
    // 同步 specifier 名字，重进页面时也带着数值
    for (PSSpecifier *spec in _specifiers) {
        if ([[spec propertyForKey:@"key"] isEqualToString:key]) { spec.name = txt; break; }
    }
}

- (void)pipSliderChanged:(UISlider *)sender {
    NSString *key = objc_getAssociatedObject(sender, kPiPSliderPrefKey);
    if (key == nil) return;
    CGFloat v = sender.value;
    [self pipMirrorPref:key value:@(v) throttle:YES];
    [self pipUpdateTitleForSlider:sender key:key value:v];
}

#pragma mark - 生命周期

// roothide 下 PSSwitchCell 的标准写入可能落到「设置」App 的 per-app 容器副本，
// 而 tweak 读的是全局 plist 文件。故每次变更都镜像写一份到全局文件。
- (void)setPreferenceValue:(id)value forSpecifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value forSpecifier:specifier];
    NSString *key = [specifier propertyForKey:@"key"];
    if (key == nil) return;
    [self pipMirrorPref:key value:value throttle:NO];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (!_specifiers) [self specifiers];

    // 兜底镜像：把各开关当前值从 suite 同步到全局文件
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"com.yxh41.pipbar"];
    for (PSSpecifier *spec in _specifiers) {
        NSString *key = [spec propertyForKey:@"key"];
        if (!key) continue;
        id val = [d objectForKey:key];
        if (val) [self pipMirrorPref:key value:val throttle:NO];
    }
    pipPrefsLog(@"viewWillAppear: specifiers=%d", (int)_specifiers.count);
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self pipBindSliders];
}

@end
