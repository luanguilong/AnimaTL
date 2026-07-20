# 01 — 已完成

状态:全部构建通过(rojo build)、stylua + selene clean。git init(main),**尚未 commit**。
部分经 MCP 在 Studio 内联实测。

## 数据契约 & 共享求值(`src/shared/`)

- **CutsceneFormat** — 唯一真相:Track(camera/transform/animation/event)、Keyframe、CameraShot(vcam+blend)、AnimationClip、CutsceneEvent、Cutscene。
- **Easing** — linear / quadIn/Out/InOut / cubicInOut / sine。
- **Sampler** — CFrame 关键帧插值(camera/transform 共用)。
- **VCam** — vcam 名 → 位姿解析(含 LookAt / FOV attribute)、list/find/getContainer。
- **CameraEval** — shots + blend 的 Cinemachine 式求值(当前 vcam,blend 区间与上一 vcam Lerp)。

## 运行时(`src/runtime/`)

- **CutscenePlayer** — RenderStepped playhead 调度。
- **CameraTrack** — shots 优先 / keyframes 回退。
- **CharacterBinder** — 绑真实 Character(装扮天然跟随)。
- **TransformTrack / EventTrack**。
- `src/client/AnimaBootstrap` — 播放示例(`_G.AnimaPlayBossIntro`)。
- `cutscenes/boss_intro.luau` — 手写示例(animationId 仍是占位 `rbxassetid://0`)。

## 插件骨架(`src/plugin/`)

- **init.server** — 工具栏 Anima ▸ 过场编辑器 / 相机预览;两个 DockWidget;载入 boss_intro 或空模板;接线全部回调。
- **App** — 时间轴面板根组件(Fusion):工具条 / 内嵌预览横条 / vcam 管理条 / 左轨道名列 / 右时间轴。
- **EditorState** — 响应式可编辑数据模型 + 编辑 API + 撤销栈。
- **Playback** — 按真实时间推进播放头(▶/⏸/🔁 循环/⏮)。
- **LivePreview** — 一键接管主视口相机全保真跟随(再点归还)+ lookThrough 取景。
- **Preview** — scrub 时把 transform/camera 求值应用到编辑器场景(复用 Sampler)。
- **SceneResolver** — 逻辑名 → 场景实例("Player"→第一个 Humanoid 占位角色)。
- **Serializer** — Cutscene → 可 require 的 `.luau` 源码(CFrame 12 分量无损);导出到 `ReplicatedStorage.AnimaExport` 供 MCP 写回文件。
- **VCamAuthoring** — 创建带 gizmo(朝向箭头 + 名字标签)的 vcam 实体;setLookAt。
- **Theme** — 暗色配色 + 尺寸常量。

## ★ 手感批(P0 + P1 + 3D 轨迹,2026-07-15)

**新增模块**
- **DragController** — 统一拖拽/scrub 生命周期。基于 `PluginGui:GetRelativeMousePosition()`(拖出小元素也不丢手,不受停靠影响),UIS 监听移动/松开。含 `fracInArea`(x→时间比例)、`snapTime`(吸附)。
- **PreviewViewport** — 可挂任意 parent 的实时预览(从旧 PreviewWindow 抽出并增强):电影黑边 + 三分构图网格 + 右上 vcam/FOV/时间叠加 + Lighting 拷贝 + 地面(Baseplate)克隆 + `refresh()` 按需重建克隆。
- **CameraPath** — 3D 视口运镜轨迹:`workspace.AnimaCameraPath`(Locked / CanQuery=false / Archivable=false,不污染导出/选取)。沿 shots 等步长(0.1s,≤240 段)采样相机连成发光曲线 + 机位球 + 朝向短杆 + 播放头处滑动当前点。面板开则建、关则毁。
- **ContextMenu** — 右键浮层(item/header/sep,点外部关闭)。

**交互(App 分层 ZIndex)**
- scrub 层(2):空白按住 = 连续 scrub;单击 = seek。
- shot 块(5):拖移 startTime;左端 blend 手柄(7)拖调 blend;右键菜单。
- 关键帧菱形(6):拖移 t;右键菜单(删/复制+0.5s/缓动)。
- 播放头把手(11):可拖 scrub。
- **拖拽 = 实时反馈**:拖动连续 setTime → RenderStepped 预览/轨迹即时跟随。
- **吸附**:整数秒 + 其它标记时间,阈值 8px→秒换算,按住 **Alt** 关闭。

