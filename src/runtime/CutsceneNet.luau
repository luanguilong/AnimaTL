--!strict
-- CutsceneNet — 服务器触发全员播放(22 spec)。
--
-- 权威:只有 server 广播;client 只按名字在 Cutscenes 白名单树内查模块(防注入),
-- 用 GetServerTimeNow 对时 seek 进场;迟到玩家由 server 单发同一消息走同一条路径。
--
-- server 端:
--   local net = CutsceneNet.initServer({ lateJoinMode = "seek" })
--   net:playAll("Skills/Ult/ult_slash")   -- 名字 = Cutscenes 下路径,"/"分隔
-- client 端:
--   CutsceneNet.initClient({ resolver = ..., forgeVfxModule = ..., onFinished = ... })

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CutscenePlayer = require(script.Parent.CutscenePlayer)
local CutsceneFormat = require(script.Parent.Parent.Shared.CutsceneFormat)

local REMOTE_NAME = "AnimaCutscene"
local STREAM_TIMEOUT_SEC = 2

local CutsceneNet = {}

local function animaFolder(): Instance
	return ReplicatedStorage:WaitForChild("Anima")
end

-- 白名单查找:name 只允许是 Cutscenes 树内的 "/" 路径,拒绝任意 Instance/路径注入。
local function findCutsceneModule(name: string): ModuleScript?
	local node: Instance? = animaFolder():FindFirstChild("Cutscenes")
	for _, part in string.split(name, "/") do
		if not node or part == "" or part == ".." then
			return nil
		end
		node = node:FindFirstChild(part)
	end
	if node and node:IsA("ModuleScript") then
		return node
	end
	return nil
end

local REMOTE_WAIT_SEC = 10

local function getRemote(create: boolean): RemoteEvent?
	local anima = animaFolder()
	local remotes = anima:FindFirstChild("Remotes")
	if not remotes then
		if create then
			local folder = Instance.new("Folder")
			folder.Name = "Remotes"
			folder.Parent = anima
			remotes = folder
		else
			-- client 侧限时等 server initServer 创建;超时返回 nil,不永久挂起
			remotes = anima:WaitForChild("Remotes", REMOTE_WAIT_SEC)
		end
	end
	if not remotes then
		return nil
	end
	local remote = remotes:FindFirstChild(REMOTE_NAME)
	if not remote then
		if create then
			local ev = Instance.new("RemoteEvent")
			ev.Name = REMOTE_NAME
			ev.Parent = remotes
			remote = ev
		else
			remote = remotes:WaitForChild(REMOTE_NAME, REMOTE_WAIT_SEC)
		end
	end
	if remote and remote:IsA("RemoteEvent") then
		return remote
	end
	return nil
end

-- ============================== server ==============================

export type ServerOpts = {
	lateJoinMode: ("seek" | "skip")?, -- 迟到玩家:seek(缺省)= 从当前进度进场;skip = 不播
}

export type ServerController = {
	playAll: (self: ServerController, name: string) -> boolean,
	stopAll: (self: ServerController) -> (), -- V2 预留:目前仅清 active 记录,不打断已播客户端
}

function CutsceneNet.initServer(opts: ServerOpts?): ServerController
	assert(RunService:IsServer(), "[anima] CutsceneNet.initServer 只能在 server 调用")
	local remote = getRemote(true)
	assert(remote, "[anima] CutsceneNet:无法创建 RemoteEvent")
	local lateJoinMode = (opts and opts.lateJoinMode) or "seek"

	local active: { name: string, startClock: number, duration: number }? = nil

	Players.PlayerAdded:Connect(function(player)
		if not active or lateJoinMode ~= "seek" then
			return
		end
		local a = active :: { name: string, startClock: number, duration: number }
		if workspace:GetServerTimeNow() - a.startClock < a.duration then
			remote:FireClient(player, "play", a.name, a.startClock)
		end
	end)

	local controller = {}

	function controller.playAll(_self: ServerController, name: string): boolean
		local mod = findCutsceneModule(name)
		if not mod then
			warn(`[anima] CutsceneNet:找不到过场 '{name}',未广播`)
			return false
		end
		local ok, data = pcall(require, mod)
		if not ok or type(data) ~= "table" or type((data :: any).duration) ~= "number" then
			warn(`[anima] CutsceneNet:过场 '{name}' 数据无效,未广播`)
			return false
		end
		local startClock = workspace:GetServerTimeNow()
		active = { name = name, startClock = startClock, duration = (data :: any).duration }
		remote:FireAllClients("play", name, startClock)
		return true
	end

	function controller.stopAll(_self: ServerController)
		active = nil
	end

	return controller :: ServerController
