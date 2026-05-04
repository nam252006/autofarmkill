-- =====================================================
--  PLAYER TELEPORT v5 - WALK THEN TELEPORT
--  Đi bộ pathfinding trước → chui đất → teleport
--  Chết → chờ respawn → lặp lại tự động
--  P = toggle | N = noclip | X = stop
-- =====================================================

if _G.PTP_Loop        then _G.PTP_Loop:Disconnect()        end
if _G.PTP_RespConn    then _G.PTP_RespConn:Disconnect()    end
if _G.PTP_Noclip      then _G.PTP_Noclip:Disconnect()      end
if _G.PTP_Input       then _G.PTP_Input:Disconnect()       end
if _G.PTP_AutoRestart then _G.PTP_AutoRestart:Disconnect() end
if _G.PTP_Main        then task.cancel(_G.PTP_Main)        end

-- =====================================================
--  CONFIG
-- =====================================================
local CFG_FILE = "ptp_v5.json"
local cfg = {
    targetName   = "",
    active       = true,
    speed        = 80,
    offset       = 3,
    walkTime     = 5,
    sinkDepth    = 15,
    manualNoclip = false,
}

local function save()
    pcall(function()
        writefile(CFG_FILE, game:GetService("HttpService"):JSONEncode(cfg))
    end)
end
local function load()
    pcall(function()
        if isfile and isfile(CFG_FILE) then
            local d = game:GetService("HttpService"):JSONDecode(readfile(CFG_FILE))
            if type(d)=="table" then for k,v in pairs(d) do cfg[k]=v end end
        end
    end)
end
load()

-- =====================================================
--  SERVICES
-- =====================================================
local Players            = game:GetService("Players")
local RS                 = game:GetService("RunService")
local UIS                = game:GetService("UserInputService")
local TS                 = game:GetService("TweenService")
local PathfindingService = game:GetService("PathfindingService")
local lp                 = Players.LocalPlayer

-- =====================================================
--  STATE
-- =====================================================
local noclipOn = false
local isDead   = false
local stopped  = false
local setStatus

-- =====================================================
--  HELPERS
-- =====================================================
local function getHRP()
    local c = lp.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end
local function getHum()
    local c = lp.Character
    return c and c:FindFirstChildOfClass("Humanoid")
end
local function getTargetHRP()
    local tp = Players:FindFirstChild(cfg.targetName)
    if not tp or not tp.Character then return nil end
    return tp.Character:FindFirstChild("HumanoidRootPart")
end

-- =====================================================
--  NOCLIP
-- =====================================================
local function setNoclip(on)
    noclipOn = on
    local char = lp.Character
    if not char then return end
    for _, p in ipairs(char:GetDescendants()) do
        if p:IsA("BasePart") then p.CanCollide = not on end
    end
end

_G.PTP_Noclip = RS.Stepped:Connect(function()
    if not noclipOn then return end
    local char = lp.Character
    if not char then return end
    for _, p in ipairs(char:GetDescendants()) do
        if p:IsA("BasePart") then p.CanCollide = false end
    end
end)

-- =====================================================
--  BƯỚC 1: ĐI BỘ PATHFINDING
-- =====================================================
local function walkPhase()
    local hum = getHum()
    if not hum then return end
    hum.WalkSpeed = 16

    local startTime = tick()
    while tick() - startTime < cfg.walkTime do
        if isDead or stopped then return end

        local hrp  = getHRP()
        local thrp = getTargetHRP()
        if not hrp or not thrp then task.wait(0.5); continue end

        local path = PathfindingService:CreatePath({
            AgentRadius     = 2,
            AgentHeight     = 5,
            AgentCanJump    = true,
            AgentJumpHeight = 7,
            AgentMaxSlope   = 45,
            WaypointSpacing = 4,
        })

        local ok = pcall(function()
            path:ComputeAsync(hrp.Position, thrp.Position)
        end)

        if ok and path.Status == Enum.PathStatus.Success then
            local wps = path:GetWaypoints()
            for i = 2, #wps do
                if isDead or stopped then return end
                if tick() - startTime >= cfg.walkTime then return end
                local wp = wps[i]
                if wp.Action == Enum.PathWaypointAction.Jump then
                    hum.Jump = true
                end
                hum:MoveTo(wp.Position)
                hum.MoveToFinished:Wait(2)
                local rem = math.max(0, math.ceil(cfg.walkTime - (tick() - startTime)))
                setStatus("🚶 Đi bộ... " .. rem .. "s", Color3.fromRGB(100,180,255))
            end
        else
            local thrp2 = getTargetHRP()
            if thrp2 then hum:MoveTo(thrp2.Position); task.wait(1) end
        end
        task.wait(0.1)
    end
    hum.WalkSpeed = 16
