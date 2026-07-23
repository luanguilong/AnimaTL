# Anima

Roblox 过场动画（cutscene）系统：**Studio 插件（制作）+ 运行时播放（游戏内）**。

标杆场景：人物开门 → 镜头环绕 → 特效（Forge）→ 拉远；运行时绑定玩家 **真实 Character**，装扮随骨骼自动跟随。

---

## 仓库与文档地址

| 说明 | 地址 |
|------|------|
| **本仓库（实现 + 插件源码）** | https://github.com/luanguilong/AnimaTL |
| **AI / 同事交接索引** | [AI-HANDOFF.md](./AI-HANDOFF.md) |
| **功能清单（实现快照）** | [.claude/cmr/04-features.md](./.claude/cmr/04-features.md) |
| **规格索引（CMR）** | [.claude/cmr/README.md](./.claude/cmr/README.md) |
| **B2 模板仓（仅 anima 设计规格对表）** | https://github.com/showhand-org/template/tree/main/anima |
| **Forge VFX emit 模块（特效轨对齐）** | https://github.com/zilibobi/forge-vfx |

---

## 功能介绍

### 编辑器（Studio 插件）

- **Timeline**：动画 / 相机 / 变换 / 事件 / **音效** / **特效** 多轨；磁吸、时长、导出区间等（见 CMR 11–14）。
- **相机**：虚拟相机（VCam）、贝塞尔路径、**followBinding** 相对关键帧（跟 Player / HRP）、视口 A 透视打帧（CMR 05–07）。
- **动画**：`AnimationClip`、R6/R15 `rigType`、时长匹配（CMR 08、11）。
- **特效轨**：
  - **particle**：模板名 / LoadAsset 粒子；
  - **forge**：对齐 [forge-vfx](https://github.com/zilibobi/forge-vfx) 的 `vfx.init()` + `vfx.emit(绑定实例)`（CMR **16**）。
- **持久化**：未保存草稿、💾 导出到 `ReplicatedStorage.Anima.Cutscenes`（CMR 10）。
- **构建插件**：`rojo build plugin.project.json -o build/anima.rbxm` → 安装到 `%LOCALAPPDATA%\Roblox\Plugins\`。

### 运行时（游戏内）

- **`CutscenePlayer`**：按时间轴驱动相机、动画、变换、事件、音效、特效。
- **`CharacterBinder`**：动画绑真实 Character，装扮自然跟随。
- **`EffectTrack` + `ForgeEffectPlay`**：客户端走官方 **`vfx.emit`**；过场结束对 `EmitResult:Clear()`。
- **示例启动**：`src/client/AnimaBootstrap.client.luau` — 进游戏按 **`V`** 播放 **`Player_lvti`**（需 `Cutscenes.Player_lvti` + `ReplicatedStorage.ForgeVFX`）。

### 示例过场（`cutscenes/`）

| 模块 | 说明 |
|------|------|
| `boss_intro.luau` | 手写示例 |
| `Player_lvti.luau` | Player 绑定 + 相机 follow + Forge「驴踢」演示 |
| `rig1_lvti.luau` | 旧 Rig 占位示例（可被 Timeline 导出覆盖） |

---

## 核心设计

- **数据契约唯一真相**：`src/shared/CutsceneFormat.luau`。插件生产数据，运行时消费，互不 require。
- **概念模型**：借鉴 UE Sequencer / Unity Timeline — `Cutscene → tracks[] → keyframes / cues`。
- **绑定**：轨上 `target` 为逻辑名；运行时由 **`BindingResolver`** 解析（如 `"Player"` → `LocalPlayer.Character`）。

---

## 目录

```
src/shared/     CutsceneFormat、Sampler、FollowAnchor、ForgeEffectPlay …
src/runtime/    CutscenePlayer、CameraTrack、EffectTrack、SoundTrack …
src/client/     AnimaBootstrap — 按 V 播放 Player_lvti
src/plugin/     Studio 插件（Fusion UI、导出、预览）
cutscenes/      过场 ModuleScript 源码（Rojo 同步到 ReplicatedStorage.Anima.Cutscenes）
.claude/cmr/    实现侧规格 05–16
AI-HANDOFF.md   后续 AI 入口
```

---

## 开发环境

```bash
rokit install
rojo serve default.project.json    # 同步 Runtime + Cutscenes + Bootstrap
rojo build plugin.project.json -o build/anima.rbxm
rojo build default.project.json -o build/game.rbxlx
stylua src cutscenes && selene src cutscenes
```

Windows 本机常见流程：Rojo 连 Studio + 将 `build/anima.rbxm` 拷入 Plugins 目录。

---

## 运行时接入（概要）

```lua
local CutscenePlayer = require(ReplicatedStorage.Anima.Runtime.CutscenePlayer)
local cutscene = require(ReplicatedStorage.Anima.Cutscenes.Player_lvti)

local player = CutscenePlayer.new(cutscene, {
	resolver = function(name)
		if name == "Player" then
			return localPlayer.Character
		end
		return workspace:FindFirstChild(name, true)
	end,
	camera = workspace.CurrentCamera,
	forgeVfxModule = ReplicatedStorage:FindFirstChild("ForgeVFX"), -- forge cue 必需
	onEvent = function(ev) end,
})
player:play(function() print("done") end)
```

**Forge 特效**：place 内放置 [forge-vfx Releases](https://github.com/zilibobi/forge-vfx/releases) 的 **`ForgeVFX`** ModuleScript；特效 cue 设 `emitMode = "forge"`，`forgeRoot` 留空表示对整包绑定 emit。

**Studio 试播**：同步 `AnimaBootstrap` 后 F5，Output 见 `[anima] 进游戏按 V 播放 Player_lvti`，或 `_G.AnimaPlayPlayerLvTi()`。

---

## 相机轨透视编辑（视口 A）

选中 **camera 轨** 时主视口 WASD 构图；跟随绑定与相对关键帧见 [.claude/cmr/05-camera-authoring-spec.md](./.claude/cmr/05-camera-authoring-spec.md)、[06-camera-follow-binding-spec.md](./.claude/cmr/06-camera-follow-binding-spec.md)。

---

## 状态

- ✅ 运行时 + 插件 Timeline M0（含 Forge 特效轨、音效轨、导出、草稿）
- ✅ `Player_lvti` + Bootstrap **V 键** 联调路径
- ⬜ B2 主工程 `showhand-template` 默认尚未挂载 Anima Runtime（规格见 [template/anima](https://github.com/showhand-org/template/tree/main/anima)）
