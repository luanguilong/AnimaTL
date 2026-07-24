--!strict
-- CutsceneValidate — 导出前数据体检(24 spec)。全部提醒级,不阻断导出:
-- 编辑器数据经常是故意的半成品,阻断只会烦人;把"到运行时才炸"的问题提前说出来即可。

local CutsceneFormat = require(script.Parent.Shared.CutsceneFormat)
local VCam = require(script.Parent.Shared.VCam)
local SceneResolver = require(script.Parent.SceneResolver)

local CutsceneValidate = {}

local function trackLabel(tr: CutsceneFormat.Track, i: number): string
	return `轨 {i}({tr.kind} · {tr.target})`
end

-- 轨道是否有任何内容(空轨判定)。
local function trackHasContent(tr: CutsceneFormat.Track): boolean
	return (tr.keyframes and #tr.keyframes > 0)
		or (tr.fovKeyframes and #tr.fovKeyframes > 0)
		or (tr.clips and #tr.clips > 0)
		or (tr.events and #tr.events > 0)
		or (tr.soundCues and #tr.soundCues > 0)
		or (tr.effectCues and #tr.effectCues > 0)
		or (tr.propKeyframes and #tr.propKeyframes > 0)
		or (tr.jointTracks and #tr.jointTracks > 0)
		or (tr.screenCues and #tr.screenCues > 0)
		or #CutsceneFormat.segmentsOf(tr) > 0
end

local function collectOutOfRange(tr: CutsceneFormat.Track, dur: number): number
	local n = 0
	local function chk(t: number?)
		if t and (t < -1e-6 or t > dur + 1e-6) then
			n += 1
		end
	end
	for _, k in tr.keyframes or {} do
		chk(k.t)
	end
	for _, k in tr.fovKeyframes or {} do
		chk(k.t)
	end
	for _, k in tr.propKeyframes or {} do
		chk(k.t)
	end
	for _, c in tr.clips or {} do
		chk(c.startAt)
		chk(c.endAt)
	end
	for _, ev in tr.events or {} do
		chk(ev.t)
	end
	for _, c in tr.soundCues or {} do
		chk(c.t)
	end
	for _, c in tr.effectCues or {} do
		chk(c.t)
	end
	for _, c in tr.screenCues or {} do
		chk(c.t)
	end
	for _, s in CutsceneFormat.segmentsOf(tr) do
		chk(s.from)
		chk(s.to)
	end
	return n
end

-- 体检:返回提醒列表(空 = 干净)。绑定解析按编辑期场景(运行时 resolver 另算,提示级)。
function CutsceneValidate.run(cutscene: CutsceneFormat.Cutscene): { string }
	local warns: { string } = {}
	local dur = cutscene.duration
	local hiddenCount = 0

	for i, tr in cutscene.tracks do
		local label = trackLabel(tr, i)
		if tr.hidden then
			hiddenCount += 1
		end

		-- 悬空 vcam / 绑定
		if tr.kind == "camera" or tr.kind == "cameraMove" then
			if not VCam.find(tr.target) then
				table.insert(
					warns,
					`{label}:场景中找不到 vcam '{tr.target}'(悬空相机轨)`
				)
			end
			if tr.kind == "camera" and tr.followBinding and tr.followBinding ~= "" then
				if not SceneResolver.resolve(tr.followBinding) then
					table.insert(
						warns,
						`{label}:followBinding '{tr.followBinding}' 编辑期解析失败`
					)
				end
			end
		elseif tr.kind ~= "screen" then
			-- screen 轨 target 固定 "Screen" 不走解析
			if not SceneResolver.resolve(tr.target) then
				table.insert(
					warns,
					`{label}:绑定 '{tr.target}' 编辑期解析失败(运行时以游戏 resolver 为准)`
				)
			end
		end

		-- 空轨
		if not trackHasContent(tr) then
			table.insert(warns, `{label}:空轨(无任何关键帧/片段/cue)`)
		end

		-- camera 有运动但无生效段 → 永不上镜
		if
			tr.kind == "camera"
			and tr.keyframes
			and #tr.keyframes > 0
			and #CutsceneFormat.segmentsOf(tr) == 0
		then
			table.insert(warns, `{label}:有运动关键帧但无生效段,永不上镜`)
		end

		-- 越界 key
		local oob = collectOutOfRange(tr, dur)
		if oob > 0 then
			table.insert(warns, `{label}:{oob} 个关键帧/端点越出 [0, {dur}s]`)
		end

		-- 占位动画 id
		for _, c in tr.clips or {} do
			if c.animationId == "" or c.animationId == "rbxassetid://0" then
				table.insert(
					warns,
					`{label}:动画 clip 是占位 id(rbxassetid://0),运行时无动作`
				)
				break
			end
		end

		-- splash 缺贴图
		for _, c in tr.screenCues or {} do
			if c.kind == "splash" and (not c.imageId or c.imageId == "") then
				table.insert(warns, `{label}:splash cue 缺 imageId,运行时静默不渲染`)
				break
			end
		end
	end

	if hiddenCount > 0 then
		table.insert(warns, `{hiddenCount} 条轨道处于隐藏状态,导出后运行时会跳过`)
	end
	return warns
end

-- 跑体检并逐条打 Output;返回提醒数(导出日志带计数用)。
function CutsceneValidate.report(cutscene: CutsceneFormat.Cutscene): number
	local warns = CutsceneValidate.run(cutscene)
	if #warns > 0 then
		warn(`[anima] 导出校验:{#warns} 处提醒(不阻断导出)`)
		for _, w in warns do
			warn(`[anima]   · {w}`)
		end
	end
	return #warns
end

return CutsceneValidate