**编辑完成度**
- 右键菜单:关键帧(删/复制/缓动) / shot(删/blend 档 0·0.25·0.5·1·2 / 缓动) / 轨道(换目标/删) / vcam(选中定位 gizmo / 用当前视口位姿更新 / FOV 档 / LookAt 候选 / 删)。
- **vcam 管理条**:列出所有 vcam(名·FOV·→LookAt),点选中,右键改属性。
- **轨道增删**:左列表头 ＋ 选种类(镜头/变换/动画/事件)加轨;右键轨道删/换目标。
- **自建撤销/重做**:EditorState 快照双栈(`pushUndo/undo/redo`,上限 60)。关键帧数据在插件内存,ChangeHistoryService 管不到,故自建。离散操作自压快照,拖拽由调用方开始时压一次(整段拖算一步)。工具条 ↶↷ + Ctrl+Z / Ctrl+Y(仅鼠标在面板内,避免与 Studio 撤销打架)。
- **内嵌预览横条**:面板顶部,「▲/▼ 预览」可折叠;「🖥 跟随」= 主视口全保真跟随。

**机制要点**
- `EditorState.commitTracks(structural)`:structural=true 才 `+revision`,触发预览/轨迹重建;拖拽中用 false 省重建(预览每帧自更新)。
- init 用 `Fusion.Observer(state.revision)` 驱动 `PreviewViewport:refresh()` + `CameraPath:rebuild()`。
- 修了旧 bug:`cloneTracks` 之前丢 `shots` 字段(加载带 shots 的过场会丢镜头)。
- 删除:旧 `PreviewWindow.luau`(被 PreviewViewport 取代)。

## ★ 动画轨 + 事件轨编辑批(2026-07-16)

让"纯点鼠标"也能做出多角色动画 + 声音/粒子事件的过场。

**新增模块**
- **InputPrompt** — 模态文本输入浮层(遮罩 + 标题 + TextBox + 确定/取消,回车提交)。供 AnimationId / 事件名 / speed / vcam 改名复用。

**EditorState 扩展**
- 动画片段:`addClip / removeClip / moveClip(拖) / setClipField(animationId·speed·looped·fadeTime)`。
- 事件:`addEvent / removeEvent / moveEvent(拖) / renameEvent`。
- `finishDrag` 补 clips(by startAt) / events(by t) 排序。

**App 编辑 UI**
- **animation 轨画 clip 块**:拖移 startAt;右键改 AnimationId / speed / 循环开关 / 定位 / 删除。块宽 = 到下一 clip 或 +1.5s,标签显示 id 尾号(循环显 🔁)。
- **event 轨画 event 菱形**:不旋转容器内放旋转菱形 + 上方名字标签;拖移 t;右键改名 / 定位 / 删除。
- **轨道左列右键按 kind 加入口**:animation「＋动画片段…」/ event「＋事件…」/ transform「在此刻打帧(采集目标位姿)」。
- **vcam 右键补「改名…」**(补齐上一批遗留);改名同步 shots 引用 + 校验重名(`init.onRenameVcam`)。

**PreviewViewport 动画定帧**
- 克隆角色上建 Animator + `LoadAnimation`,`Play()` 后 `AdjustSpeed(0)` 冻结,scrub 时按 `(t-startAt)*speed` 设 `TimePosition` 定格到对应帧(循环取模,非循环 clamp)。无效/占位 id(`rbxassetid://0`)静默跳过。rebuild 时清 `_animTracks`。

**init**
- `onCaptureTransform(track)`:`SceneResolver.resolve` 目标 → BasePart.CFrame / Model:GetPivot() → `captureTransform` 打帧。

## ★ 交互修复批(2026-07-16)

