-- =====================================================
--  PLAYER TELEPORT v5 - WALK THEN TELEPORT
--  Đi bộ pathfinding trước → rồi teleport CFrame
--  Chết → respawn → lặp lại
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
    walkTime     = 5,   -- giây đi bộ trước khi teleport
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
--  BƯỚC 1: ĐI BỘ PATHFINDING (tự nhiên, không CFrame)
-- =====================================================
local function walkPhase()
    local hum = getHum()
    if not hum then return end

    -- walkspeed bình thường
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
            -- fallback nếu path thất bại
            local thrp2 = getTargetHRP()
            if thrp2 then
                hum:MoveTo(thrp2.Position)
                task.wait(1)
            end
        end

        task.wait(0.1)
    end

    -- reset walkspeed
    hum.WalkSpeed = 16
end

-- =====================================================
--  BƯỚC 2: TELEPORT BẰNG CFRAME (như script gốc)
-- =====================================================
local function teleportPhase()
    setNoclip(true)
    setStatus("⬇️ Chui xuống đất...", Color3.fromRGB(180,120,255))

    -- BƯỚC 1: chui xuống đúng 15 studs, lock Y liên tục
    local hrp = getHRP()
    if not hrp then return end
    local undergroundY = hrp.Position.Y - 15

    local sinkConn
    sinkConn = RS.Heartbeat:Connect(function(dt)
        local h = getHRP()
        if not h then sinkConn:Disconnect() return end
        if h.Position.Y <= undergroundY then sinkConn:Disconnect() return end
        -- di chuyển xuống + tắt gravity bằng cách set velocity = 0
        h.CFrame = CFrame.new(h.Position.X, h.Position.Y - 60*dt, h.Position.Z)
        h.AssemblyLinearVelocity = Vector3.zero
        h.AssemblyAngularVelocity = Vector3.zero
    end)

    while not isDead and not stopped do
        local h = getHRP()
        if not h or h.Position.Y <= undergroundY then break end
        task.wait(0.05)
    end
    pcall(function() sinkConn:Disconnect() end)
    if isDead or stopped then return end

    -- lưu Y dưới đất
    local h = getHRP()
    if not h then return end
    local lockedY = h.Position.Y  -- giữ Y này trong suốt quá trình di chuyển ngang

    -- BƯỚC 2: teleport ngang đến X,Z của target, LOCK Y không cho rơi
    setStatus("⚡ Teleport dưới đất...", Color3.fromRGB(255,200,50))

    local tpConn
    tpConn = RS.Heartbeat:Connect(function(dt)
        if isDead or stopped then tpConn:Disconnect() return end
        local hrp2 = getHRP()
        local thrp = getTargetHRP()
        if not hrp2 or not thrp then return end

        local dest = Vector3.new(thrp.Position.X, lockedY, thrp.Position.Z)
        local dir  = dest - hrp2.Position
        local dist = dir.Magnitude

        if dist < 3 then tpConn:Disconnect() return end

        local step = cfg.speed * dt
        -- set CFrame với Y luôn = lockedY, không cho gravity kéo
        local newPos = hrp2.Position + dir.Unit * math.min(step, dist)
        hrp2.CFrame = CFrame.new(newPos.X, lockedY, newPos.Z)
        hrp2.AssemblyLinearVelocity = Vector3.zero
        hrp2.AssemblyAngularVelocity = Vector3.zero
    end)

    while not isDead and not stopped do
        local hrp2 = getHRP()
        local thrp = getTargetHRP()
        if hrp2 and thrp then
            local dest = Vector3.new(thrp.Position.X, lockedY, thrp.Position.Z)
            if (hrp2.Position - dest).Magnitude < 3 then break end
        end
        task.wait(0.1)
    end
    pcall(function() tpConn:Disconnect() end)
    if isDead or stopped then return end

    -- BƯỚC 3: nổi lên đến target, lock X,Z không cho trôi
    setStatus("⬆️ Nổi lên...", Color3.fromRGB(100,255,150))

    local riseConn
    riseConn = RS.Heartbeat:Connect(function(dt)
        if isDead or stopped then riseConn:Disconnect() return end
        local hrp3 = getHRP()
        local thrp = getTargetHRP()
        if not hrp3 or not thrp then riseConn:Disconnect() return end

        local dest = thrp.Position + Vector3.new(0, cfg.offset, 0)
        local dir  = dest - hrp3.Position
        local dist = dir.Magnitude

        if dist < 2 then
            riseConn:Disconnect()
            setStatus("✅ Đã đến!", Color3.fromRGB(80,220,130))
            return
        end

        local step = cfg.speed * dt
        local newPos = hrp3.Position + dir.Unit * math.min(step, dist)
        hrp3.CFrame = CFrame.new(newPos)
        hrp3.AssemblyLinearVelocity = Vector3.zero
        hrp3.AssemblyAngularVelocity = Vector3.zero
    end)

    while not isDead and not stopped do
        local hrp3 = getHRP()
        local thrp = getTargetHRP()
        if hrp3 and thrp and (hrp3.Position - thrp.Position).Magnitude < 2 then break end
        task.wait(0.1)
    end
    pcall(function() riseConn:Disconnect() end)