end

-- =====================================================
--  BƯỚC 2: CHUI ĐẤT + TELEPORT
-- =====================================================
-- =====================================================
--  TELEPORT PHASE - LIÊN TỤC THEO TARGET
-- =====================================================
-- =====================================================
--  TELEPORT PHASE - dùng step-teleport theo target liên tục
-- =====================================================
local function teleportPhase()
    setNoclip(true)

    -- Chui xuống đất 1 lần
    setStatus("⬇️ Chui xuống đất...", Color3.fromRGB(180,120,255))
    local hrp = getHRP()
    if not hrp then return end
    local undergroundY = hrp.Position.Y - (cfg.sinkDepth or 15)

    local sinkConn
    sinkConn = RS.Heartbeat:Connect(function(dt)
        local h = getHRP()
        if not h then pcall(function() sinkConn:Disconnect() end) return end
        if h.Position.Y <= undergroundY then pcall(function() sinkConn:Disconnect() end) return end
        h.CFrame = CFrame.new(h.Position.X, h.Position.Y - 60*dt, h.Position.Z)
        h.AssemblyLinearVelocity  = Vector3.zero
        h.AssemblyAngularVelocity = Vector3.zero
    end)

    while not isDead and not stopped do
        local h = getHRP()
        if not h or h.Position.Y <= undergroundY then break end
        task.wait(0.05)
    end
    pcall(function() sinkConn:Disconnect() end)
    if isDead or stopped then return end

    -- Lấy Y cố định dưới đất
    local h = getHRP()
    if not h then return end
    local lockedY = h.Position.Y

    -- ── STEP-TELEPORT LOOP (từ NMA MOV) ──
    -- target là Vector3 cập nhật liên tục theo player
    local followTarget = nil

    -- Thread cập nhật followTarget theo target player
    local updateConn = RS.Heartbeat:Connect(function()
        local thrp = getTargetHRP()
        if thrp then
            -- Giữ Y dưới đất, chỉ theo X,Z của target
            followTarget = Vector3.new(thrp.Position.X, lockedY, thrp.Position.Z)
        end
    end)

    -- Step-teleport loop: di chuyển từng bước về followTarget
    local stepConn = RS.Heartbeat:Connect(function(dt)
        if isDead or stopped then return end
        if not followTarget then return end

        local hrp2 = getHRP()
        if not hrp2 then return end

        local dir  = followTarget - hrp2.Position
        local dist = dir.Magnitude
        local step = cfg.speed * dt

        if dist <= step then
            -- Đã sát → snap vào luôn
            hrp2.CFrame = CFrame.new(followTarget)
            hrp2.AssemblyLinearVelocity  = Vector3.zero
            hrp2.AssemblyAngularVelocity = Vector3.zero
            setStatus("✅ Sát " .. cfg.targetName, Color3.fromRGB(80,220,130))
            return
        end

        -- Di chuyển step
        local newPos = hrp2.Position + dir.Unit * step
        hrp2.CFrame  = CFrame.new(newPos)
        hrp2.AssemblyLinearVelocity  = Vector3.zero
        hrp2.AssemblyAngularVelocity = Vector3.zero

        setStatus(string.format("🎯 Theo %s | %.0f studs", cfg.targetName, dist),
            Color3.fromRGB(255,200,50))
    end)

    -- Giữ phase sống đến khi chết/dừng
    while not isDead and not stopped do
        task.wait(0.5)
    end

    pcall(function() updateConn:Disconnect() end)
    pcall(function() stepConn:Disconnect()   end)
