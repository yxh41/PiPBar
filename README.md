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

## 版本

- v0.1：外框 + 播放/暂停（Pegasus 命令通道）+ 嗅探日志
- v0.2：设置面板（启用/外框/按钮/宽度/高度/日志，翻开关即时热生效）+
  文件日志（/var/mobile/Library/Logs/PiPBar.log）+ 外框挂载层改运行时选择
  （v0.1 贴在容器层会伸到可见区外，真机截图已证明）+ 边条全部 layoutSubviews 重算
- v0.3（计划）：接通上一曲/下一曲（等真机 CMD 嗅探日志拿 playbackAction 码）

## 设置

设置 → PiPBar：启用 / 显示外框 / 显示控制按钮 / 外框宽度 / 底部高度 / 文件日志 / 调试日志。
所有开关走 Darwin 通知（com.yxh41.pipbar.reload），**改完立即生效，无需 respring**。

## 日志

- 文件：`/var/mobile/Library/Logs/PiPBar.log`（设置里开「文件日志」，Filza 直接翻，超 256KB 自动清空重记）
- syslog：搜 `[PiPBar`
