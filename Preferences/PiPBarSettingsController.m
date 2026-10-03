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
#import <math.h>
#import "PiPBarPrefsBridge.h"

@interface PSListController (PIPSetPrefForward)
- (void)setPreferenceValue:(id)value forSpecifier:(PSSpecifier *)specifier;
- (UITableViewCell *)cellForSpecifier:(PSSpecifier *)specifier;
- (UITableView *)tableView;
@end

@interface PSSpecifier (PIPSetProp)
- (id)propertyForKey:(NSString *)key;
@end

// 关联对象 key
static const void *kPiPSliderBoundKey = &kPiPSliderBoundKey;   // 已挂 target 标记
static const void *kPiPSliderPrefKey  = &kPiPSliderPrefKey;    // 属于哪个偏好项
static const void *kPiPSliderCellKey  = &kPiPSliderCellKey;    // 记住所属 cell（弱）
static const void *kPiPSliderHitLayerKey = &kPiPSliderHitLayerKey; // v0.21 整行命中层（弱）

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

        // v0.21：**扩大滑条命中区**（用户反馈「很难拉，也可能是反应太慢」）。
        // 做法：不改 slider.frame（v0.19 教训，会破坏手势联动），而是挂一个
        // 覆盖整行的透明手势层，捕获触摸后**直接把 value 设到该点**，
        // 并同步触发 UIControlEventValueChanged —— 等于自己实现"点哪到哪"。
        // 这样手指不必精确按在细滑轨上，横向拖到哪就是哪。
        UIView *hitLayer = [self pipEnsureHitLayerForSlider:sl inCell:cell];
        if (hitLayer != nil) {
            UITapGestureRecognizer *tap =
                [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(pipSliderTap:)];
            [hitLayer addGestureRecognizer:tap];
            UIPanGestureRecognizer *pan =
                [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pipSliderPan:)];
            [hitLayer addGestureRecognizer:pan];
            objc_setAssociatedObject(sl, kPiPSliderHitLayerKey, hitLayer, OBJC_ASSOCIATION_ASSIGN);
        }

        // 进页面先把当前值写进标题 + 建好右侧说明小字
        [self pipUpdateTitleForSlider:sl key:key value:sl.value];
        [self pipLayoutSliderRowInCell:cell];
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

// 数值显示：v0.21 数值放到**名称前面**（如「8 外框宽度」）—— 用户要求「左上那 4 个字
// 不能放数值前面吗」。滑条几何依旧完全交还系统（v0.19 教训：改 frame 会破坏手势联动）。
- (void)pipUpdateTitleForSlider:(UISlider *)sl key:(NSString *)key value:(CGFloat)f {
    NSString *base = [self pipBaseNameForKey:key];
    if (base == nil) return;
    UITableViewCell *cell = objc_getAssociatedObject(sl, kPiPSliderCellKey);
    NSString *txt = [NSString stringWithFormat:@"%.0f pt　%@", f, base];

    if (cell != nil) {
        // 标题：11pt 灰字放左上，文字形如「8 pt　外框宽度」⇒ 数值在名称之前
        UILabel *title = cell.textLabel;
        if (title != nil) {
            if (![title.text isEqualToString:txt]) title.text = txt;
            title.font = [UIFont systemFontOfSize:11.0];
            title.textColor = [UIColor secondaryLabelColor];
        }
        [self pipLayoutSliderRowInCell:cell];
    }
    for (PSSpecifier *spec in _specifiers) {
        if ([[spec propertyForKey:@"key"] isEqualToString:key]) { spec.name = txt; break; }
    }
}

- (NSString *)pipBaseNameForKey:(NSString *)key {
    if ([key isEqualToString:@"FrameWidth"]) return @"外框宽度";
    if ([key isEqualToString:@"BarHeight"])  return @"底部高度";
    return nil;
}


// v0.20 布局：**绝不改 UISlider 的 frame**。
// v0.19 手工把滑条压到下方（`sl.frame = ...`），后果有两个（真机反馈）：
//   ① 「下边的滑块滑不动」—— 改 frame 打断了 PSSliderCell 自身的布局/手势配合；
//   ② 「文字位置还是有问题」—— 系统每次 layout 又把 label/slider 摆回默认，
//      我们设的坐标被覆盖，于是又叠到一起。
// 正确做法：滑条完全交给系统，只把**标题**缩到 11pt 放在左上、**数值**放右上，
// 二者同处 cell 顶部那一条（PSSliderCell 顶部本就留白给 label），互不重叠。
- (void)pipLayoutSliderRowInCell:(UITableViewCell *)cell {
    if (cell == nil) return;
    CGFloat w = CGRectGetWidth(cell.contentView.bounds);
    if (w < 10.0) return;      // 布局未就绪，等下一次
    // 标题（含数值）在左上独占一行；滑条完全交给系统，**绝不改其 frame**。
    UILabel *title = cell.textLabel;
    if (title != nil) {
        title.frame = CGRectMake(14.0, 1.0, w - 28.0, 13.0);
    }
    // v0.21：同步整行命中层位置（滑条 frame 由系统决定，故每次布局都要跟一次）
    UISlider *sl = [self pipFindSliderIn:cell];
    if (sl != nil) {
        [self pipLayoutHitLayer:objc_getAssociatedObject(sl, kPiPSliderHitLayerKey)
                         inCell:cell slider:sl];
    }
}

