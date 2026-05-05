-- Discord: @sillyrelshy | Roblox: @sillyrelshy
-- This LocalScript owns the client side of the grapple tool: input, aiming,
-- hook visuals, and character movement are kept together so the tool responds
-- immediately for the player using it.
-- soz if i overexplain, last application got rejected because I didn't add enough comments ;c

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

-- These values separate range, visual speed, pull strength, and safety limits.
-- The pull is velocity capped instead of spring based, because shortening a
-- rope every frame can add energy and make the player accelerate forever.
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


-- Hook uses a metatable so each character gets its own state, visuals, physics
-- helper, and event connections without mixing data between respawns.
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

	-- LinearVelocity is created once per character and disabled until a shot lands.
	-- Reusing it avoids inserting new movers during rapid shots, and it gives
	-- grounded horizontal pulls enough force to beat floor friction.
	local att = Instance.new("Attachment")
	att.Name = "GrapplePullAttachment"
	att.Parent = self.root

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


-- The rope and projectile are client-side visuals only, so they are anchored,
-- non-colliding, and created lazily when the tool is first fired.
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


-- The rope is drawn as one thin Part. CFrame.lookAt handles direction, the
-- midpoint places it between the endpoints, and Size.Z becomes the rope length.
function Hook:drawLine(part, a, b)
	local d = b - a
	local mag = d.Magnitude
	if mag < 0.001 then
		-- If the endpoints overlap, lookAt has no direction to face, so the rope
		-- is collapsed for that frame instead of using an invalid orientation.
		part.Size = Vector3.new(part.Size.X, part.Size.Y, 0)
		return
	end
	part.CFrame = CFrame.lookAt(a + d * 0.5, b)
	part.Size = Vector3.new(part.Size.X, part.Size.Y, mag)
end


-- Aiming from the camera matches the crosshair instead of the character body.
-- The ray excludes the character and hook visuals so the tool cannot hit itself.
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


-- Fire is guarded by equipped, cooldown, and state checks so input spam cannot
-- start multiple hook tweens at the same time.
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
		-- Misses still animate to max range so failed shots have readable feedback.
		local mouse = plr:GetMouse()
		local target = origin + (mouse.Hit.Position - origin).Unit * MAX_RANGE
		self:flyHook(origin, target, false)
	else
		self:flyHook(origin, hit.Position, true)
	end
end


-- TweenService only moves the visible hook head. Player movement starts later,
-- after the tween reaches a confirmed hit point and calls attach.
function Hook:flyHook(from, to, didHit)
	self.state = "firing"
	self:ensureVisuals()
	self.rope.Transparency = 0
	self.projectile.Transparency = 0
	self.projectile.CFrame = CFrame.lookAt(from, to)

	local dist = (to - from).Magnitude
	local time = math.max(dist / TRAVEL_SPEED, 0.05)

	-- Time is based on distance, so close and far shots share one travel speed.
	local tw = TS:Create(self.projectile, TweenInfo.new(time, Enum.EasingStyle.Linear), {
		CFrame = CFrame.lookAt(to, to + (to - from).Unit)
	})

	-- The callback disconnects itself because each tween belongs to one shot.
	-- Without that, respawning during flight could leave an old listener alive.
	local c
	c = tw.Completed:Connect(function()
		c:Disconnect()
		if self.state ~= "firing" then return end
		if didHit then self:attach(to) else self:retract() end
	end)
	tw:Play()
end


-- Attach switches from projectile travel to player movement. PlatformStand stays
-- off so the humanoid does not ragdoll; LinearVelocity handles the pull instead.
function Hook:attach(point)
	self.state = "attached"
	self.anchor = point
	self.hum.PlatformStand = false
	self.lv.Enabled = true
	if sndHit then sndHit:Play() end
	if sndConnect then sndConnect:Play() end
end


-- Retract is shared by mouse release, misses, arrival, and unequip. It disables
-- movement first, hides visuals, then returns the tool to idle.
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


-- Heartbeat runs after the current physics step. Updating here gives the next
-- frame a clean target velocity and keeps the rope synced with the moving tool.
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


-- pullStep is the movement solver. It measures the player-to-anchor vector,
-- checks arrival, then adjusts only the velocity pointing along the rope.
function Hook:pullStep(dt)
	if not self.anchor then return end

	local toAnchor = self.anchor - self.root.Position
	local dist = toAnchor.Magnitude
	-- Arrival is checked before pulling so the player releases cleanly instead
	-- of overshooting and orbiting around the anchor.
	if dist <= ARRIVE_DIST then
		self:retract()
		return
	end

	local dir = toAnchor / dist
	-- A level rope can be blocked by ground friction. If the player is on the
	-- floor and the anchor is nearly horizontal, this small upward bias unsticks
	-- the humanoid without using PlatformStand.
	if self.hum.FloorMaterial ~= Enum.Material.Air and dir.Y < FLAT_PULL_Y then
		dir = (dir + Vector3.yAxis * GROUND_LIFT).Unit
	end

	local velocity = self.root.AssemblyLinearVelocity
	local vAlong = velocity:Dot(dir)
	-- Splitting velocity preserves sideways motion, so the player keeps a swing
	-- arc while only the inward rope-axis speed is pushed toward PULL_SPEED.
	local sideVelocity = velocity - dir * vAlong

	local maxStep = PULL_ACCEL * dt
	local newAlong = math.min(PULL_SPEED, vAlong + maxStep)
	local newVelocity = sideVelocity + dir * newAlong

	-- The total speed cap catches outside momentum from slopes, moving parts, or
	-- repeated hooks before it turns into runaway velocity.
	if newVelocity.Magnitude > MAX_SWING_SPEED then
		newVelocity = newVelocity.Unit * MAX_SWING_SPEED
	end

	-- LinearVelocity keeps pushing against floor friction, while setting the root
	-- velocity directly makes the response immediate on the current frame.
	self.lv.VectorVelocity = newVelocity
	self.root.AssemblyLinearVelocity = newVelocity
end


-- The rope starts from the live barrel attachment every frame, so tool and
-- character animations do not visually detach it from the handle.
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


-- destroy clears connections before removing visuals and constraints. This
-- matters on respawn because old Heartbeat callbacks should not control a dead body.
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


-- Each respawn gets a fresh Hook tied to the new HumanoidRootPart.
local active
local function onChar(c)
	if active then active:destroy() end
	active = Hook.new(c)
end

if plr.Character then onChar(plr.Character) end
plr.CharacterAdded:Connect(onChar)


-- Mouse down is only bound while equipped, so normal clicks cannot fire a
-- grapple that is sitting in the backpack.
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

-- Mouse release stays global because the player may release after the hook has
-- attached or during a quick unequip.
UIS.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		if active and active.state == "attached" then
			active:retract()
		end
	end
end)
