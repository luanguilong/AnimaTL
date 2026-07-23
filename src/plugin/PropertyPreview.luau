--!strict
-- PropertyPreview — 编辑 scrub 时把属性轨求值应用到场景/小窗克隆(17 spec)。
-- 按 context(workspace / viewport)各自记录首次写入前的原值,restore 时还原,
-- 保证 scrub 不在工程里留脏状态。revision 变更 / 面板关闭时由调用方 restore。

local Sampler = require(script.Parent.Shared.Sampler)
local CutsceneFormat = require(script.Parent.Shared.CutsceneFormat)

local PropertyPreview = {}

type Context = {
	-- originals[inst][prop] = 首次写入前的原值
	originals: { [Instance]: { [string]: any } },
}

local _contexts: { [string]: Context } = {}
local _warnedWrite: { [string]: boolean } = {}

local function getContext(contextId: string): Context
	local ctx = _contexts[contextId]
	if not ctx then
		ctx = { originals = {} }
		_contexts[contextId] = ctx
	end
	return ctx
end

local function captureOriginal(ctx: Context, inst: Instance, prop: string)
	local perInst = ctx.originals[inst]
	if perInst and perInst[prop] ~= nil then
		return
	end
	local ok, v = pcall(function()
		return (inst :: any)[prop]
	end)
	if not ok then
		return
	end
	if not perInst then
		perInst = {}
		ctx.originals[inst] = perInst
	end
	perInst[prop] = v
end

local function writeProp(inst: Instance, prop: string, value: any)
	local ok = pcall(function()
		(inst :: any)[prop] = value
	end)
	if not ok then
		local key = inst:GetFullName() .. "." .. prop
		if not _warnedWrite[key] then
			_warnedWrite[key] = true
			warn(`[anima] PropertyPreview:'{key}' 写入失败,已静默`)
		end
	end
end

-- 把 t 时刻的属性轨求值应用到 resolveBinding 解析出的实例上。
function PropertyPreview.apply(
	cutscene: CutsceneFormat.Cutscene,
	t: number,
	resolveBinding: CutsceneFormat.BindingResolver,
	contextId: string
)
	local ctx = getContext(contextId)
	for _, track in cutscene.tracks do
		if track.kind ~= "property" or track.hidden then
			continue
		end
		local prop = track.propertyName
		if not prop or prop == "" or not track.propKeyframes then
			continue
		end
		local inst = resolveBinding(track.target)
		if not inst then
			continue
		end
		local value = Sampler.sampleValue(track.propKeyframes, t)
		if value == nil then
			continue
		end
		captureOriginal(ctx, inst, prop)
		writeProp(inst, prop, value)
	end
end

-- 还原某 context(缺省全部)记录的原值并清空。
function PropertyPreview.restore(contextId: string?)
	if contextId then
		local ctx = _contexts[contextId]
		if not ctx then
			return
		end
		for inst, perInst in ctx.originals do
			if inst.Parent then
				for prop, v in perInst do
					writeProp(inst, prop, v)
				end
			end
		end
		table.clear(ctx.originals)
		return
	end
	for id in _contexts do
		PropertyPreview.restore(id)
	end
end

return PropertyPreview
