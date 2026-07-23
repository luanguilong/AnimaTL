--!strict
-- ForgeEffectPlay — 对齐 forge-vfx 官方 emit API(vfx.init / vfx.emit)。
-- 插件编辑期不得 require ForgeVFX(VFX-DL);Play 时可用 shared.vfx 或 runtime 注入的 ModuleScript。

local RunService = game:GetService("RunService")

local ForgeEffectPlay = {}

local function isForgeApi(api: any): boolean
	return typeof(api) == "table" and typeof(api.emit) == "function"
end

function ForgeEffectPlay.ensureInit(api: any): boolean
	if not isForgeApi(api) then
		return false
	end
	if api.setup == true then
		return true
	end
	if typeof(api.init) == "function" then
		local ok = pcall(api.init)
		return ok and api.setup == true
	end
	return false
end

-- 优先 shared.vfx(已由游戏侧 init);否则 require 注入的 ForgeVFX ModuleScript。
function ForgeEffectPlay.resolveApi(forgeVfxModule: ModuleScript?): any?
	if RunService:IsClient() then
		-- selene: allow(global_usage) -- forge 官方 API 即挂在 shared.vfx
		local sharedVfx = rawget(shared, "vfx")
		if isForgeApi(sharedVfx) then
			ForgeEffectPlay.ensureInit(sharedVfx)
			return sharedVfx
		end
	end
	if forgeVfxModule then
		local ok, mod = pcall(require, forgeVfxModule)
		if ok and isForgeApi(mod) then
			ForgeEffectPlay.ensureInit(mod)
			return mod
		end
	end
	return nil
end

-- 官方签名: emit(instance) 或 emit(scale, instance...)
function ForgeEffectPlay.emitOnRoot(api: any, root: Instance, scale: number): (boolean, any?)
	if not ForgeEffectPlay.ensureInit(api) then
		return false, nil
	end
	local ok, result = pcall(function()
		if scale ~= 1 then
			return api.emit(scale, root)
		end
		return api.emit(root)
	end)
	return ok, result
end

function ForgeEffectPlay.registerClear(trackForgeClears: { () -> () }, emitResult: any)
	if typeof(emitResult) == "table" and typeof(emitResult.Clear) == "function" then
		table.insert(trackForgeClears, function()
			pcall(emitResult.Clear, emitResult)
		end)
	end
end

return ForgeEffectPlay
