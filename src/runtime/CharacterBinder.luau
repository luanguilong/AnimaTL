--!strict
-- CharacterBinder — 把动画轨道播到"真实角色"上,装扮自动跟随。
--
-- 核心洞见:Roblox 动画只驱动骨骼关节(Motor6D),不碰外观。
-- 只要 target 是玩家真实的 Character,accessories/body/mesh 会跟着骨骼走,
-- 于是"每个人过场按各自装扮不同"天然成立 —— 本模块不做任何外观处理。
--
-- 职责:在给定 Model 上拿到 Animator,LoadAnimation 并按时间轴调度播放/停止。

local CharacterBinder = {}
CharacterBinder.__index = CharacterBinder

local CutsceneFormat = require(script.Parent.Parent.Shared.CutsceneFormat)

export type CharacterBinder = typeof(setmetatable(
	{} :: {
		model: Model,
		animator: Animator,
		_tracks: { [string]: AnimationTrack }, -- animationId -> track
	},
	CharacterBinder
))

-- 从一个角色 Model 取得(或创建)Animator。
-- R15/R6 都有 Humanoid;Animator 挂在 Humanoid 下。
local function resolveAnimator(model: Model): Animator?
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return nil
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	return animator
end

function CharacterBinder.new(model: Model): CharacterBinder?
	local animator = resolveAnimator(model)
	if not animator then
		warn(`[anima] CharacterBinder: 目标 {model:GetFullName()} 没有 Humanoid/Animator`)
		return nil
	end
	return setmetatable({
		model = model,
		animator = animator,
		_tracks = {},
	}, CharacterBinder)
end

-- 载入一个 AnimationId,返回可复用的 AnimationTrack。
function CharacterBinder.load(self: CharacterBinder, animationId: string): AnimationTrack
	local existing = self._tracks[animationId]
	if existing then
		return existing
	end
	local anim = Instance.new("Animation")
	anim.AnimationId = animationId
	local track = self.animator:LoadAnimation(anim)
	self._tracks[animationId] = track
	return track
end

function CharacterBinder.stopClip(self: CharacterBinder, animationId: string, fadeTime: number?)
	local track = self._tracks[animationId]
	if track then
		track:Stop(fadeTime or 0.1)
	end
end

-- 播放一个片段。
function CharacterBinder.playClip(self: CharacterBinder, clip: CutsceneFormat.AnimationClip)
	local track = CharacterBinder.load(self, clip.animationId)
	track.Looped = clip.looped == true
	track:Play(clip.fadeTime or 0.1)
	track:AdjustSpeed(clip.speed or 1)
end

-- 停止全部(过场结束/取消时清理)。
function CharacterBinder.stopAll(self: CharacterBinder, fadeTime: number?)
	for _, track in self._tracks do
		track:Stop(fadeTime or 0.1)
	end
end

return CharacterBinder