// v0.21：覆盖整行的透明命中层（放在滑条**之下**，不抢滑条自身手势）
- (UIView *)pipEnsureHitLayerForSlider:(UISlider *)sl inCell:(UITableViewCell *)cell {
    UIView *old = objc_getAssociatedObject(sl, kPiPSliderHitLayerKey);
    if (old != nil) return old;
    UIView *layer = [[UIView alloc] initWithFrame:CGRectZero];
    layer.backgroundColor = UIColor.clearColor;
    layer.userInteractionEnabled = YES;
    [cell.contentView insertSubview:layer belowSubview:sl];
    objc_setAssociatedObject(sl, kPiPSliderHitLayerKey, layer, OBJC_ASSOCIATION_ASSIGN);
    return layer;
}

// 命中层布局：整行可点（标题行 + 滑条行都算）
- (void)pipLayoutHitLayer:(UIView *)layer inCell:(UITableViewCell *)cell slider:(UISlider *)sl {
    if (layer == nil || cell == nil) return;
    CGFloat w = CGRectGetWidth(cell.contentView.bounds);
    if (w < 10.0) return;
    CGFloat top = CGRectGetMinY(sl.frame) - 2.0;
    CGFloat h = CGRectGetHeight(sl.frame) + 4.0;
    if (h < 28.0) { top = CGRectGetMinY(sl.frame) - 10.0; h = CGRectGetHeight(sl.frame) + 20.0; }
    layer.frame = CGRectMake(0.0, MAX(0.0, top), w, h);
}

// 触摸 x → 滑条 value（并广播 UIControlEventValueChanged，走同一条写偏好链路）
- (void)pipApplyTouchToSlider:(UISlider *)sl atX:(CGFloat)x {
    CGFloat trackW = CGRectGetWidth(sl.frame);
    if (trackW < 1.0) return;
    CGFloat r = (x - CGRectGetMinX(sl.frame)) / trackW;
    if (r < 0.0) r = 0.0;
    if (r > 1.0) r = 1.0;
    CGFloat v = sl.minimumValue + r * (sl.maximumValue - sl.minimumValue);
    if (fabs(v - sl.value) < 0.01) return;
    sl.value = v;
    [sl sendActionsForControlEvents:UIControlEventValueChanged];
}

- (void)pipSliderTap:(UITapGestureRecognizer *)gr {
    UIView *layer = gr.view;
    UISlider *sl = [self pipFindSliderIn:layer.superview];
    if (sl == nil) return;
    [self pipApplyTouchToSlider:sl atX:[gr locationInView:layer].x];
}

- (void)pipSliderPan:(UIPanGestureRecognizer *)gr {
    UIView *layer = gr.view;
    UISlider *sl = [self pipFindSliderIn:layer.superview];
    if (sl == nil) return;
    [self pipApplyTouchToSlider:sl atX:[gr locationInView:layer].x];
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
    // v0.18：cell 布局完成后数值标签要按最终宽度右对齐
    [self pipRelayoutValueLabels];
}

// v0.18：cell 宽度在 layoutSubviews 后才最终确定 ⇒ 重新定位所有数值标签
- (void)pipRelayoutValueLabels {
    if (_specifiers == nil) return;
    for (PSSpecifier *spec in _specifiers) {
        NSString *key = [spec propertyForKey:@"key"];
        if (![self pipIsSliderKey:key]) continue;
        UITableViewCell *cell = nil;
        @try { cell = [self cellForSpecifier:spec]; } @catch (NSException *e) { cell = nil; }
        [self pipLayoutSliderRowInCell:cell];
    }
}

- (BOOL)pipIsSliderKey:(NSString *)key {
    return [key isEqualToString:@"FrameWidth"] || [key isEqualToString:@"BarHeight"];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self pipBindSliders];   // 布局完成后 cell 才齐全（已绑过的滑块靠关联对象自动跳过）
}

@end