修用户实测的三个手感 bug。
- **bug#1 点不到具体元素、"条完全跟鼠标走"**:根因 = scrub 覆盖层(`scrubLayer` TextButton, ZIndex 2)是 rows 容器(ZIndex 1)的兄弟,在 DockWidget 的 Sibling ZIndexBehavior 下把整个轨道内容盖死,点哪都触发 scrub。修:**删除覆盖层**,空白 scrub 改由标尺(`ruler`)和每行 `trackContent` 容器自身的 `InputBegan` 处理(Active=true),关键帧/镜头/片段/事件作为子级自然叠在上层、可点可拖。rows 容器(`contentArea`)兼作坐标 area。新增 `beginScrub` / `draggedTime` 两个 helper。
- **bug#2 拖动时轨道内容闪没、要再点一下才见**:根因 = 拖拽每帧 `commitTracks` 换 tracks 引用 → Fusion 整树重建(销毁重建所有元素实例)。修:**拖拽时不 commit**,直接改数据字段(`kf.t`/`shot.startTime`/`clip.startAt`/`ev.t`/`shot.blend`)+ 挪被拖实例自身的 Position,**松手才 `finishDrag`**(排序+提交+重建到正确态)。预览/轨迹因每帧读可变对象,拖拽中照样实时反映。各渲染函数改为持自身实例引用(diamond/block/container)。
- **bug#3 播放时预览没动画**:非代码 bug —— 预览动画是 `TimePosition` 定帧,需**真实 R6 AnimationId**;占位 `rbxassetid://0` 看不到动作。且插件预览是编辑态,运行时整条播放要 Play 模式下 client 调 `CutscenePlayer`。

## ★ 分组折叠 + 播放快捷键批(2026-07-16)

面向"每个对象一条独立轨道 / UE Sequencer 式分组"的第一步。
- **播放快捷键**:面板聚焦(鼠标在面板内、非输入态)时**空格 / Enter** = 播放暂停(`init` 的 InputBegan)。
- **Track.group 字段**:`CutsceneFormat.Track` 加可选 `group`(分组名);`Serializer` 输出、`EditorState.cloneTrack` 保留。**运行时忽略 group**(仍扁平遍历,零改动)。
- **EditorState**:`addTrack(kind,target,name,group)` 加 group 参;`removeGroup(g)` 删整组轨、`renameGroup(old,new)` 改组内所有轨的 group。
- **App 分组折叠渲染**:`buildDisplayRows(tracks, collapsed)` 把扁平 tracks 折成"表头行 + 可见轨道行"序列(无 group 的平铺、有 group 的成组、折叠时藏子轨)。labelColumn/timeline 共用;折叠态存 App 的 `collapsed` Fusion.Value,左右联动。
  - 分组表头行:▸/▾ 折叠 + ◆组名 + 「＋子轨」(加 动画/变换/事件/镜头 子轨,target 默认=组名);右键 改名/删整组。
  - 顶部 ＋ 菜单加「＋ 对象分组…」(选场景对象 → 建 transform 轨 group=对象名);原"新增轨道"平铺项保留。
- 旧数据(boss_intro 无 group)照常平铺显示,向后兼容。

## ★ 阶段二:相机运动子轨批(2026-07-16)

让单台 vcam 用关键帧自己运动(环绕/推拉),不再靠摆很多机位近似。顶层镜头切换轨(shots)仍决定谁上镜+blend;某 vcam 有运动轨则其位姿=采样运动轨、否则=静态机位。

**数据 + 求值(shared)**
- **新 TrackKind `cameraMove`**:keyframes=CFrame,target=vcam 名,驱动该 vcam 自己的运动。运行时 CameraTrack 遍历时不匹配 camera/transform/... → **被忽略,仅作 poseAt 的数据源**。
- **新 `shared/VCamPose`**:`at(cutscene, name, t)` = 有 cameraMove 轨(target==name)则 `Sampler.sampleCFrame`、否则 `VCam.resolvePose`(静态+LookAt);`resolver(cutscene)` 返回 `(name,t)->CFrame` 给 CameraEval。
- **CameraEval.evaluate 的 resolve 改 `(name,t)->CFrame`**(blend 时 prev/cur 都按 t 求),`CutsceneFormat.VCamResolver` 同步改签名。

**运行时**
- `CameraTrack.new(track, camera, resolve)` 接注入的 resolver;`CutscenePlayer` 构造 `VCamPose.resolver(cutscene)` 注入。去掉 CameraTrack 里的 VCam 直连。

**插件求值(三处都接 poseAt)**:PreviewViewport / LivePreview 的 evalCamera、CameraPath 的曲线采样+头点,全部 `CameraEval.evaluate(shots, t, VCamPose.resolver(cutscene))` → 预览与 3D 轨迹实时反映相机运动。

