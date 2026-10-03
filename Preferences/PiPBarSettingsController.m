//
//  PiPBarSettingsController.m
//  由 Root.plist 描述所有开关，域统一为 com.yxh41.pipbar。
//  不依赖 Cephei：直接读写全局 plist 文件（见 PiPBarPrefsBridge.h），
//  与 Tweak.x 的 pipPref 命中同一物理文件，绕开 roothide per-app NSUserDefaults 容器隔离。
//  整套范式照搬 MapAdKiller（本机 roothide/iOS16.4.1 已验证面板可见 + 值可达）。
//

#import "PiPBarSettingsController.h"
#import <UIKit/UIKit.h>
#import <Preferences/PSSpecifier.h>
#import <objc/runtime.h>
#import "PiPBarPrefsBridge.h"

// ⚠️ roothide 的 PSListController.h 未公开声明部分方法，但 PreferenceLoader 运行时确实实现；
// 补前向声明让调用通过 -Werror（否则报 "no visible @interface declares the selector"）。
@interface PSListController (PIPSetPrefForward)
- (void)setPreferenceValue:(id)value forSpecifier:(PSSpecifier *)specifier;
- (void)reloadSpecifier:(PSSpecifier *)specifier;
- (UITableViewCell *)cellForSpecifier:(PSSpecifier *)specifier;
@end

// PSSpecifier 头未声明 propertyForKey:，补声明（避免 -Werror 告警）
@interface PSSpecifier (PIPSetProp)
- (id)propertyForKey:(NSString *)key;
@end

// 关联对象 key：标记「该 UISlider 已挂过 target」并记住它属于哪个偏好项
static const void *kPiPSliderBoundKey = &kPiPSliderBoundKey;
static const void *kPiPSliderPrefKeyKey = &kPiPSliderPrefKeyKey;

