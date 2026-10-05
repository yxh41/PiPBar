//
//  PiPBarSettingsController.m
//  设置页主控制器（编译型 PreferenceLoader bundle，不依赖 Cephei）
//  直接读写全局 plist 文件（见 PiPBarPrefsBridge.h），与 Tweak.x 的 pipPref
//  命中同一物理文件，绕开 roothide per-app NSUserDefaults 容器隔离。
//
//  v0.22 滑块供 cell 方式定案：
//   * v0.21 教训：plist 里把 cell 写成自定义类名，框架**不会** NSClassFromString
//     实例化它 —— 未知 cell 名被当普通文本行渲染，滑块整个消失（真机截图实证）。
//   * 定案：plist 写回 PSSliderCell（保证框架把它当真行、行映射正确），然后
//     重写 tableView:cellForRowAtIndexPath: 拦截这两行，自己供 PiPSliderCell。
//     数据源就是 self（PSListController 实现 UITableViewDataSource），Objective-C
//     动态分发必然先进我们的重写；万一重写没生效，兜底是系统原生 PSSliderCell，
//     退化为「能用但难拉」，不会再整行消失。
//   * PiPSliderCell 布局（用户参考图）：名称 17pt 黑字左上独占一行 /
//     全宽原生 UISlider / 数值 17pt 灰字右对齐同行。滑条全宽 → 原生手势好拉。
//

#import "PiPBarSettingsController.h"
#import <UIKit/UIKit.h>
#import <Preferences/PSSpecifier.h>
#import "PiPBarPrefsBridge.h"

@interface PSListController (PiPPrefsBridge)
- (void)setPreferenceValue:(id)value forSpecifier:(PSSpecifier *)specifier;
@end

// 设置面板自己的文件日志（独立文件，方便与 tweak 日志一起回传）
// 上限 256KB，超过自动清空重记。
//
// v0.37h：与 tweak 共用同一个总开关（全局 plist 的 FileLog）。旧版本里面板日志无条件
// 写 syslog + 落盘，于是用户把「文件日志」关了，syslog 仍被面板刷 —— 与 tweak 侧的
// 「syslog 恒开」是同一个「关不掉」的两半。现在关掉 FileLog ⇒ 面板侧也彻底静默。
//   force=YES 例外：只给「开关被拨动」那一行用。否则「关闭日志」这个动作本身
//   连一条痕迹都不留 —— 而它恰恰是最需要留证的一次操作。
static void pipPrefsLogEx(BOOL force, NSString *line) {
    if (!force) {
        id v = pip_globalPrefs()[@"FileLog"];
        if (v != nil && [v boolValue] == NO) return;
    }
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

#define pipPrefsLog(fmt, ...)      pipPrefsLogEx(NO,  [NSString stringWithFormat:fmt, ##__VA_ARGS__])
#define pipPrefsLogForce(fmt, ...) pipPrefsLogEx(YES, [NSString stringWithFormat:fmt, ##__VA_ARGS__])

#pragma mark - 自定义滑块 cell（参考图布局，由控制器直接供出）

@protocol PiPSliderRowDelegate <NSObject>
- (void)pipSliderValueChanged:(UISlider *)slider specifier:(PSSpecifier *)specifier;
@end

@interface PiPSliderCell : UITableViewCell
@property (nonatomic, retain) PSSpecifier *pipSpecifier;
- (void)pipRefresh;
@end

@implementation PiPSliderCell {
    UILabel *_titleLabel;   // 名称（左上，正常字号）
    UISlider *_slider;      // 全宽滑条（原生手势）
    UILabel *_valueLabel;   // 数值（滑条行右侧，灰字）
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        // 父类默认 textLabel 可能存在，藏掉避免叠字
        self.textLabel.hidden = YES;
        self.detailTextLabel.hidden = YES;

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.font = [UIFont systemFontOfSize:17.0];
        _titleLabel.textColor = UIColor.labelColor;
        [self.contentView addSubview:_titleLabel];

        _valueLabel = [[UILabel alloc] init];
        _valueLabel.font = [UIFont systemFontOfSize:17.0];
        _valueLabel.textColor = UIColor.secondaryLabelColor;
        _valueLabel.textAlignment = NSTextAlignmentRight;
        [self.contentView addSubview:_valueLabel];

        _slider = [[UISlider alloc] init];
        [_slider addTarget:self action:@selector(pipSliderChanged:)
          forControlEvents:UIControlEventValueChanged];
        [self.contentView addSubview:_slider];
    }
    return self;
}