end

-- =====================================================
--  MAIN SEQUENCE
-- =====================================================
local function runSequence()
    if _G.PTP_Main then task.cancel(_G.PTP_Main) end
    _G.PTP_Main = task.spawn(function()
        while true do
            while not cfg.active or cfg.targetName == "" or stopped do
                task.wait(0.5)
            end

            local hum = getHum()
            if not hum or hum.Health <= 0 then task.wait(0.5); continue end

            -- đi bộ
            walkPhase()
            if isDead or stopped then task.wait(0.5); continue end

            -- chui đất + teleport
            teleportPhase()
            if isDead or stopped then task.wait(0.5); continue end

            -- chờ chết
            setStatus("✅ Đã đến! Chờ lần tiếp...", Color3.fromRGB(80,220,130))
            while not isDead and not stopped do
                task.wait(0.5)
            end
            task.wait(0.5)
        end
    end)
end

-- =====================================================
--  START / STOP
-- =====================================================
local function startTP()
    if not cfg.active or cfg.targetName == "" then return end
    stopped = false
    isDead  = false
    runSequence()
end

local function stopTP(reason)
    stopped = true
    if _G.PTP_Main then task.cancel(_G.PTP_Main); _G.PTP_Main = nil end
    local hum = getHum()
    if hum then
        local hrp = getHRP()
        if hrp then hum:MoveTo(hrp.Position) end
    end
    if not cfg.manualNoclip then setNoclip(false) end
    setStatus(reason or "Đã dừng", Color3.fromRGB(200,140,70))
end

-- =====================================================
--  RESPAWN - chờ load xong mới bắt đầu
-- =====================================================
_G.PTP_RespConn = lp.CharacterAdded:Connect(function(char)
    char:WaitForChild("HumanoidRootPart")
    char:WaitForChild("Humanoid")

    isDead  = false
    stopped = false
    if _G.PTP_Main then task.cancel(_G.PTP_Main); _G.PTP_Main = nil end

    setStatus("⏳ Chờ respawn...", Color3.fromRGB(200,200,80))

    -- chờ health > 0
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then return end
    while hum.Health <= 0 do task.wait(0.1) end

    -- chờ thêm 2s cho chắc
    task.wait(2)

    if not cfg.active or cfg.targetName == "" then
        setStatus("Nhập tên player để bắt đầu")
        return
    end

    -- theo dõi chết
    hum.Died:Connect(function()
        isDead  = true
        stopped = true
        if not cfg.manualNoclip then setNoclip(false) end
        setStatus("💀 Đã chết! Chờ respawn...", Color3.fromRGB(200,80,80))
    end)

    setStatus("✅ Đã respawn! Bắt đầu...", Color3.fromRGB(80,220,130))
    task.wait(0.5)
    runSequence()
end)

-- =====================================================
--  HOTKEYS
-- =====================================================
_G.PTP_Input = UIS.InputBegan:Connect(function(input, gp)
    if gp then return end
    if input.KeyCode == Enum.KeyCode.P then
        cfg.active = not cfg.active; save()
        if not cfg.active then stopTP("Đã tắt (P)") else startTP() end
    end
    if input.KeyCode == Enum.KeyCode.N then
        cfg.manualNoclip = not cfg.manualNoclip; save()
        setNoclip(cfg.manualNoclip)
        setStatus("Noclip: " .. (cfg.manualNoclip and "ON" or "OFF"),
            cfg.manualNoclip and Color3.fromRGB(255,200,60) or Color3.fromRGB(200,140,70))
    end
    if input.KeyCode == Enum.KeyCode.X then stopTP("Dừng (X)") end
end)

-- =====================================================
--  UI
-- =====================================================
if lp.PlayerGui:FindFirstChild("PTP5") then lp.PlayerGui.PTP5:Destroy() end

