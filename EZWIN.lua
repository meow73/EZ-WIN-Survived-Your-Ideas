--[[
    EZ WIN  |  by orang ganteng
    Library: https://sirius.menu/rayfield (official loader)
    Docs:    https://docs.sirius.menu/rayfield
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer

local HUB_NAME = "EZ WIN"
local HUB_CREDIT = "by orang ganteng"
local PROMPT_SCALE = 0.90
local WINDOW_SCALE = 0.85
local DRAG_THRESHOLD = 8

local ok, Rayfield = pcall(function()
    return loadstring(game:HttpGet("https://sirius.menu/rayfield"))()
end)

if not ok or type(Rayfield) ~= "table" then
    warn("[EZ WIN] Failed to load Rayfield: " .. tostring(Rayfield))
    return
end

local function safe(name, fn)
    return function(...)
        local success, err = pcall(fn, ...)
        if not success then
            warn(("[EZ WIN] Error in '%s': %s"):format(name, tostring(err)))
            Rayfield:Notify({
                Title = "Script Error",
                Content = ("'%s' failed. Check the console (F9)."):format(name),
                Duration = 5,
            })
        end
    end
end

local function getHumanoid()
    local character = LocalPlayer and LocalPlayer.Character
    return character and character:FindFirstChildOfClass("Humanoid")
end

local function isAlive(humanoid)
    return humanoid ~= nil and humanoid.Health > 0
end

local function disconnect(connection)
    if connection then
        connection:Disconnect()
    end
end

local function disconnectAll(connections)
    for _, connection in ipairs(connections) do
        connection:Disconnect()
    end
end

local State = {
    -- Speed: ONE mode decides everything. "Default" | "Fast" | "Turbo" | "Custom"
    SpeedMode = "Default",
    SpeedValue = 16,           -- slider value, only used while SpeedMode == "Custom"

    JumpEnabled = false,
    JumpValue = 50,
    DefaultJump = 50,

    InfJumpDebounce = false,
    InfJumpConnection = nil,

    Notifications = true,
}

local Anchor = {
    Active = false,
    Saved = nil,
    Heartbeat = nil,
    Toggle = nil,
    Button = nil,
    OnRelease = nil,
}

local UI = {}

local Presets = {
    Default = 16,
    Fast = 40,
    Turbo = 80,
}
local SPEED_OPTIONS = { "Default", "Fast", "Turbo", "Custom" }

-- Sets a Rayfield element without ever erroring (callbacks are idempotent, so no loops)
local function syncElement(element, value)
    if element then
        pcall(function()
            element:Set(value)
        end)
    end
end

local function notify(title, content)
    if State.Notifications then
        Rayfield:Notify({ Title = title, Content = content, Duration = 3 })
    end
end

local function getTargetSpeed()
    if State.SpeedMode == "Custom" then
        return State.SpeedValue
    end
    return Presets[State.SpeedMode]
end

local function applySpeed()
    if Anchor.Active then return end
    local humanoid = getHumanoid()
    if humanoid then
        humanoid.WalkSpeed = getTargetSpeed()
    end
end

--// Single entry point for every speed change (toggle, dropdown, reset).
--// Returns true if the mode actually changed. Calling it with the current mode is a no-op,
--// which is what stops the toggle <-> dropdown syncing from looping.
local function setSpeedMode(mode, silent)
    if mode ~= "Custom" and not Presets[mode] then
        mode = "Default"
    end
    if mode == State.SpeedMode then return false end

    State.SpeedMode = mode
    applySpeed()
    syncElement(UI.SpeedToggle, mode == "Custom")
    syncElement(UI.SpeedPreset, { mode })

    if not silent then
        notify("Speed Mode", ("%s (%d)"):format(mode, getTargetSpeed()))
    end
    return true
end

local function applyJump()
    if Anchor.Active then return end
    local humanoid = getHumanoid()
    if humanoid then
        humanoid.UseJumpPower = true
        humanoid.JumpPower = State.JumpEnabled and State.JumpValue or State.DefaultJump
    end
end

--// Infinite Jump (JumpFly) - based on the Infinite Yield "infjump" behavior
local function setInfiniteJump(enabled)
    disconnect(State.InfJumpConnection)
    State.InfJumpConnection = nil

    if enabled then
        State.InfJumpConnection = UserInputService.JumpRequest:Connect(function()
            if State.InfJumpDebounce then return end
            State.InfJumpDebounce = true

            local humanoid = getHumanoid()
            if humanoid then
                humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
            end

            task.wait()
            State.InfJumpDebounce = false
        end)
    end
end

---------------------------------------------------------------------
-- DRAG HELPERS (tap vs. drag, kept on screen)
---------------------------------------------------------------------
local function clampToScreen(target, bounds)
    local gui = target:FindFirstAncestorWhichIsA("ScreenGui")
    if not gui then return end

    local gp, gs = gui.AbsolutePosition, gui.AbsoluteSize
    local p, s = bounds.AbsolutePosition, bounds.AbsoluteSize
    local dx, dy = 0, 0

    if p.X < gp.X then
        dx = gp.X - p.X
    elseif p.X + s.X > gp.X + gs.X then
        dx = (gp.X + gs.X) - (p.X + s.X)
    end
    if p.Y < gp.Y then
        dy = gp.Y - p.Y
    elseif p.Y + s.Y > gp.Y + gs.Y then
        dy = (gp.Y + gs.Y) - (p.Y + s.Y)
    end

    if dx ~= 0 or dy ~= 0 then
        local pos = target.Position
        target.Position = UDim2.new(pos.X.Scale, pos.X.Offset + dx, pos.Y.Scale, pos.Y.Offset + dy)
    end
end

--[[
    makeMovable(target, handle, opts)
    - target: the GuiObject whose Position is changed
    - handle: the GuiObject that receives the press (mouse or touch)
    - opts.bounds       : object kept on screen (defaults to target)
    - opts.onTap()      : called on release if the press did NOT turn into a drag
    - opts.onDragStart(): called once when the drag threshold is passed
    - opts.onFinish(moved): called on release (moved = true if it was dragged)
]]
local function makeMovable(target, handle, opts)
    opts = opts or {}
    local bounds = opts.bounds or target

    handle.InputBegan:Connect(function(input)
        local inputType = input.UserInputType
        if inputType ~= Enum.UserInputType.MouseButton1 and inputType ~= Enum.UserInputType.Touch then
            return
        end

        local startInput = input.Position
        local startPos = target.Position
        local moved = false
        local finished = false
        local changedConnection, endedConnection

        local function finish()
            if finished then return end
            finished = true
            disconnect(changedConnection)
            disconnect(endedConnection)
            if opts.onFinish then pcall(opts.onFinish, moved) end
            if not moved and opts.onTap then pcall(opts.onTap) end
        end

        changedConnection = UserInputService.InputChanged:Connect(function(changed)
            if changed ~= input and changed.UserInputType ~= Enum.UserInputType.MouseMovement then
                return
            end

            local delta = changed.Position - startInput
            if not moved then
                if delta.Magnitude < DRAG_THRESHOLD then return end
                moved = true
                if opts.onDragStart then pcall(opts.onDragStart) end
            end

            target.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
            clampToScreen(target, bounds)
        end)

        endedConnection = input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                finish()
            end
        end)
    end)
end

---------------------------------------------------------------------
-- RAYFIELD TWEAKS: movable minimized button
---------------------------------------------------------------------
local function isRayfieldGui(gui)
    if not gui:IsA("ScreenGui") then return false end
    local main = gui:FindFirstChild("Main")
    return main ~= nil and main:FindFirstChild("Topbar") ~= nil
end

local function findRayfieldGui()
    local containers = {}

    if typeof(gethui) == "function" then
        local okHui, hui = pcall(gethui)
        if okHui and hui then table.insert(containers, hui) end
    end
    local okCore, core = pcall(function() return game:GetService("CoreGui") end)
    if okCore and core then table.insert(containers, core) end
    local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if playerGui then table.insert(containers, playerGui) end

    local fallback
    for _, container in ipairs(containers) do
        local okChildren, children = pcall(function() return container:GetChildren() end)
        if okChildren then
            for _, gui in ipairs(children) do
                if isRayfieldGui(gui) then
                    if gui.Name == "Rayfield" then return gui end
                    fallback = fallback or gui
                end
            end
        end
    end
    return fallback
end

-- The button only exists on touch devices (Rayfield's own behavior).
local function setupPromptDrag(rfGui)
    local prompt = rfGui:FindFirstChild("Prompt")
    local interact = prompt and prompt:FindFirstChild("Interact")
    if not prompt or not interact then return false end

    -- Rayfield keeps tweening the prompt's own Position, so we move a wrapper frame instead.
    local wrapper = Instance.new("Frame")
    wrapper.Name = "EZWINPromptDrag"
    wrapper.BackgroundTransparency = 1
    wrapper.BorderSizePixel = 0
    wrapper.Active = false
    wrapper.Size = UDim2.fromScale(1, 1)
    wrapper.Position = UDim2.fromOffset(0, 0)
    wrapper.ZIndex = prompt.ZIndex
    wrapper.Parent = rfGui
    prompt.Parent = wrapper

    local scale = Instance.new("UIScale")
    scale.Name = "EZWINScale"
    scale.Scale = PROMPT_SCALE
    scale.Parent = prompt

    makeMovable(wrapper, interact, {
        bounds = prompt,
        -- Hide Rayfield's click area while dragging so releasing a drag doesn't reopen the window
        onDragStart = function()
            interact.Visible = false
        end,
        onFinish = function(moved)
            if moved then
                task.delay(0.2, function()
                    if interact and interact.Parent then
                        interact.Visible = true
                    end
                end)
            end
        end,
    })

    return true
end

-- Scales only the Rayfield window (Main). The minimized button, anchor button and
-- notifications live outside Main, so they keep their own sizes.
local function applyWindowScale(rfGui)
    local main = rfGui:FindFirstChild("Main")
    if not main then return false end

    local windowScale = main:FindFirstChild("EZWINWindowScale")
    if not windowScale then
        windowScale = Instance.new("UIScale")
        windowScale.Name = "EZWINWindowScale"
        windowScale.Parent = main
    end
    windowScale.Scale = WINDOW_SCALE
    return true
end

local rayfieldGui = findRayfieldGui()
if rayfieldGui then
    local okPrompt, promptResult = pcall(setupPromptDrag, rayfieldGui)
    if not okPrompt then
        warn("[EZ WIN] Could not make the minimized button movable: " .. tostring(promptResult))
    end
else
    warn("[EZ WIN] Could not find the Rayfield GUI; the minimized button tweak was skipped.")
end

---------------------------------------------------------------------
-- RESIZABLE WINDOW (grip in the bottom-right corner only)
---------------------------------------------------------------------
local RESIZE_CONFIG = {
    MinSize = Vector2.new(400, 200),            -- smallest window (width, height); 400 wide keeps all tabs + sliders readable
    HandleSize = 32,
    GripColor = Color3.fromRGB(210, 210, 220),
    ScreenMargin = 16,
}

local function fillWidth(object)
    local height = object.Size.Y
    object.Size = UDim2.new(1, 0, height.Scale, height.Offset)
end

local function setupWindowResize(rfGui)
    local main = rfGui:FindFirstChild("Main")
    if not main then return false end
    if main:FindFirstChild("EZWINResizeRight") then return true end

    local defaultSize = nil   -- Rayfield's own size, remembered on the first resize
    local userSize = nil
    local resizing = false
    local restoring = false
    local grip
    local applyingLayout = false
    local layoutQueued = false

    local function layoutSlider(item)
        local title = item:FindFirstChild("Title")
        local track = item:FindFirstChild("Main")
        if title and title:IsA("TextLabel") then
            title.Position = UDim2.new(0, 10, 0, 5)
            title.Size = UDim2.new(1, -20, 0, 18)
            title.TextXAlignment = Enum.TextXAlignment.Left
        end
        if not (track and track:IsA("Frame")) then return end

        local trackSize = track.Size
        local progress = track:FindFirstChild("Progress")
        local fillRatio

        if progress then
            fillRatio = progress:GetAttribute("EZWINFillRatio")
            if fillRatio == nil then
                fillRatio = math.clamp(progress.AbsoluteSize.X / math.max(track.AbsoluteSize.X, 1), 0, 1)
                progress:SetAttribute("EZWINFillRatio", fillRatio)
            end

            if not progress:GetAttribute("EZWINRatioWatcher") then
                progress:SetAttribute("EZWINRatioWatcher", true)
                progress:GetPropertyChangedSignal("Size"):Connect(function()
                    if not applyingLayout and track.AbsoluteSize.X > 0 then
                        progress:SetAttribute(
                            "EZWINFillRatio",
                            math.clamp(progress.AbsoluteSize.X / track.AbsoluteSize.X, 0, 1)
                        )
                    end
                end)
            end
        end

        track.Position = UDim2.new(0, 10, 0, 30)
        track.Size = UDim2.new(1, -20, trackSize.Y.Scale, trackSize.Y.Offset)

        if progress and fillRatio then
            local newTrackWidth = math.max(track.AbsoluteSize.X, 1)
            progress.Size = UDim2.new(0, math.max(5, newTrackWidth * fillRatio), 1, 0)
        end
    end

    local function layoutPage(page)
        fillWidth(page)

        for _, item in ipairs(page:GetChildren()) do
            if item:IsA("Frame")
                and item.Name ~= "SectionSpacing"
                and item.Name ~= "SectionTitle"
                and item.Name ~= "Placeholder" then

                local itemSize = item.Size
                item.Size = UDim2.new(1, math.min(itemSize.X.Offset, -20), itemSize.Y.Scale, itemSize.Y.Offset)

                local itemMain = item:FindFirstChild("Main")
                if item.Name == "Slider" or itemMain and itemMain:FindFirstChild("Progress") then
                    layoutSlider(item)
                end
            end
        end
    end

    local function applyResponsiveLayout()
        if applyingLayout or not main.Parent then return end
        applyingLayout = true

        local topbar = main:FindFirstChild("Topbar")
        local tabList = main:FindFirstChild("TabList")
        local elements = main:FindFirstChild("Elements")

        if topbar then
            fillWidth(topbar)
        end

        if tabList then
            fillWidth(tabList)
            if tabList:IsA("ScrollingFrame") then
                tabList.Active = true
                tabList.ScrollingEnabled = true
                tabList.ScrollingDirection = Enum.ScrollingDirection.X
                tabList.AutomaticCanvasSize = Enum.AutomaticSize.X
                tabList.CanvasSize = UDim2.new(0, 0, 0, 0)
                tabList.ScrollBarThickness = 0
                tabList.ScrollBarImageTransparency = 1
            end
        end

        if elements then
            fillWidth(elements)
            for _, page in ipairs(elements:GetChildren()) do
                if page:IsA("ScrollingFrame") and page.Name ~= "Template" then
                    layoutPage(page)
                end
            end
        end

        applyingLayout = false
    end

    local function queueResponsiveLayout()
        if layoutQueued then return end
        layoutQueued = true
        task.defer(function()
            layoutQueued = false
            applyResponsiveLayout()
        end)
    end

    local function windowScaleValue()
        local windowScale = main:FindFirstChild("EZWINWindowScale")
        return windowScale and windowScale.Scale or 1
    end

    -- Total scale between screen pixels and the window's Size offsets
    local function guiScale()
        local uiScale = rfGui:FindFirstChildOfClass("UIScale")
        return windowScaleValue() * (uiScale and uiScale.Scale or 1)
    end

    local function currentSize()
        local size = main.Size
        if size.X.Scale == 0 and size.Y.Scale == 0 then
            return Vector2.new(size.X.Offset, size.Y.Offset)
        end
        local abs = main.AbsoluteSize / guiScale()
        return Vector2.new(abs.X, abs.Y)
    end

    local function updateGrip()
        if grip then
            grip.Visible = main.Visible and main.AbsoluteSize.Y > 120
        end
    end

    local function addGrip(handle)
        local size = RESIZE_CONFIG.HandleSize
        for i = 1, 3 do
            local k = 5 * i
            local line = Instance.new("Frame")
            line.AnchorPoint = Vector2.new(0.5, 0.5)
            line.BackgroundColor3 = RESIZE_CONFIG.GripColor
            line.BackgroundTransparency = 0.35
            line.BorderSizePixel = 0
            line.Size = UDim2.fromOffset(6 * i, 2)
            line.Rotation = -45
            line.Position = UDim2.fromOffset(size - k, size - k)
            line.ZIndex = 101
            line.Parent = handle
        end
    end

    local function createGrip()
        local size = RESIZE_CONFIG.HandleSize
        local handle = Instance.new("Frame")
        handle.Name = "EZWINResizeRight"
        handle.AnchorPoint = Vector2.new(1, 1)
        handle.Position = UDim2.new(1, -4, 1, -4)
        handle.Size = UDim2.fromOffset(size, size)
        handle.BackgroundTransparency = 1
        handle.BorderSizePixel = 0
        handle.Active = true       -- takes the press so the content behind doesn't scroll
        handle.ZIndex = 100
        handle.Parent = main
        addGrip(handle)
        grip = handle

        handle.InputBegan:Connect(function(input)
            local inputType = input.UserInputType
            if inputType ~= Enum.UserInputType.MouseButton1 and inputType ~= Enum.UserInputType.Touch then
                return
            end

            defaultSize = defaultSize or main.Size
            resizing = true

            local scale = guiScale()
            local startInput = Vector2.new(input.Position.X, input.Position.Y)
            local startSize = currentSize()
            local startPos = main.Position
            local anchor = main.AnchorPoint
            local screen = rfGui.AbsoluteSize / scale
            local maxW = math.max(RESIZE_CONFIG.MinSize.X, screen.X - RESIZE_CONFIG.ScreenMargin * 2)
            local maxH = math.max(RESIZE_CONFIG.MinSize.Y, screen.Y - RESIZE_CONFIG.ScreenMargin * 2)

            local finished = false
            local changedConnection, endedConnection, inputEndedConnection

            local function finish()
                if finished then return end
                finished = true
                resizing = false
                disconnect(changedConnection)
                disconnect(endedConnection)
                disconnect(inputEndedConnection)
                userSize = main.Size
            end

            changedConnection = UserInputService.InputChanged:Connect(function(changed)
                if changed ~= input and changed.UserInputType ~= Enum.UserInputType.MouseMovement then
                    return
                end

                local delta = (Vector2.new(changed.Position.X, changed.Position.Y) - startInput) / scale

                local newW = math.clamp(startSize.X + delta.X, RESIZE_CONFIG.MinSize.X, maxW)
                local newH = math.clamp(startSize.Y + delta.Y, RESIZE_CONFIG.MinSize.Y, maxH)
                local dW = newW - startSize.X
                local dH = newH - startSize.Y

                -- Keep the opposite edge and the top edge fixed while the window grows
                -- (the window is drawn at windowScale, so its visual growth is dW * windowScale)
                local visualScale = windowScaleValue()
                local shiftX = anchor.X * dW * visualScale
                local shiftY = anchor.Y * dH * visualScale

                main.Size = UDim2.fromOffset(newW, newH)
                main.Position = UDim2.new(
                    startPos.X.Scale, startPos.X.Offset + shiftX,
                    startPos.Y.Scale, startPos.Y.Offset + shiftY
                )
            end)

            endedConnection = input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    finish()
                end
            end)
            inputEndedConnection = UserInputService.InputEnded:Connect(function(ended)
                if ended == input then
                    finish()
                end
            end)
        end)

    end

    createGrip()

    local topbar = main:FindFirstChild("Topbar")
    if topbar then
        topbar:GetPropertyChangedSignal("Size"):Connect(queueResponsiveLayout)
    end
    main:GetPropertyChangedSignal("AbsoluteSize"):Connect(queueResponsiveLayout)
    main.DescendantAdded:Connect(queueResponsiveLayout)
    queueResponsiveLayout()

    -- Rayfield tweens the window back to its default size when you minimize/reopen it.
    -- When that happens, put the player's chosen size back.
    main:GetPropertyChangedSignal("Size"):Connect(function()
        updateGrip()
        queueResponsiveLayout()
        if resizing or restoring or not userSize or not defaultSize then return end

        local size = main.Size
        local atDefault = math.abs(size.X.Offset - defaultSize.X.Offset) < 1
            and math.abs(size.Y.Offset - defaultSize.Y.Offset) < 1
        if atDefault and size ~= userSize then
            restoring = true
            local tween = TweenService:Create(
                main,
                TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
                { Size = userSize }
            )
            tween.Completed:Once(function()
                restoring = false
            end)
            tween:Play()
        end
    end)
    main:GetPropertyChangedSignal("Visible"):Connect(updateGrip)
    updateGrip()

    return true
end

---------------------------------------------------------------------
-- SCRIPT 1: ESP / CHAMS (converted to start/stop so it can be toggled)
---------------------------------------------------------------------
local ESP_CONFIG = {
    Color = Color3.fromRGB(0, 120, 255),
    StrokeColor = Color3.fromRGB(0, 0, 0),
    FillTransparency = 0.6,
    OutlineTransparency = 0.8,
    StrokeTransparency = 0.25,
    TextSize = 14,
    Font = Enum.Font.GothamBold,
    LabelWidth = 200,
    HeadOffset = 2,
    MaxDistance = 1000,
    MaxHighlights = 31,
    WaitTimeout = 10,
}

local ESP_LINE_HEIGHT = ESP_CONFIG.TextSize + 4

local ESP = {
    Running = false,
    Entries = {},
    PlayerConnections = {},
    Ranked = {},
    RenderConnection = nil,
    AddedConnection = nil,
    RemovingConnection = nil,
}

local function rootOf(character)
    return character and character:FindFirstChild("HumanoidRootPart")
end

local function byDistance(a, b)
    return a.distance < b.distance
end

local function espCreateLabel(parent, row)
    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Position = UDim2.fromOffset(0, row * ESP_LINE_HEIGHT)
    label.Size = UDim2.new(1, 0, 0, ESP_LINE_HEIGHT)
    label.Font = ESP_CONFIG.Font
    label.TextSize = ESP_CONFIG.TextSize
    label.TextColor3 = ESP_CONFIG.Color
    label.TextStrokeColor3 = ESP_CONFIG.StrokeColor
    label.TextStrokeTransparency = ESP_CONFIG.StrokeTransparency
    label.Parent = parent
    return label
end

local function espDetach(player)
    local entry = ESP.Entries[player]
    if not entry then return end
    ESP.Entries[player] = nil
    disconnectAll(entry.connections)
    if entry.gui then
        entry.gui:Destroy()
        entry.highlight:Destroy()
    end
end

local function espAttach(player, character)
    espDetach(player)
    local entry = { character = character, connections = {} }
    -- Registered before yielding so a respawn/leave/stop during the waits cancels this attach
    ESP.Entries[player] = entry

    local humanoid = character:WaitForChild("Humanoid", ESP_CONFIG.WaitTimeout)
    local head = character:WaitForChild("Head", ESP_CONFIG.WaitTimeout)
    if ESP.Entries[player] ~= entry then
        return
    end
    if not (humanoid and head) then
        espDetach(player)
        return
    end

    local highlight = Instance.new("Highlight")
    highlight.Name = "Chams"
    highlight.Adornee = character
    highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    highlight.FillColor = ESP_CONFIG.Color
    highlight.OutlineColor = ESP_CONFIG.Color
    highlight.FillTransparency = ESP_CONFIG.FillTransparency
    highlight.OutlineTransparency = ESP_CONFIG.OutlineTransparency
    highlight.Enabled = false
    highlight.Parent = character

    -- Text fills only the top half; the empty bottom half keeps the block above the head at any range
    local gui = Instance.new("BillboardGui")
    gui.Name = "ESP"
    gui.Adornee = head
    gui.AlwaysOnTop = true
    gui.LightInfluence = 0
    gui.Size = UDim2.fromOffset(ESP_CONFIG.LabelWidth, ESP_LINE_HEIGHT * 6)
    gui.StudsOffset = Vector3.new(0, ESP_CONFIG.HeadOffset, 0)
    gui.Enabled = false
    gui.Parent = head

    local nameLabel = espCreateLabel(gui, 0)
    local healthLabel = espCreateLabel(gui, 1)
    local distanceLabel = espCreateLabel(gui, 2)
    nameLabel.Text = player.Name

    local function updateHealth()
        healthLabel.Text = string.format("HP %.0f/%.0f", humanoid.Health, humanoid.MaxHealth)
    end
    updateHealth()
    table.insert(entry.connections, humanoid.HealthChanged:Connect(updateHealth))
    table.insert(entry.connections, humanoid:GetPropertyChangedSignal("MaxHealth"):Connect(updateHealth))

    entry.highlight = highlight
    entry.gui = gui
    entry.distanceLabel = distanceLabel
end

local function espOnPlayerAdded(player)
    if player == LocalPlayer or ESP.PlayerConnections[player] then
        return
    end
    ESP.PlayerConnections[player] = {
        player.CharacterAdded:Connect(function(character)
            espAttach(player, character)
        end),
        player.CharacterRemoving:Connect(function()
            espDetach(player)
        end),
    }
    if player.Character then
        task.spawn(espAttach, player, player.Character)
    end
end

local function espOnPlayerRemoving(player)
    espDetach(player)
    local connections = ESP.PlayerConnections[player]
    if connections then
        ESP.PlayerConnections[player] = nil
        disconnectAll(connections)
    end
end

local function espRender()
    local localRoot = rootOf(LocalPlayer.Character)
    table.clear(ESP.Ranked)

    for _, entry in pairs(ESP.Entries) do
        local root = entry.gui and rootOf(entry.character)
        if localRoot and root then
            entry.distance = (root.Position - localRoot.Position).Magnitude
            table.insert(ESP.Ranked, entry)
        elseif entry.gui then
            entry.highlight.Enabled = false
            entry.gui.Enabled = false
        end
    end

    -- Nearest first, so the 31-Highlight cap always keeps the closest players
    table.sort(ESP.Ranked, byDistance)

    for rank, entry in ipairs(ESP.Ranked) do
        local inRange = entry.distance <= ESP_CONFIG.MaxDistance
        entry.highlight.Enabled = inRange and rank <= ESP_CONFIG.MaxHighlights
        entry.gui.Enabled = inRange
        if inRange then
            local studs = math.round(entry.distance)
            if studs ~= entry.studs then
                entry.studs = studs
                entry.distanceLabel.Text = string.format("%d studs", studs)
            end
        end
    end
end

local function startESP()
    if ESP.Running then return end
    ESP.Running = true

    ESP.AddedConnection = Players.PlayerAdded:Connect(espOnPlayerAdded)
    ESP.RemovingConnection = Players.PlayerRemoving:Connect(espOnPlayerRemoving)
    for _, player in ipairs(Players:GetPlayers()) do
        espOnPlayerAdded(player)
    end
    ESP.RenderConnection = RunService.RenderStepped:Connect(espRender)
end

local function stopESP()
    if not ESP.Running then return end
    ESP.Running = false

    disconnect(ESP.RenderConnection)
    disconnect(ESP.AddedConnection)
    disconnect(ESP.RemovingConnection)
    ESP.RenderConnection, ESP.AddedConnection, ESP.RemovingConnection = nil, nil, nil

    for player in pairs(ESP.PlayerConnections) do
        espOnPlayerRemoving(player)
    end
    table.clear(ESP.Ranked)
end

---------------------------------------------------------------------
-- ANCHOR CHARACTER (single unified section: logic + movable on-screen button)
---------------------------------------------------------------------
local ANCHOR_CONFIG = {
    ButtonSize = UDim2.fromOffset(90, 42),
    ButtonPosition = UDim2.new(1, -24, 1, -170),
    ColorOff = Color3.fromRGB(55, 58, 70),
    ColorOn = Color3.fromRGB(0, 170, 110),
    ColorDisabled = Color3.fromRGB(35, 36, 42),
}

local function getCharacterParts()
    local character = LocalPlayer.Character
    if not character or not character.Parent then
        return nil, nil, nil
    end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local root = character:FindFirstChild("HumanoidRootPart")
    if humanoid and root and root:IsA("BasePart") then
        return character, humanoid, root
    end
    return nil, nil, nil
end

local function zeroVelocity(root)
    root.AssemblyLinearVelocity = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero
end

-- Movable on-screen toggle button. cfg: GuiName, Label, Position, IsActive(), OnTap().
-- Returns { SetVisible(visible), Refresh() }; the dragged position is remembered for the session.
local function createButtonSlot(cfg)
    local slot = {}
    local gui, button
    local position = cfg.Position

    function slot.Refresh()
        if not button then return end
        local _, humanoid = getCharacterParts()
        local ready = isAlive(humanoid)
        local active = ready and cfg.IsActive()
        button.Text = cfg.Label .. (active and ": ON" or ": OFF")
        TweenService:Create(button, TweenInfo.new(0.15), {
            BackgroundColor3 = not ready and ANCHOR_CONFIG.ColorDisabled
                or (active and ANCHOR_CONFIG.ColorOn or ANCHOR_CONFIG.ColorOff),
        }):Play()
    end

    function slot.SetVisible(visible)
        if not visible then
            if gui then gui:Destroy() end
            gui, button = nil, nil
            return
        end
        if gui then return end

        local playerGui = LocalPlayer:WaitForChild("PlayerGui", 10)
        if not playerGui then
            warn("[EZ WIN] PlayerGui not found; cannot create " .. cfg.Label .. " button.")
            return
        end

        local old = playerGui:FindFirstChild(cfg.GuiName)
        if old then old:Destroy() end

        gui = Instance.new("ScreenGui")
        gui.Name = cfg.GuiName
        gui.ResetOnSpawn = false
        gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
        gui.DisplayOrder = 10
        gui.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
        gui.Parent = playerGui

        button = Instance.new("TextButton")
        button.Name = cfg.GuiName .. "Button"
        button.AnchorPoint = Vector2.new(1, 1)
        button.Position = position
        button.Size = ANCHOR_CONFIG.ButtonSize
        button.BackgroundColor3 = ANCHOR_CONFIG.ColorOff
        button.AutoButtonColor = false
        button.Font = Enum.Font.GothamBold
        button.TextSize = 14
        button.TextColor3 = Color3.new(1, 1, 1)
        button.Text = cfg.Label .. ": OFF"
        button.Parent = gui

        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 10)
        corner.Parent = button

        local stroke = Instance.new("UIStroke")
        stroke.Thickness = 2
        stroke.Color = Color3.new(1, 1, 1)
        stroke.Transparency = 0.6
        stroke.Parent = button

        local scale = Instance.new("UIScale")
        scale.Parent = button

        makeMovable(button, button, {
            onFinish = function(moved)
                if moved then position = button.Position end
            end,
            onTap = function()
                scale.Scale = 0.92
                TweenService:Create(scale, TweenInfo.new(0.12, Enum.EasingStyle.Back), { Scale = 1 }):Play()
                cfg.OnTap()
            end,
        })

        slot.Refresh()
    end

    return slot