// 统一配置：名称 / 区间 / 当前值。幂等，供 cell 与复用共用。
- (void)pipRefresh {
    PSSpecifier *spec = self.pipSpecifier;
    if (spec == nil) return;

    NSString *nm = spec.name;
    if (nm.length == 0) nm = [spec propertyForKey:@"label"];
    _titleLabel.text = nm;

    id minP = [spec propertyForKey:@"min"];
    id maxP = [spec propertyForKey:@"max"];
    if (minP != nil) _slider.minimumValue = [minP floatValue];
    if (maxP != nil) _slider.maximumValue = [maxP floatValue];

    // 当前值：全局 plist 优先（与 tweak 同一物理文件），回落 plist 的 default
    NSString *key = [spec propertyForKey:@"key"];
    NSDictionary *g = [NSDictionary dictionaryWithContentsOfFile:kPIPGlobalPlist];
    NSNumber *cur = (key != nil) ? [g objectForKey:key] : nil;
    if (cur == nil) cur = [spec propertyForKey:@"default"];
    if (cur != nil) {
        _slider.value = [cur floatValue];
    } else {
        _slider.value = (_slider.minimumValue + _slider.maximumValue) / 2.0;
    }
    if ([key isEqualToString:@"FrameColor"]) {
        // 外框颜色：0=白 1=黑 2=青，滑条取整并回显颜色名
        NSInteger ci = (NSInteger)round(_slider.value);
        _slider.value = (CGFloat)ci;
        _valueLabel.text = (ci == 0 ? @"白" : (ci == 2 ? @"青" : @"黑"));
    } else {
        _valueLabel.text = [NSString stringWithFormat:@"%.0f", _slider.value];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = CGRectGetWidth(self.contentView.bounds);
    if (w < 10.0) return;
    CGFloat pad = 16.0;
    CGFloat valW = 56.0;
    _titleLabel.frame = CGRectMake(pad, 10.0, w - pad * 2.0, 22.0);
    CGFloat sliderY = 44.0;
    _slider.frame = CGRectMake(pad, sliderY, w - pad * 2.0 - valW - 10.0, 31.0);
    _valueLabel.frame = CGRectMake(w - pad - valW, sliderY + 2.0, valW, 27.0);
}

- (void)pipSliderChanged:(UISlider *)sl {
    _valueLabel.text = [NSString stringWithFormat:@"%.0f", sl.value];
    id target = self.pipSpecifier.target;
    if ([target conformsToProtocol:@protocol(PiPSliderRowDelegate)]) {
        [(id<PiPSliderRowDelegate>)target pipSliderValueChanged:sl
                                                     specifier:self.pipSpecifier];
    }
}

@end

#pragma mark - 自定义开关 cell（v0.37g）
// 为什么必须有它（真机日志实证）：PSSwitchCell 的改动**不会**回调到控制器的
// setPreferenceValue:forSpecifier:（PiPBarPrefs.log 里两次 viewWillAppear 之间
// 完全没有 setPreferenceValue / mirror 行，全局 plist 值纹丝不动）⇒ 开关拨了不落盘，
// 下次进面板 viewWillAppear 的「全局 plist → suite」同步又把旧值写回 cell = 「弹回」。
// 照抄 v0.22 已验证的滑块范式：plist 仍写 PSSwitchCell（保证框架当它是真行），
// 由控制器在 cellForRowAtIndexPath 拦截并供 PiPSwitchCell；值直接读写全局 plist，
// 绕开 roothide per-app NSUserDefaults 容器隔离。

@protocol PiPSwitchRowDelegate <NSObject>
- (void)pipSwitchChanged:(UISwitch *)sw specifier:(PSSpecifier *)specifier;
@end

@interface PiPSwitchCell : UITableViewCell
@property (nonatomic, retain) PSSpecifier *pipSpecifier;
- (void)pipRefresh;
@end

@implementation PiPSwitchCell {
    UILabel *_titleLabel;
    UISwitch *_sw;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.textLabel.hidden = YES;
        self.detailTextLabel.hidden = YES;

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.font = [UIFont systemFontOfSize:17.0];
        _titleLabel.textColor = UIColor.labelColor;
        [self.contentView addSubview:_titleLabel];

        _sw = [[UISwitch alloc] init];
        [_sw addTarget:self action:@selector(pipSwitchFlipped:)
      forControlEvents:UIControlEventValueChanged];
        self.accessoryView = _sw;
    }
    return self;
}

