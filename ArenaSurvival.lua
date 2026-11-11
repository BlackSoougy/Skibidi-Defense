--[[
    ArenaSurvival Hub
    Игра: ArenaSurvival (авто-шутер, Roblox)
    Всё, что делает скрипт — клиентская сторона + вызов штатных ремоутов.
    Сервер сам проверяет цены и лимиты, поэтому скрипт ничего не «взламывает»:
    он автоматизирует покупки, подсвечивает зомби и доворачивает камеру.

    Переключить окно: RightShift
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

-- ---------------------------------------------------------- очистка прошлой копии
do
    local previous = getgenv().ASHub
    if previous and previous.Unload then
        pcall(previous.Unload)
    end
    local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
    if playerGui then
        for _, name in ipairs({ "ASHubGui", "ASHubEsp" }) do
            local stale = playerGui:FindFirstChild(name)
            while stale do
                pcall(function() stale:Destroy() end)
                stale = playerGui:FindFirstChild(name)
            end
        end
    end
    getgenv().ASHub = nil
end

-- ============================================================ инфраструктура

local Hub = {
    State = {
        Esp = false,
        EspMaxDist = 180,
        EspKinds = true,
        Aim = false,
        AimSmooth = 10,
        AutoBuy = false,
        AutoBuyOrder = "health,gun,weapon",
        AutoUpgrade = false,
        AutoSkip = false,
        AutoReward = false,
        AutoRestart = false,
        AntiAfk = true,
        Speed = false,
        WalkSpeed = 44,
        Jump = false,
        JumpPower = 50,
        Fly = false,
        FlySpeed = 60,
    },
    Connections = {},
    Highlights = {},
    LastFire = {},
}

local function log(...)
    local parts = {}
    for i = 1, select("#", ...) do
        table.insert(parts, tostring((select(i, ...))))
    end
    print("[ASHub] " .. table.concat(parts, " "))
end

function Hub.Track(conn)
    table.insert(Hub.Connections, conn)
    return conn
end

function Hub.WaitFor(parent, name, timeout)
    local ok, child = pcall(function()
        return parent:WaitForChild(name, timeout or 20)
    end)
    if ok then return child end
    return nil
end

-- ============================================================ данные игры

local AS = Hub.WaitFor(ReplicatedStorage, "ArenaSurvival", 30)
local Remotes = AS and Hub.WaitFor(AS, "Remotes", 20)

local Config
if AS then
    local module = AS:FindFirstChild("Config")
    if module then
        local ok, result = pcall(require, module)
        if ok then Config = result end
    end
end

local function attr(name, default)
    local value = LocalPlayer:GetAttribute(name)
    if value == nil then return default end
    return value
end

-- Единая точка отправки: не даём спамить ремоуты чаще, чем раз в interval.
function Hub.Fire(remoteName, interval, ...)
    if not Remotes then return false end
    local remote = Remotes:FindFirstChild(remoteName)
    if not remote or not remote:IsA("RemoteEvent") then return false end
    local now = os.clock()
    if now - (Hub.LastFire[remoteName] or 0) < (interval or 0.25) then
        return false
    end
    Hub.LastFire[remoteName] = now
    local ok = pcall(function(...)
        remote:FireServer(...)
    end, ...)
    return ok
end

-- ============================================================ зомби

local function rigsFolder()
    local fx = Workspace:FindFirstChild("ASClientFx")
    if not fx then return nil end
    return fx:FindFirstChild("ASZombieRigs")
end

local function rigRoot(model)
    if not model or not model:IsA("Model") then return nil end
    return model.PrimaryPart
        or model:FindFirstChild("HumanoidRootPart")
        or model:FindFirstChildWhichIsA("BasePart")
end

local PARKED_Y = -500

function Hub.ActiveZombies(maxDist)
    local list = {}
    local folder = rigsFolder()
    if not folder then return list end

    local origin
    local character = LocalPlayer.Character
    if character then
        local root = character:FindFirstChild("HumanoidRootPart")
        if root then origin = root.Position end
    end
    if not origin then return list end

    for _, model in ipairs(folder:GetChildren()) do
        if model:IsA("Model") then
            local part = rigRoot(model)
            if part then
                local position = part.Position
                if position.Y > PARKED_Y then
                    local distance = (position - origin).Magnitude
                    if not maxDist or distance <= maxDist then
                        table.insert(list, {
                            model = model,
                            part = part,
                            position = position,
                            distance = distance,
                            kind = model.Name,
                        })
                    end
                end
            end
        end
    end

    table.sort(list, function(a, b) return a.distance < b.distance end)
    return list
end

-- ============================================================ ESP

local espGui
local ESP_COLORS = {
    boss = Color3.fromRGB(255, 70, 70),
    tank = Color3.fromRGB(255, 160, 60),
    runner = Color3.fromRGB(255, 235, 90),
    default = Color3.fromRGB(120, 220, 255),
}

local function colorFor(kind)
    local lower = string.lower(kind or "")
    for key, color in pairs(ESP_COLORS) do
        if key ~= "default" and string.find(lower, key, 1, true) then
            return color
        end
    end
    return ESP_COLORS.default
end

local function ensureEspGui()
    if espGui and espGui.Parent then return espGui end
    espGui = Instance.new("ScreenGui")
    espGui.Name = "ASHubEsp"
    espGui.ResetOnSpawn = false
    espGui.IgnoreGuiInset = true
    espGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    espGui.DisplayOrder = 5
    espGui.Parent = LocalPlayer:WaitForChild("PlayerGui")
    return espGui
end

local function clearEsp()
    for model, objects in pairs(Hub.Highlights) do
        for _, object in ipairs(objects) do
            pcall(function() object:Destroy() end)
        end
    end
    Hub.Highlights = {}
    if espGui then espGui:ClearAllChildren() end
end

local function drawEsp()
    if not Hub.State.Esp then
        if next(Hub.Highlights) then clearEsp() end
        return
    end
    ensureEspGui()

    local zombies = Hub.ActiveZombies(Hub.State.EspMaxDist)
    local seen = {}

    for index, zombie in ipairs(zombies) do
        if index > 80 then break end
        seen[zombie.model] = true
        local color = colorFor(zombie.kind)

        local objects = Hub.Highlights[zombie.model]
        if not objects then
            objects = {}

            local highlight = Instance.new("Highlight")
            highlight.Name = "ASHubHighlight"
            highlight.Adornee = zombie.model
            highlight.FillColor = color
            highlight.FillTransparency = 0.65
            highlight.OutlineColor = color
            highlight.OutlineTransparency = 0
            highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
            highlight.Parent = espGui
            table.insert(objects, highlight)

            local billboard = Instance.new("BillboardGui")
            billboard.Name = "ASHubTag"
            billboard.Adornee = zombie.part
            billboard.Size = UDim2.fromOffset(140, 28)
            billboard.StudsOffsetWorldSpace = Vector3.new(0, 2.6, 0)
            billboard.AlwaysOnTop = true
            billboard.MaxDistance = Hub.State.EspMaxDist
            billboard.Parent = espGui

            local label = Instance.new("TextLabel")
            label.Name = "Text"
            label.BackgroundTransparency = 1
            label.Size = UDim2.fromScale(1, 1)
            label.Font = Enum.Font.GothamBold
            label.TextScaled = true
            label.TextColor3 = color
            label.TextStrokeTransparency = 0.4
            label.Text = zombie.kind
            label.Parent = billboard
            table.insert(objects, billboard)

            Hub.Highlights[zombie.model] = objects
        else
            local highlight = objects[1]
            if highlight then highlight.FillColor = color; highlight.OutlineColor = color end
        end

        if Hub.State.EspKinds then
            local billboard = objects[2]
            local label = billboard and billboard:FindFirstChild("Text")
            if label then
                label.Text = string.format("%s  [%d]", zombie.kind, math.floor(zombie.distance))
                label.TextColor3 = color
            end
        end
    end

    for model, objects in pairs(Hub.Highlights) do
        if not seen[model] then
            for _, object in ipairs(objects) do
                pcall(function() object:Destroy() end)
            end
            Hub.Highlights[model] = nil
        end
    end
end

-- ============================================================ авто-наведение

local function bestAimPoint()
    local zombies = Hub.ActiveZombies(Config and Config.GUN_RANGE and Config.GUN_RANGE + 12 or 58)
    if #zombies == 0 then return nil end

    local sum, weight = Vector3.zero, 0
    for index = 1, math.min(#zombies, 6) do
        local zombie = zombies[index]
        local w = 1 / math.max(1, zombie.distance)
        sum = sum + zombie.position * w
        weight = weight + w
    end
    if weight == 0 then return nil end
    return sum / weight
end

local function aimStep(dt)
    if not Hub.State.Aim then return end
    local camera = Workspace.CurrentCamera
    if not camera then return end
    local target = bestAimPoint()
    if not target then return end

    local origin = camera.CFrame.Position
    if (target - origin).Magnitude < 3 then return end

    local desired = CFrame.lookAt(origin, target)
    local alpha = math.clamp(dt * Hub.State.AimSmooth, 0, 1)
    camera.CFrame = camera.CFrame:Lerp(desired, alpha)
end

-- ============================================================ авто-покупки

local function affordable(costAttr)
    local cost = attr(costAttr, -1)
    if type(cost) ~= "number" or cost < 0 then return false end
    local shards = attr("ASShards", 0)
    return shards >= cost
end

local function autoBuyStep()
    if not Hub.State.AutoBuy then return end
    local order = {}
    for kind in string.gmatch(Hub.State.AutoBuyOrder, "[^,%s]+") do
        table.insert(order, kind)
    end

    for _, kind in ipairs(order) do
        local costAttr = (kind == "health" and "ASCostHealth")
            or (kind == "gun" and "ASCostGun")
            or (kind == "weapon" and "ASCostWeapon")
        if costAttr and affordable(costAttr) then
            Hub.Fire("BuyUpgrade", 0.45, kind)
            return
        end
    end
end

local function autoUpgradeStep()
    if not Hub.State.AutoUpgrade then return end
    if not Config or not Config.stepCost then return end

    local shards = attr("ASShards", 0)
    for slot = 1, 4 do
        local name = LocalPlayer:GetAttribute("ASSlot" .. slot)
        if type(name) == "string" and name ~= "" then
            local steps = attr("ASSteps" .. name, 0)
            if type(steps) == "number" and steps < 8 then
                local ok, cost = pcall(Config.stepCost, "weapon", name)
                if ok and type(cost) == "number" and cost > 0 and shards >= cost then
                    Hub.Fire("UpgradeWeapon", 1.2, name)
                    return
                end
            end
        end
    end
end

local function autoSkipStep()
    if not Hub.State.AutoSkip then return end
    if attr("ASAutoSkip", false) ~= true then
        Hub.Fire("SetAutoSkip", 3, true)
        return
    end
    if attr("ASSkipArmed", false) == true then
        Hub.Fire("SkipVote", 2, true)
    end
end

local function autoRewardStep()
    if not Hub.State.AutoReward then return end
    local free = attr("ASFreeReward", "")
    if type(free) == "string" and free ~= "" then
        Hub.Fire("FreeReward", 6)
    end
    local nextAt = attr("ASDailyNextAt", 0)
    if type(nextAt) == "number" and nextAt > 0 and os.time() >= nextAt then
        Hub.Fire("ClaimDaily", 6)
    end
end

-- ============================================================ движение

local function isDead()
    local character = LocalPlayer.Character
    if not character then return false end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not humanoid then return false end
    return humanoid.Health <= 0
end

local function autoRestartStep()
    if not Hub.State.AutoRestart then return end
    if not isDead() then return end
    Hub.Fire("PlayAgain", 5)
end

-- ============================================================ движение и полёт

local flyState = { velocity = nil, gyro = nil, character = nil }

local function stopFly()
    if flyState.velocity then pcall(function() flyState.velocity:Destroy() end) end
    if flyState.gyro then pcall(function() flyState.gyro:Destroy() end) end
    flyState.velocity, flyState.gyro = nil, nil
    local character = flyState.character or LocalPlayer.Character
    flyState.character = nil
    if character then
        local humanoid = character:FindFirstChildOfClass("Humanoid")
        if humanoid then
            pcall(function() humanoid.PlatformStand = false end)
        end
    end
end

local function startFly()
    local character = LocalPlayer.Character
    if not character then return false end
    local root = character:FindFirstChild("HumanoidRootPart")
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not (root and humanoid) then return false end

    stopFly()
    pcall(function() humanoid.PlatformStand = true end)

    local velocity = Instance.new("BodyVelocity")
    velocity.Name = "ASHubFly"
    velocity.MaxForce = Vector3.new(1e6, 1e6, 1e6)
    velocity.Velocity = Vector3.zero
    velocity.Parent = root

    local gyro = Instance.new("BodyGyro")
    gyro.Name = "ASHubFlyGyro"
    gyro.MaxTorque = Vector3.new(1e6, 1e6, 1e6)
    gyro.P = 3000
    gyro.D = 50
    gyro.CFrame = root.CFrame
    gyro.Parent = root

    flyState.velocity, flyState.gyro, flyState.character = velocity, gyro, character
    return true
end

local function flyStep()
    if not Hub.State.Fly then
        if flyState.velocity then stopFly() end
        return
    end

    local character = LocalPlayer.Character
    if not character then return end
    local root = character:FindFirstChild("HumanoidRootPart")
    if not root then return end

    if flyState.character ~= character or not flyState.velocity or not flyState.velocity.Parent then
        if not startFly() then return end
    end

    local camera = Workspace.CurrentCamera
    if not camera then return end

    local look = camera.CFrame.LookVector
    local right = camera.CFrame.RightVector
    local direction = Vector3.zero

    if UserInputService:IsKeyDown(Enum.KeyCode.W) then direction = direction + look end
    if UserInputService:IsKeyDown(Enum.KeyCode.S) then direction = direction - look end
    if UserInputService:IsKeyDown(Enum.KeyCode.D) then direction = direction + right end
    if UserInputService:IsKeyDown(Enum.KeyCode.A) then direction = direction - right end
    if UserInputService:IsKeyDown(Enum.KeyCode.Space) then direction = direction + Vector3.new(0, 1, 0) end
    if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then direction = direction - Vector3.new(0, 1, 0) end

    if direction.Magnitude > 0 then direction = direction.Unit end

    flyState.velocity.Velocity = direction * Hub.State.FlySpeed
    flyState.gyro.CFrame = camera.CFrame
end

local function movementStep()
    local character = LocalPlayer.Character
    if not character then return end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not humanoid then return end

    if Hub.State.Speed and humanoid.WalkSpeed ~= Hub.State.WalkSpeed then
        humanoid.WalkSpeed = Hub.State.WalkSpeed
    end

    if Hub.State.Jump then
        -- игра держит UseJumpPower = false и рулит высотой через JumpHeight,
        -- поэтому одной записи в JumpPower недостаточно
        if humanoid.UseJumpPower ~= true then
            pcall(function() humanoid.UseJumpPower = true end)
        end
        if humanoid.JumpPower ~= Hub.State.JumpPower then
            humanoid.JumpPower = Hub.State.JumpPower
        end
    end
end

Hub.Track(LocalPlayer.CharacterAdded:Connect(function()
    stopFly()
end))

-- ============================================================ интерфейс

local function new(class, props, parent)
    local object = Instance.new(class)
    for key, value in pairs(props or {}) do
        object[key] = value
    end
    if parent then object.Parent = parent end
    return object
end

local gui = new("ScreenGui", {
    Name = "ASHubGui",
    ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    DisplayOrder = 50,
}, LocalPlayer:WaitForChild("PlayerGui"))

local root = new("Frame", {
    Name = "Window",
    Size = UDim2.fromOffset(360, 560),
    Position = UDim2.new(0, 40, 0, 120),
    BackgroundColor3 = Color3.fromRGB(18, 19, 24),
    BorderSizePixel = 0,
    Active = true,
}, gui)

new("UICorner", { CornerRadius = UDim.new(0, 10) }, root)
new("UIStroke", { Color = Color3.fromRGB(70, 74, 92), Thickness = 1 }, root)

local header = new("Frame", {
    Size = UDim2.new(1, 0, 0, 40),
    BackgroundColor3 = Color3.fromRGB(26, 28, 36),
    BorderSizePixel = 0,
}, root)
new("UICorner", { CornerRadius = UDim.new(0, 10) }, header)

local title = new("TextLabel", {
    Size = UDim2.new(1, -60, 1, 0),
    Position = UDim2.fromOffset(14, 0),
    BackgroundTransparency = 1,
    Font = Enum.Font.GothamBold,
    TextSize = 15,
    TextColor3 = Color3.fromRGB(235, 238, 250),
    TextXAlignment = Enum.TextXAlignment.Left,
    Text = "ARENA SURVIVAL HUB",
}, header)

local closeButton = new("TextButton", {
    Size = UDim2.fromOffset(28, 28),
    Position = UDim2.new(1, -36, 0, 6),
    BackgroundColor3 = Color3.fromRGB(45, 48, 60),
    Font = Enum.Font.GothamBold,
    TextSize = 15,
    TextColor3 = Color3.fromRGB(235, 238, 250),
    Text = "×",
}, header)
new("UICorner", { CornerRadius = UDim.new(0, 6) }, closeButton)

local scroll = new("ScrollingFrame", {
    Size = UDim2.new(1, -16, 1, -52),
    Position = UDim2.fromOffset(8, 46),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ScrollBarThickness = 4,
    CanvasSize = UDim2.new(0, 0, 0, 0),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, root)
new("UIListLayout", {
    Padding = UDim.new(0, 6),
    SortOrder = Enum.SortOrder.LayoutOrder,
}, scroll)

local layoutOrder = 0
local function nextOrder()
    layoutOrder = layoutOrder + 1
    return layoutOrder
end

local function section(text)
    local frame = new("Frame", {
        Size = UDim2.new(1, 0, 0, 26),
        BackgroundTransparency = 1,
        LayoutOrder = nextOrder(),
    }, scroll)
    new("TextLabel", {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 12,
        TextColor3 = Color3.fromRGB(120, 200, 255),
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = string.upper(text),
    }, frame)
    return frame
end

local function toggle(text, key, callback)
    local button = new("TextButton", {
        Size = UDim2.new(1, 0, 0, 32),
        BackgroundColor3 = Color3.fromRGB(32, 34, 44),
        Font = Enum.Font.GothamMedium,
        TextSize = 13,
        TextColor3 = Color3.fromRGB(210, 214, 230),
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = "   " .. text,
        LayoutOrder = nextOrder(),
    }, scroll)
    new("UICorner", { CornerRadius = UDim.new(0, 6) }, button)

    local function refresh()
        local on = Hub.State[key] == true
        button.BackgroundColor3 = on and Color3.fromRGB(34, 92, 62) or Color3.fromRGB(32, 34, 44)
        button.TextColor3 = on and Color3.fromRGB(160, 255, 200) or Color3.fromRGB(210, 214, 230)
    end

    button.Activated:Connect(function()
        Hub.State[key] = not Hub.State[key]
        refresh()
        if callback then pcall(callback, Hub.State[key]) end
    end)
    refresh()
    return button
end

local function slider(text, key, min, max, callback)
    local holder = new("Frame", {
        Size = UDim2.new(1, 0, 0, 46),
        BackgroundColor3 = Color3.fromRGB(32, 34, 44),
        LayoutOrder = nextOrder(),
    }, scroll)
    new("UICorner", { CornerRadius = UDim.new(0, 6) }, holder)

    local label = new("TextLabel", {
        Size = UDim2.new(1, -20, 0, 22),
        Position = UDim2.fromOffset(10, 4),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamMedium,
        TextSize = 12,
        TextColor3 = Color3.fromRGB(210, 214, 230),
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = text .. ": " .. tostring(Hub.State[key]),
    }, holder)

    local bar = new("Frame", {
        Size = UDim2.new(1, -20, 0, 8),
        Position = UDim2.fromOffset(10, 30),
        BackgroundColor3 = Color3.fromRGB(52, 56, 70),
        BorderSizePixel = 0,
    }, holder)
    new("UICorner", { CornerRadius = UDim.new(0, 4) }, bar)

    local fill = new("Frame", {
        Size = UDim2.fromScale((Hub.State[key] - min) / (max - min), 1),
        BackgroundColor3 = Color3.fromRGB(90, 190, 255),
        BorderSizePixel = 0,
    }, bar)
    new("UICorner", { CornerRadius = UDim.new(0, 4) }, fill)

    local dragging = false
    local function apply(input)
        local relative = math.clamp((input.Position.X - bar.AbsolutePosition.X) / bar.AbsoluteSize.X, 0, 1)
        local value = math.floor(min + (max - min) * relative + 0.5)
        Hub.State[key] = value
        label.Text = text .. ": " .. tostring(value)
        fill.Size = UDim2.fromScale(relative, 1)
        if callback then pcall(callback, value) end
    end

    bar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true
            apply(input)
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
            apply(input)
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = false
        end
    end)
    return holder
end

local function action(text, callback)
    local button = new("TextButton", {
        Size = UDim2.new(1, 0, 0, 30),
        BackgroundColor3 = Color3.fromRGB(46, 50, 66),
        Font = Enum.Font.GothamMedium,
        TextSize = 13,
        TextColor3 = Color3.fromRGB(220, 224, 240),
        Text = text,
        LayoutOrder = nextOrder(),
    }, scroll)
    new("UICorner", { CornerRadius = UDim.new(0, 6) }, button)
    button.Activated:Connect(function()
        local ok, err = pcall(callback)
        if not ok then log("ошибка действия:", err) end
    end)
    return button
end

local function readout(key)
    local frame = new("Frame", {
        Size = UDim2.new(1, 0, 0, 20),
        BackgroundTransparency = 1,
        LayoutOrder = nextOrder(),
    }, scroll)
    local label = new("TextLabel", {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Font = Enum.Font.Code,
        TextSize = 12,
        TextColor3 = Color3.fromRGB(170, 176, 195),
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = key,
    }, frame)
    return label
end

-- ---------------------------------------------------------------- наполнение

section("Информация")
local infoLabel = readout("загрузка...")

section("Визуал")
toggle("ESP зомби", "Esp")
toggle("Показывать вид зомби", "EspKinds")
slider("Дистанция ESP", "EspMaxDist", 40, 400)

section("Бой")
toggle("Авто-наведение камеры", "Aim")
slider("Скорость доводки", "AimSmooth", 2, 30)

section("Автоматизация")
toggle("Авто-покупки", "AutoBuy")
toggle("Авто-апгрейд оружия (тратит шары)", "AutoUpgrade")
toggle("Авто-скип волн", "AutoSkip")
toggle("Авто-награды", "AutoReward")
toggle("Авто-рестарт после смерти", "AutoRestart")
toggle("Анти-АФК", "AntiAfk")

section("Игрок")
toggle("Скорость", "Speed")
slider("WalkSpeed", "WalkSpeed", 16, 200)
toggle("Прыжок", "Jump")
slider("JumpPower", "JumpPower", 50, 250)
toggle("Полёт (WASD + Space/Ctrl)", "Fly")
slider("Скорость полёта", "FlySpeed", 10, 300)

section("Сервис")
action("Сбросить ESP", clearEsp)
action("Перезагрузить скрипт", function()
    if Hub.Unload then Hub.Unload() end
end)

-- ============================================================ перетаскивание

do
    local dragging, dragStart, startPos
    header.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true
            dragStart = input.Position
            startPos = root.Position
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
            local delta = input.Position - dragStart
            root.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = false
        end
    end)
end

local visible = true
closeButton.Activated:Connect(function()
    visible = not visible
    root.Visible = visible
end)

Hub.Track(UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == Enum.KeyCode.RightShift then
        visible = not visible
        root.Visible = visible
    end
end))

-- ============================================================ циклы

Hub.Track(RunService.RenderStepped:Connect(function(dt)
    local ok, err = pcall(aimStep, dt)
    if not ok then log("aim:", err) end
    local flyOk, flyErr = pcall(flyStep)
    if not flyOk then log("fly:", flyErr) end
end))

local espAccumulator = 0
Hub.Track(RunService.Heartbeat:Connect(function(dt)
    espAccumulator = espAccumulator + dt
    if espAccumulator >= 0.12 then
        espAccumulator = 0
        local ok, err = pcall(drawEsp)
        if not ok then log("esp:", err) end
    end
end))

task.spawn(function()
    while gui.Parent do
        pcall(autoBuyStep)
        pcall(autoUpgradeStep)
        pcall(autoSkipStep)
        pcall(autoRewardStep)
        pcall(autoRestartStep)
        pcall(movementStep)
        task.wait(0.35)
    end
end)

-- анти-АФК
Hub.Track(LocalPlayer.Idled:Connect(function()
    if not Hub.State.AntiAfk then return end
    local ok = pcall(function()
        local virtualUser = game:GetService("VirtualUser")
        virtualUser:CaptureController()
        virtualUser:ClickButton2(Vector2.new())
    end)
    if not ok then
        pcall(function()
            local virtualUser = game:GetService("VirtualUser")
            virtualUser:CaptureController()
        end)
    end
end))

-- обновление инфо-панели
task.spawn(function()
    while gui.Parent do
        local wave = attr("ASWave", 0)
        local target = attr("Target", 0)
        local bossFrac = attr("ASFrac", nil)
        if bossFrac == nil and AS then bossFrac = AS:GetAttribute("BossFrac") end
        local alive = #Hub.ActiveZombies(nil)
        local shards = attr("ASShards", 0)
        local credits = attr("ASCredits", 0)
        local guns = attr("ASGuns", 0)
        local dps = attr("ASDps", 0)
        local kills = attr("ASKills", 0)

        infoLabel.Text = string.format(
            "волна %s   цель %s   живых %d\nшары %s   кредиты %s\nпушек %s   dps %s   убийств %s\nбосс %s",
            tostring(wave), tostring(target), alive,
            tostring(shards), tostring(credits),
            tostring(guns), tostring(dps), tostring(kills),
            bossFrac and string.format("%.0f%%", bossFrac * 100) or "-"
        )
        task.wait(0.6)
    end
end)

-- ============================================================ выгрузка

function Hub.Unload()
    for _, conn in ipairs(Hub.Connections) do
        pcall(function() conn:Disconnect() end)
    end
    Hub.Connections = {}
    clearEsp()
    pcall(stopFly)
    pcall(function() RunService:UnbindFromRenderStep("ASHubAim") end)
    pcall(function() gui:Destroy() end)
    if espGui then pcall(function() espGui:Destroy() end) end
    log("выгружен")
end

log("загружен. RightShift — показать/скрыть окно.")
log(string.format("режим=%s волна=%s", tostring(attr("ASMode", "?")), tostring(attr("ASWave", "?"))))

getgenv().ASHub = Hub

return Hub
