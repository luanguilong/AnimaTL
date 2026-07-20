# 03 — 后续增加功能 + 改善手感(规划)

按优先级分组。P0=手感/闭环核心,P1=编辑完成度,P2=进阶/打磨。

> ✅ 已于 2026-07-16 完成(详见 01-done):**动画轨编辑 + 预览定帧**、**事件轨编辑**、**vcam 改名**、**内联文本输入(InputPrompt)**、**transform 打帧入口**、**对象分组折叠(Track.group)**、**空格/Enter 播放**、**相机运动子轨(cameraMove:单台 vcam 关键帧运动,顶层 shots 决定谁上镜)**、**Record 录制模式**、**每相机独立轨模型(生效区间+上层优先+直线/曲线插值+行内起止两帧录制)**。下面保留仍未做的部分。

## P0 — 手感与近处闭环(优先)

- **时间轴缩放 + 横向滚动**(最影响手感):定位从 `t/duration`(Scale)改为 `pixelsPerSecond + 滚动偏移`(ScrollingFrame / 视口变换)。带来:长过场可展开、拖拽更精细、滚轮缩放、拖动画布平移。App 坐标系较大重构,但值得。
- **补齐半成品入口**:
  - vcam / 轨道 **改名**:右键→内联 TextBox 覆盖编辑,回车提交(复用一个 `promptText` helper)。
  - **改时长** UI:工具条放可编辑时间数字(TextBox)或 +/- 档,调 `EditorState.setDuration`。
- **多选 + 框选关键帧**:框选一组,整体拖移/删除/缓动。
- **复制/粘贴关键帧**(Ctrl+C/V),跨轨道同刻粘贴。
- **键盘帧步进**:`,` / `.` 上一/下一关键帧或镜头边界;空格播放/暂停;Home 回起点。

## P1 — 编辑完成度

- **动画轨道编辑**:
  - 选 AnimationId(输入 rbxassetid 或从场景/资源选)。
  - 时间轴上摆 clip(拖移 startAt、拖右边缘改时长、设 speed/looped/fadeTime)。
  - **预览窗口里真的播动画**:PreviewViewport 克隆角色上 LoadAnimation + 按 playhead `AdjustSpeed(0)` + `TimePosition` 定帧(scrub 时定格到对应帧)。
- **Record 录制模式**:进入录制后,挪场景物体/相机 → 到当前 playhead 自动打关键帧(相机可自动新建 vcam + shot)。类 Sequencer 录制,极大提速摆帧。
- **多过场浏览器**:侧栏列 `cutscenes/*`,新建 / 打开 / 另存;导入回读闭环(从 ModuleScript 载回面板)。
- **事件轨编辑**:在时间轴打 event 点,填 name + payload(音效/粒子/切镜等具名信号)。

## P2 — 进阶与打磨

- **曲线编辑器**(Graph Editor):对 transform/camera 关键帧看/编 easing 曲线,拖控制点(超越现有具名 easing 档)。
- **vcam 视锥 gizmo**:真视锥 wireframe(按 FOV/宽高比),LookAt 连线,选中时高亮。
- **CameraPath 增强**:轨迹独立显隐开关;按 shot 分段上色;blend 区间虚线;悬停显示 t/vcam。
- **预览保真**:黑边按真实输出宽高比自适应;可选安全框(action/title safe);跟随主视口时也叠加构图网格。
- **过场校验**:检测悬空 vcam 引用、空轨道、超出时长的关键帧,面板给告警。
- **DataModel 撤销整合**:vcam Part 的移动走 ChangeHistoryService,与自建数据撤销栈协调(避免两套撤销割裂)。

## 手感原则(贯穿各批)

- **拖拽即所见**:任何拖拽(时间/blend/物体)预览与 3D 轨迹实时跟随,不等松手。
- **吸附但可关**:默认吸附整数秒/相邻标记,Alt 临时关闭;缩放后吸附阈值按像素换算保持一致手感。
- **一步一撤销**:整段拖拽算一步;离散操作各自一步;快捷键就近(面板内 Ctrl+Z/Y)。
- **零 Explorer 手改**:vcam/轨道/目标全在面板内可视化管理。
- **不污染工程**:辅助实体(vcam gizmo / CameraPath)Locked / CanQuery=false / Archivable=false,不进导出、不挡选取。
