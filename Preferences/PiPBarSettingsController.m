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

// ⚠️ roothide 的 PSListController.h 未公开声明 setPreferenceValue:forSpecifier:，
// 但 PreferenceLoader 运行时确实实现该方法；补前向声明让 [super setPreferenceValue:...]
// 通过 -Werror 编译（否则报 "no visible @interface declares the selector"）。
@interface PSListController (PIPSetPrefForward)
- (void)setPreferenceValue:(id)value forSpecifier:(PSSpecifier *)specifier;
- (void)reloadSpecifier:(PSSpecifier *)specifier;
@end

// PSSpecifier 头未声明 setProperty:forKey:，补声明以直接调用（避免 -Werror 告警）
@interface PSSpecifier (PIPSetProp)
- (void)setProperty:(id)property forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
@end

@implementation PiPBarSettingsController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

// 滑块 key → 配对「实时数值」静态 cell 的 key
- (NSString *)pipStaticKeyForSlider:(NSString *)sliderKey {
    if ([sliderKey isEqualToString:@"FrameWidth"]) return @"FrameWidthVal";
    if ([sliderKey isEqualToString:@"BarHeight"]) return @"BarHeightVal";
    return nil;
}

// 在已加载的 specifiers 里按 key 找 specifier
- (PSSpecifier *)pipSpecWithKey:(NSString *)key {
    if (!key) return nil;
    for (PSSpecifier *s in _specifiers) {
        NSString *k = [s propertyForKey:@"key"];
        if (k != nil && [k isEqualToString:key]) return s;
    }
    return nil;
}

// 把「当前值」写入滑块下方的静态 cell，并只 reload 该 cell（不重载滑块本身，不打断拖动）
- (void)pipRefreshValueCellForSlider:(NSString *)sliderKey value:(CGFloat)f {
    NSString *staticKey = [self pipStaticKeyForSlider:sliderKey];
    if (staticKey == nil) return;
    PSSpecifier *st = [self pipSpecWithKey:staticKey];
    if (st == nil) return;
    NSString *base = [sliderKey isEqualToString:@"FrameWidth"] ? @"外框宽度" : @"底部高度";
    st.name = [NSString stringWithFormat:@"%@：当前 %.0f pt", base, f];
    if ([self respondsToSelector:@selector(reloadSpecifier:)]) {
        [self reloadSpecifier:st];
    }
}

// roothide 下 PSSwitchCell 的标准写入可能落到「设置」App 的 per-app 容器副本，
// 而 tweak 读的是全局 plist 文件。故每次变更都镜像写一份到全局文件。
- (void)setPreferenceValue:(id)value forSpecifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value forSpecifier:specifier];
    NSString *key = [specifier propertyForKey:@"key"];
    if (key) pip_setGlobalPref(key, value);
    // 滑块实时数值：只 reload 下方静态 cell，不碰滑块 cell ⇒ 拖动手势不被打断
    if ([key isEqualToString:@"FrameWidth"] || [key isEqualToString:@"BarHeight"]) {
        [self pipRefreshValueCellForSlider:key value:[value floatValue]];
    }
}

// 兜底镜像：打开设置页时把各开关当前值从 suite 同步到全局文件，
// 覆盖「setPreferenceValue: 不被调用」的 roothide 版本；并把两个滑块的当前值刷进静态 cell。
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (!_specifiers) [self specifiers];
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"com.yxh41.pipbar"];
    for (PSSpecifier *spec in _specifiers) {
        NSString *key = [spec propertyForKey:@"key"];
        if (!key) continue;
        id val = [d objectForKey:key];
        if (val) pip_setGlobalPref(key, val);   // 仅镜像有显式值的 key；nil 跳过
    }
    // 进入页面即把两个滑块当前值显示到静态 cell（读全局 plist，带默认值兜底）
    NSDictionary *g = pip_globalPrefs();
    id fw = g[@"FrameWidth"];
    id bh = g[@"BarHeight"];
    [self pipRefreshValueCellForSlider:@"FrameWidth"
                                 value:fw != nil ? [fw floatValue] : 8.0];
    [self pipRefreshValueCellForSlider:@"BarHeight"
                                 value:bh != nil ? [bh floatValue] : 40.0];
}

@end