end

-- =====================================================
--  MAIN SEQUENCE
-- =====================================================
local function runSequence()
    _G.PTP_Main = task.spawn(function()
        while true do
            -- chờ active + có target
            while not cfg.active or cfg.targetName == "" or stopped do
                task.wait(0.5)
            end

            -- chờ nhân vật load
            if not lp.Character then
                lp.CharacterAdded:Wait()
                task.wait(1.5)
            end

            local hum = getHum()
            if not hum then task.wait(0.5); continue end

            -- nếu đang chết thì chờ respawn
            if hum.Health <= 0 or isDead then
                setStatus("💀 Chờ respawn...", Color3.fromRGB(200,80,80))
                lp.CharacterAdded:Wait()
                task.wait(2)
                isDead = false
                if not cfg.active or stopped then continue end
            end

            -- theo dõi khi chết
            local curHum = getHum()
            if curHum then
                curHum.Died:Connect(function()
                    isDead = true
                    if not cfg.manualNoclip then setNoclip(false) end
                    setStatus("💀 Đã chết! Chờ respawn...", Color3.fromRGB(200,80,80))
                end)
            end

            -- BƯỚC 1: đi bộ
            walkPhase()

            if isDead or stopped then
                task.wait(0.5)
                continue
            end

            -- BƯỚC 2: teleport CFrame
            teleportPhase()

            -- chờ đến khi chết để restart
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
--  HOTKEYS  P / N / X
-- =====================================================
_G.PTP_Input = UIS.InputBegan:Connect(function(input, gp)
    if gp then return end
    if input.KeyCode == Enum.KeyCode.P then
        cfg.active = not cfg.active; save()
        if not cfg.active then stopTP("Đã tắt (P)")
        else startTP() end
    end
    if input.KeyCode == Enum.KeyCode.N then
        cfg.manualNoclip = not cfg.manualNoclip; save()
        setNoclip(cfg.manualNoclip)
        setStatus("Noclip: " .. (cfg.manualNoclip and "ON" or "OFF"),
            cfg.manualNoclip and Color3.fromRGB(255,200,60) or Color3.fromRGB(200,140,70))
    end
    if input.KeyCode == Enum.KeyCode.X then
        stopTP("Dừng (X)")
    end
end)

-- =====================================================
--  RESPAWN
-- =====================================================
_G.PTP_RespConn = lp.CharacterAdded:Connect(function(char)
    char:WaitForChild("HumanoidRootPart")
    isDead = false
    task.wait(2)
    if cfg.active and cfg.targetName ~= "" and not stopped then
        setStatus("🔄 Respawned → bắt đầu lại")
    end
end)

-- =====================================================
--  UI (giữ nguyên từ v5 gốc)
-- =====================================================
if lp.PlayerGui:FindFirstChild("PTP5") then
    lp.PlayerGui.PTP5:Destroy()
end

local sg = Instance.new("ScreenGui")
sg.Name = "PTP5"; sg.ResetOnSpawn = false; sg.Parent = lp.PlayerGui

local main = Instance.new("Frame", sg)
main.Size = UDim2.fromOffset(265, 310)
main.Position = UDim2.fromOffset(20, 140)
main.BackgroundColor3 = Color3.fromRGB(14,14,19)
main.BorderSizePixel = 0
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
statLbl.BackgroundColor3 = Color3.fromRGB(22,22,30); statLbl.TextColor3 = Color3.fromRGB(110,200,130)
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

mkDiv(122)
mkToggle(128,"Bật script",cfg.active,function(on)
    cfg.active=on; save()
    if not on then stopTP("Đã tắt") else startTP() end
end)
mkDiv(166)
mkToggle(172,"Noclip thường trực",cfg.manualNoclip,function(on)
    cfg.manualNoclip=on; save(); setNoclip(on)
end)
mkDiv(210)

-- Walk time slider
mkLbl(216,"Thời gian đi bộ (giây)")
local wT=Instance.new("Frame",main)
wT.Size=UDim2.new(1,-16,0,6); wT.Position=UDim2.fromOffset(8,232)
wT.BackgroundColor3=Color3.fromRGB(30,30,44); wT.BorderSizePixel=0
Instance.new("UICorner",wT).CornerRadius=UDim.new(1,0)
local wF=Instance.new("Frame",wT)
wF.Size=UDim2.fromScale((cfg.walkTime-1)/19,1)
wF.BackgroundColor3=Color3.fromRGB(80,180,255); wF.BorderSizePixel=0
Instance.new("UICorner",wF).CornerRadius=UDim.new(1,0)
local wV=Instance.new("TextLabel",main)
wV.Size=UDim2.new(1,-16,0,14); wV.Position=UDim2.fromOffset(8,216)
wV.BackgroundTransparency=1; wV.Text=tostring(cfg.walkTime).."s"
wV.TextColor3=Color3.fromRGB(80,180,255); wV.Font=Enum.Font.GothamBold
wV.TextSize=10; wV.TextXAlignment=Enum.TextXAlignment.Right
local wSld=false
wT.InputBegan:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then wSld=true end end)
UIS.InputEnded:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then wSld=false end end)
UIS.InputChanged:Connect(function(i)
    if not wSld or i.UserInputType~=Enum.UserInputType.MouseMovement then return end
    local t=math.clamp((i.Position.X-wT.AbsolutePosition.X)/wT.AbsoluteSize.X,0,1)
    cfg.walkTime=math.floor(1+t*19)
    wF.Size=UDim2.fromScale(t,1); wV.Text=tostring(cfg.walkTime).."s"; save()
end)

