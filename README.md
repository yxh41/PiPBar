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
   | 显示控制按钮 | 开 | 底部三颗：上一个 / 播放暂停 / 下一个（无切歌能力时回退 ±10s） |
   | 左右键优先切歌 | 开 | 走 MediaRemote 切歌通道；关掉则始终只做 ±10s 快退快进 |
   | 外框宽度 | 8 | 4–24 pt（v0.5 由 12 改 8：顶/左右更细）。下方实时显示当前值 |
   | 底部高度 | 40 | 28–80 pt，比左右宽的那条。下方实时显示当前值 |
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

- 播放/暂停、左右键均已可用。左右键**优先走 MediaRemote 切歌通道**
  （`kMRNextTrack`/`kMRPreviousTrack`），App 无切歌能力时自动回退 ±10s 快退/快进
  （如播放单条网页视频时）。可用设置里的「左右键优先切歌」关掉切歌、只做 ±10s。
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
- v0.5.1：修「外框消失」—— `loadView` 钩触发时整棵 PiP 视图几何还都是 `{0,0}`（content.view 且
  `[hidden]`），`pipPickHostView` 找不到有尺寸的宿主、回退成**全屏** `content.view`，壳被 >60% 屏宽
  误判成「展开」而 `self.hidden=YES`。改法：① 显示链心跳（CADisplayLink）每帧用已就绪几何重解析
  真正的视频宿主 `PGLayerHostView`（`gContentVC` 弱引用持有 content VC）；② 「是否展开」改按
  **视频宽度**判（`vrW > 屏宽*0.6`），不再用画布（content.view）宽度。日志 `build=` 由 v0.2 更正为 v0.5。
  （设置里两个滑块 = **外框宽度** / **底部高度**，见上方表格）
- v0.6：三修 ——
  ① **蒙灰**：投影彻底删除。v0.5 把 shadowPath 改成无洞外圈矩形，剪影把整个视频区罩住、
     35% 黑从透明洞透出来 = 均匀蒙灰（真凶）。质感改由近黑壳 + 内沿发丝高光承担。
  ② **按钮看不见**：独立悬浮 UIWindow 两轮真机都没渲染出来（iOS 16 无 windowScene 的窗口
     大概率不显示）→ 删除。按钮改为壳（PIPFrameView，实测渲染位置正确）的子视图，叠在
     视频底部内侧（窗口边界内 ⇒ 触摸必然可达），半透明胶囊底衬。
  ③ **拖动卡顿**：删除 30fps CADisplayLink 心跳（每帧强制 layout + 窗口移动即卡顿源）。
     按钮随壳走原生视图树，拖动跟随零成本；host 重解析移到 layoutSubviews。
  另：设置面板两个滑块写明作用 + min/max 端点数值 + 标题带当前值；新增 `PGCMD-META`
  方法表 dump（class_copyMethodList 不含类方法，`+commandForXxx:` 工厂在元类上）；
  真机日志实锤系统快退/快进 = `playbackAction=1 + dict[6]=±10`，v0.7 接 seek。
- v0.7：三修 ——
  ① **外框又消失**（v0.6 回归）：v0.6 删除 CADisplayLink 心跳后，host 重解析只留在
     `layoutSubviews`，而 PiP 视频层尺寸变化**不触发父 view 重布局** → `layoutSubviews`
     不被调用 → `pipPickHostView` 永不运行 → host 卡零尺寸 → 外框永不重画
     （日志 `videoRect={{0,0},{0,0}}` 印证）。修：加回「无卡顿版」心跳 `PIPSyncSink.tick`——
     每帧算当前视频矩形，与 `gLastVR` 不等才 `setNeedsLayout`；拖动时窗口移动但画布局部
     几何不变 ⇒ 不重画 ⇒ 不卡（与 v0.6 卡顿根因不同：v0.6 是每帧强制 layout）。`loadView`
     安装壳后调用 `pipEnsureSyncLink()`。
  ② **滑块仍无数值**（v0.6 回归）：私有 `PSSliderCell` 不渲染当前值，且 `setPreferenceValue:`
     在拖动中每帧触发、用 reload 刷新标题会打断手势；`spec.name` 改法 roothide 下不刷新单元格。
     修：本 theos SDK 的 `PSSliderCell` 是枚举常量（非类，`@class` 与之冲突、无法子类化），
     故改走稳妥路线——在两个滑块下方各加一个 `PSStaticTextCell`，`setPreferenceValue:` 里
     只 `reloadSpecifier:` 该静态 cell（不重载滑块本身 ⇒ 拖动手势不被打断），实时显示「X pt」。
     进入设置页（viewWillAppear）即把当前值刷进静态 cell。
  ③ **上一曲/下一曲接通**：`frame.onTap` 的 tag1/tag3 发 `action=1 + double=∓10`
     （上一曲 −10s / 下一曲 +10s）到 `handleCommand:`，脚注同步标注快退快进语义。
  构建：roothide theos，`-Werror`，无废弃 UIKit API。
