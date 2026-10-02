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

- v0.1：外框 + 播放/暂停（Pegasus 命令通道）+ 嗅探日志（定位上一曲/下一曲 action 码）
- v0.2（计划）：接通上一曲/下一曲；外框宽度/颜色设置面板
