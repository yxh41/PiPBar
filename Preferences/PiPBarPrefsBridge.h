//
//  PiPBarPrefsBridge.h
//  跨进程偏好桥（范式取自 MapAdKiller / Oback，已在 roothide/iOS16.4.1 验证）：
//  roothide 下 PSSwitchCell 标准写入会落到「设置」App 自己的容器副本，SpringBoard 读不到。
//  本桥直接读写一个双方都能命中的全局 plist 物理文件，绕开 per-app 容器化。
//  函数体 static inline（ARC 安全），tweak 与设置 bundle 各编一份、互不影响。
//

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

static NSString *const kPIPGlobalPlist = @"/var/mobile/Library/Preferences/com.yxh41.pipbar.plist";
static NSString *const kPIPReloadNotify = @"com.yxh41.pipbar.reload";

// 读取全局偏好字典（文件不存在时返回空字典，调用方须判空）
static inline NSDictionary *pip_globalPrefs(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPIPGlobalPlist];
    return d ? d : @{};
}

// 写入单个 key（value 为 nil 表示删除），并广播 darwin 通知让 SpringBoard 热生效
static inline void pip_setGlobalPref(NSString *key, id value) {
    if (!key) return;
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:kPIPGlobalPlist];
    if (!d) d = [NSMutableDictionary dictionary];
    if (value) d[key] = value; else [d removeObjectForKey:key];
    [d writeToFile:kPIPGlobalPlist atomically:YES];
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)kPIPReloadNotify, NULL, NULL, YES);
}
