-- discord: @sillyrelshy | roblox: @sillyrelshy

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local TS = game:GetService("TweenService")

local plr = Players.LocalPlayer
local cam = workspace.CurrentCamera

local tool = script.Parent
local handle = tool:WaitForChild("Handle")
local ropeAtt = handle:WaitForChild("RopeAttachment")
local sndFire = handle:FindFirstChild("Fire")
local sndHit  = handle:FindFirstChild("Hit")
local sndConnect = handle:FindFirstChild("Connect")

-- capped values stop the pull from building endless speed
local MAX_RANGE       = 180
local TRAVEL_SPEED    = 280
local PULL_SPEED      = 70
local PULL_ACCEL      = 420
local MAX_SWING_SPEED = 95
local GROUND_LIFT     = 0.28
local FLAT_PULL_Y     = 0.18
local ARRIVE_DIST     = 5
local COOLDOWN        = 0.35

local ROPE_THICK = 0.12
local ROPE_COLOR = Color3.fromRGB(70, 45, 30)
local HOOK_COLOR = Color3.fromRGB(180, 180, 190)
local HOOK_SIZE  = Vector3.new(0.4, 0.4, 1.4)


-- each hook object belongs to one character
local Hook = {}
Hook.__index = Hook


function Hook.new(char)
	local self = setmetatable({}, Hook)
	self.char = char
	self.hum  = char:WaitForChild("Humanoid")
	self.root = char:WaitForChild("HumanoidRootPart")

	self.state    = "idle"
	self.anchor   = nil
	self.lastFire = 0
	self.equipped = false
	self.conns    = {}

	local att = Instance.new("Attachment")
	att.Name = "GrapplePullAttachment"
	att.Parent = self.root

	-- linearvelocity helps level pulls work while grounded
	local lv = Instance.new("LinearVelocity")
	lv.Name = "GrapplePullVelocity"
	lv.Attachment0 = att
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.VectorVelocity = Vector3.zero
	lv.MaxForce = 1000000
	lv.Enabled = false
	lv.Parent = self.root
	self.att, self.lv = att, lv

	self:bindStep()

	table.insert(self.conns, self.hum.Died:Connect(function()
		self:destroy()
	end))

	return self
end


function Hook:ensureVisuals()
	if not self.rope then
		local p = Instance.new("Part")
		p.Name = "GrappleRope"
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Material = Enum.Material.Fabric
		p.Color = ROPE_COLOR
		p.Size = Vector3.new(ROPE_THICK, ROPE_THICK, 0)
		p.Parent = workspace
		self.rope = p
	end
	if not self.projectile then
		local p = Instance.new("Part")
		p.Name = "GrappleProjectile"
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Material = Enum.Material.Metal
		p.Color = HOOK_COLOR
		p.Size = HOOK_SIZE
		p.Parent = workspace
		self.projectile = p
	end
end


function Hook:drawLine(part, a, b)
	local d = b - a
	local mag = d.Magnitude
	if mag < 0.001 then
		part.Size = Vector3.new(part.Size.X, part.Size.Y, 0)
		return
	end
	part.CFrame = CFrame.lookAt(a + d * 0.5, b)
	part.Size = Vector3.new(part.Size.X, part.Size.Y, mag)
end


-- camera ray keeps the hook lined up with the crosshair
function Hook:aim()
	local mouse = plr:GetMouse()
	local origin = cam.CFrame.Position
	local dir = (mouse.Hit.Position - origin).Unit * MAX_RANGE

	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = {self.char, self.rope, self.projectile}
	rp.IgnoreWater = true
	return workspace:Raycast(origin, dir, rp)
end


function Hook:fire()
	if not self.equipped then return end
	local t = os.clock()
	if t - self.lastFire < COOLDOWN then return end
	if self.state ~= "idle" then return end
	self.lastFire = t

	if sndFire then sndFire:Play() end

	local origin = ropeAtt.WorldPosition
	local hit = self:aim()
	if not hit then
		local mouse = plr:GetMouse()
		local target = origin + (mouse.Hit.Position - origin).Unit * MAX_RANGE
		self:flyHook(origin, target, false)
	else
		self:flyHook(origin, hit.Position, true)
	end
end