local sg = Instance.new("ScreenGui")
sg.Name = "PTP5"; sg.ResetOnSpawn = false; sg.Parent = lp.PlayerGui

local main = Instance.new("Frame", sg)
main.Size             = UDim2.fromOffset(265, 460)
main.Position         = UDim2.fromOffset(20, 140)
main.BackgroundColor3 = Color3.fromRGB(14,14,19)
main.BorderSizePixel  = 0
Instance.new("UICorner", main).CornerRadius = UDim.new(0,10)

local sh = Instance.new("Frame", main)
sh.Size = UDim2.new(1,8,1,8); sh.Position = UDim2.fromOffset(-4,-4)
sh.BackgroundColor3 = Color3.fromRGB(0,0,0)
sh.BackgroundTransparency = 0.62; sh.ZIndex = main.ZIndex-1; sh.BorderSizePixel = 0
Instance.new("UICorner", sh).CornerRadius = UDim.new(0,13)

local tbar = Instance.new("Frame", main)
tbar.Size = UDim2.new(1,0,0,36)
tbar.BackgroundColor3 = Color3.fromRGB(20,20,28); tbar.BorderSizePixel = 0
Instance.new("UICorner", tbar).CornerRadius = UDim.new(0,10)

local titleTxt = Instance.new("TextLabel", tbar)
titleTxt.Size = UDim2.new(1,-38,1,0); titleTxt.Position = UDim2.fromOffset(10,0)
titleTxt.BackgroundTransparency = 1; titleTxt.Text = "🎯  Player Teleport v5 WTP"
titleTxt.TextColor3 = Color3.fromRGB(210,210,220); titleTxt.Font = Enum.Font.GothamBold
titleTxt.TextSize = 13; titleTxt.TextXAlignment = Enum.TextXAlignment.Left

local xBtn = Instance.new("TextButton", tbar)
xBtn.Size = UDim2.fromOffset(26,26); xBtn.Position = UDim2.new(1,-30,0,5)
xBtn.BackgroundColor3 = Color3.fromRGB(185,48,48); xBtn.Text = "✕"
xBtn.TextColor3 = Color3.fromRGB(255,255,255); xBtn.Font = Enum.Font.GothamBold
xBtn.TextSize = 12; xBtn.BorderSizePixel = 0
Instance.new("UICorner", xBtn).CornerRadius = UDim.new(0,5)
xBtn.MouseButton1Click:Connect(function() stopTP("Closed"); sg:Destroy() end)

local drg,ds,fs = false
tbar.InputBegan:Connect(function(i)
    if i.UserInputType==Enum.UserInputType.MouseButton1 then drg=true;ds=i.Position;fs=main.Position end
end)
tbar.InputEnded:Connect(function(i)
    if i.UserInputType==Enum.UserInputType.MouseButton1 then drg=false end
end)
UIS.InputChanged:Connect(function(i)
    if drg and i.UserInputType==Enum.UserInputType.MouseMovement then
        local d=i.Position-ds
        main.Position=UDim2.fromOffset(fs.X.Offset+d.X,fs.Y.Offset+d.Y)
    end
end)

local statLbl = Instance.new("TextLabel", main)
statLbl.Size = UDim2.new(1,-16,0,20); statLbl.Position = UDim2.fromOffset(8,42)
statLbl.BackgroundColor3 = Color3.fromRGB(22,22,30)
statLbl.TextColor3 = Color3.fromRGB(110,200,130)
statLbl.Font = Enum.Font.Code; statLbl.TextSize = 10; statLbl.Text = "> idle"
statLbl.TextXAlignment = Enum.TextXAlignment.Left; statLbl.BorderSizePixel = 0
statLbl.ClipsDescendants = true
Instance.new("UICorner", statLbl).CornerRadius = UDim.new(0,5)
Instance.new("UIPadding", statLbl).PaddingLeft = UDim.new(0,6)

function setStatus(t, c)
    statLbl.Text = "> "..t
    statLbl.TextColor3 = c or Color3.fromRGB(110,200,130)
end

