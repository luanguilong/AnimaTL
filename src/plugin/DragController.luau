--!strict
-- DragController — 插件面板里的统一拖拽 / scrub 生命周期。
--
-- holdDrag:满 holdTime 进入 armed;只有鼠标移动超过阈值后才 onMove/onBegin;
-- 松开时若未移动则不改数据(走 onClick)。避免「点一下/换点按」误改关键帧时间。

local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local OverlayHost = require(script.Parent.OverlayHost)

local DragController = {}

type Session = {
	stop: () -> (),
	cancel: () -> (),
}

local activeSession: Session? = nil

local DRAG_THRESHOLD = 4

export type Handlers = {
	onBegin: (() -> ())?,
	onMove: (mouse: Vector2) -> (),
	onEnd: (() -> ())?,
	onClick: (() -> ())?,
	onCancel: (() -> ())?,
	threshold: number?,
	holdTime: number?,
	holdDrag: boolean?,
	feedbackElement: GuiObject?,
	pressSource: GuiObject?,
	pressInput: InputObject?,
}

function DragController.isDragging(): boolean
	return activeSession ~= nil
end

function DragController.begin(gui: PluginGui, handlers: Handlers): () -> ()
	if activeSession then
		activeSession.cancel()
	end

	local conns: { RBXScriptConnection } = {}
	local stopped = false
	local startPos = gui:GetRelativeMousePosition()
	local startTime = os.clock()
	local armed = false
	local draggedSinceArm = false
	local armPos: Vector2? = nil
	local threshold = handlers.threshold or DRAG_THRESHOLD
	local buttonHeld = true

	local cancelled = false
	local editTouched = false
	local feedback = handlers.feedbackElement
	local feedbackBaseTransparency: number? = nil
	if feedback and feedback:IsA("GuiObject") then
		feedbackBaseTransparency = feedback.BackgroundTransparency
	end

	local overlay: Frame? = nil
	local stop: () -> ()
	local cancel: () -> ()
	local fire: () -> ()
	local pressInput = handlers.pressInput

	local function setHoldFeedback(progress: number?)
		if not feedback or feedbackBaseTransparency == nil then
			return
		end
		if progress == nil then
			feedback.BackgroundTransparency = feedbackBaseTransparency
			return
		end
		feedback.BackgroundTransparency = math.clamp(feedbackBaseTransparency - progress * 0.35, 0, 1)
	end

	local function destroyOverlay()
		if overlay then
			overlay:Destroy()
			overlay = nil
		end
	end

	local function finishHandlers()
		if cancelled then
			return
		end
		if armed and draggedSinceArm then
			handlers.onMove(gui:GetRelativeMousePosition())
			if handlers.onEnd then
				handlers.onEnd()
			end
		else
			if handlers.onClick then
				handlers.onClick()
			end
		end
	end

	stop = function()
		if stopped then
			return
		end
		stopped = true
		for _, c in conns do
			c:Disconnect()
		end
		table.clear(conns)
		destroyOverlay()
		setHoldFeedback(nil)
		activeSession = nil
		finishHandlers()
	end

	cancel = function()
		if editTouched and handlers.onCancel then
			handlers.onCancel()
		end
		cancelled = true
		stop()
	end

	local function onMouse1Release(_input: InputObject)
		if not buttonHeld then
			return
		end
		buttonHeld = false
		stop()
	end

	local function ensureOverlay()
		if overlay then
			return
		end
		local o = Instance.new("Frame")
		o.Name = "AnimaDragOverlay"
		o.BackgroundTransparency = 1
		o.Size = UDim2.fromScale(1, 1)
		o.ZIndex = 1
		o.Active = true
		o.Parent = OverlayHost.ensure(gui)
		overlay = o

		table.insert(
			conns,
			o.InputChanged:Connect(function(input: InputObject)
				if input.UserInputType == Enum.UserInputType.MouseMovement then
					fire()
				end
			end)
		)
		table.insert(
			conns,
			o.InputEnded:Connect(function(input: InputObject)
				if input.UserInputType == Enum.UserInputType.MouseButton1 then
					onMouse1Release(input)
				end
			end)
		)
		table.insert(
			conns,
			o.InputBegan:Connect(function(input: InputObject)
				if input.UserInputType == Enum.UserInputType.MouseButton1 then
					cancel()
				end
			end)
		)
	end

	local function tryDragMove(mouse: Vector2)
		if not buttonHeld then
			return
		end
		if handlers.holdDrag then
			local origin = armPos or startPos
			if not draggedSinceArm then
				if (mouse - origin).Magnitude < threshold then
					return
				end
				draggedSinceArm = true
				if handlers.onBegin then
					handlers.onBegin()
					editTouched = true
				end
			end
		elseif not draggedSinceArm then
			if (mouse - startPos).Magnitude < threshold then
				return
			end
			draggedSinceArm = true
			if handlers.onBegin then
				handlers.onBegin()
				editTouched = true
			end
		end
		handlers.onMove(mouse)
	end

	fire = function()
		if stopped then
			return
		end
		if pressInput and buttonHeld and pressInput.UserInputState == Enum.UserInputState.End then
			onMouse1Release(pressInput)
			return
		end
		if armed and handlers.holdDrag and not buttonHeld then
			stop()
			return
		end
		local mouse = gui:GetRelativeMousePosition()
		if not armed then
			if handlers.holdDrag and handlers.holdTime then
				local elapsed = os.clock() - startTime
				if elapsed < handlers.holdTime then
					setHoldFeedback(elapsed / handlers.holdTime)
					return
				end
				setHoldFeedback(nil)
			elseif handlers.holdTime then
				local moved = (mouse - startPos).Magnitude >= threshold
				local elapsed = os.clock() - startTime
				if elapsed < handlers.holdTime then
					setHoldFeedback(elapsed / handlers.holdTime)
					if moved then
						cancel()
					end
					return
				end
				setHoldFeedback(nil)
			elseif (mouse - startPos).Magnitude < threshold then
				return
			end
			armed = true
			armPos = mouse
			if not handlers.holdDrag then
				ensureOverlay()
				draggedSinceArm = true
				if handlers.onBegin then
					handlers.onBegin()
					editTouched = true
				end
				handlers.onMove(mouse)
			end
			return
		end
		tryDragMove(mouse)
	end

	activeSession = { stop = stop, cancel = cancel }

	local pressSource = handlers.pressSource or handlers.feedbackElement
	if pressSource then
		table.insert(
			conns,
			pressSource.InputEnded:Connect(function(input: InputObject)
				if input.UserInputType == Enum.UserInputType.MouseButton1 then
					onMouse1Release(input)
				end
			end)
		)
	end

	if not handlers.holdDrag then
		ensureOverlay()
	end

	table.insert(conns, RunService.RenderStepped:Connect(fire))
	table.insert(
		conns,
		UserInputService.InputChanged:Connect(function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseMovement then
				fire()
			end
		end)
	)
	table.insert(
		conns,
		UserInputService.InputEnded:Connect(function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				onMouse1Release(input)
			end
		end)
	)
	table.insert(conns, gui.WindowFocusReleased:Connect(function()
		buttonHeld = false
		cancel()
	end))

	return stop
