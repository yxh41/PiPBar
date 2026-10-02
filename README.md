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
   | 显示外框 | 开 | 顶部/左右边条；关掉后只留底部 |
   | 显示控制按钮 | 开 | 底部三颗：上一曲 / 播放暂停 / 下一曲 |
   | 外框宽度 | 12 | 4–24 pt，顶部与左右同宽 |
   | 底部高度 | 40 | 28–80 pt，比左右宽的那条 |
   | 文件日志 | 关 | 打开后写 `/var/mobile/Library/Logs/PiPBar.log` |
   | 调试日志 | 关 | 打开后额外打 `HIER` 视图层级树（排查画错位时用） |

   改任意一项**不用 respring**，走 Darwin 通知即时热生效。

3. 播放任意支持画中画的视频（Safari/腾讯视频/B站等）→ 上滑触发 PiP，
   出现即自动套上外框；拖动、单击展开、双击缩放等原生手势保持可用。

## 日志怎么看

- **文件**（推荐）：设置里开「文件日志」→ 触发一次 PiP →
  用 Filza 打开 `/var/mobile/Library/Logs/PiPBar.log`（看不到文件 = 开关没开或还没触发过 PiP）。
- **syslog / Console**：过滤关键字 `[PiPBar`。
- 关键行含义：
  - `HOST <- scan(strong)` → 已找到真正的视频宿主层（最理想）
  - `HOST candidate xxx 不可用` → 该私有 ivar 名在本系统不存在（正常，会换下一级）
  - `HOST fallback -> contentViewController.view` → 三级都没命中，会回到 v0.1 的错位行为，
    **请开「调试日志」把 `HIER` 那段回传**
  - `CMD playbackAction=N` → 用户点系统控制时上报的命令码（接通上一曲/下一曲的依据）
  - `reload applied:` → 设置改动已热生效

## 已知限制

- 播放/暂停已可用；**上一曲 / 下一曲待 v0.3**，需要真机 `CMD playbackAction=N` 日志
  确定 Pegasus 的 action 枚举值后接通（目前点这两颗只打日志）。
- 只支持系统原生 PiP，App 内自建的假画中画不在射程内。

## 版本

- v0.1：外框 + 播放/暂停（Pegasus 命令通道）+ 嗅探日志
- v0.2：设置面板（启用/外框/按钮/宽度/高度/日志，翻开关即时热生效）+
  文件日志（/var/mobile/Library/Logs/PiPBar.log）+ 外框挂载层改三级择优
  （强信号扫描 → KVC ivar → 弱信号扫描 → 回退）+ layoutSubviews 自愈贴合父 bounds +
  hitTest 覆写（透明覆盖层不再吃掉 PiP 原生拖动/单击/双击）+ Pegasus 钩子拆独立 %group
- v0.3（计划）：接通上一曲/下一曲（等真机 CMD 嗅探日志拿 playbackAction 码）

## 设置

设置 → PiPBar：启用 / 显示外框 / 显示控制按钮 / 外框宽度 / 底部高度 / 文件日志 / 调试日志。
所有开关走 Darwin 通知（com.yxh41.pipbar.reload），**改完立即生效，无需 respring**。

## 日志

- 文件：`/var/mobile/Library/Logs/PiPBar.log`（设置里开「文件日志」，Filza 直接翻，超 256KB 自动清空重记）
- syslog：搜 `[PiPBar`