local function mkLbl(y,txt)
    local l=Instance.new("TextLabel",main)
    l.Size=UDim2.new(1,-16,0,14); l.Position=UDim2.fromOffset(8,y)
    l.BackgroundTransparency=1; l.Text=txt
    l.TextColor3=Color3.fromRGB(105,105,130); l.Font=Enum.Font.Gotham
    l.TextSize=10; l.TextXAlignment=Enum.TextXAlignment.Left
end
local function mkDiv(y)
    local d=Instance.new("Frame",main)
    d.Size=UDim2.new(1,-16,0,1); d.Position=UDim2.fromOffset(8,y)
    d.BackgroundColor3=Color3.fromRGB(30,30,42); d.BorderSizePixel=0
end
local function mkToggle(y,label,init,onChange)
    local row=Instance.new("Frame",main)
    row.Size=UDim2.new(1,-16,0,34); row.Position=UDim2.fromOffset(8,y)
    row.BackgroundTransparency=1
    local lbl=Instance.new("TextLabel",row)
    lbl.Size=UDim2.new(1,-70,1,0); lbl.BackgroundTransparency=1
    lbl.TextColor3=Color3.fromRGB(205,205,218); lbl.Font=Enum.Font.GothamBold
    lbl.TextSize=12; lbl.TextXAlignment=Enum.TextXAlignment.Left; lbl.Text=label
    local stxt=Instance.new("TextLabel",row)
    stxt.Size=UDim2.fromOffset(34,34); stxt.Position=UDim2.new(1,-74,0,0)
    stxt.BackgroundTransparency=1; stxt.Font=Enum.Font.GothamBold; stxt.TextSize=10
    stxt.TextXAlignment=Enum.TextXAlignment.Right
    local track=Instance.new("Frame",row)
    track.Size=UDim2.fromOffset(46,26); track.Position=UDim2.new(1,-50,0.5,-13)
    track.BorderSizePixel=0; Instance.new("UICorner",track).CornerRadius=UDim.new(1,0)
    local knob=Instance.new("Frame",track)
    knob.Size=UDim2.fromOffset(20,20); knob.BackgroundColor3=Color3.fromRGB(245,245,250)
    knob.BorderSizePixel=0; Instance.new("UICorner",knob).CornerRadius=UDim.new(1,0)
    local cur=init
    local function apply(on,anim)
        local i=TweenInfo.new(anim and 0.15 or 0)
        TS:Create(track,i,{BackgroundColor3=on and Color3.fromRGB(30,170,80) or Color3.fromRGB(48,48,62)}):Play()
        TS:Create(knob,i,{Position=on and UDim2.fromOffset(24,3) or UDim2.fromOffset(2,3)}):Play()
        stxt.Text=on and "ON" or "OFF"
        stxt.TextColor3=on and Color3.fromRGB(60,215,105) or Color3.fromRGB(95,95,115)
    end
    apply(cur,false)
    local function toggle() cur=not cur; apply(cur,true); onChange(cur) end
    local btn=Instance.new("TextButton",track)
    btn.Size=UDim2.fromScale(1,1); btn.BackgroundTransparency=1; btn.Text=""; btn.ZIndex=5
    btn.MouseButton1Click:Connect(toggle)
    local rb=Instance.new("TextButton",row)
    rb.Size=UDim2.new(1,-56,1,0); rb.BackgroundTransparency=1; rb.Text=""
    rb.MouseButton1Click:Connect(toggle)