- (void)pipSwitchFlipped:(UISwitch *)sw {
    id target = self.pipSpecifier.target;
    if ([target conformsToProtocol:@protocol(PiPSwitchRowDelegate)]) {
        [(id<PiPSwitchRowDelegate>)target pipSwitchChanged:sw specifier:self.pipSpecifier];
    }
}

- (void)pipRefresh {
    NSString *nm = self.pipSpecifier.name;
    if (nm.length == 0) nm = [self.pipSpecifier propertyForKey:@"label"];
    _titleLabel.text = nm;

    NSString *key = [self.pipSpecifier propertyForKey:@"key"];
    NSDictionary *g = pip_globalPrefs();
    NSNumber *cur = (key != nil) ? [g objectForKey:key] : nil;
    if (cur == nil) cur = [self.pipSpecifier propertyForKey:@"default"];
    _sw.on = cur ? [cur boolValue] : NO;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = CGRectGetWidth(self.contentView.bounds);
    if (w < 10.0) return;
    CGFloat pad = 16.0;
    CGFloat swW = CGRectGetWidth(self.accessoryView.bounds);
    _titleLabel.frame = CGRectMake(pad, 0, w - pad * 2.0 - swW - 10.0,
                                   CGRectGetHeight(self.contentView.bounds));
}

@end

#pragma mark - 主控制器

@interface PiPBarSettingsController () <PiPSliderRowDelegate, PiPSwitchRowDelegate>
@end

@implementation PiPBarSettingsController {
    NSTimeInterval _lastNotify;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (BOOL)pipIsSliderKey:(NSString *)key {
    return [key isEqualToString:@"FrameWidth"] || [key isEqualToString:@"BarHeight"]
        || [key isEqualToString:@"SkipSeconds"] || [key isEqualToString:@"FrameOpacity"]
        || [key isEqualToString:@"FrameColor"];
}

// v0.37g：带 key 且不是滑块的行 = 开关行（分组行无 key，会被 key==nil 挡掉）
- (BOOL)pipIsSwitchKey:(NSString *)key {
    if (key == nil) return NO;
    return ![self pipIsSliderKey:key];
}

// 取 indexPath 对应的 specifier（失败返回 nil，调用方回落 super）
- (PSSpecifier *)pipSpecAt:(NSIndexPath *)indexPath {
    @try {
        return [self specifierAtIndexPath:indexPath];
    } @catch (NSException *e) {
        return nil;
    }
}

#pragma mark - 供 cell：滑块行拦截，其余交回框架

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *spec = [self pipSpecAt:indexPath];
    NSString *key = [spec propertyForKey:@"key"];
    if (spec != nil && [self pipIsSliderKey:key]) {
        PiPSliderCell *cell = [tableView dequeueReusableCellWithIdentifier:@"PiPSliderCell"];
        if (cell == nil) {
            cell = [[PiPSliderCell alloc] initWithStyle:UITableViewCellStyleDefault
                                        reuseIdentifier:@"PiPSliderCell"];
        }
        cell.pipSpecifier = spec;
        [cell pipRefresh];
        return cell;
    }
    // v0.37g：开关行也自己供 cell（PSSwitchCell 不回调 setPreferenceValue:，见 PiPSwitchCell 注释）
    if (spec != nil && [self pipIsSwitchKey:key]) {
        PiPSwitchCell *cell = [tableView dequeueReusableCellWithIdentifier:@"PiPSwitchCell"];
        if (cell == nil) {
            cell = [[PiPSwitchCell alloc] initWithStyle:UITableViewCellStyleDefault
                                        reuseIdentifier:@"PiPSwitchCell"];
        }
        cell.pipSpecifier = spec;
        [cell pipRefresh];
        return cell;
    }
    return [super tableView:tableView cellForRowAtIndexPath:indexPath];
}

- (CGFloat)tableView:(UITableView *)tableView
heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *spec = [self pipSpecAt:indexPath];
    if (spec != nil && [self pipIsSliderKey:[spec propertyForKey:@"key"]]) {
        NSNumber *h = [spec propertyForKey:@"height"];
        return h != nil ? [h doubleValue] : 80.0;
    }
    return [super tableView:tableView heightForRowAtIndexPath:indexPath];
}