- v0.8：修「外框彻底消失」（v0.7 真机日志实锤两个叠加根因）——
  ① **心跳锁死错误宿主**：v0.7 心跳只在「当前 host 无尺寸」时重扫，但 fallback 容器
     `PGHitTestExtendableView` 是**全屏**的、装壳第一帧就有尺寸 ⇒ 重扫永远停摆 ⇒
     壳锁死在全屏容器上（日志：装壳后再无第二条 HOST 行）。修：重扫条件改为
     「还没找到真视频宿主（`PGLayerHost*`）就继续找」，节流 12Hz + 静默扫描防刷屏，
     找到/变化才打一行 `HOST tick re-pick`。
  ② **放大档 PiP 被误判全屏**：旧「>60% 屏宽」阈值会把双击放大的 PiP（约 2/3~9/10 屏宽）
     整壳隐藏。修：收紧为「宽、高同时 ≥95% 屏幕」才算全屏播放。
  参考（机制层面，未复用 GPL 代码）：FreePIP（sohsatoh）证实 PiP 位置由 NSLayoutConstraint
  钉住、其边框画在 PiP VC 自身 view 内沿所以无需同步；CaiWanFeng/PiP（App 级）证实
  KVO view 尺寸可作为心跳的替代方案（备选）。
- v0.9：v0.8 真机确认**外框已重现并正确贴合视频**（日志 `HOST <- scan(strong) PGLayerHostView
  frame={{0,0},{170,302.33}}`），本轮修三个体验问题——
  ① **按钮压到外框上**：胶囊条改为**骑跨视频下沿**（视觉向下溢出、压进底部黑边），
     按钮本体仍留在窗口内。原因：PiP 窗口边界 == 视频矩形（日志实测容器与视频层同为
     170×302.33），窗口外坐标不进入 hitTest——这正是 v0.5「按钮点不到」的根因，
     所以只能视觉骑跨、不能真放窗外。
  ② **左右键语义纠正**：用户日志里 30 个 `PGCMD-META` 工厂方法就是 Pegasus 的全部命令，
     只有 `skipByInterval`/`skipToLive`/`skipPreroll`，**没有 track/next/previous**；
     系统 AVKit PiP 本身 likewise 只有快退/快进/播放暂停。故图标由 `backward.end.fill`/
     `forward.end.fill`（切歌语义）改为 `gobackward.10`/`goforward.10`（±10s 快退快进），
     脚注与日志文案同步说明——**画中画无法切歌，这是系统能力上限**。
  ③ **滑块数值刷不出来**：根因是 roothide 下 `PSSliderCell` 拖动时未必回调
     `setPreferenceValue:`。改为 `viewWillAppear`/`viewDidAppear` 时递归找出 cell 内的
     `UISlider`，用关联对象标记幂等挂 `UIControlEventValueChanged` target，拖动即刷新；
     数值 cell 双保险刷新（直接改可见 cell 的 label + 更新 spec.name 并 reloadSpecifier）；
     拖动期全局 plist 每帧写但 darwin 通知节流 120ms，避免通知风暴。
- v0.10：**左右键真正支持「上一个/下一个」**（v0.9 判定"画中画无法切歌"只覆盖了
  Pegasus 一条通道，实际还有第二条）——
  ① 新增 **MediaRemote 切歌通道**：画中画自己的 Pegasus 命令只有 skipByInterval/
     skipToLive/skipPreroll（无 track/next/previous），但锁屏「上/下一曲」按钮走的是
     mediaserverd 的 `MediaRemote`，系统会把它路由到 App 的
     `MPRemoteCommandCenter` 的 nextTrack/previousTrack handler —— 走这条能真正切歌。
     常量出处：`Cykey/ios-reversed-headers · MediaRemote/MediaRemote.h`
     （`kMRNextTrack=4` / `kMRPreviousTrack=5`，`MRMediaRemoteSendCommand(cmd, nil)`）。
     实现用 dlopen 私有框架 + dlsym 取函数指针（不链接符号，跨版本安全）。
  ② **能力探测 + 自动回退**：该头文件**没有** `SupportsNextTrack` 能力键（只有
     SupportsFastForward15Seconds / SupportsRewind15Seconds / ProhibitsSkip /
     IsMusicApp / TotalTrackCount），无法精确探测，故用启发式：音乐类 App 或
     播放列表 >1 首 ⇒ 判为支持切歌，发 `kMRNextTrack/kMRPreviousTrack`；
     否则回退 Pegasus 的 ±10s 快退快进。日志会打出走了哪条通道及判据。
     必须调 `MRMediaRemoteKeepAlive()`，否则 now playing 回调不投递、探测永远失灵。
  ③ 设置新增开关「左右键优先切歌」（默认开）；按钮图标恢复
     `backward.end.fill`/`forward.end.fill` 切歌语义。

## 设置

设置 → PiPBar：启用 / 显示外框 / 显示控制按钮 / 外框宽度 / 底部高度 / 文件日志 / 调试日志。
所有开关走 Darwin 通知（com.yxh41.pipbar.reload），**改完立即生效，无需 respring**。

## 日志

- 文件：`/var/mobile/Library/Logs/PiPBar.log`（设置里开「文件日志」，Filza 直接翻，超 256KB 自动清空重记）
- syslog：搜 `[PiPBar`