end
local function mkSlider(yLbl, yBar, label, min, max, valCfg, color, fmt, onChange)
    mkLbl(yLbl, label)
    local bar=Instance.new("Frame",main)
    bar.Size=UDim2.new(1,-16,0,6); bar.Position=UDim2.fromOffset(8,yBar)
    bar.BackgroundColor3=Color3.fromRGB(30,30,44); bar.BorderSizePixel=0
    Instance.new("UICorner",bar).CornerRadius=UDim.new(1,0)
    local fill=Instance.new("Frame",bar)
    fill.Size=UDim2.fromScale((valCfg-min)/(max-min),1)
    fill.BackgroundColor3=color; fill.BorderSizePixel=0
    Instance.new("UICorner",fill).CornerRadius=UDim.new(1,0)
    local valLbl=Instance.new("TextLabel",main)
    valLbl.Size=UDim2.new(1,-16,0,14); valLbl.Position=UDim2.fromOffset(8,yLbl)
    valLbl.BackgroundTransparency=1; valLbl.Text=fmt(valCfg)
    valLbl.TextColor3=color; valLbl.Font=Enum.Font.GothamBold
    valLbl.TextSize=10; valLbl.TextXAlignment=Enum.TextXAlignment.Right
    local sld=false
    bar.InputBegan:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then sld=true end end)
    UIS.InputEnded:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then sld=false end end)
    UIS.InputChanged:Connect(function(i)
        if not sld or i.UserInputType~=Enum.UserInputType.MouseMovement then return end
        local t=math.clamp((i.Position.X-bar.AbsolutePosition.X)/bar.AbsoluteSize.X,0,1)
        local val=math.floor(min+t*(max-min))
        fill.Size=UDim2.fromScale(t,1); valLbl.Text=fmt(val)
        onChange(val); save()
    end)
end

-- ===== NAME INPUT =====
mkLbl(70,"Tên người chơi")
local nameBg=Instance.new("Frame",main)
nameBg.Size=UDim2.new(1,-16,0,30); nameBg.Position=UDim2.fromOffset(8,84)
nameBg.BackgroundColor3=Color3.fromRGB(24,24,32); nameBg.BorderSizePixel=0
Instance.new("UICorner",nameBg).CornerRadius=UDim.new(0,6)

local nameBox=Instance.new("TextBox",nameBg)
nameBox.Size=UDim2.new(1,-12,1,0); nameBox.Position=UDim2.fromOffset(6,0)
nameBox.BackgroundTransparency=1; nameBox.Text=cfg.targetName
nameBox.PlaceholderText="Nhập username..."; nameBox.PlaceholderColor3=Color3.fromRGB(70,70,92)
nameBox.TextColor3=Color3.fromRGB(215,215,230); nameBox.Font=Enum.Font.Gotham
nameBox.TextSize=12; nameBox.ClearTextOnFocus=false
nameBox.FocusLost:Connect(function()
    cfg.targetName=nameBox.Text; save()
    if cfg.active and cfg.targetName~="" then
        stopTP("Đổi target..."); task.wait(0.3); startTP()
    end
end)

local drop=Instance.new("Frame",main)
drop.Size=UDim2.new(1,-16,0,0); drop.Position=UDim2.fromOffset(8,115)
drop.BackgroundColor3=Color3.fromRGB(22,22,32); drop.BorderSizePixel=0
drop.ClipsDescendants=true; drop.ZIndex=30
Instance.new("UICorner",drop).CornerRadius=UDim.new(0,6)
Instance.new("UIListLayout",drop).SortOrder=Enum.SortOrder.LayoutOrder

local function refreshDrop(f)
    for _,c in ipairs(drop:GetChildren()) do
        if c:IsA("TextButton") then c:Destroy() end
    end
    if f=="" then TS:Create(drop,TweenInfo.new(0.1),{Size=UDim2.new(1,-16,0,0)}):Play(); return end
    local n=0
    for _,p in ipairs(Players:GetPlayers()) do
        if p~=lp and p.Name:lower():find(f:lower(),1,true) then
            n+=1
            local b=Instance.new("TextButton",drop)
            b.Size=UDim2.fromOffset(265,24); b.BackgroundColor3=Color3.fromRGB(28,28,38)
            b.Text="  "..p.Name; b.TextColor3=Color3.fromRGB(195,195,215)
            b.Font=Enum.Font.Gotham; b.TextSize=11; b.TextXAlignment=Enum.TextXAlignment.Left
            b.BorderSizePixel=0; b.ZIndex=31
            b.MouseButton1Click:Connect(function()
                nameBox.Text=p.Name; cfg.targetName=p.Name; save()
                TS:Create(drop,TweenInfo.new(0.1),{Size=UDim2.new(1,-16,0,0)}):Play()
                stopTP("Đổi target..."); task.wait(0.3); startTP()
            end)
        end
    end
    TS:Create(drop,TweenInfo.new(0.12),{Size=UDim2.new(1,-16,0,math.min(n*24,72))}):Play()