end

-- Runs cfg.OnSpawn(character) for the current character and every respawn. Once the Humanoid
-- (and the root part, with cfg.NeedsRoot) exists, cfg.OnReady() runs and cfg.OnDeath(root) is
-- connected to its death. cfg.OnRespawned() runs after each respawn's setup.
-- Returns a function that stops watching.
local function watchCharacter(cfg)
    local died

    local function setup(character)
        disconnect(died)
        died = nil
        cfg.OnSpawn(character)

        local humanoid = character:WaitForChild("Humanoid", 10)
        local root = cfg.NeedsRoot and character:WaitForChild("HumanoidRootPart", 10)
        if not humanoid or cfg.NeedsRoot and not root or LocalPlayer.Character ~= character then
            return
        end

        died = humanoid.Died:Connect(function()
            cfg.OnDeath(root)
        end)
        if cfg.OnReady then cfg.OnReady() end
    end

    local added = LocalPlayer.CharacterAdded:Connect(function(character)
        setup(character)
        if cfg.OnRespawned then cfg.OnRespawned() end
    end)
    if LocalPlayer.Character then
        task.spawn(setup, LocalPlayer.Character)
    end

    return function()
        added:Disconnect()
        disconnect(died)
        died = nil
    end
end

local function clearAnchorLock()
    Anchor.Active = false
    Anchor.Saved = nil
    disconnect(Anchor.Heartbeat)
    Anchor.Heartbeat = nil
