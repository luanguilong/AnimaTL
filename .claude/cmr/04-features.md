# 04 — 功能清单(代码现状快照)

> 快照时间:2026-07-16,交互修复批二之后。按**代码实际实现**整理(非规划)。
> 状态标记:✅ 已验证(构建通过且经 MCP/用户实测)/ 🟡 实现完成、待 Studio 实测 / ⚠️ 已知取舍。
> 注意:右键菜单类功能此前因嵌套 ScreenGui 不渲染**从未被真正看见过**,本批修复后全部标 🟡,建议实测时逐项点一遍。

## 1. 数据契约与共享求值(`src/shared/`)

| 功能 | 说明 | 状态 |
|------|------|------|
| CutsceneFormat | 唯一真相:Cutscene → tracks[](…);AnimationClip 含可选 `rigType`(08);`clipMatchesRig` / `clipsForRig` | ✅ |
| Easing | linear / quadIn·Out·InOut / cubicInOut / sine | ✅ |
| Sampler | CFrame 关键帧插值;smooth 且 ≥3 帧时位置走 Catmull-Rom 曲线、旋转 slerp | ✅ |
| VCam | vcam(隐形 Part)解析:CFrame 机位 + LookAt/FOV attribute;list/find/getContainer | ✅ |
| VCamPose | vcam 名 + t → 位姿:有 cameraMove 轨则采样、否则静态机位 | ✅ |
| CameraDirector | 相机求值:①覆盖 t 的独立相机轨取层级最高(tracks 索引最小)上镜,硬切;②回退老 shots;③回退无区间 camera keyframes。新旧数据兼容 | ✅ |

## 2. 运行时播放(`src/runtime/` + `src/client/`)

| 功能 | 说明 | 状态 |
|------|------|------|
| CutscenePlayer | RenderStepped 播放头调度,`play(onDone)`;注入 resolver/camera/onEvent | ✅ |
| CameraTrack | "相机导演":整场一个实例,用 CameraDirector 求值驱动 CurrentCamera | ✅ |
| CharacterBinder | 动画绑玩家**真实 Character**(只驱动 Motor6D,装扮/配件天然跟随);R6 骨架 | 🟡 装扮跟随待 Play 模式最终验证(需真实动画 id) |
| TransformTrack / EventTrack / SoundTrack / EffectTrack | CFrame 应用 / 事件 / 音效·特效 cue | ✅ |
| AnimaBootstrap 示例 | client 端 `_G.AnimaPlayBossIntro()` 播 boss_intro | ✅(动画 id 仍是占位) |

## 3. 插件 — 面板结构与工具条(`src/plugin/`)

| 功能 | 说明 | 状态 |
|------|------|------|
| 工具栏入口 | Anima ▸ 过场编辑器 / 相机预览 两个 DockWidget;载入 boss_intro 或空模板 | ✅ |
| 工具条 | 🎬 标题 · 帧 n/N(**点击可改总时长**,InputPrompt)· ⏮ ▶/⏸ ●录制 🔁循环 · ↶↷ · ＋相机 · 👁透视 · 💾导出 · 🖥跟随 · ▲/▼预览折叠 | 🟡(InputPrompt 相关此前不可见) |
| 内嵌预览横条 | 可折叠;底边拖拽分隔条调高(90–480);电影黑边 + 三分网格 + vcam/FOV/时间叠加;动画 TimePosition 定帧 | ✅ |
| vcam 管理条 | 列出所有 vcam(名·FOV·→LookAt);点选中定位 gizmo;右键改属性/改名/删 | 🟡(右键菜单) |
| 左轨道列 | 表头「＋轨道」按钮;轨道行(色条+名+绑定芯片);分组表头行(▸/▾ 折叠 + ＋子轨);相机轨行内 ◠/— 曲线切换 + ⏺ 录制 | 🟡(菜单入口) |
| 右时间轴 | 帧标尺(自适应网格)+ 竖网格线 + 播放头(红线+把手)+ 横向 ScrollingFrame;滚轮以鼠标为锚缩放 + 右下角缩放按钮 | ✅ |
| 导出 | Serializer → ModuleScript；**可选区间**（起止帧/秒，slice 后 duration 缩短、时间从 0 起）；编辑器数据不变 | ✅ |

## 4. 插件 — 时间轴编辑交互

统一手感规则(DragController,交互修复批二定稿):

