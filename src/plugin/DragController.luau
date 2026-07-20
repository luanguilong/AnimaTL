--!strict
-- DragController — 插件面板里的统一拖拽 / scrub 生命周期。
--
-- holdDrag:满 holdTime 进入 armed;只有鼠标移动超过阈值后才 onMove/onBegin;
-- 松开时若未移动则不改数据(走 onClick)。避免「点一下/换点按」误改关键帧时间。

local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local Theme = require(script.Parent.Theme)

local DragController = {}

local activeSession: { stop: () -> () }? = nil

local DRAG_THRESHOLD = 4

export type Handlers = {
	onBegin: (() -> ())?,
	onMove: (mouse: Vector2) -> (),
	onEnd: (() -> ())?,
	onClick: (() -> ())?,
	threshold: number?,
	holdTime: number?,
	holdDrag: boolean?,
	feedbackElement: GuiObject?,
	pressSource: GuiObject?,
}

function DragController.isDragging(): boolean
	return activeSession ~= nil
end

function DragController.begin(gui: PluginGui, handlers: Handlers): () -> ()
	if activeSession then
		activeSession.stop()
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
	local cancel: () -> ()
	local feedback = handlers.feedbackElement
	local feedbackBaseTransparency: number? = nil
	if feedback and feedback:IsA("GuiObject") then
		feedbackBaseTransparency = feedback.BackgroundTransparency
	end

	local overlay: Frame? = nil
	local fire: () -> ()

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

	local function ensureOverlay()
		if overlay then
			return
		end
		local o = Instance.new("Frame")
		o.Name = "AnimaDragOverlay"
		o.BackgroundTransparency = 1
		o.Size = UDim2.fromScale(1, 1)
		o.ZIndex = Theme.overlayZIndex
		o.Active = true
		o.Parent = gui
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
					buttonHeld = false
					stop()
				end
			end)
		)
	end

	local function onMouse1Release(_input: InputObject)
		buttonHeld = false
		stop()
	end

	local function tryDragMove(mouse: Vector2)
		if handlers.holdDrag then
			local origin = armPos or startPos
			if not draggedSinceArm then
				if (mouse - origin).Magnitude < threshold then
					return
				end
				draggedSinceArm = true
				if handlers.onBegin then
					handlers.onBegin()
				end
			end
		elseif not draggedSinceArm then
			if (mouse - startPos).Magnitude < threshold then
				return
			end
			draggedSinceArm = true
			if handlers.onBegin then
				handlers.onBegin()
			end
		end
		handlers.onMove(mouse)
	end

	function fire()
		if stopped then
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
			if handlers.holdDrag then
				ensureOverlay()
			else
				draggedSinceArm = true
				if handlers.onBegin then
					handlers.onBegin()
				end
				handlers.onMove(mouse)
			end
			return
		end
		tryDragMove(mouse)
	end

	local function stop()
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

	cancel = function()
		cancelled = true
		stop()
	end

	activeSession = { stop = stop }

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
		UserInputService.InputEnded:Connect(function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				onMouse1Release(input)
			end
		end)
	)
	table.insert(conns, gui.WindowFocusReleased:Connect(function()
		buttonHeld = false
		stop()
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

function DragController.fracInArea(area: GuiObject, mouse: Vector2): number
	local x0 = area.AbsolutePosition.X
	local w = math.max(area.AbsoluteSize.X, 1)
	return math.clamp((mouse.X - x0) / w, 0, 1)
end

function DragController.snapTime(
	t: number,
	duration: number,
	candidates: { number }?,
	thresholdSec: number,
	disable: boolean?
): number
	if disable then
		return t
	end
	local best = t
	local bestDist = thresholdSec
	local sec = math.floor(t + 0.5)
	if sec >= 0 and sec <= duration then
		local d = math.abs(t - sec)
		if d < bestDist then
			best, bestDist = sec, d
		end
	end
	if candidates then
		for _, c in candidates do
			local d = math.abs(t - c)
			if d < bestDist then
				best, bestDist = c, d
			end
		end
	end
	return best
end

return DragController