**编辑 UI**
- cameraMove 轨走关键帧菱形渲染(有 keyframes);Theme 加 `cameraMove` 青色。
- 轨道右键加「采集相机位姿打帧」→ `cb.onCaptureCameraMove`(采集**当前编辑视口相机** CFrame,像 Cinemachine 采机位);init 实现。
- 分组表头 ＋子轨 / 顶部 ＋ 都列出「相机运动轨 → VCamN」(选一台 vcam 建 cameraMove 轨,target=该 vcam)。
- `EditorState.captureTransform` 泛化为 **`captureFrame`**(transform + cameraMove 都能打帧)。

**兼容**:default(游戏树)+ plugin 两个 rojo 工程均 build 通过;旧 boss_intro(无 cameraMove)照常。用法:摆好视口相机角度 → 在某 vcam 的运动轨上「采集相机位姿打帧」,打几帧即成一条运镜路径;该 vcam 一旦被 shot 引用上镜,就按这条路径运动。

## ★ Record 录制模式批(2026-07-16)

auto-key / scrub-and-pose:开录制后在视口摆布,自动在当前播放头打帧。
- **`EditorState.captureFrameNoUndo`**:录制专用打帧(不压快照,整段录制算一步撤销,同 t 覆盖不重复)。
- **新 `Recorder`**:开启后 RenderStepped 每帧遍历 transform / cameraMove 轨,取 target 当前 CFrame(transform→`SceneResolver.resolve` 物体、cameraMove→`VCam.find` 的 vcam Part),变化超阈值(位置 0.02 / 朝向 0.01)就 `captureFrameNoUndo` 到当前 playhead。start 压一次 undo。
- **工具条「● 录制」按钮**(激活变红,Callbacks `recordActive`/`onToggleRecord`);init 创建 Recorder,开录前先关主视口跟随让视口/gizmo 可自由摆;卸载时 stop。
- 用法:scrub 到某刻 → 在视口拖物体 / 用移动工具挪相机 gizmo → 自动记一帧;再 scrub 到别处摆 → 新帧;同刻反复摆则覆盖。整段录制一次 Ctrl+Z 撤销。

## ★ UI 修复批 2(2026-07-16,用户实测反馈)

- **播放头/scrub 松不掉(一直跟手)**:根因 = DockWidget 里 `UserInputService.InputEnded` 常收不到鼠标松开。修:DragController 每帧轮询 `IsMouseButtonPressed(MouseButton1)`,松开即 `stop()`(InputEnded 仅作保险)。现在单击=seek 一次即停、按住=持续 scrub。
- **录制红点看不见**:未激活时也给暗红底(`RGB 96,48,52`)、激活亮红;按钮从工具条最右挪到播放组内(⏮ ▶ ● 🔁)。
- **内嵌预览太小/不能调**:默认高度 156→**220**,预览容器底边加**可拖分隔条**(拖改 `previewHeight`,范围 90–480);另可点「▲ 预览」折叠,或用独立「相机预览」DockWidget(可自由缩放)。

## ★ 每相机独立轨模型批(2026-07-16,推翻 shots)

按用户要求把相机从"一条切换轨+shots"改成"**每台相机一条独立轨 = vcam + 生效区间[from,to] + 运动关键帧**"。播放时覆盖 t 的相机轨中**时间轴最上层(tracks 索引最小)**那条上镜(硬切,"看谁在上面播谁")。

**数据(shared)**
- `CutsceneFormat.Track` 加 `from`/`to`(生效区间)+ `smooth`(直线/曲线);Serializer 输出、EditorState.cloneTrack 保留。
- **新 `shared/CameraDirector.at`(实为 evaluate)**:①覆盖 t 的独立相机轨取层级最高→有 keyframes 采样(smooth)、否则 vcam 静态机位;②回退老 shots;③回退无区间老 camera keyframes。返回 (CFrame, 上镜相机名)。**新旧兼容**。
- **`Sampler.sampleCFrame(kf, t, smooth)`**:smooth 且 ≥3 帧时位置走 **Catmull-Rom 平滑曲线**、旋转仍 slerp。

**运行时**:`CameraTrack` 重写为"相机导演"(持整个 cutscene,update 用 CameraDirector);`CutscenePlayer` 整场只建一个 CameraTrack(不再每 camera 轨一个)。

**插件求值三处**改用 `CameraDirector.evaluate`:PreviewViewport(FOV 从上镜相机名取)、LivePreview、CameraPath(曲线沿时长采样当前上镜相机、机位标记=每条相机轨的关键帧)。老 CameraEval/VCamPose 直连移除。