#pragma mark - 全局 plist 镜像（tweak 读同一物理文件）

- (void)pipMirrorPref:(NSString *)key value:(id)value throttle:(BOOL)throttle {
    if (key == nil) return;
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:kPIPGlobalPlist];
    if (d == nil) d = [NSMutableDictionary dictionary];
    if (value) d[key] = value; else [d removeObjectForKey:key];
    BOOL ok = [d writeToFile:kPIPGlobalPlist atomically:YES];
    // v0.37f 诊断：回读校验，确认值真的落到全局 plist（而不是写完就没了）
    NSDictionary *back = [NSDictionary dictionaryWithContentsOfFile:kPIPGlobalPlist];
    pipPrefsLog(@"mirror key=%@ value=%@ write=%d back=%@", key, value, ok, back[key]);

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

#pragma mark - 滑块回调（PiPSliderCell 调用，节流通知）

- (void)pipSliderValueChanged:(UISlider *)slider specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (key == nil) return;
    if ([key isEqualToString:@"FrameColor"]) {
        NSInteger ci = (NSInteger)round(slider.value);   // 外框颜色取整 0/1/2
        slider.value = (CGFloat)ci;
        [self pipMirrorPref:key value:@(ci) throttle:YES];
        pipPrefsLog(@"slider %@ -> %ld（%@）", key, (long)ci,
                    (ci == 0 ? @"白" : (ci == 2 ? @"青" : @"黑")));
    } else {
        [self pipMirrorPref:key value:@(slider.value) throttle:YES];
        pipPrefsLog(@"slider %@ -> %.0f", key, (double)slider.value);
    }
}

#pragma mark - 开关回调（PiPSwitchCell 调用，直接落全局 plist）

- (void)pipSwitchChanged:(UISwitch *)sw specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (key == nil) return;
    [self pipMirrorPref:key value:@(sw.on) throttle:NO];
    pipPrefsLogForce(@"switch %@ -> %d", key, sw.on);
}

#pragma mark - 生命周期

// roothide 下 PSSwitchCell 的标准写入可能落到「设置」App 的 per-app 容器副本，
// 而 tweak 读的是全局 plist 文件。故每次变更都镜像写一份到全局文件。
- (void)setPreferenceValue:(id)value forSpecifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value forSpecifier:specifier];
    NSString *key = [specifier propertyForKey:@"key"];
    // v0.37f 诊断：先确认框架到底有没有回调到这里（没这行 = 开关改动根本没进写入流程）
    pipPrefsLog(@"setPreferenceValue key=%@ value=%@", key, value);
    if (key == nil) return;
    [self pipMirrorPref:key value:value throttle:NO];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // v0.38b：设置进程也跑一次偏好迁移（SpringBoard %ctor 已跑）。两进程谁先启动谁搬，
    // 杜绝「装完、respring 前先开设置」用空新文件盖掉旧偏好的竞态。幂等：新文件存在即不动。
    pipMigratePrefsOnce();
    if (!_specifiers) [self specifiers];

    // v0.25 方向修正（真机实锤 barh=60）：旧代码把 NSUserDefaults suite 的值**覆盖写回**
    // 全局 plist。但 roothide 下 suite 就是「设置」App 自己的容器副本、常是旧值 ⇒
    // 用户把「底部高度」设成 28 后，下次进面板就被 suite 里的旧值冲回 60，tweak 也就读成 60。
    // 权威源是全局 plist（tweak 只读它）⇒ 正确方向是【全局 plist → suite】，仅用于让 cell
    // 显示到正确值；**绝不**反向覆盖全局 plist。
    NSDictionary *global = pip_globalPrefs();
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"com.zlhkf.pipbar"];
    for (PSSpecifier *spec in _specifiers) {
        NSString *key = [spec propertyForKey:@"key"];
        if (!key) continue;
        id val = global[key];
        if (val) {
            [d setObject:val forKey:key];
            pipPrefsLog(@"sync %@=%@", key, val);
        }
    }
    // v0.37f：临时 NSUserDefaults 不显式同步可能不落盘 ⇒ 下次进面板 cell 又读回旧值（表现为「弹回」）
    [d synchronize];
    pipPrefsLog(@"viewWillAppear: specifiers=%d（全局 plist → suite 单向同步，已 synchronize）",
                (int)_specifiers.count);
}

@end