end
nameBox:GetPropertyChangedSignal("Text"):Connect(function() refreshDrop(nameBox.Text) end)

-- ===== TOGGLES =====
mkDiv(122)
mkToggle(128,"Bật script",cfg.active,function(on)
    cfg.active=on; save()
    if not on then stopTP("Đã tắt") else startTP() end
end)
mkDiv(166)
mkToggle(172,"Noclip thường trực",cfg.manualNoclip,function(on)
    cfg.manualNoclip=on; save(); setNoclip(on)
end)

-- ===== SLIDERS =====
mkDiv(210)
mkSlider(216, 232, "Thời gian đi bộ (giây)", 1, 20, cfg.walkTime,
    Color3.fromRGB(80,180,255),
    function(v) return v.."s" end,
    function(v) cfg.walkTime=v end)

mkDiv(242)
mkSlider(248, 264, "Độ sâu chui xuống (studs)", 1, 50, cfg.sinkDepth,
    Color3.fromRGB(160,80,220),
    function(v) return v.." studs" end,
    function(v) cfg.sinkDepth=v end)

mkDiv(274)
mkSlider(280, 296, "Teleport Speed", 10, 200, cfg.speed,
    Color3.fromRGB(48,138,215),
    function(v) return tostring(v) end,
    function(v) cfg.speed=v end)

-- ===== HOTKEY LABEL =====
local hkLbl=Instance.new("TextLabel",main)
hkLbl.Size=UDim2.new(1,-16,0,12); hkLbl.Position=UDim2.fromOffset(8,308)
hkLbl.BackgroundTransparency=1; hkLbl.Text="P=toggle  N=noclip  X=stop"
hkLbl.TextColor3=Color3.fromRGB(75,75,95); hkLbl.Font=Enum.Font.Code
hkLbl.TextSize=9; hkLbl.TextXAlignment=Enum.TextXAlignment.Center

-- ===== COPY JOBID =====
mkDiv(323)
local copyBtn=Instance.new("TextButton",main)
copyBtn.Size=UDim2.new(1,-16,0,28); copyBtn.Position=UDim2.fromOffset(8,328)
copyBtn.BackgroundColor3=Color3.fromRGB(40,80,140); copyBtn.BorderSizePixel=0
copyBtn.Text="📋 Copy JobId Server Này"
copyBtn.TextColor3=Color3.fromRGB(255,255,255); copyBtn.Font=Enum.Font.GothamBold
copyBtn.TextSize=11
Instance.new("UICorner",copyBtn).CornerRadius=UDim.new(0,6)
copyBtn.MouseButton1Click:Connect(function()
    pcall(function() setclipboard(game.JobId) end)
    copyBtn.Text="✅ Đã copy!"; copyBtn.BackgroundColor3=Color3.fromRGB(30,120,60)
    task.wait(2)
    copyBtn.Text="📋 Copy JobId Server Này"; copyBtn.BackgroundColor3=Color3.fromRGB(40,80,140)
end)

-- ===== JOB ID INPUT =====
mkLbl(362,"Dán JobId muốn join vào đây")
local jobBg=Instance.new("Frame",main)
jobBg.Size=UDim2.new(1,-16,0,30); jobBg.Position=UDim2.fromOffset(8,376)
jobBg.BackgroundColor3=Color3.fromRGB(24,24,32); jobBg.BorderSizePixel=0
Instance.new("UICorner",jobBg).CornerRadius=UDim.new(0,6)

local jobBox=Instance.new("TextBox",jobBg)
jobBox.Size=UDim2.new(1,-12,1,0); jobBox.Position=UDim2.fromOffset(6,0)
jobBox.BackgroundTransparency=1; jobBox.Text=""
jobBox.PlaceholderText="Dán JobId vào đây..."
jobBox.PlaceholderColor3=Color3.fromRGB(70,70,92)
jobBox.TextColor3=Color3.fromRGB(215,215,230)
jobBox.Font=Enum.Font.Code; jobBox.TextSize=10
jobBox.ClearTextOnFocus=false

