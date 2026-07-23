--!strict
-- SoundTrack — 到点播放音效 cue;stop 时清理实例。

local Debris = game:GetService("Debris")

local CutsceneFormat = require(script.Parent.Parent.Shared.CutsceneFormat)

local SoundTrack = {}
SoundTrack.__index = SoundTrack

export type SoundCueHandler = (cue: CutsceneFormat.SoundCue, target: Instance?) -> Sound?

export type SoundTrack = typeof(setmetatable(
	{} :: {
		cues: { CutsceneFormat.SoundCue },
		target: Instance?,
		handler: SoundCueHandler,
		_fired: { [number]: boolean },
		_active: { Sound },
	},
	SoundTrack
))

local function normalizeSoundId(raw: string): string
	if string.find(raw, "rbxassetid://", 1, true) then
		return raw
	end
	local digits = raw:match("^(%d+)$")
	if digits then
		return "rbxassetid://" .. digits
	end
	return raw
end

local function defaultParentForSound(target: Instance?): Instance
	if not target then
		return workspace.CurrentCamera
	end
	if target:IsA("BasePart") or target:IsA("Attachment") then
		return target
	end
	if target:IsA("Model") then
		local part = target.PrimaryPart or target:FindFirstChildWhichIsA("BasePart", true)
		if part then
			return part
		end
	end
	return workspace.CurrentCamera
end

function SoundTrack.defaultHandler(cue: CutsceneFormat.SoundCue, target: Instance?): Sound?
	if cue.soundId == "" or cue.soundId == "rbxassetid://0" then
		return nil
	end
	local sound = Instance.new("Sound")
	sound.SoundId = normalizeSoundId(cue.soundId)
	sound.Volume = cue.volume or 1
	sound.PlaybackSpeed = cue.playbackSpeed or 1
	sound.Looped = cue.looped == true
	sound.Parent = defaultParentForSound(target)
	if cue.maxDistance then
		sound.RollOffMode = Enum.RollOffMode.Inverse
		sound.RollOffMaxDistance = cue.maxDistance
	end
	sound:Play()
	if not cue.looped then
		local life = sound.TimeLength
		if life > 0 then
			Debris:AddItem(sound, life + 0.5)
		else
			Debris:AddItem(sound, 10)
		end
	end
	return sound
end

function SoundTrack.new(
	track: CutsceneFormat.Track,
	target: Instance?,
	handler: SoundCueHandler?
): SoundTrack
	return setmetatable({
		cues = track.soundCues or {},
		target = target,
		handler = handler or SoundTrack.defaultHandler,
		_fired = {},
		_active = {},
	}, SoundTrack)
end

function SoundTrack.update(self: SoundTrack, t: number)
	for i, cue in self.cues do
		if not self._fired[i] and t >= cue.t then
			self._fired[i] = true
			local played = self.handler(cue, self.target)
			if played and played:IsA("Sound") and cue.looped then
				table.insert(self._active, played)
			end
		end
	end
end

function SoundTrack.stop(self: SoundTrack)
	for _, s in self._active do
		pcall(function()
			s:Stop()
			s:Destroy()
		end)
	end
	table.clear(self._active)
	self._fired = {}
end

return SoundTrack