mkDiv(245)

-- TP Speed slider
mkLbl(251,"Teleport Speed")
local sT=Instance.new("Frame",main)
sT.Size=UDim2.new(1,-16,0,6); sT.Position=UDim2.fromOffset(8,267)
sT.BackgroundColor3=Color3.fromRGB(30,30,44); sT.BorderSizePixel=0
Instance.new("UICorner",sT).CornerRadius=UDim.new(1,0)
local sF=Instance.new("Frame",sT)
sF.Size=UDim2.fromScale((cfg.speed-10)/190,1)
sF.BackgroundColor3=Color3.fromRGB(48,138,215); sF.BorderSizePixel=0
Instance.new("UICorner",sF).CornerRadius=UDim.new(1,0)
local sV=Instance.new("TextLabel",main)
sV.Size=UDim2.new(1,-16,0,14); sV.Position=UDim2.fromOffset(8,251)
sV.BackgroundTransparency=1; sV.Text=tostring(cfg.speed)
sV.TextColor3=Color3.fromRGB(78,178,130); sV.Font=Enum.Font.GothamBold
sV.TextSize=10; sV.TextXAlignment=Enum.TextXAlignment.Right
local sSld=false
sT.InputBegan:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then sSld=true end end)
UIS.InputEnded:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then sSld=false end end)
UIS.InputChanged:Connect(function(i)
    if not sSld or i.UserInputType~=Enum.UserInputType.MouseMovement then return end
    local t=math.clamp((i.Position.X-sT.AbsolutePosition.X)/sT.AbsoluteSize.X,0,1)
    cfg.speed=math.floor(10+t*190)
    sF.Size=UDim2.fromScale(t,1); sV.Text=tostring(cfg.speed); save()
end)

local hkLbl=Instance.new("TextLabel",main)
hkLbl.Size=UDim2.new(1,-16,0,12); hkLbl.Position=UDim2.fromOffset(8,282)
hkLbl.BackgroundTransparency=1; hkLbl.Text="P=toggle  N=noclip  X=stop"
hkLbl.TextColor3=Color3.fromRGB(75,75,95); hkLbl.Font=Enum.Font.Code
hkLbl.TextSize=9; hkLbl.TextXAlignment=Enum.TextXAlignment.Center

mkDiv(295)

-- ========== COPY JOB ID ==========
local copyBtn = Instance.new("TextButton", main)
copyBtn.Size             = UDim2.new(1,-16,0,28)
copyBtn.Position         = UDim2.fromOffset(8, 300)
copyBtn.BackgroundColor3 = Color3.fromRGB(40,80,140)
copyBtn.BorderSizePixel  = 0
copyBtn.Text             = "📋 Copy JobId Server Này"
copyBtn.TextColor3       = Color3.fromRGB(255,255,255)
copyBtn.Font             = Enum.Font.GothamBold
copyBtn.TextSize         = 11
Instance.new("UICorner", copyBtn).CornerRadius = UDim.new(0,6)

copyBtn.MouseButton1Click:Connect(function()
    pcall(function() setclipboard(game.JobId) end)
    copyBtn.Text = "✅ Đã copy JobId!"
    copyBtn.BackgroundColor3 = Color3.fromRGB(30,120,60)
    task.wait(2)
    copyBtn.Text = "📋 Copy JobId Server Này"
    copyBtn.BackgroundColor3 = Color3.fromRGB(40,80,140)
end)