- **严格长按拖拽**:按住且基本不动 **0.35s** 才进入拖拽跟随;时间没到就移动 = 本次取消(不拖不点);快速松开 = 纯点击(选中/取消/seek)。单击、快速划过**绝不误拖**。
- **吸附(Snap V1)**:整秒 + 同轨标记(clip/段头尾、关键帧等)+ **播放头**;缘拖/平移时 **同距离优先头尾接龙**;8px 阈值后再量化到帧(1/fps);**Alt** = 自由不吸附;**Shift** = 跨轨候选(V2,已实现接口)。
- **拖拽实时反馈**:拖动中不 commit(直接改数据+挪实例),松手 finishDrag 排序提交;预览/3D 轨迹每帧跟随。
- 会话自愈:松开事件漏收时,下一次按下自动作废旧会话(不再"粘鼠标")。

| 元素 | 左键长按拖 | 纯点击 | 右键菜单 | 状态 |
|------|-----------|--------|----------|------|
| 关键帧菱形 | 改时间 t | 选中 | 定位 / 缓动 / 复制+0.5s / 视口对帧调整 / 删除 | 🟡 |
| 动画 clip 块 | 改 startAt | 选中 | 定位起播 / 改 AnimationId·speed·循环 / 删除 | 🟡 |
| 事件菱形 | 改时间 t | 选中 | 定位 / 改名 / 改时间 / 删除 | 🟡 |
| 相机轨区间块 | 两端把手 resize(改 from/to)、拖身体平移 | 选中该轨 | 删轨等 | 🟡 |
| 播放头把手 | scrub(抓点不跳) | — | — | 🟡 |
| 标尺 / 行空白 | scrub | seek / 取消选中 | 轨道菜单(行)/ 新增轨道(空白) | 🟡 |

| 创建/管理入口 | 说明 | 状态 |
|------|------|------|
| ＋轨道 按钮 | 新增轨道菜单:摄像机轨 / 动画轨→选角色 / 变换轨→选目标 / 事件轨 / 相机运动轨→vcam / ＋对象分组 | 🟡(此前菜单不可见,看似失效) |
| 时间轴/左列空白右键 | 弹同一套"新增轨道"菜单(标尺区除外;轨道行/元素菜单优先) | 🟡(本批新增) |
| 轨道行右键(时间轴侧) | ＋动画片段 / ＋事件 / 打帧,**在右键点击处的时间创建**(菜单项带 `@ x.xxs`);改名 / 换目标 / 删除 | 🟡(本批新增 atTime) |
| 轨道行右键(左列侧) | 同上,创建用当前播放头时间 | 🟡 |
| 分组表头 | ▸/▾ 折叠(左右联动);＋子轨(target 默认=组名);右键改组名 / 删整组 | 🟡 |
| 相机录制 ⏺ | 起止两帧录制:开始打 from 帧 → scrub+摆相机 → 结束打 to 帧,整段一步撤销 | 🟡 |
| 撤销/重做 | 自建快照双栈(上限 60);工具条 ↶↷ + Ctrl+Z / Ctrl+Y(鼠标在面板内才响应,不与 Studio 打架);拖拽整段算一步 | ✅ |
| 播放快捷键 | 面板内(非输入态)空格 / Enter = 播放暂停 | ✅ |

## 5. 插件 — 预览与 3D 辅助

| 功能 | 说明 | 状态 |
|------|------|------|
| PreviewViewport | ViewportFrame 实时预览:Lighting 拷贝 + 地面克隆 + 按 revision 重建;动画 TimePosition 定帧(循环取模/非循环 clamp) | ✅ |
| LivePreview(🖥 跟随) | 一键接管主视口相机全保真跟随,再点归还;👁 lookThrough 取景 | ✅ |
| CameraPath | 3D 视口运镜轨迹 + 贝塞尔切线 gizmo；**预览折线段数**可右键调(自动/固定/倍率,Plugin 偏好,不影响播放) | ✅ |
| 编辑态 scrub 联动 | Preview 把 transform/camera 求值实时应用到编辑器场景 | ✅ |

## 6. 已知取舍 / 限制(详见 02-todo)

| 项 | 说明 |
|----|------|
| ⚠️ 动画预览是定帧非播放 | ViewportFrame 里 Animator 不自动 step;占位 `rbxassetid://0` 看不到动作,需真实 R6 动画 id |
| ⚠️ clip 块宽度是估计值 | 到下一 clip 或 +1.5s,非动画真实时长 |
| ⚠️ 事件 payload 无编辑 UI | 只能填事件名,payload 靠 onEvent 按名分发 |
| ✅ 多过场浏览器(2026-07-22) | 📂 导入菜单递归列出 Cutscenes 下全部模块(含子路径,超 12 个走 Explorer 导入);克隆-require 载入不吃缓存;另存/导出子路径预填上次值 |
| ⚠️ 运行时忽略 group | 分组仅编辑器组织用,运行时扁平遍历 |
