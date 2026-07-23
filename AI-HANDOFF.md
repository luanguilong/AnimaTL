# Anima — 后续 AI / 同事交接索引

> **给新 AI 的第一句话**：实现与插件在 **`C:\Users\Ymz\Documents\anima`**；B2 模板仓库 **`showhand-template`** 里只有 **`anima/*.md` 规格**，没有 Runtime 源码。先读本文件，再读 `.claude/cmr/04-features.md` 与对应 NN-spec。

---

## 两个仓库怎么分

| 仓库 | 路径 | 里面有什么 |
|------|------|------------|
| **anima（实现）** | `C:\Users\Ymz\Documents\anima` | 插件、`src/shared` + `src/runtime`、构建 `build/anima.rbxm`、CMR 规格 |
| **showhand-template（B2 + 规格对表）** | `C:\Users\Ymz\Documents\showhand-template` | 游戏 `src/`（**尚未默认接入 Anima Runtime**）、`anima/05–10-*-spec.md`、`AGENTS.md` |

**改 Studio 插件 / CutscenePlayer → 只改 `Documents\anima`。**  
**改设计契约、和策划对表 → 先改 spec（两边 anima 目录同步），再改 anima 源码。**

---

## 产物 vs 源码

| 产物 | 路径 |
|------|------|
| **Studio 插件包** | `C:\Users\Ymz\Documents\anima\build\anima.rbxm` |
| **源码根目录** | `C:\Users\Ymz\Documents\anima` |
| **安装位置（本机）** | `%LOCALAPPDATA%\Roblox\Plugins\anima.rbxm` |

插件入口在顶栏 **「Anima」工具栏**（不是「插件」菜单里的 Rojo）。加载成功 Output：`[anima] 插件已加载…`

---

## 构建

```powershell
cd C:\Users\Ymz\Documents\anima
rojo build plugin.project.json -o build/anima.rbxm
```

联调游戏树（Runtime + Cutscenes 示例）：

```powershell
rojo build default.project.json -o build/game.rbxlx
# 或 rojo serve default.project.json
```

---

## 目录职责（常改文件）

```
C:\Users\Ymz\Documents\anima\
├── plugin.project.json       # 插件 Rojo 工程
├── default.project.json      # DataModel：ReplicatedStorage.Anima + 示例 Client
├── src/
│   ├── plugin/               # Studio 插件
│   │   ├── init.server.luau  # 入口、草稿、导出/导入回调
│   │   ├── App.luau          # Timeline UI
│   │   ├── EditorState.luau  # 可编辑数据 + 撤销
│   │   ├── Serializer.luau   # serialize / deserialize
│   │   ├── CutsceneExport.luau   # 导出到 Cutscenes/<子路径>/<名>
│   │   ├── EditorPersistence.luau # Plugin GetSetting 草稿
│   │   ├── MediaPreview.luau
│   │   └── ...
│   ├── shared/               # 契约 + 求值（插件与 runtime 共用）
│   │   └── CutsceneFormat.luau   # 唯一真相；08 rigType；09 sound/effect 类型
│   ├── runtime/              # 游戏内播放（接进 B2 的也是这套）
│   │   ├── CutscenePlayer.luau
│   │   ├── SoundTrack.luau / EffectTrack.luau  # 09
│   │   └── ...
│   └── client/               # AnimaBootstrap：进游戏按 V 播 Player_lvti
├── cutscenes/                # 手写/示例过场 .luau
└── .claude/cmr/              # 实现侧规格 + 04-features 快照
```

---

## 规格文档（读哪份）

| 编号 | anima 实现侧 | showhand 对表 |
|------|----------------|---------------|
| 索引 | `.claude/cmr/README.md` | `showhand-template/anima/README.md` |
| 05–07 | 相机视口 / follow / 贝塞尔 | 同主题 `05–07-*-spec.md` |
| **08** | `08-animation-rig-type-spec.md` | `anima/08-…` |
| **09** | `09-sound-effect-tracks-spec.md` | `anima/09-…` |
| **16** | `16-forge-effect-track-spec.md` | `anima/16-…`（Forge `emitMode=forge`） |
| **10** | `10-editor-persistence-spec.md` | `anima/10-…` |
| 现状清单 | `04-features.md` | — |
| 待办 | `02-todo.md` | — |

**B2 总纲**：`showhand-template/AGENTS.md`（Anima 仅列 anima/ 规格入口）。

---

## 数据流（给程序 / TA）

1. **编辑**：Studio 插件 Timeline → 轨类型 A/C/V/event/sound/effect（见 04-features）。
2. **导出**：💾 导出 → 输入 **模块名** + **子路径**（如 `Skills/Ult` + `ult_slash`）→ 写入  
   `ReplicatedStorage.Anima.Cutscenes[...]` ModuleScript，并提示 Rojo 路径 `cutscenes/Skills/Ult/ult_slash.luau`。
3. **多份过场**：每个大招/剧情 **导出一次、一个模块**；程序 `require(ReplicatedStorage.Anima.Cutscenes....)`。
4. **播放**（客户端，Runtime 接入后）：

```lua
local CutscenePlayer = require(ReplicatedStorage.Anima.Runtime.CutscenePlayer)
local cutscene = require(ReplicatedStorage.Anima.Cutscenes.Skills.Ult.ult_slash)
CutscenePlayer.new(cutscene, {
	resolver = function(name) ... end, -- "Player" / "Door" / "Boss" 与绑定名一致
	camera = workspace.CurrentCamera,
	onEvent = function(ev, target) ... end,
}):play(onDone)
```

**不需要**再写格式解析器；**不需要**游戏内再做 Studio 插件。

---

## 改代码前硬约定

- 相机/采样：**只改** `src/shared`（Sampler、CameraDirector、FollowAnchor）。
- Rig 过滤：**只改** `CutsceneFormat.clipsForRig`（08），plugin + runtime 共用。
- 音效/特效 cue：**SoundTrack / EffectTrack**（09 + **16 Forge**），与 EventTrack 分工（event = 纯逻辑名）。
- UTF-8、`--!strict`；**禁止**未确认就 git commit；**禁止**改 `showhand-template/config/`。

---

## 交给其他 AI 的 Prompt 模板

```markdown
维护 Anima（Roblox 过场插件 + Runtime）。
- 先读：C:\Users\Ymz\Documents\anima\AI-HANDOFF.md
- 实现仓库：C:\Users\Ymz\Documents\anima（不是 showhand-template/src）
- 规格：.claude/cmr/ 与 showhand-template/anima/ 对表
- 构建：rojo build plugin.project.json -o build/anima.rbxm
- 共享契约：src/shared/CutsceneFormat.luau
任务：<你的具体需求>
```

---

## 内网 / 历史路径（可选）

VM 同步开发见 `.claude/cmr/00-overview.md`（Rojo 端口、MCP Studio）。本地 Windows 以 **`C:\Users\Ymz\Documents\anima`** 为准。