function Hook:flyHook(from, to, didHit)
	self.state = "firing"
	self:ensureVisuals()
	self.rope.Transparency = 0
	self.projectile.Transparency = 0
	self.projectile.CFrame = CFrame.lookAt(from, to)

	local dist = (to - from).Magnitude
	local time = math.max(dist / TRAVEL_SPEED, 0.05)

	-- tweening the hook head makes the shot readable
	local tw = TS:Create(self.projectile, TweenInfo.new(time, Enum.EasingStyle.Linear), {
		CFrame = CFrame.lookAt(to, to + (to - from).Unit)
	})

	local c
	c = tw.Completed:Connect(function()
		c:Disconnect()
		if self.state ~= "firing" then return end
		if didHit then self:attach(to) else self:retract() end
	end)
	tw:Play()
end


function Hook:attach(point)
	self.state = "attached"
	self.anchor = point
	self.hum.PlatformStand = false
	self.lv.Enabled = true
	if sndHit then sndHit:Play() end
	if sndConnect then sndConnect:Play() end
end


function Hook:retract()
	self.state = "retracting"
	self.anchor = nil
	if self.lv then
		self.lv.Enabled = false
		self.lv.VectorVelocity = Vector3.zero
	end
	if self.hum then
		self.hum.PlatformStand = false
	end

	if self.rope then self.rope.Transparency = 1 end
	if self.projectile then self.projectile.Transparency = 1 end
	self.state = "idle"
end


function Hook:bindStep()
	local c = RunService.Heartbeat:Connect(function(dt)
		if self.state == "attached" then
			self:pullStep(dt)
			self:drawRope()
		elseif self.state == "firing" or self.state == "retracting" then
			self:drawRope()
		end
	end)
	table.insert(self.conns, c)
end


function Hook:pullStep(dt)
	if not self.anchor then return end

	local toAnchor = self.anchor - self.root.Position
	local dist = toAnchor.Magnitude
	-- reaching the anchor drops the rope automatically
	if dist <= ARRIVE_DIST then
		self:retract()
		return
	end

	local dir = toAnchor / dist
	-- flat grounded pulls get a little lift so friction does not pin the player
	if self.hum.FloorMaterial ~= Enum.Material.Air and dir.Y < FLAT_PULL_Y then
		dir = (dir + Vector3.yAxis * GROUND_LIFT).Unit
	end

	local velocity = self.root.AssemblyLinearVelocity
	local vAlong = velocity:Dot(dir)
	-- keep the sideways swing
	local sideVelocity = velocity - dir * vAlong

	local maxStep = PULL_ACCEL * dt
	local newAlong = math.min(PULL_SPEED, vAlong + maxStep)
	local newVelocity = sideVelocity + dir * newAlong

	if newVelocity.Magnitude > MAX_SWING_SPEED then
		newVelocity = newVelocity.Unit * MAX_SWING_SPEED
	end

	self.lv.VectorVelocity = newVelocity
	self.root.AssemblyLinearVelocity = newVelocity
end


function Hook:drawRope()
	if not self.rope then return end
	local from = ropeAtt.WorldPosition
	local to
	if self.state == "attached" and self.anchor then
		to = self.anchor
	elseif self.projectile then
		to = self.projectile.Position
	else
		return
	end
	self:drawLine(self.rope, from, to)
end


function Hook:destroy()
	for _, c in ipairs(self.conns) do c:Disconnect() end
	self.conns = {}
	if self.hum and self.hum.Parent then
		self.hum.PlatformStand = false
	end
	if self.lv then self.lv:Destroy() end
	if self.att then self.att:Destroy() end
	if self.rope then self.rope:Destroy() end
	if self.projectile then self.projectile:Destroy() end
	self.state = "idle"
end


local active
local function onChar(c)
	if active then active:destroy() end
	active = Hook.new(c)
end

if plr.Character then onChar(plr.Character) end
plr.CharacterAdded:Connect(onChar)


local mouseDownConn

tool.Equipped:Connect(function()
	if active then active.equipped = true end
	mouseDownConn = UIS.InputBegan:Connect(function(input, processed)
		if processed then return end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			if active then active:fire() end
		end
	end)
end)

tool.Unequipped:Connect(function()
	if active then
		active.equipped = false
		if active.state == "attached" then
			active:retract()
		end
	end
	if mouseDownConn then
		mouseDownConn:Disconnect()
		mouseDownConn = nil
	end
end)

UIS.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		if active and active.state == "attached" then
			active:retract()
		end
	end
end)
