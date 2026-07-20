# anima

Roblox 过场动画(cutscene)系统:**Studio 插件(制作)+ 运行时播放模块(游戏内)**。

标杆场景:人物开门 → 镜头环绕人物 → 拉远到 Boss 站位;运行时绑定玩家**真实 Character**,每个玩家过场按各自装扮不同呈现。

## 核心设计

- **数据契约唯一真相**:`src/shared/CutsceneFormat.luau`。插件"生产"过场数据,运行时"消费"它,两边不互相依赖。
- **概念模型借鉴 UE Sequencer / Unity Timeline**:`Cutscene → tracks[] → keyframes[]`,每条 track 有一个 `target`(Binding 逻辑名),运行时映射到真实实例。
- **装扮跟随是天然特性**:Roblox 动画只驱动骨骼关节(Motor6D),不碰外观。把动画绑到玩家真实 R15 Character 上播,accessories/装扮自动跟随。见 `CharacterBinder`。

## 目录

```
src/shared/     CutsceneFormat / Easing / Sampler   —— 编辑&运行时共用契约
src/runtime/    CutscenePlayer + CameraTrack/CharacterBinder/TransformTrack/EventTrack
src/client/     AnimaBootstrap.client —— client 端播放示例
src/plugin/     Studio 插件(阶段二,Fusion UI + 关键帧采集)
cutscenes/      过场数据资源(boss_intro 为手写示例)
```

轨道类型:`animation`(角色动画)/ `camera`(镜头 CFrame)/ `transform`(门、Boss 的 CFrame)/ `event`(音效、粒子、切镜)。

## 开发环境

代码/git/rojo 在 Linux VM;Roblox Studio 在本地 Windows,走 rojo 局域网同步 + roblox-studio MCP 验证。

```bash
rokit install                                   # 装 rojo/stylua/selene
rojo serve                                      # VM 上起同步服务(Studio Rojo 插件连 192.168.110.69:34872)
rojo build default.project.json -o game.rbxlx   # 或直接 build 游戏
rojo build plugin.project.json  -o anima.rbxm   # build 插件
stylua src cutscenes && selene src cutscenes    # 格式化 + lint
```

## 运行时用法

```lua
local player = CutscenePlayer.new(cutscene, {
    resolver = function(name)          -- 逻辑名 → 真实实例
        if name == "Player" then return localCharacter end
        return workspace:FindFirstChild(name, true)
    end,
    camera = workspace.CurrentCamera,
    onEvent = function(event, target) ... end,
})
player:play(function() print("done") end)
```

在 Studio 里可调 `_G.AnimaPlayBossIntro()` 手动触发示例过场。

## 状态

- ✅ 阶段一:骨架 + 数据契约 + 运行时播放器 + 手写 boss_intro(已构建通过)
- ⬜ 待 Studio 验证:装扮跟随 + 整条链路(走 roblox-studio MCP)
- ⬜ 阶段二:Studio 插件时间轴 UI + 关键帧采集
