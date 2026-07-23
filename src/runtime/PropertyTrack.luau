--!strict
-- PropertyTrack — 逐帧把目标实例的某个属性设为关键帧插值结果(17 spec)。
-- number/Vector3/Color3 插值,boolean 等阶梯;stop 时还原原值(keepOnDone=true 保留终值)。

local Sampler = require(script.Parent.Parent.Shared.Sampler)
local CutsceneFormat = require(script.Parent.Parent.Shared.CutsceneFormat)

local PropertyTrack = {}
PropertyTrack.__index = PropertyTrack

export type PropertyTrack = typeof(setmetatable(
	{} :: {
		keyframes: { CutsceneFormat.PropKeyframe },
		target: Instance,
		propertyName: string,
		keepOnDone: boolean,
		_original: CutsceneFormat.PropValue?,
		_originalCaptured: boolean,
		_warned: boolean,
	},
	PropertyTrack
))

-- 无 propertyName / 无关键帧时返回 nil(调用方跳过本轨)。
function PropertyTrack.new(track: CutsceneFormat.Track, target: Instance): PropertyTrack?
	local propertyName = track.propertyName
	if not propertyName or propertyName == "" then
		warn(`[anima] property 轨道 '{track.target}' 缺 propertyName,跳过`)
		return nil
	end
	return setmetatable({
		keyframes = track.propKeyframes or {},
		target = target,
		propertyName = propertyName,
		keepOnDone = track.keepOnDone == true,
		_original = nil,
		_originalCaptured = false,
		_warned = false,
	}, PropertyTrack)
end

local function readProperty(self: PropertyTrack): (boolean, any)
	return pcall(function()
		return (self.target :: any)[self.propertyName]
	end)
end

local function writeProperty(self: PropertyTrack, value: any): boolean
	local ok = pcall(function()
		(self.target :: any)[self.propertyName] = value
	end)
	if not ok and not self._warned then
		self._warned = true
		warn(
			`[anima] PropertyTrack:'{self.target:GetFullName()}.{self.propertyName}' 写入失败,本轨静默`
		)
	end
	return ok
end

function PropertyTrack.update(self: PropertyTrack, t: number)
	local value = Sampler.sampleValue(self.keyframes, t)
	if value == nil then
		return
	end
	-- 首次写入前抓原值,stop 还原用
	if not self._originalCaptured then
		local ok, orig = readProperty(self)
		if ok then
			self._original = orig
			self._originalCaptured = true
		end
	end
	writeProperty(self, value)
end

function PropertyTrack.stop(self: PropertyTrack)
	if self.keepOnDone then
		return
	end
	if self._originalCaptured then
		writeProperty(self, self._original)
	end
end

return PropertyTrack
