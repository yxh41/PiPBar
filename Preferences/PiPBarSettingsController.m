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
static const void *kPiPHintLabelKey   = &kPiPHintLabelKey;     // 滑块右侧说明小字

// 设置面板自己的文件日志（独立文件，方便与 tweak 日志一起回传）
// v0.14：加 256KB 上限自动清空重记 —— 上一版因判重失效被刷到 3.4MB。
static void pipPrefsLogImpl(NSString *line) {
    @try {
        NSString *path = @"/var/mobile/Library/Logs/PiPBarPrefs.log";
        NSFileManager *fm = NSFileManager.defaultManager;
        NSDictionary *attr = [fm attributesOfItemAtPath:path error:nil];
        if (attr != nil && [attr fileSize] > 256 * 1024) {
            [fm removeItemAtPath:path error:nil];
        }
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

// v0.13：roothide 下 -[PSListController tableView] 返回 nil（日志实证
// `bind: tableView 为 nil`），这是 v0.11/v0.12 滑块数值不刷新的真凶。
// 改为多重兜底找表：tableView 选择器 → KVC「table」→ 从 self.view 递归找 UITableView。
- (UITableView *)pipFindTableIn:(UIView *)root {
    if (root == nil) return nil;
    if ([root isKindOfClass:[UITableView class]]) return (UITableView *)root;
    for (UIView *v in root.subviews) {
        UITableView *t = [self pipFindTableIn:v];
        if (t != nil) return t;
    }
    return nil;
}

- (UITableView *)pipFindTableView {
    @try {
        UITableView *tv = [self tableView];
        if (tv != nil) return tv;
    } @catch (NSException *e) { /* 继续兜底 */ }
    @try {
        id t = [self valueForKey:@"table"];
        if ([t isKindOfClass:[UITableView class]]) return (UITableView *)t;
    } @catch (NSException *e) { /* 继续兜底 */ }
    return [self pipFindTableIn:self.view];
}

- (void)pipBindSliders {
    UITableView *tv = [self pipFindTableView];
    if (tv == nil) {
        pipPrefsLog(@"bind: 找不到 UITableView（self.view=%@）", NSStringFromClass(self.view.class));
        return;
    }

    NSMutableArray *cells = [NSMutableArray array];
    [self pipCollectCells:tv into:cells];
    __weak PiPBarSettingsController *weakSelf = self;
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

        // 进页面先把当前值写进标题 + 建好右侧说明小字
        [self pipUpdateTitleForSlider:sl key:key value:sl.value];
        [self pipLayoutHintLabel:[self pipEnsureHintLabelForCell:cell] inCell:cell];
        pipPrefsLog(@"bind: %@ 滑块已挂 target（min=%.0f max=%.0f value=%.0f）",
                    key, (double)sl.minimumValue, (double)sl.maximumValue, (double)sl.value);
    }
    // v0.14：本轮一个都没绑到时**不写日志** —— viewDidLayoutSubviews 会被高频调用，
    // 上一版每次都写 ⇒ PiPBarPrefs.log 刷到 3.4MB。
    if (bound == 0) {
        // cell 可能在绑定之后才真正创建（reload/滚动）⇒ 延迟重试几次，避免漏绑
        for (int i = 1; i <= 3; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * i * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [weakSelf pipBindSliders];
            });
        }
        return;
    }
    pipPrefsLog(@"bind: 扫描到 cell=%d，本轮新绑定=%d", (int)cells.count, bound);
}

// 数值显示：直接改【滑块所在 cell 自己的】标题文字 —— 与滑块同一行、跟手即时。
// v0.17：按用户要求，把「说明文案」缩小后挪到【同一行右侧】（不再用 cell 下方的
// footnote 长段文字），并把「当前值」放在标题里。左标题 + 右侧小字，两行合一。
- (void)pipUpdateTitleForSlider:(UISlider *)sl key:(NSString *)key value:(CGFloat)f {
    NSString *base = [self pipBaseNameForKey:key];
    if (base == nil) return;
    UITableViewCell *cell = objc_getAssociatedObject(sl, kPiPSliderCellKey);
    NSString *txt = [NSString stringWithFormat:@"%@：%.0f pt", base, f];
    if (cell != nil && ![cell.textLabel.text isEqualToString:txt]) {
        cell.textLabel.text = txt;
        [cell setNeedsLayout];
    }
    // 右侧说明小字：重新取一次并更新
    UILabel *hint = [self pipEnsureHintLabelForCell:cell];
    if (hint != nil) {
        NSString *h = [self pipHintTextForKey:key];
        if (![hint.text isEqualToString:h]) {
            hint.text = h;
            [self pipLayoutHintLabel:hint inCell:cell];
        }
    }
    // 同步 specifier 名字，重进页面时也带着数值
    for (PSSpecifier *spec in _specifiers) {
        if ([[spec propertyForKey:@"key"] isEqualToString:key]) { spec.name = txt; break; }
    }
}

// 滑块右侧的说明小字（单位/范围），v0.17 新增
- (NSString *)pipHintTextForKey:(NSString *)key {
    if ([key isEqualToString:@"FrameWidth"]) return @"顶/左右两侧 · 4–24pt";
    if ([key isEqualToString:@"BarHeight"])  return @"底部黑边 · 28–80pt";
    return nil;
}

- (UILabel *)pipEnsureHintLabelForCell:(UITableViewCell *)cell {
    if (cell == nil) return nil;
    UILabel *hint = objc_getAssociatedObject(cell, kPiPHintLabelKey);
    if (hint == nil) {
        hint = [[UILabel alloc] initWithFrame:CGRectZero];
        hint.font = [UIFont systemFontOfSize:10.0];
        hint.textColor = [UIColor grayColor];
        hint.textAlignment = NSTextAlignmentRight;
        hint.userInteractionEnabled = NO;    // 不吃触摸
        [cell.contentView addSubview:hint];
        objc_setAssociatedObject(cell, kPiPHintLabelKey, hint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return hint;
}

// 右上角定位：在标题行右侧、避开文字（用 cell 宽度的一半点右对齐）
- (void)pipLayoutHintLabel:(UILabel *)hint inCell:(UITableViewCell *)cell {
    if (hint == nil || cell == nil) return;
    [hint sizeToFit];
    CGFloat w = CGRectGetWidth(cell.contentView.bounds);
    CGFloat h = CGRectGetHeight(hint.bounds);
    hint.frame = CGRectMake(MAX(80.0, w * 0.52), 5.0, MAX(60.0, w * 0.46), h > 0 ? h : 13.0);
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

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self pipBindSliders];   // 布局完成后 cell 才齐全（已绑过的滑块靠关联对象自动跳过）
}

@end
