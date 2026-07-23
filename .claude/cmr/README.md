# CMR — anima 项目索引

**anima** = Roblox 过场动画(cutscene)Studio 插件 + 运行时播放模块。
标杆场景:人物开门 → 镜头环绕 → 拉远到 Boss。定位 = Unity Timeline + Cinemachine 的 Roblox 等价物,让策划不写代码做过场。

本文件夹是**项目索引**(CMR),分类记录进度与规划。权威开发记忆另见
`~/.claude/projects/-home-showhand-users-linguanglei-anima/memory/`(anima-* 系列)。

## 索引

| 文件 | 内容 |
|------|------|
| [00-overview.md](00-overview.md) | 项目定位、架构、关键约束(端口/rig/分布式) |
| [01-done.md](01-done.md) | 已完成功能清单(运行时 / 数据契约 / 插件 / 手感批) |
| [02-todo.md](02-todo.md) | 未完成 / 待办 / 已知取舍 |
| [03-roadmap.md](03-roadmap.md) | 后续增加功能 + 改善手感的规划(分优先级) |
| [04-features.md](04-features.md) | **功能清单快照**(按代码现状分区列表 + 验证状态 ✅/🟡/⚠️) |
| [05-camera-authoring-spec.md](05-camera-authoring-spec.md) | **相机轨透视编辑(视口 A)** M0 行为约定 |
| [06-camera-follow-binding-spec.md](06-camera-follow-binding-spec.md) | **followBinding** 相对关键帧 |
| [07-camera-bezier-path-spec.md](07-camera-bezier-path-spec.md) | **贝塞尔路径 + 切线 gizmo** M0–M4 实现规格 |
| [08-animation-rig-type-spec.md](08-animation-rig-type-spec.md) | **AnimationClip.rigType** R6/R15 单文件双 clip |
| [09-sound-effect-tracks-spec.md](09-sound-effect-tracks-spec.md) | **sound / effect 轨** |
| [10-editor-persistence-spec.md](10-editor-persistence-spec.md) | **草稿 / 导入 / 另存** |

## 一句话现状(截至 2026-07-16)

运行时闭环 + 相机 vcam 模型 + 时间轴插件均已落地并构建通过。
已完成:拖拽手感 + 拖拽即实时预览(内嵌横条) + 3D 运镜轨迹 + 右键菜单 + vcam 管理条 +
轨道增删 + 自建撤销重做 + 动画轨/事件轨编辑 + **对象分组折叠(UE Sequencer 式)** +
**相机运动子轨(cameraMove:单台 vcam 关键帧运镜,顶层 shots 决定谁上镜)** + 空格/Enter 播放。
全部 stylua/selene clean、default(游戏树)与 plugin 两个 rojo 工程均 build 通过。

## 构建 & 重装工作流

1. VM:`cd anima && stylua src/ && selene src/ && rojo build plugin.project.json -o build/AnimaPlugin.rbxm`
2. 下载服务(端口 34871,服务 `build/` 目录)常驻;不在则
   `cd build && setsid nohup python3 -m http.server 34871 --bind 0.0.0.0 >httplog 2>&1 </dev/null &`
3. Windows Studio 重下覆盖 `http://192.168.110.69:34871/AnimaPlugin.rbxm` → 自动重载
4. 验证:MCP `get_console_output` 看 `[anima] 插件已加载`(GUI 截不到,截图只出 3D 视口)

> rojo serve 端口 = **34870**(34872 是别的项目 X1,勿占);共享 OS 用户,禁 `pkill -f rojo`。
