# 02 — 未完成 / 待办 / 已知取舍

## 半成品 / 已知取舍

- ~~**改时长**:工具条无 UI 触发~~ → 已解决:点工具条帧数标签弹 InputPrompt 改总时长(但此前 InputPrompt 不渲染,实际待实测)。
- ~~**缩放/滚动**:整条过场铺满面板宽度~~ → 已解决:横向 ScrollingFrame + 滚轮以鼠标为锚缩放 + 右下角缩放按钮。
- **动画预览是"定帧"非"播放"**:PreviewViewport 用 `TimePosition` 定格,scrub 才动;播放时靠每帧推进 `TimePosition`,非引擎原生播放(ViewportFrame 里 Animator 不自动 step)。占位 `rbxassetid://0` 看不到动作,需真实 R6 动画 id。
- **clip 块宽度是估计值**(到下一 clip 或 +1.5s),非动画真实时长(真实时长要加载后 `AnimationTrack.Length` 才知)。
- **事件 payload 无编辑 UI**:只能填 event 名,payload(音效 id / 粒子参数)仍需手写或在 onEvent handler 里按名分发。

## 功能待办

- **多过场浏览器**:新建 / 打开 / 另存多个 cutscene(当前只载入单个 boss_intro 或空模板)。
- **导入回读**:目前只有导出(→ AnimaExport,MCP 写回文件);缺"从文件/场景重新载入到面板"闭环 UI。

## 打磨待办

- vcam 视锥 gizmo 美化(当前是长方体 + 箭头贴图,可换真视锥 wireframe)。
- CameraPath 轨迹开关按钮(目前随面板开关,无独立显隐;实体虽 Locked/CanQuery=false 但一直在场景里)。
- 预览横条尺寸/黑边比例自适应(当前黑边固定 11%,非按真实输出宽高比动态算)。

## 验证待办(task#4 装扮跟随最终验证)

- 仍需真实 R6 开门动画 id + 场景放 Door/Boss 物体。
- boss_intro 里 animationId 仍是占位 `rbxassetid://0`。
- 需 Play 模式跑 boss_intro 截图确认装扮跟随。R6 骨架已定。

## 工程待办

- git 尚未 commit(等用户要求)。
- 手感批尚未经 MCP 在真实 Studio 实测(GUI 交互 MCP 截不到,靠用户手动验证 + 控制台日志)。
