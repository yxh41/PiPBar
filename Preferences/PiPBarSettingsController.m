//
//  PiPBarSettingsController.m
//  设置页主控制器（编译型 PreferenceLoader bundle，不依赖 Cephei）
//  直接读写全局 plist 文件（见 PiPBarPrefsBridge.h），与 Tweak.x 的 pipPref
//  命中同一物理文件，绕开 roothide per-app NSUserDefaults 容器隔离。
//
//  v0.21 滑块方案（照用户参考图重做，前版本全部废弃）：
//   失败史（v0.11~v0.20）：PSSliderCell 天生「标签左、滑条右」，滑条只占半行宽，
//   真机上极难点中。此前所有修法——扫描 cell 认领滑块、改滑条 frame、加整行命中层——
//   都是在跟 PSSliderCell 的内部布局搏斗，每修一处就引入新问题（拖不动 / 文字叠回 /
//   状态互相打断）。
//   最终方案：弃用 PSSliderCell，自定义 PiPSliderCell（用户参考图布局）：
//       名称（正常字号，黑色，左上独占一行）
//       [────────────●──────────────]  40
//   滑条全宽 → 原生手势 → 天生好拉；数值为滑条行右侧灰字；零 hack。
//

#import "PiPBarSettingsController.h"
#import <UIKit/UIKit.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <objc/runtime.h>
#import "PiPBarPrefsBridge.h"

@interface PSListController (PiPPrefsBridge)
- (void)setPreferenceValue:(id)value forSpecifier:(PSSpecifier *)specifier;
@end

// 设置面板自己的文件日志（独立文件，方便与 tweak 日志一起回传）
// 上限 256KB，超过自动清空重记。
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

#define pipPrefsLog(fmt, ...) pipPrefsLogImpl([NSString stringWithFormat:fmt, ##__VA_ARGS__])

#pragma mark - 自定义滑块 cell（参考图布局）

@protocol PiPSliderRowDelegate <NSObject>
- (void)pipSliderValueChanged:(UISlider *)slider specifier:(PSSpecifier *)specifier;
@end

@interface PiPSliderCell : PSTableCell
@end

@implementation PiPSliderCell {
    UILabel *_titleLabel;   // 名称（左上，正常字号）
    UISlider *_slider;      // 全宽滑条（原生手势）
    UILabel *_valueLabel;   // 数值（滑条行右侧，灰字）
    BOOL _uiBuilt;
}

- (void)pipCommonInit {
    if (_uiBuilt) return;
    _uiBuilt = YES;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    // PSTableCell 父类可能创建默认 titleLabel，藏掉避免叠字
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

// 统一配置：名称 / 区间 / 当前值。幂等，init 与复用刷新共用。
- (void)pipConfigureWithSpecifier:(PSSpecifier *)spec {
    if (spec == nil) return;
    self.specifier = spec;

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
    _valueLabel.text = [NSString stringWithFormat:@"%.0f", _slider.value];
}

- (instancetype)initWithSpecifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:UITableViewCellStyleDefault
               reuseIdentifier:nil
                      specifier:specifier];
    if (self) {
        [self pipCommonInit];
        [self pipConfigureWithSpecifier:specifier];
    }
    return self;
}

// 兜底：若框架走这条初始化路径也能正常出 UI
- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier
                      specifier:specifier];
    if (self) {
        [self pipCommonInit];
        [self pipConfigureWithSpecifier:specifier];
    }
    return self;
}

// 复用 / reload 时重配
- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    [self pipConfigureWithSpecifier:specifier];
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
    id target = self.specifier.target;
    if ([target conformsToProtocol:@protocol(PiPSliderRowDelegate)]) {
        [(id<PiPSliderRowDelegate>)target pipSliderValueChanged:sl
                                                     specifier:self.specifier];
    }
}

@end

#pragma mark - 主控制器

@interface PiPBarSettingsController () <PiPSliderRowDelegate>
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

#pragma mark - 滑块回调（PiPSliderCell 调用，节流通知）

- (void)pipSliderValueChanged:(UISlider *)slider specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (key == nil) return;
    [self pipMirrorPref:key value:@(slider.value) throttle:YES];
    pipPrefsLog(@"slider %@ -> %.0f", key, (double)slider.value);
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

@end