end

local function setAnchored(enabled)
    if enabled == Anchor.Active then return end

    local _, humanoid, root = getCharacterParts()

    if enabled then
        if not root or not isAlive(humanoid) then
            Anchor.Button.Refresh()
            syncElement(Anchor.Toggle, false)
            return
        end

        Anchor.Saved = {
            WalkSpeed = humanoid.WalkSpeed,
            JumpPower = humanoid.JumpPower,
            JumpHeight = humanoid.JumpHeight,
            AutoRotate = humanoid.AutoRotate,
        }
        Anchor.Active = true

        humanoid.WalkSpeed = 0
        humanoid.JumpPower = 0
        humanoid.JumpHeight = 0
        humanoid.AutoRotate = false
        zeroVelocity(root)      -- zero BEFORE anchoring so no residual momentum remains
        root.Anchored = true

        Anchor.Heartbeat = RunService.Heartbeat:Connect(function()
            local _, h, r = getCharacterParts()
            if not h or not r then return end
            if not r.Anchored then r.Anchored = true end
            zeroVelocity(r)
        end)
    else
        local saved = Anchor.Saved
        clearAnchorLock()

        if root then
            root.Anchored = false
        end
        if humanoid and saved then
            humanoid.WalkSpeed = saved.WalkSpeed
            humanoid.JumpPower = saved.JumpPower
            humanoid.JumpHeight = saved.JumpHeight
            humanoid.AutoRotate = saved.AutoRotate
        end

        -- The hub's current speed/jump win over the stale values saved before the lock
        if State.SpeedMode ~= "Default" then applySpeed() end
        if State.JumpEnabled then applyJump() end

        if Anchor.OnRelease then Anchor.OnRelease() end
    end

    Anchor.Button.Refresh()
    syncElement(Anchor.Toggle, enabled)