-- ========== JOB ID INPUT ==========
mkLbl(335, "Dán JobId muốn join vào đây")
local jobBg = Instance.new("Frame", main)
jobBg.Size             = UDim2.new(1,-16,0,30)
jobBg.Position         = UDim2.fromOffset(8, 350)
jobBg.BackgroundColor3 = Color3.fromRGB(24,24,32)
jobBg.BorderSizePixel  = 0
Instance.new("UICorner", jobBg).CornerRadius = UDim.new(0,6)

local jobBox = Instance.new("TextBox", jobBg)
jobBox.Size              = UDim2.new(1,-12,1,0)
jobBox.Position          = UDim2.fromOffset(6,0)
jobBox.BackgroundTransparency = 1
jobBox.Text              = ""
jobBox.PlaceholderText   = "Dán JobId vào đây..."
jobBox.PlaceholderColor3 = Color3.fromRGB(70,70,92)
jobBox.TextColor3        = Color3.fromRGB(215,215,230)
jobBox.Font              = Enum.Font.Code
jobBox.TextSize          = 10
jobBox.ClearTextOnFocus  = false

-- ========== AUTO JOIN ==========
local autoJoinEnabled = false
local autoJoinThread  = nil

local joinBtn = Instance.new("TextButton", main)
joinBtn.Size             = UDim2.new(1,-16,0,28)
joinBtn.Position         = UDim2.fromOffset(8, 387)
joinBtn.BackgroundColor3 = Color3.fromRGB(100,40,40)
joinBtn.BorderSizePixel  = 0
joinBtn.Text             = "🔄 Auto Join: OFF"
joinBtn.TextColor3       = Color3.fromRGB(255,255,255)
joinBtn.Font             = Enum.Font.GothamBold
joinBtn.TextSize         = 12
Instance.new("UICorner", joinBtn).CornerRadius = UDim.new(0,6)

local joinLbl = Instance.new("TextLabel", main)
joinLbl.Size             = UDim2.new(1,-16,0,16)
joinLbl.Position         = UDim2.fromOffset(8, 420)
joinLbl.BackgroundTransparency = 1
joinLbl.Text             = ""
joinLbl.TextColor3       = Color3.fromRGB(150,150,180)
joinLbl.Font             = Enum.Font.Code
joinLbl.TextSize         = 10
joinLbl.TextXAlignment   = Enum.TextXAlignment.Center

local function stopAutoJoin()
    autoJoinEnabled = false
    if autoJoinThread then task.cancel(autoJoinThread); autoJoinThread = nil end
    joinBtn.Text             = "🔄 Auto Join: OFF"
    joinBtn.BackgroundColor3 = Color3.fromRGB(100,40,40)
    joinLbl.Text             = ""
end

local function startAutoJoin()
    local targetJob = jobBox.Text:gsub("%s+", "") -- xóa khoảng trắng

    if targetJob == "" then
        joinLbl.Text      = "❌ Chưa dán JobId!"
        joinLbl.TextColor3 = Color3.fromRGB(255,80,80)
        task.wait(2)
        joinLbl.Text = ""
        return
    end

    autoJoinEnabled = true
    joinBtn.Text             = "🔴 Auto Join: ON"
    joinBtn.BackgroundColor3 = Color3.fromRGB(30,120,60)

    autoJoinThread = task.spawn(function()
        while autoJoinEnabled do
            -- hiện jobid đang nhắm đến
            joinLbl.TextColor3 = Color3.fromRGB(150,150,180)

            for i = 5, 1, -1 do
                if not autoJoinEnabled then return end
                joinLbl.Text = "⏱ Join sau "..i.."s → "..targetJob:sub(1,8).."..."
                task.wait(1)
            end

            if not autoJoinEnabled then return end

            joinLbl.Text      = "🚀 Đang join..."
            joinLbl.TextColor3 = Color3.fromRGB(255,200,50)

            local ok, err = pcall(function()
                game:GetService("TeleportService"):TeleportToPlaceInstance(
                    game.PlaceId,
                    targetJob,
                    lp
                )
            end)

            if not ok then
                joinLbl.Text      = "❌ Lỗi: "..tostring(err):sub(1,20)
                joinLbl.TextColor3 = Color3.fromRGB(255,80,80)
            end

            task.wait(5)
        end
    end)
end

joinBtn.MouseButton1Click:Connect(function()
    if autoJoinEnabled then
        stopAutoJoin()
    else
        startAutoJoin()
    end
end)

-- resize frame
main.Size = UDim2.fromOffset(265, 445)

-- =====================================================
--  AUTO START
-- =====================================================
task.wait(0.5)
if cfg.active and cfg.targetName ~= "" then
    startTP()
else
    setStatus(cfg.targetName=="" and "Nhập tên player để bắt đầu" or "Đã tắt")
end

print("[PTP v5 WTP] loaded!")