**EditorState**:`addCameraTrack(vcam,from,to,group)`、`setTrackSmooth`;`captureFrame`/`captureFrameNoUndo` 放行 `camera` 轨打帧。

**App UI**
- **`cameraRegion`**:相机轨在时间轴画生效区间块(from~to),**两端手柄拖 resize**(改 from/to,只挪自身不 commit、松手 finishDrag),右键删轨;关键帧菱形叠在区间块上(ZIndex 6 > 块 3)可拖。
- **`cameraRowControls`**(左列相机轨行内):**◠/— 直线曲线切换**(setTrackSmooth)+ **⏺ 录制按钮**(红=录制中)。
- 顶部 ＋ 和 分组表头 ＋ 都加「＋ 摄像机(独立轨)」→ `onAddCameraTrack`。

**init**
- `onAddCameraTrack(group)`:视口位姿建 vcam + `addCameraTrack`(区间默认整段)。
- `onCameraRecord(track)`:**起止两帧录制** —— 点开始 `pushUndo`+记 `from`+`recordingCam:set`+打起始帧;点结束记 `to`+清 recordingCam+打结束帧。整段一步撤销。`recordingCam` Fusion.Value 驱动行内按钮红态。

**用法**:＋摄像机 → 出现一条相机轨 → 第1帧点行内 ⏺ 开始 → scrub 到第10帧、在视口移动相机 → 再点 ⏺ 结束 → 自动成区间[1,10]+起止两帧;拖关键帧改运动、拖区间两端改生效窗口、点 ◠ 切曲线;多条相机轨重叠时上层赢。plugin+game 两工程 build 通过。

## ★ 交互修复批二(2026-07-16,用户实测反馈:长按手感 / 右键菜单 / ＋轨道)

修用户实测三问题,根因两个:

- **右键菜单、＋轨道按钮、输入弹窗全部"没反应"**:根因 = ContextMenu / InputPrompt 把浮层建在 `Instance.new("ScreenGui")` 再挂到 PluginGui 下,而 **DockWidget 里嵌套 ScreenGui 不渲染** —— 菜单一直在弹,只是完全不可见(＋轨道按钮其实正常触发)。修:holder 改普通全尺寸透明 Frame 直接挂 PluginGui(同 DragController overlay 做法),`DisplayOrder` 改 ZIndex(菜单 2^30-1、弹窗 2^30);顺带菜单位置按面板尺寸夹紧,靠边不裁。
- **"单击后可拖拽 / 手感怪"**:HOLD_SEC 0.2s 太短(正常单击常超过被误判成拖);holdTime 判定纯看时间,按住期间移动照样到点跳拖;另有松开事件漏收(面板外/同帧松开)→ 会话不终止 → 元素粘着鼠标走。修(DragController):
  - **严格长按**:时间没到就移动越过像素阈值 = 本次取消(不拖也不算点击);按住基本不动满 holdTime 才 arm。HOLD_SEC 0.2→**0.35**。
  - **自愈兜底**:overlay 收到新的 MouseButton1 按下 = 上次松开被漏掉,立即作废会话。
  - 预览分隔条(无 holdTime、像素阈值拖)不受影响。

顺带的交互补全(用户确认的方向):

- **右键创建用点击处时间**:`showTrackMenu` 加 `atTime?`;时间轴行右键把点击 x 换算成时间(按 fps 量化)传入,「＋动画片段/＋事件/打帧」在该时间生效(菜单项文案带 `@ x.xxs`)。左列行右键仍用播放头时间。链路:`addClip/addEvent` 本就有可选时间参;`EditorState.captureFrame` 加 `t?`;init 的 `onCaptureTransform/onCaptureCameraMove` 加 `t?` 透传。
- **空白右键 = 新增轨道**:＋轨道按钮的菜单抽成 `showAddTrackMenu`(按钮/右键共用);左列空白与时间轴空白(标尺区除外)右键弹同一菜单,`task.defer + ContextMenu.justShown()` 仲裁保证轨道行/元素菜单优先。

stylua + selene clean;`rojo build plugin.project.json` 通过。待用户 Studio 实测:单击不误拖、按住 0.35s 拖、右键菜单可见、＋轨道可用、InputPrompt 弹窗可见。