end

Anchor.Button = createButtonSlot({
    GuiName = "EZWINAnchorGui",
    Label = "Anchor",
    Position = ANCHOR_CONFIG.ButtonPosition,
    IsActive = function() return Anchor.Active end,
    OnTap = function()
        local _, humanoid = getCharacterParts()
        if isAlive(humanoid) then
            setAnchored(not Anchor.Active)
        end
    end,
})

local stopAnchorWatch = watchCharacter({
    NeedsRoot = true,
    OnSpawn = function()
        clearAnchorLock()
        syncElement(Anchor.Toggle, false)
        Anchor.Button.Refresh()
    end,
    OnReady = Anchor.Button.Refresh,
    OnDeath = function(root)
        clearAnchorLock()
        if root:IsA("BasePart") then
            root.Anchored = false
        end
        syncElement(Anchor.Toggle, false)
        Anchor.Button.Refresh()
    end,
    OnRespawned = function()
        task.wait(0.5)
        pcall(function()
            if State.SpeedMode ~= "Default" then applySpeed() end
            if State.JumpEnabled then applyJump() end
        end)
    end,
})

---------------------------------------------------------------------
-- SCRIPT 3: SURVIVE (TP to one random other player and back)
---------------------------------------------------------------------
local tpRunning = false

local function tpToOtherPlayer()
    if tpRunning then return end

    local character, _, root = getCharacterParts()
    if not root then
        notify("Survive", "Your character isn't available.")
        return
    end

    local targets = {}
    for _, player in ipairs(Players:GetPlayers()) do
        local targetCharacter = player.Character
        local targetHumanoid = targetCharacter and targetCharacter:FindFirstChildOfClass("Humanoid")
        if player ~= LocalPlayer and rootOf(targetCharacter) and isAlive(targetHumanoid) then
            table.insert(targets, targetCharacter)
        end
    end
    if #targets == 0 then
        notify("Survive", "No other player to teleport to.")
        return
    end

    local targetRoot = rootOf(targets[math.random(#targets)])
    local originalCFrame = root.CFrame
    local wasAnchored = Anchor.Active
    tpRunning = true

    local okTp, tpError = pcall(function()
        if wasAnchored then
            setAnchored(false)
            root = select(3, getCharacterParts())
        end
        root.CFrame = targetRoot.CFrame
        if type(firetouchinterest) == "function" then
            firetouchinterest(root, targetRoot, 0)
            task.wait()
            firetouchinterest(root, targetRoot, 1)
        end
        task.wait(0.2)
    end)
    if not okTp then
        warn("[EZ WIN] Teleport interrupted: " .. tostring(tpError))
    end

    -- Always returns, even if the teleport above failed; skipped only if we died or respawned
    pcall(function()
        local currentCharacter, humanoid, currentRoot = getCharacterParts()
        if currentCharacter ~= character or not isAlive(humanoid) then return end
        currentRoot.CFrame = originalCFrame
        zeroVelocity(currentRoot)
        if wasAnchored then
            setAnchored(true)
        end
    end)

    tpRunning = false
end

---------------------------------------------------------------------
-- SCRIPT 4: FLOAT (teleport up + hover, survive tab)
---------------------------------------------------------------------
local FLOAT_CONFIG = {
    Height = 170,
    ButtonPosition = UDim2.new(1, -24, 1, -222),
    GroundRayLength = 5000,
}

local Float = {
    Active = false,
    Origin = nil,
    Attachment = nil,
    Force = nil,
    Heartbeat = nil,
    Toggle = nil,
    Button = nil,
}

local function releaseFloatPhysics()
    disconnect(Float.Heartbeat)
    if Float.Force then Float.Force:Destroy() end
    if Float.Attachment then Float.Attachment:Destroy() end
    Float.Heartbeat, Float.Force, Float.Attachment = nil, nil, nil
end

local function resetFloat()
    releaseFloatPhysics()
    Float.Active = false
    Float.Origin = nil
    syncElement(Float.Toggle, false)
    Float.Button.Refresh()
end

local function findGroundCFrame(character, humanoid, root, origin)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { character }
    params.IgnoreWater = true

    local hit = workspace:Raycast(root.Position, Vector3.new(0, -FLOAT_CONFIG.GroundRayLength, 0), params)
    local position = hit
        and (hit.Position + Vector3.new(0, humanoid.HipHeight + root.Size.Y / 2 + 0.5, 0))
        or origin.Position
    return CFrame.new(position) * (root.CFrame - root.CFrame.Position)
end

local function setFloat(enabled)
    if enabled == Float.Active then return end -- also stops toggle <-> button sync loops

    local character, humanoid, root = getCharacterParts()

    if enabled then
        if not isAlive(humanoid) then
            notify("Float", "Your character isn't available.")
            syncElement(Float.Toggle, false)
            return
        end
        if Anchor.Active then
            notify("Float", "Turn off Anchor first.")
            syncElement(Float.Toggle, false)
            return
        end

        Float.Active = true
        Float.Origin = root.CFrame
        root.CFrame = root.CFrame + Vector3.new(0, FLOAT_CONFIG.Height, 0)
        zeroVelocity(root)

        local attachment = Instance.new("Attachment")
        attachment.Name = "EZWINFloatAttachment"
        attachment.Parent = root

        local force = Instance.new("VectorForce")
        force.Name = "EZWINFloatForce"
        force.RelativeTo = Enum.ActuatorRelativeTo.World
        force.ApplyAtCenterOfMass = true
        force.Attachment0 = attachment
        force.Force = Vector3.zero
        force.Parent = root
        Float.Attachment, Float.Force = attachment, force

        -- Cancel gravity for the whole assembly and kill vertical drift; horizontal movement stays free
        Float.Heartbeat = RunService.Heartbeat:Connect(function()
            if not root.Parent then return end
            force.Force = Vector3.new(0, root.AssemblyMass * workspace.Gravity, 0)
            local velocity = root.AssemblyLinearVelocity
            if velocity.Y ~= 0 then
                root.AssemblyLinearVelocity = Vector3.new(velocity.X, 0, velocity.Z)
            end
        end)
    else
        local origin = Float.Origin
        releaseFloatPhysics()
        Float.Active = false
        Float.Origin = nil
        -- Anchored: stay where we are; only drop to the ground when Anchor is not holding us
        if root and isAlive(humanoid) and origin and not Anchor.Active then
            root.CFrame = findGroundCFrame(character, humanoid, root, origin)
            zeroVelocity(root)
        end
    end

    syncElement(Float.Toggle, enabled)
    Float.Button.Refresh()
end

-- Turning Anchor off while Float is on turns Float off too (skipped during the Survive teleport's temporary unanchor)
Anchor.OnRelease = function()
    if Float.Active and not tpRunning then
        setFloat(false)
    end
end

Float.Button = createButtonSlot({
    GuiName = "EZWINFloatGui",
    Label = "Float",
    Position = FLOAT_CONFIG.ButtonPosition,
    IsActive = function() return Float.Active end,
    OnTap = function() setFloat(not Float.Active) end,
})

local stopFloatWatch = watchCharacter({
    OnSpawn = resetFloat,
    OnDeath = resetFloat,
})

---------------------------------------------------------------------
-- SCRIPT 5: MOBILE AIMBOT (scripts tab)
---------------------------------------------------------------------
local AIM_CONFIG = {
    ButtonPosition = UDim2.new(1, -24, 1, -274),
    ScanInterval = 0.1,                            -- target scan rate (10 Hz); camera runs every frame
    DistanceWeight = 0.05,
    BindName = "EZWINAim",
}

local Aim = {
    Armed = false,
    Active = false,
    TargetPlayer = nil,
    TargetPart = nil,
    Elapsed = 0,
    Button = nil,
    CircleGui = nil,
    Circle = nil,
    Toggle = nil,
    RayParams = RaycastParams.new(),
    Settings = {
        AimPart = "Head",
        Priority = "Closest", -- "Closest" | "Lowest HP" | "Highest HP" | "Random"
        Smoothing = 0.25,    -- 0.05 (slow) .. 1 (instant)
        FOV = 150,
        MaxDistance = 500,
        TeamCheck = true,
        WallCheck = true,
        ShowCircle = true,
    },
}
Aim.RayParams.FilterType = Enum.RaycastFilterType.Exclude
Aim.RayParams.IgnoreWater = true
Aim.RayParams.RespectCanCollide = true

-- Returns (score, aimPart, health) when the player is a valid target right now, lower score = better
local function aimEvaluate(player, camera, center)
    local settings = Aim.Settings
    if player == LocalPlayer then return nil end
    if settings.TeamCheck and player.Team and player.Team == LocalPlayer.Team then return nil end

    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not isAlive(humanoid) then return nil end

    local part = character:FindFirstChild(settings.AimPart) or character:FindFirstChild("HumanoidRootPart")
    if not part then return nil end

    local worldDistance = (part.Position - camera.CFrame.Position).Magnitude
    if worldDistance > settings.MaxDistance then return nil end

    local point, onScreen = camera:WorldToViewportPoint(part.Position)
    if not onScreen then return nil end

    local screenDistance = (Vector2.new(point.X, point.Y) - center).Magnitude
    if screenDistance > settings.FOV then return nil end

    return screenDistance + worldDistance * AIM_CONFIG.DistanceWeight, part, humanoid.Health
end

local function aimIsVisible(camera, part)
    local origin = camera.CFrame.Position
    local result = workspace:Raycast(origin, part.Position - origin, Aim.RayParams)
    return result == nil or result.Instance:IsDescendantOf(part.Parent)
end

local function aimAccepts(camera, part)
    return not Aim.Settings.WallCheck or aimIsVisible(camera, part)
end

local function sortAimCandidates(candidates)
    local priority = Aim.Settings.Priority
    if priority == "Random" then
        for i = #candidates, 2, -1 do
            local j = math.random(i)
            candidates[i], candidates[j] = candidates[j], candidates[i]
        end
    elseif priority == "Lowest HP" then
        table.sort(candidates, function(a, b)
            if a.Health ~= b.Health then return a.Health < b.Health end
            return a.Score < b.Score
        end)
    elseif priority == "Highest HP" then
        table.sort(candidates, function(a, b)
            if a.Health ~= b.Health then return a.Health > b.Health end
            return a.Score < b.Score
        end)
    else
        table.sort(candidates, function(a, b) return a.Score < b.Score end)
    end
end

local function aimScan(camera)
    Aim.RayParams.FilterDescendantsInstances = { LocalPlayer.Character }
    local viewport = camera.ViewportSize
    local center = Vector2.new(viewport.X / 2, viewport.Y / 2)

    if Aim.TargetPlayer then
        local _, part = aimEvaluate(Aim.TargetPlayer, camera, center)
        if part and aimAccepts(camera, part) then
            Aim.TargetPart = part
            return
        end
        Aim.TargetPlayer, Aim.TargetPart = nil, nil
    end

    local candidates = {}
    for _, player in ipairs(Players:GetPlayers()) do
        local score, part, health = aimEvaluate(player, camera, center)
        if score then
            candidates[#candidates + 1] = { Score = score, Part = part, Player = player, Health = health }
        end
    end
    sortAimCandidates(candidates)

    for _, candidate in ipairs(candidates) do
        if aimAccepts(camera, candidate.Part) then
            Aim.TargetPlayer, Aim.TargetPart = candidate.Player, candidate.Part
            return
        end
    end
end

-- Runs every frame right after the default camera script
local function aimStep(dt)
    local camera = workspace.CurrentCamera
    if not camera then return end

    Aim.Elapsed += dt
    if Aim.Elapsed >= AIM_CONFIG.ScanInterval then
        Aim.Elapsed = 0
        aimScan(camera)
    end

    local part = Aim.TargetPart
    if not part or not part.Parent then
        Aim.TargetPlayer, Aim.TargetPart = nil, nil
        return
    end

    local current = camera.CFrame
    local desired = CFrame.lookAt(current.Position, part.Position)
    -- Frame-rate independent smoothing: identical feel at 30 and 60 FPS
    local alpha = 1 - (1 - Aim.Settings.Smoothing) ^ (dt * 60)
    camera.CFrame = current:Lerp(desired, alpha)
end

local function setAimActive(enabled)
    if enabled == Aim.Active then return end

    if enabled then
        if not Aim.Armed then return end
        Aim.Active = true
        Aim.Elapsed = AIM_CONFIG.ScanInterval -- scan on the very first frame
        RunService:BindToRenderStep(AIM_CONFIG.BindName, Enum.RenderPriority.Camera.Value + 1, aimStep)
    else
        Aim.Active = false
        pcall(RunService.UnbindFromRenderStep, RunService, AIM_CONFIG.BindName)
        Aim.TargetPlayer, Aim.TargetPart = nil, nil
    end

    Aim.Button.Refresh()
end

local function updateAimCircle()
    if not Aim.CircleGui then return end
    Aim.CircleGui.Enabled = Aim.Settings.ShowCircle
    Aim.Circle.Size = UDim2.fromOffset(Aim.Settings.FOV * 2, Aim.Settings.FOV * 2)
end

local function createAimCircle()
    if Aim.CircleGui then return end
    local playerGui = LocalPlayer:WaitForChild("PlayerGui", 10)
    if not playerGui then return end

    local old = playerGui:FindFirstChild("EZWINAimCircleGui")
    if old then old:Destroy() end

    local gui = Instance.new("ScreenGui")
    gui.Name = "EZWINAimCircleGui"
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 5
    gui.ScreenInsets = Enum.ScreenInsets.None -- centered on the true viewport, same space as WorldToViewportPoint
    gui.Parent = playerGui

    local circle = Instance.new("Frame")
    circle.AnchorPoint = Vector2.new(0.5, 0.5)
    circle.Position = UDim2.fromScale(0.5, 0.5)
    circle.BackgroundTransparency = 1
    circle.Parent = gui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(1, 0)
    corner.Parent = circle

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1.5
    stroke.Color = Color3.new(1, 1, 1)
    stroke.Transparency = 0.5
    stroke.Parent = circle

    Aim.CircleGui, Aim.Circle = gui, circle
    updateAimCircle()
end

local function destroyAimCircle()
    if Aim.CircleGui then Aim.CircleGui:Destroy() end
    Aim.CircleGui, Aim.Circle = nil, nil
end

Aim.Button = createButtonSlot({
    GuiName = "EZWINAimGui",
    Label = "Aim",
    Position = AIM_CONFIG.ButtonPosition,
    IsActive = function() return Aim.Active end,
    OnTap = function() setAimActive(not Aim.Active) end,
})

-- "Armed" = the on-screen Aim button and FOV circle exist; tapping the button starts/stops aiming
local function setAimArmed(enabled)
    if enabled == Aim.Armed then return end
    Aim.Armed = enabled

    if enabled then
        createAimCircle()
        Aim.Button.SetVisible(true)
    else
        setAimActive(false)
        Aim.Button.SetVisible(false)
        destroyAimCircle()
    end
end

local stopAimWatch = watchCharacter({
    OnSpawn = function() setAimActive(false) end,
    OnDeath = function() setAimActive(false) end,
})

---------------------------------------------------------------------
-- UNLOAD (restores everything the hub changed)
---------------------------------------------------------------------
local function unloadAll()
    setInfiniteJump(false)
    stopESP()
    setAnchored(false)
    Anchor.Button.SetVisible(false)
    stopAnchorWatch()
    setFloat(false)
    Float.Button.SetVisible(false)
    stopFloatWatch()
    setAimArmed(false)
    stopAimWatch()
    State.SpeedMode = "Default"
    State.JumpEnabled = false
    applySpeed()
    applyJump()
end

---------------------------------------------------------------------
-- WINDOW
---------------------------------------------------------------------
local Window = Rayfield:CreateWindow({
    Name = HUB_NAME,
    Icon = 0,
    LoadingTitle = HUB_NAME,
    LoadingSubtitle = HUB_CREDIT,
    ShowText = HUB_NAME,
    Theme = "Default",

    ToggleUIKeybind = "K",

    DisableRayfieldPrompts = false,
    DisableBuildWarnings = false,

    ConfigurationSaving = {
        Enabled = true,
        FolderName = "EZWIN",
        FileName = "EZWINConfig",
    },

    Discord = {
        Enabled = false,
        Invite = "noinvitelink",
        RememberJoins = true,
    },

    KeySystem = false,
    KeySettings = {
        Title = "EZ WIN | Key",
        Subtitle = "Key System",
        Note = "Enter the key to continue.",
        FileName = "EZWINKey",
        SaveKey = true,
        GrabKeyFromSite = false,
        Key = { "ChangeThisKey" },
    },
})

do
    local rfGui = findRayfieldGui() or rayfieldGui
    if rfGui then
        pcall(applyWindowScale, rfGui)
        local okResize, resizeResult = pcall(setupWindowResize, rfGui)
        if not okResize or resizeResult == false then
            warn("[EZ WIN] Could not make the window resizable: " .. tostring(resizeResult))
        end
    else
        warn("[EZ WIN] Could not find the Rayfield GUI; the resize grips were skipped.")
    end
end

---------------------------------------------------------------------
-- MAIN TAB
---------------------------------------------------------------------
local MainTab = Window:CreateTab("Main", "home")

MainTab:CreateSection("Speed")

UI.SpeedToggle = MainTab:CreateToggle({
    Name = "Enable Custom Walk Speed",
    CurrentValue = false,
    Flag = "SpeedToggle",
    Callback = safe("SpeedToggle", function(Value)
        if Value then
            setSpeedMode("Custom")
        elseif State.SpeedMode == "Custom" then
            setSpeedMode("Default")
        end
    end),
})

UI.SpeedSlider = MainTab:CreateSlider({
    Name = "Walk Speed (Custom mode)",
    Range = { 16, 200 },
    Increment = 1,
    Suffix = " studs/s",
    CurrentValue = 16,
    Flag = "SpeedSlider",
    Callback = safe("SpeedSlider", function(Value)
        State.SpeedValue = Value
        if State.SpeedMode == "Custom" then
            applySpeed()
        end
    end),
})

UI.SpeedPreset = MainTab:CreateDropdown({
    Name = "Speed Preset",
    Options = SPEED_OPTIONS,
    CurrentOption = { "Default" },
    MultipleOptions = false,
    Flag = "SpeedPresetDropdown",
    Callback = safe("PresetDropdown", function(Options)
        setSpeedMode(Options[1] or "Default")
    end),
})

MainTab:CreateSection("Jump")

UI.JumpToggle = MainTab:CreateToggle({
    Name = "Enable Custom Jump Power",
    CurrentValue = false,
    Flag = "JumpToggle",
    Callback = safe("JumpToggle", function(Value)
        State.JumpEnabled = Value
        applyJump()
    end),
})

UI.JumpSlider = MainTab:CreateSlider({
    Name = "Jump Power",
    Range = { 50, 300 },
    Increment = 1,
    Suffix = " power",
    CurrentValue = 50,
    Flag = "JumpSlider",
    Callback = safe("JumpSlider", function(Value)
        State.JumpValue = Value
        if State.JumpEnabled then
            applyJump()
        end
    end),
})

MainTab:CreateToggle({
    Name = "JumpFly (Infinite Jump)",
    CurrentValue = false,
    Flag = "InfJumpToggle",
    Callback = safe("InfJumpToggle", function(Value)
        setInfiniteJump(Value)
        notify("JumpFly", Value and "Enabled - keep pressing jump in mid-air." or "Disabled.")
    end),
})

MainTab:CreateButton({
    Name = "Reset Speed & Jump",
    Callback = safe("ResetButton", function()
        setSpeedMode("Default", true)
        State.SpeedValue = Presets.Default
        syncElement(UI.SpeedSlider, Presets.Default)

        State.JumpEnabled = false
        State.JumpValue = State.DefaultJump
        syncElement(UI.JumpToggle, false)
        syncElement(UI.JumpSlider, State.DefaultJump)

        applySpeed()
        applyJump()
        notify("Reset", "Speed and jump restored to default.")
    end),
})

---------------------------------------------------------------------
-- SCRIPTS TAB
---------------------------------------------------------------------
local ScriptsTab = Window:CreateTab("Scripts", "code")

ScriptsTab:CreateSection("ESP / Chams")

ScriptsTab:CreateToggle({
    Name = "Player ESP (Chams + Name/HP/Distance)",
    CurrentValue = false,
    Flag = "ESPToggle",
    Callback = safe("ESPToggle", function(Value)
        if Value then
            startESP()
        else
            stopESP()
        end
    end),
})

ScriptsTab:CreateSection("Anchor Character")

-- No Flag on purpose: this state is never saved, so you won't load in frozen.
Anchor.Toggle = ScriptsTab:CreateToggle({
    Name = "Anchor Character",
    CurrentValue = false,
    Callback = safe("AnchorToggle", setAnchored),
})

ScriptsTab:CreateToggle({
    Name = "Show On-Screen Anchor Button (movable)",
    CurrentValue = false,
    Flag = "AnchorButtonToggle",
    Callback = safe("AnchorButtonToggle", Anchor.Button.SetVisible),
})

ScriptsTab:CreateSection("Mobile Aimbot")

Aim.Toggle = ScriptsTab:CreateToggle({
    Name = "Aimbot (shows movable Aim button)",
    CurrentValue = false,
    Flag = "AimbotToggle",
    Callback = safe("AimbotToggle", setAimArmed),
})

ScriptsTab:CreateDropdown({
    Name = "Target Priority",
    Options = { "Closest", "Lowest HP", "Highest HP", "Random" },
    CurrentOption = { "Closest" },
    MultipleOptions = false,
    Flag = "AimPriorityDropdown",
    Callback = safe("AimPriority", function(Options)
        Aim.Settings.Priority = Options[1] or "Closest"
        Aim.TargetPlayer, Aim.TargetPart = nil, nil -- re-pick with the new rule on the next scan
    end),
})

ScriptsTab:CreateDropdown({
    Name = "Aim Part",
    Options = { "Head", "HumanoidRootPart" },
    CurrentOption = { "Head" },
    MultipleOptions = false,
    Flag = "AimPartDropdown",
    Callback = safe("AimPart", function(Options)
        Aim.Settings.AimPart = Options[1] or "Head"
        Aim.TargetPlayer, Aim.TargetPart = nil, nil
    end),
})

ScriptsTab:CreateSlider({
    Name = "Smoothing (higher = faster lock)",
    Range = { 5, 100 },
    Increment = 5,
    Suffix = " %",
    CurrentValue = 25,
    Flag = "AimSmoothingSlider",
    Callback = safe("AimSmoothing", function(Value)
        Aim.Settings.Smoothing = Value / 100
    end),
})

ScriptsTab:CreateSlider({
    Name = "FOV Radius",
    Range = { 50, 400 },
    Increment = 10,
    Suffix = " px",
    CurrentValue = 150,
    Flag = "AimFOVSlider",
    Callback = safe("AimFOV", function(Value)
        Aim.Settings.FOV = Value
        updateAimCircle()
    end),
})

ScriptsTab:CreateSlider({
    Name = "Max Distance",
    Range = { 50, 1000 },
    Increment = 10,
    Suffix = " studs",
    CurrentValue = 500,
    Flag = "AimDistanceSlider",
    Callback = safe("AimDistance", function(Value)
        Aim.Settings.MaxDistance = Value
    end),
})

ScriptsTab:CreateToggle({
    Name = "Team Check",
    CurrentValue = true,
    Flag = "AimTeamCheckToggle",
    Callback = safe("AimTeamCheck", function(Value)
        Aim.Settings.TeamCheck = Value
    end),
})

ScriptsTab:CreateToggle({
    Name = "Wall Check",
    CurrentValue = true,
    Flag = "AimWallCheckToggle",
    Callback = safe("AimWallCheck", function(Value)
        Aim.Settings.WallCheck = Value
    end),
})

ScriptsTab:CreateToggle({
    Name = "Show FOV Circle",
    CurrentValue = true,
    Flag = "AimShowFOVCircleToggle",
    Callback = safe("AimCircle", function(Value)
        Aim.Settings.ShowCircle = Value
        updateAimCircle()
    end),
})

---------------------------------------------------------------------
-- SURVIVE TAB (TP to other players)
---------------------------------------------------------------------
local NaniTab = Window:CreateTab("Survive", "shield")

NaniTab:CreateSection("Nani")

NaniTab:CreateButton({
    Name = "TP to Other Player",
    Callback = safe("TPToOtherPlayer", tpToOtherPlayer),
})

NaniTab:CreateSection("Float (+170 studs)")

-- No Flag on purpose: this state is never saved, so you won't load in floating.
Float.Toggle = NaniTab:CreateToggle({
    Name = "Teleport Up 170 Studs & Float",
    CurrentValue = false,
    Callback = safe("FloatToggle", setFloat),
})

NaniTab:CreateToggle({
    Name = "Show On-Screen Float Button (movable)",
    CurrentValue = false,
    Flag = "FloatButtonToggle",
    Callback = safe("FloatButtonToggle", Float.Button.SetVisible),
})

---------------------------------------------------------------------
-- SETTINGS TAB
---------------------------------------------------------------------
local SettingsTab = Window:CreateTab("Settings", "settings")

SettingsTab:CreateSection("Appearance")

SettingsTab:CreateDropdown({
    Name = "UI Theme",
    Options = { "Default", "AmberGlow", "Amethyst", "Bloom", "DarkBlue", "Green", "Light", "Ocean", "Serenity" },
    CurrentOption = { "Default" },
    MultipleOptions = false,
    Flag = "ThemeDropdown",
    Callback = safe("ThemeDropdown", function(Options)
        Window.ModifyTheme(Options[1])
    end),
})

SettingsTab:CreateSection("Script Control")

SettingsTab:CreateToggle({
    Name = "Show Notifications",
    CurrentValue = true,
    Flag = "NotifyToggle",
    Callback = safe("NotifyToggle", function(Value)
        State.Notifications = Value
    end),
})

SettingsTab:CreateButton({
    Name = "Unload Script",
    Callback = safe("UnloadButton", function()
        unloadAll()
        Rayfield:Destroy()
    end),
})

Rayfield:Notify({
    Title = HUB_NAME .. " Loaded",
    Content = "Press K or tap the minimized button to show/hide the UI. Drag the bottom-right corner to resize.",
    Duration = 5,
})

--// Load saved configuration (must be called AFTER all elements are created)
pcall(function()
    Rayfield:LoadConfiguration()
end)