end

-- ============================== client ==============================

export type ClientConfig = {
	resolver: CutsceneFormat.BindingResolver,
	camera: Camera?,
	onEvent: any?,
	onSoundCue: any?,
	onEffectCue: any?,
	forgeVfxModule: ModuleScript?,
	screenDisplayOrder: number?,
	onFinished: ((name: string, skipped: boolean?) -> ())?,
}

-- StreamingEnabled 降级:关键绑定解析失败 → 围绕过场发生地请求流送一次再重试。
local function preResolveWithStreaming(cutscene: CutsceneFormat.Cutscene, config: ClientConfig)
	if not workspace.StreamingEnabled then
		return
	end
	local missing = false
	for _, tr in cutscene.tracks do
		if tr.kind == "animation" or (tr.kind == "camera" and tr.followBinding) then
			local name = if tr.kind == "camera" then tr.followBinding :: string else tr.target
			if not config.resolver(name) then
				missing = true
				break
			end
		end
	end
	if not missing then
		return
	end
	-- 流送锚点:首个带位姿关键帧的相机/变换轨,否则本地角色
	local anchor: Vector3? = nil
	for _, tr in cutscene.tracks do
		if tr.keyframes then
			for _, kf in tr.keyframes do
				if kf.value then
					anchor = (kf.value :: CFrame).Position
					break
				end
			end
		end
		if anchor then
			break
		end
	end
	if not anchor then
		local char = Players.LocalPlayer and Players.LocalPlayer.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		anchor = if hrp and hrp:IsA("BasePart") then hrp.Position else nil
	end
	if anchor then
		local player = Players.LocalPlayer
		if player then
			local done = false
			task.spawn(function()
				pcall(function()
					player:RequestStreamAroundAsync(anchor :: Vector3, STREAM_TIMEOUT_SEC)
				end)
				done = true
			end)
			local deadline = os.clock() + STREAM_TIMEOUT_SEC
			while not done and os.clock() < deadline do
				task.wait(0.05)
			end
		end
	end
	-- 重试后仍缺的绑定交给 CutscenePlayer 现有 warn-and-skip 路径,不阻塞整场
end

function CutsceneNet.initClient(config: ClientConfig)
	assert(RunService:IsClient(), "[anima] CutsceneNet.initClient 只能在 client 调用")
	local remote = getRemote(false)
	if not remote then
		warn("[anima] CutsceneNet:client 未找到 RemoteEvent(server 未 initServer?)")
		return
	end

	local activePlayer: CutscenePlayer.CutscenePlayer? = nil

	remote.OnClientEvent:Connect(function(msg: string, name: string, startClock: number)
		if msg ~= "play" or type(name) ~= "string" or type(startClock) ~= "number" then
			return
		end
		if activePlayer and (activePlayer :: any)._playing then
			return
		end
		local mod = findCutsceneModule(name)
		if not mod then
			warn(`[anima] CutsceneNet:client 找不到过场 '{name}'`)
			return
		end
		local ok, cutscene = pcall(require, mod)
		if not ok or type(cutscene) ~= "table" then
			warn(`[anima] CutsceneNet:过场 '{name}' require 失败`)
			return
		end
		local cs = cutscene :: CutsceneFormat.Cutscene
		local startAt = math.max(workspace:GetServerTimeNow() - startClock, 0)
		if startAt >= cs.duration then
			return -- 收到时已播完(极端延迟)
		end
		preResolveWithStreaming(cs, config)
		local player = CutscenePlayer.new(cs, {
			resolver = config.resolver,
			camera = config.camera,
			onEvent = config.onEvent,
			onSoundCue = config.onSoundCue,
			onEffectCue = config.onEffectCue,
			forgeVfxModule = config.forgeVfxModule,
			screenDisplayOrder = config.screenDisplayOrder,
		})
		activePlayer = player
		player:play(function(skipped)
			activePlayer = nil
			if config.onFinished then
				config.onFinished(name, skipped)
			end
		end, startAt)
	end)
end

return CutsceneNet
