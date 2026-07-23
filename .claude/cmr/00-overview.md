# 00 — 项目定位与约束

## 目标

Roblox 过场动画 Studio 插件。交付两部分:
- **Studio 插件**(编辑时制作过场,类 Unity Timeline + Cinemachine)
- **运行时播放模块**(游戏内,绑玩家真实 Character 播放)

标杆场景:人物开门 → 镜头环绕人物 → 拉远到 Boss 站位。每个玩家过场按各自装扮呈现。

## 过场数据模型(借鉴 UE Sequencer / Unity Timeline)

`Cutscene ── tracks[] ── keyframes[] / shots[] / clips[] / events[]`

4 类轨道(Track):
- **animation** — 角色动画(AnimationClip,绑 target 角色播 AnimationId)
- **camera** — 镜头:优先 `shots`(vcam 引用 + blend,Cinemachine 式),回退 `keyframes`(原始 CFrame)
- **transform** — 物体变换(门/Boss 的 CFrame 关键帧)
- **event** — 事件(音效/粒子/切镜)

唯一真相 = `src/shared/CutsceneFormat.luau`。插件"生产"数据,运行时"消费",两边只依赖契约。

## 核心技术洞见

- **"每个人过场按装扮不同"几乎免费**:Roblox 动画只驱动骨骼关节(Motor6D CFrame),不碰外观。同一 AnimationId 在角色上播,装扮/配件自动跟骨骼。运行时把动画绑到玩家真实 Character 即可。
- **动画资产分 Rig**:R6 与 R15 的 AnimationId 不通用;同过场可在一条 animation 轨挂两条 clip(各带 `rigType`),运行时/预览按 Humanoid.RigType 择一。`clipMatchesRig` / `clipsForRig` 见 CutsceneFormat(08 spec)。运行时代码 rig 无关(Humanoid→Animator→LoadAnimation)。
- **vcam 相机模型(Cinemachine 式)**:vcam = `workspace.AnimaVCams` 下隐形 Part。`Part.CFrame`=机位(看向 Front/-Z),Attribute `LookAt`=目标名(自动看向),`FOV`=视野。解析 `src/shared/VCam`,blend 求值 `src/shared/CameraEval`。
- **编辑预览复用运行时求值**:插件 scrub/预览用同一套 Sampler/CameraEval,所以运行时先行、插件预览几乎免费。

## 分布式开发架构(关键约束)

- **代码/git/rojo/文件**:内网 Linux VM `fedora`(192.168.110.69),`/home/showhand/users/linguanglei/anima`。用 Bash/Read/Write。
- **Roblox Studio(有 GUI)**:开发者本地 Windows,VM 无 Studio GUI。看场景/跑 Luau/测试**只能走 roblox-studio MCP**。
- **同步**:Rojo 局域网直连,Studio 的 Rojo 插件连 `192.168.110.69:34870`。
- MCP 会频繁断连,需 `list_roblox_studios` + `set_active_studio` 重设。

## 技术选型

- 数据格式:Luau ModuleScript(`.luau` return table,运行时直接 require)
- 插件 UI:**Fusion 0.2.0**(经 wally 装 Packages,命名空间隔离,不与 X1 的 Fusion 0.3 冲突)
- 工具链:rokit(rojo 7.5.1 / stylua 2.1.0 / selene 0.29.0 / wally)

## 目录结构

```
anima/
├── plugin.project.json     # rojo:单独 build 插件 → AnimaPlugin.rbxm
├── default.project.json    # rojo:整个 DataModel → 游戏
├── src/shared/   CutsceneFormat / Easing / Sampler / VCam / CameraEval  (插件+运行时共用)
├── src/runtime/  CutscenePlayer / CameraTrack / CharacterBinder / TransformTrack / EventTrack
├── src/plugin/   见 01-done.md 插件模块清单
├── src/client/   AnimaBootstrap(播放示例)
└── cutscenes/    boss_intro.luau(手写示例)
```