@implementation PiPBarSettingsController {
    NSTimeInterval _lastNotify;   // 拖动期 darwin 通知节流，避免通知风暴
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

#pragma mark - 全局 plist 镜像

// 写全局 plist（tweak 读同一物理文件）。throttle=YES 时对 darwin 通知节流 120ms，
// 避免拖动期每帧广播把 SpringBoard 刷爆；plist 本身仍每帧写，保证最终值准确。
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

#pragma mark - 滑块实时数值

- (NSString *)pipStaticKeyForSlider:(NSString *)sliderKey {
    if ([sliderKey isEqualToString:@"FrameWidth"]) return @"FrameWidthVal";
    if ([sliderKey isEqualToString:@"BarHeight"]) return @"BarHeightVal";
    return nil;
}

- (NSString *)pipBaseNameForSlider:(NSString *)sliderKey {
    if ([sliderKey isEqualToString:@"FrameWidth"]) return @"外框宽度";
    if ([sliderKey isEqualToString:@"BarHeight"]) return @"底部高度";
    return nil;
}

- (BOOL)pipIsSliderKey:(NSString *)key {
    return [key isEqualToString:@"FrameWidth"] || [key isEqualToString:@"BarHeight"];
}

- (PSSpecifier *)pipSpecWithKey:(NSString *)key {
    if (key == nil) return nil;
    for (PSSpecifier *s in _specifiers) {
        NSString *k = [s propertyForKey:@"key"];
        if (k != nil && [k isEqualToString:key]) return s;
    }
    return nil;
}

// 双保险刷新静态数值 cell：
//   ① 直接改【已可见 cell】的 label —— 不依赖 reload 重建，最稳（v0.9 实锤需要）
//   ② 同时更新 spec.name 并 reloadSpecifier —— cell 未创建/被复用时兜底
- (void)pipUpdateValueCellForSlider:(NSString *)sliderKey value:(CGFloat)f {
    NSString *staticKey = [self pipStaticKeyForSlider:sliderKey];
    NSString *base = [self pipBaseNameForSlider:sliderKey];
    if (staticKey == nil || base == nil) return;
    PSSpecifier *st = [self pipSpecWithKey:staticKey];
    if (st == nil) return;

    NSString *txt = [NSString stringWithFormat:@"%@：当前 %.0f pt", base, f];
    st.name = txt;

    UITableViewCell *cell = nil;
    @try { cell = [self cellForSpecifier:st]; } @catch (NSException *e) { cell = nil; }
    if (cell != nil) {
        cell.textLabel.text = txt;
        cell.detailTextLabel.text = txt;
        [cell setNeedsLayout];
    }
    if ([self respondsToSelector:@selector(reloadSpecifier:)]) {
        [self reloadSpecifier:st];
    }
}

#pragma mark - 滑块 target 绑定

// 递归找 cell 内的 UISlider（不依赖私有 ivar 名，跨版本稳健）
- (UISlider *)pipFindSliderIn:(UIView *)root {
    if (root == nil) return nil;
    if ([root isKindOfClass:[UISlider class]]) return (UISlider *)root;
    for (UIView *v in root.subviews) {
        UISlider *s = [self pipFindSliderIn:v];
        if (s != nil) return s;
    }
    return nil;
}

// v0.9 关键：roothide 下 PSSliderCell 拖动时未必回调 setPreferenceValue:，
// 所以主动给 cell 内的 UISlider 挂 UIControlEventValueChanged target —— 拖动即刷新。
- (void)pipBindSliders {
    if (_specifiers == nil) return;
    for (PSSpecifier *spec in _specifiers) {
        NSString *cellType = [spec propertyForKey:@"cell"];
        if (![cellType isEqualToString:@"PSSliderCell"]) continue;
        NSString *key = [spec propertyForKey:@"key"];
        if (![self pipIsSliderKey:key]) continue;

        UITableViewCell *cell = nil;
        @try { cell = [self cellForSpecifier:spec]; } @catch (NSException *e) { cell = nil; }
        UISlider *sl = [self pipFindSliderIn:cell];
        if (sl == nil) continue;
        // 标记挂在 UISlider 上（cell 重建后新滑块无标记 → 会重新绑定，幂等）
        if (objc_getAssociatedObject(sl, kPiPSliderBoundKey) != nil) continue;

        objc_setAssociatedObject(sl, kPiPSliderPrefKeyKey, key, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [sl addTarget:self action:@selector(pipSliderChanged:)
              forControlEvents:UIControlEventValueChanged];
        objc_setAssociatedObject(sl, kPiPSliderBoundKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

- (void)pipSliderChanged:(UISlider *)sender {
    NSString *key = objc_getAssociatedObject(sender, kPiPSliderPrefKeyKey);
    if (key == nil) return;
    [self pipMirrorPref:key value:@(sender.value) throttle:YES];
    [self pipUpdateValueCellForSlider:key value:sender.value];
}

#pragma mark - 生命周期

// roothide 下 PSSwitchCell 的标准写入可能落到「设置」App 的 per-app 容器副本，
// 而 tweak 读的是全局 plist 文件。故每次变更都镜像写一份到全局文件。
- (void)setPreferenceValue:(id)value forSpecifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value forSpecifier:specifier];
    NSString *key = [specifier propertyForKey:@"key"];
    if (key == nil) return;
    [self pipMirrorPref:key value:value throttle:NO];
    if ([self pipIsSliderKey:key]) {
        [self pipUpdateValueCellForSlider:key value:[value floatValue]];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (!_specifiers) [self specifiers];

    // 兜底镜像：把各开关当前值从 suite 同步到全局文件，
    // 覆盖「setPreferenceValue: 不被调用」的 roothide 版本。
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"com.yxh41.pipbar"];
    for (PSSpecifier *spec in _specifiers) {
        NSString *key = [spec propertyForKey:@"key"];
        if (!key) continue;
        id val = [d objectForKey:key];
        if (val) [self pipMirrorPref:key value:val throttle:NO];
    }

    [self pipBindSliders];

    // 滑块当前值显示（读全局 plist，带默认值兜底）
    NSDictionary *g = pip_globalPrefs();
    id fw = g[@"FrameWidth"];
    id bh = g[@"BarHeight"];
    [self pipUpdateValueCellForSlider:@"FrameWidth" value:fw != nil ? [fw floatValue] : 8.0];
    [self pipUpdateValueCellForSlider:@"BarHeight"  value:bh != nil ? [bh floatValue] : 40.0];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self pipBindSliders];   // 表格已布局完成，此时 cell 一定存在
}

@end