end

function DragController.attach(
	gui: PluginGui,
	element: GuiObject,
	handlers: Handlers
): RBXScriptConnection
	return element.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			handlers.pressSource = element
			DragController.begin(gui, handlers)
		end
	end)
end

-- mouse 为 PluginGui:GetRelativeMousePosition();area 须为该 PluginGui 后代。
function DragController.fracInArea(area: GuiObject, mouse: Vector2, pluginGui: PluginGui): number
	local areaLeft = area.AbsolutePosition.X - pluginGui.AbsolutePosition.X
	local w = math.max(area.AbsoluteSize.X, 1)
	return math.clamp((mouse.X - areaLeft) / w, 0, 1)
end

function DragController.snapTime(
	t: number,
	duration: number,
	candidates: { number }?,
	thresholdSec: number,
	disable: boolean?,
	priorityCandidates: { number }?
): number
	if disable then
		return t
	end
	local best = t
	local bestDist = thresholdSec
	local bestPriority = false

	local function consider(c: number, priority: boolean)
		local d = math.abs(t - c)
		if d > bestDist then
			return
		end
		if d < bestDist or (d == bestDist and priority and not bestPriority) then
			best = c
			bestDist = d
			bestPriority = priority
		end
	end

	local sec = math.floor(t + 0.5)
	if sec >= 0 and sec <= duration then
		consider(sec, false)
	end
	if priorityCandidates then
		for _, c in priorityCandidates do
			consider(c, true)
		end
	end
	if candidates then
		for _, c in candidates do
			consider(c, false)
		end
	end
	return best
end

return DragController
