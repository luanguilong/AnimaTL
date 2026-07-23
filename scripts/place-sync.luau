-- anima 模块同步器 — 命令栏执行:
-- loadstring(game:GetService("HttpService"):GetAsync("http://192.168.110.69:34871/sync/update.luau"))()
-- 把 VM 侧最新 runtime/shared/client 模块写入本 place 的 ReplicatedStorage.Anima 与 StarterPlayerScripts。

local HttpService = game:GetService("HttpService")
local RS = game:GetService("ReplicatedStorage")
local BASE = "http://192.168.110.69:34871/sync/"

local RUNTIME = {
	"CameraTrack", "CharacterBinder", "CutscenePlayer", "EffectTrack", "EventTrack",
	"ForgeApproxFx", "PropertyTrack", "RigAnimTrack", "SoundTrack", "TransformTrack",
}
local SHARED = {
	"CameraDirector", "CutsceneFormat", "Easing", "FollowAnchor", "ForgeEffectPlay",
	"PathBezier", "Sampler", "VCam", "VCamPose",
}

local function ensureFolder(parent, name)
	local f = parent:FindFirstChild(name)
	if not f then
		f = Instance.new("Folder")
		f.Name = name
		f.Parent = parent
	end
	return f
end

local anima = ensureFolder(RS, "Anima")

local function syncFolder(folderName, names)
	local folder = ensureFolder(anima, folderName)
	for _, n in names do
		local ok, src = pcall(function()
			return HttpService:GetAsync(BASE .. string.lower(folderName) .. "/" .. n .. ".luau")
		end)
		if ok then
			local m = folder:FindFirstChild(n)
			if not m then
				m = Instance.new("ModuleScript")
				m.Name = n
				m.Parent = folder
			end
			m.Source = src
			print("[anima-sync] " .. folderName .. "/" .. n)
		else
			warn("[anima-sync] 拉取失败 " .. folderName .. "/" .. n .. ": " .. tostring(src))
		end
	end
end

syncFolder("Runtime", RUNTIME)
syncFolder("Shared", SHARED)

local okC, srcC = pcall(function()
	return HttpService:GetAsync(BASE .. "client/AnimaBootstrap.client.luau")
end)
if okC then
	local sps = game:GetService("StarterPlayer"):FindFirstChild("StarterPlayerScripts")
	if sps then
		local holder = sps:FindFirstChild("AnimaClient")
		if not holder then
			holder = Instance.new("Folder")
			holder.Name = "AnimaClient"
			holder.Parent = sps
		end
		local ls = holder:FindFirstChild("AnimaBootstrap")
		if not ls then
			ls = Instance.new("LocalScript")
			ls.Name = "AnimaBootstrap"
			ls.Parent = holder
		end
		ls.Source = srcC
		print("[anima-sync] client/AnimaBootstrap")
	end
else
	warn("[anima-sync] client 拉取失败: " .. tostring(srcC))
end

print("[anima-sync] 完成 ✔ Runtime " .. #RUNTIME .. " · Shared " .. #SHARED)
