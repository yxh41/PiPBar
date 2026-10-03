# PiPBar — 画中画增强（iOS 16 / roothide）

给 iOS 系统画中画加一圈「手机壳」式外框：**顶部与左右同宽，底部加宽**，
底部放置控制条 —— 上一曲 / 播放暂停 / 下一曲（安卓 PiP 同款交互）。

- 目标环境：iPhone 12 Pro / iOS 16.4.1 / roothide（Dopamine）/ arm64e
- 作用进程：SpringBoard（系统画中画的宿主）
- 技术栈：Theos + Logos + Objective-C (ARC) + GitHub Actions 云编译（-Werror）
- 机制参考：FreePIP（sohsatoh）验证过「系统 PiP 在 SpringBoard 进程、
  SBPIPContainerViewController → PGPictureInPictureViewController」这条链路；
  本项目只参考该公开机制结论，**代码独立实现**（FreePIP 为 GPL-3，避免协议传染）。
  媒体控制走 Pegasus 的 `PGCommand +commandForPlaybackAction:` /
  `PGPictureInPictureViewController handleCommand:` 跨进程命令通道。

## 构建

推 main 后手动触发 `Build PiPBar (roothide)`，deb 从 `deb-artifacts` 分支
`out/pipbar_<sha>.deb` 取（双通道：upload-artifact + 孤儿分支）。

## 安装后怎么用

1. 安装 deb → **注销重装载（respring / 重启用户空间）**，SpringBoard 重启即生效。
2. **设置 App → 往下翻 → PiPBar**（面板 7 项）：

   | 项 | 默认 | 说明 |
   |---|---|---|
   | 启用 | 开 | 关掉后完全不注入，等于没装 |
   | 显示外框 | 开 | 圆角「手机壳」：顶/左右同宽 |
   | 显示控制按钮 | 开 | 底部三颗：上一曲 / 播放暂停 / 下一曲 |
   | 外框宽度 | 8 | 4–24 pt（v0.5 由 12 改 8：顶/左右更细） |
   | 底部高度 | 40 | 28–80 pt，比左右宽的那条 |
   | 文件日志 | 开 | 装完 respring 即有 `/var/mobile/Library/Logs/PiPBar.log` |
   | 调试日志 | 关 | 额外打 `HIER` 视图层级树（排查画错位时用） |

   改任意一项**不用 respring**，走 Darwin 通知即时热生效。
   **面板本身装完第一次 respring 后才会出现；若没有，把设置 App 上划杀掉再开。**

3. 播放任意支持画中画的视频（Safari/腾讯视频/B站等）→ 上滑触发 PiP，
   出现即自动套上外框；拖动、单击展开、双击缩放等原生手势保持可用。

## 日志怎么看

- **文件**（推荐）：「文件日志」默认开，触发一次 PiP 后即有 →
  用 Filza 打开 `/var/mobile/Library/Logs/PiPBar.log`（看不到文件 = 还没触发过 PiP，或 tweak 没加载）。
- **syslog / Console**：过滤关键字 `[PiPBar`。
- 关键行含义：
  - `HOST <- scan(strong)` → 已找到真正的视频宿主层（最理想）
  - `HOST candidate xxx 不可用` → 该私有 ivar 名在本系统不存在（正常，会换下一级）
  - `HOST fallback -> contentViewController.view` → 三级都没命中，会回到 v0.1 的错位行为，
    **请开「调试日志」把 `HIER` 那段回传**
  - `CMD playbackAction=N` → 用户点系统控制时上报的命令码（接通上一曲/下一曲的依据）
  - `reload applied:` → 设置改动已热生效

## 已知限制

- 播放/暂停已可用；**上一曲 / 下一曲待 v0.6**，需要真机 `CMD playbackAction=N` 日志
  确定 Pegasus 的 action 枚举值后接通（目前点这两颗只打日志，并 dump `PGCMD` 方法表辅助）。
- 只支持系统原生 PiP，App 内自建的假画中画不在射程内。
- roothide 下设置面板走「编译型 PreferenceLoader bundle + 全局 plist 直写桥」
  （绕过 per-app NSUserDefaults 容器隔离，SpringBoard 才能读到）。

## 版本

- v0.1：外框 + 播放/暂停（Pegasus 命令通道）+ 嗅探日志
- v0.2：设置面板（plist-only bundle）+ 文件日志 + 挂载层三级择优 + layoutSubviews 自愈 +
  hitTest 覆写 + Pegasus 钩子拆独立 %group
  （遗留：面板在 roothide 下不显示、按钮 0×0 不可见、直角边条不好看）
- v0.3：设置面板改自包含入口 plist（PreferenceLoader/Preferences/，零 bundle 依赖）+
  外框改 CAShapeLayer even-odd 圆角壳 + 按钮显式 frame + 直挂 self
  （真机仍反馈：设置不可见、外框造型差、按钮看不到）
- v0.4（build 4223ab6）：放弃自包含 plist，整套照搬 MapAdKiller 的**编译型** PreferenceLoader bundle
  （PiPBarPrefs.bundle + 全局 plist 直写桥，绕过 roothide 容器隔离）→ **设置终于可见**；
  外框从视频层搬到容器层（要外框不是内框）+ 15pt 图标随播放状态切换 + 按钮 44x32 精致化
- v0.5（build d1dd87b）：修四个真机问题 ——
  ① 遮罩：shadowPath 只用外圈路径（带洞路径当 shadowPath 会把投影投进视频区，画面像蒙黑遮罩）；
  ② 三按钮无反应：底条在 PiP 窗口外触摸不派发 → 按钮搬独立悬浮 UIWindow（windowLevel+1）+ CADisplayLink
     每帧同步位置，三颗全部可点；③ 日志文件：FileLog 默认开，装完 respring 即出 PiPBar.log；
  ④ 外框太粗：FrameWidth 默认 12→8；另加 PiP 展开 >60% 屏宽自动收起壳。
  CI 编译修复：`CGRectZero` 非编译期常量 → `(CGRect){{0,0},{0,0}}`；`PIPFrameView` 文件级静态指针
  加 `@class` 前置声明（C 前两段均 -Werror 失败）。

## 设置

设置 → PiPBar：启用 / 显示外框 / 显示控制按钮 / 外框宽度 / 底部高度 / 文件日志 / 调试日志。
所有开关走 Darwin 通知（com.yxh41.pipbar.reload），**改完立即生效，无需 respring**。

## 日志

- 文件：`/var/mobile/Library/Logs/PiPBar.log`（设置里开「文件日志」，Filza 直接翻，超 256KB 自动清空重记）
- syslog：搜 `[PiPBar`
