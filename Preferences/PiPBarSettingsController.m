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
@end

// PSSpecifier 头未声明 setProperty:forKey:，补声明以直接调用（避免 -Werror 告警）
@interface PSSpecifier (PIPSetProp)
- (void)setProperty:(id)property forKey:(NSString *)key;
@end

// PSListController 头未声明 readPreferenceValue:（读 specifier 当前值，滑块标题要用）
@interface PSListController (PIPReadPref)
- (id)readPreferenceValue:(PSSpecifier *)specifier;
@end

@implementation PiPBarSettingsController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

// roothide 下 PSSwitchCell 的标准写入可能落到「设置」App 的 per-app 容器副本，
// 而 tweak 读的是全局 plist 文件。故每次变更都镜像写一份到全局文件。
- (void)setPreferenceValue:(id)value forSpecifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value forSpecifier:specifier];
    NSString *key = [specifier propertyForKey:@"key"];
    if (key) pip_setGlobalPref(key, value);
    // v0.6：滑块当前值写进行标题（不 reload 表格 —— reload 会打断拖动手势；
    // 单元格下次自然重渲染 / 重进页面时即可见）
    [self pipRefreshSliderTitle:specifier];
}

// 把两个滑块的标题带上当前值，如「外框宽度（顶/左右边框粗细）: 8 pt」
- (void)pipRefreshSliderTitle:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    if (key == nil) return;
    id val = [self readPreferenceValue:spec];
    if (val == nil) return;
    CGFloat f = [val floatValue];
    NSString *base = nil;
    if ([key isEqualToString:@"FrameWidth"])      base = @"外框宽度（顶/左右边框粗细）";
    else if ([key isEqualToString:@"BarHeight"])  base = @"底部高度（视频下方黑边条）";
    else return;
    spec.name = [NSString stringWithFormat:@"%@: %.0f pt", base, f];
}

// 兜底镜像：打开设置页时把各开关当前值从 suite 同步到全局文件，
// 覆盖「setPreferenceValue: 不被调用」的 roothide 版本。
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (!_specifiers) [self specifiers];
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"com.yxh41.pipbar"];
    for (PSSpecifier *spec in _specifiers) {
        NSString *key = [spec propertyForKey:@"key"];
        if (!key) continue;
        id val = [d objectForKey:key];
        if (val) pip_setGlobalPref(key, val);   // 仅镜像有显式值的 key；nil 跳过
        [self pipRefreshSliderTitle:spec];      // v0.6：滑块标题带上当前值
    }
}

@end