-- ===== AUTO JOIN =====
local autoJoinEnabled=false
local autoJoinThread=nil

local joinBtn=Instance.new("TextButton",main)
joinBtn.Size=UDim2.new(1,-16,0,28); joinBtn.Position=UDim2.fromOffset(8,412)
joinBtn.BackgroundColor3=Color3.fromRGB(100,40,40); joinBtn.BorderSizePixel=0
joinBtn.Text="🔄 Auto Join: OFF"
joinBtn.TextColor3=Color3.fromRGB(255,255,255); joinBtn.Font=Enum.Font.GothamBold
joinBtn.TextSize=12
Instance.new("UICorner",joinBtn).CornerRadius=UDim.new(0,6)

local joinLbl=Instance.new("TextLabel",main)
joinLbl.Size=UDim2.new(1,-16,0,16); joinLbl.Position=UDim2.fromOffset(8,444)
joinLbl.BackgroundTransparency=1; joinLbl.Text=""
joinLbl.TextColor3=Color3.fromRGB(150,150,180); joinLbl.Font=Enum.Font.Code
joinLbl.TextSize=10; joinLbl.TextXAlignment=Enum.TextXAlignment.Center

local function stopAutoJoin()
    autoJoinEnabled=false
    if autoJoinThread then task.cancel(autoJoinThread); autoJoinThread=nil end
    joinBtn.Text="🔄 Auto Join: OFF"; joinBtn.BackgroundColor3=Color3.fromRGB(100,40,40)
    joinLbl.Text=""
end

local function startAutoJoin()
    local targetJob=jobBox.Text:gsub("%s+","")
    if targetJob=="" then
        joinLbl.Text="❌ Chưa dán JobId!"; joinLbl.TextColor3=Color3.fromRGB(255,80,80)
        task.wait(2); joinLbl.Text=""; return
    end
    autoJoinEnabled=true
    joinBtn.Text="🔴 Auto Join: ON"; joinBtn.BackgroundColor3=Color3.fromRGB(30,120,60)
    autoJoinThread=task.spawn(function()
        while autoJoinEnabled do
            joinLbl.TextColor3=Color3.fromRGB(150,150,180)
            for i=5,1,-1 do
                if not autoJoinEnabled then return end
                joinLbl.Text="⏱ Join sau "..i.."s → "..targetJob:sub(1,8).."..."
                task.wait(1)
            end
            if not autoJoinEnabled then return end
            joinLbl.Text="🚀 Đang join..."; joinLbl.TextColor3=Color3.fromRGB(255,200,50)
            local ok,err=pcall(function()
                game:GetService("TeleportService"):TeleportToPlaceInstance(game.PlaceId,targetJob,lp)
            end)
            if not ok then
                joinLbl.Text="❌ Lỗi: "..tostring(err):sub(1,20)
                joinLbl.TextColor3=Color3.fromRGB(255,80,80)
            end
            task.wait(5)
        end
    end)
end

joinBtn.MouseButton1Click:Connect(function()
    if autoJoinEnabled then stopAutoJoin() else startAutoJoin() end
end)

-- =====================================================
--  AUTO START
-- =====================================================
task.wait(0.5)

-- theo dõi chết cho character hiện tại
local function watchDeath()
    local char = lp.Character
    if not char then return end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then return end
    hum.Died:Connect(function()
        isDead  = true
        stopped = true
        if not cfg.manualNoclip then setNoclip(false) end
        setStatus("💀 Đã chết! Chờ respawn...", Color3.fromRGB(200,80,80))
    end)
end
watchDeath()

if cfg.active and cfg.targetName ~= "" then
    startTP()
else
    setStatus(cfg.targetName=="" and "Nhập tên player để bắt đầu" or "Đã tắt")
end

print("[PTP v5 WTP] loaded!")
