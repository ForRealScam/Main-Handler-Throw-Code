-- server side for the poop throw in Poop Throw Obby
-- ragdoll uses RagdollService by kiy4ku and DataManager uses ProfileStore by loleris
-- the client simulates its own projectile for instant feedback, this script decides
-- whether that throw was legit and creates the version everyone else actually sees

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Debris = game:GetService("Debris")

local Settings = require(ReplicatedStorage.SettingsPoopThrow) -- shared with the client so range/speed can't drift apart and make legit throws fail validation
local ThrowFunctions = require(ReplicatedStorage.SettingsPoopThrow.ThrowFunctions) -- Slip lives in one module so the client and server copies slide identically instead of separating
local DataManager = require(ServerScriptService.Data.DataManager) -- skin is read from the saved profile, if the client sent it an exploiter could use skins they don't own
local Ragdoll = require(workspace.RagdollServiceTempExtension)

local throwRemote = ReplicatedStorage["Server&Client"].Throw
local splatRemote = ReplicatedStorage.Splat
local hapticRemote = ReplicatedStorage.PlayHaptic

local propsFolder = workspace.Props
local dizzyTemplate = ServerStorage.EffectAcc.Dizzy

local RANGE_TOLERANCE = 8 -- the client measures range from where it was when it fired, the server sees an older position, so exact range would reject legit throws on high ping
local HIT_TOLERANCE = 6 -- moving targets replicate late, so the claimed hit point can sit a few studs outside where the server thinks the part is
local COOLDOWN_LENIENCY = 0.8 -- packets can arrive bunched together, two throws sent a full cooldown apart can reach the server closer than that
local SERVER_POOP_SCALE = 0.9 -- the thrower sees both their client copy and this one for a moment, slightly smaller stops z-fighting between them
local RAGDOLL_DURATION = 2
local DIZZY_LINGER = 0.7 -- stars ending exactly as they stand up looks abrupt, a short overlap reads as recovering
local KNOCKBACK_LIFT = math.rad(20) -- a flat push gets eaten by floor friction while ragdolled, a small upward angle lets them actually travel

local ESCAPE_TOOLS = { -- dictionary instead of array so the check is a direct index rather than a loop
	FlyingCarpet = true, -- PlatformStand doesn't stop the carpet's own movement, they'd fly off mid-ragdoll
	GoldenCarpet = true,
	GrappleHook = true, -- the grapple's pull overrides the knockback force
}

local throwAnimation = Instance.new("Animation") -- an Animation is just an id holder, every animator can load from the same one
throwAnimation.AnimationId = "rbxassetid://120710784454545"

local playerState = {}

local raycastParams = RaycastParams.new() -- creating new params every throw is garbage for no reason, only the filter differs between throws
raycastParams.FilterType = Enum.RaycastFilterType.Exclude

local sharedFilter = { propsFolder } -- must match the client's filter, otherwise the client hits something the server ray treats as a wall
local fogFolder = workspace:FindFirstChild("Fog") -- not every map has fog, indexing it directly would error on those maps
if fogFolder then
	table.insert(sharedFilter, fogFolder) -- fog parts are invisible to players but solid to rays
end

local function getState(player)
	local state = playerState[player]
	if not state then
		-- created lazily on first throw so players who never throw don't get an entry
		state = { lastThrow = 0, animator = nil, track = nil }
		playerState[player] = state
	end
	return state
end

local function isProtected(character)
	-- storing an end time instead of a boolean means nothing has to run later to clear it,
	-- and server time is used because this attribute replicates and os.clock differs per machine
	return (character:GetAttribute("ProtectedUntil") or 0) > workspace:GetServerTimeNow()
end

local function getCharacterFromPart(part)
	-- the hit part can be an accessory handle or a tool, which aren't direct children of the
	-- character, so we walk up to the model instead of checking part.Parent
	local model = part:FindFirstAncestorOfClass("Model")
	local humanoid = model and model:FindFirstChildOfClass("Humanoid")
	return model, humanoid
end

local function playThrowAnimation(state, humanoid)
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return -- the animation is cosmetic, a missing animator shouldn't cancel a valid throw
	end

	-- respawning gives a new animator and the old track dies with it. loading a fresh track
	-- every throw would stack tracks on the animator until roblox starts warning about the limit
	if state.animator ~= animator then
		state.animator = animator
		state.track = animator:LoadAnimation(throwAnimation)
	end

	state.track:Play() -- played from the server so other players see the throw, not just the thrower
end

local function validateThrow(character, root, hitPosition, target)
	-- remote arguments can be any type, doing math on a non Vector3 would error and kill this thread
	if typeof(hitPosition) ~= "Vector3" then
		return nil
	end

	if typeof(target) ~= "Instance" or not target:IsA("BasePart") or not target:IsDescendantOf(workspace) then
		return nil -- a part in ReplicatedStorage or a destroyed part would still pass IsA
	end

	if target:HasTag("Blocked") or target:IsDescendantOf(character) then
		return nil -- the real client's raycast can't produce these, so only a modified client sends them
	end

	-- measured from the server's copy of the root, the client could claim any origin it wants
	local distance = (hitPosition - root.Position).Magnitude
	if not (distance <= Settings.throwRange + RANGE_TOLERANCE) then
		return nil -- NaN compares false to everything, so "distance > range" would let NaN through but this doesn't
	end

	-- converting into the part's local space turns a rotated box check into a simple per-axis check
	local localOffset = target.CFrame:PointToObjectSpace(hitPosition)
	if not target:IsA("Terrain") then -- Terrain is a BasePart but its Size doesn't describe the terrain, so the box test is meaningless
		local overshoot = localOffset:Abs() - (target.Size / 2 + Vector3.one * HIT_TOLERANCE)
		if math.max(overshoot.X, overshoot.Y, overshoot.Z) > 0 then
			return nil -- the claimed point isn't on the part, so they're pairing a real part with a fake position
		end
	end

	-- assigning copies the table, so AddToFilter below changes the params but never grows sharedFilter
	raycastParams.FilterDescendantsInstances = sharedFilter
	raycastParams:AddToFilter(character) -- the ray starts at the root, without this it hits the thrower's own body first

	local obstacle = workspace:Raycast(root.Position, hitPosition - root.Position, raycastParams)
	if obstacle and obstacle.Instance:HasTag("Blocked") then
		return nil -- stops throwing through walls even when distance and hit point both look fine
	end

	-- returned in local space so we can rebuild the world position after the flight delay,
	-- a moving target would otherwise get hit where it used to be
	return localOffset
end

local function applyKnockback(targetRoot, sourcePosition)
	local attachment = targetRoot:FindFirstChild("RootAttachment")
	if not attachment then
		return -- VectorForce applies through an attachment, without one there's nothing to push
	end

	-- using the target's own height means a throw from above doesn't drive them into the floor
	local flatSource = Vector3.new(sourcePosition.X, targetRoot.Position.Y, sourcePosition.Z)
	local facing = CFrame.lookAt(flatSource, targetRoot.Position)
	local launchDirection = (facing * CFrame.Angles(KNOCKBACK_LIFT, 0, 0)).LookVector

	-- players own their character's physics, so setting velocity from the server gets overwritten.
	-- a VectorForce replicates and gets simulated by the owner, so the push actually happens
	local knockback = Instance.new("VectorForce")
	knockback.RelativeTo = Enum.ActuatorRelativeTo.World -- the default is relative to the attachment, which rotates with the root and sends them the wrong way
	knockback.ApplyAtCenterOfMass = true -- applying it at the attachment would add torque and spin them
	knockback.Force = launchDirection * Settings.knockbackForce
	knockback.Attachment0 = attachment
	knockback.Parent = targetRoot -- set up before parenting so it replicates once with final values instead of once per property

	-- a constant force for a short time behaves like an impulse, Debris removes it without yielding this thread
	Debris:AddItem(knockback, Settings.knockbackDuration)
end

local function tagAttacker(targetCharacter, attacker)
	-- Debris timers can't be reset, so getting hit again means replacing the tag
	-- otherwise the first attacker's expiry would delete the second attacker's credit early
	local previousTag = targetCharacter:FindFirstChild("WhoHit")
	if previousTag then
		previousTag:Destroy()
	end

	local tag = Instance.new("StringValue")
	tag.Name = "WhoHit" -- kill scripts look up this name to award the attacker
	tag.Value = attacker.Name
	tag.Parent = targetCharacter
	Debris:AddItem(tag, Settings.KillTimer) -- without expiry, dying to an obstacle minutes later would still reward whoever hit them last
end

local function spawnServerPoop(player, impactPosition)
	-- FindFirstChild errors on nil, so an unloaded profile falls back to "" which just finds nothing
	local template = ReplicatedStorage.PoopTypess:FindFirstChild(DataManager.GetEquiped(player) or "")
	if not template or not template:IsA("BasePart") then
		return nil -- the folder also holds an Attachment, which would break the BasePart properties below
	end

	local poop = template:Clone()
	poop.Size *= SERVER_POOP_SCALE -- MeshPart Size scales the mesh too, a regular Part with a SpecialMesh wouldn't
	poop.Anchored = true -- it's placed at the impact point, physics would make it roll off before the client hides it
	poop:PivotTo(CFrame.new(impactPosition)) -- some templates have custom pivots, setting Position would ignore them and offset the mesh

	local splat = Instance.new("Sound")
	splat.SoundId = Settings.musicList[math.random(#Settings.musicList)] -- the same splat every throw gets noticeable fast
	splat.Volume = Settings.poopHitSound
	splat:AddTag("EffectSound") -- the client's effects volume slider finds sounds by this tag, untagged sounds would ignore it
	splat.Parent = poop -- a sound in a part is 3D, so players far away hear it quieter
	poop.Parent = propsFolder -- inside Props so client and server raycasts both ignore it, otherwise poop would block later throws

	splat:Play()
	return poop
end

local function ragdollTarget(targetCharacter, targetHumanoid)
	Ragdoll:Ragdoll(targetCharacter)
	targetHumanoid.PlatformStand = true -- without this the humanoid keeps trying to stand and fights the knockback

	-- an equipped tool is parented to the character, a backpack tool can't be used so it's ignored
	local heldTool = targetCharacter:FindFirstChildOfClass("Tool")
	if heldTool and ESCAPE_TOOLS[heldTool.Name] then
		targetHumanoid:UnequipTools()
	end

	local dizzy = dizzyTemplate:Clone()
	targetHumanoid:AddAccessory(dizzy) -- welds to the matching head attachment, so it works on R6 and R15 without separate offsets
	Debris:AddItem(dizzy, RAGDOLL_DURATION + DIZZY_LINGER)

	targetCharacter:SetAttribute("ProtectedUntil", workspace:GetServerTimeNow() + Settings.protectionTime)

	-- task.delay instead of task.wait because the knockback, tag and sounds after this call
	-- need to happen now, waiting here would delay them all by the ragdoll duration
	task.delay(RAGDOLL_DURATION, function()
		if not targetCharacter.Parent then
			return -- they respawned or left during the ragdoll, this character is gone
		end

		Ragdoll:Unragdoll(targetCharacter)
		targetHumanoid.PlatformStand = false

		local root = targetCharacter:FindFirstChild("HumanoidRootPart")
		if root then
			root.AssemblyLinearVelocity = Vector3.zero -- leftover knockback momentum would slide them after they stand up
		end
	end)
end

local function handleCharacterHit(attacker, attackerRoot, poop, target, targetCharacter, targetHumanoid)
	local targetRoot = targetCharacter:FindFirstChild("HumanoidRootPart")
	if not targetRoot or targetHumanoid.Health <= 0 or targetHumanoid:HasTag("Ragdoll") or isProtected(targetCharacter) then
		Debris:AddItem(poop, 0.1) -- the throw still lands visually, but a protected player shouldn't keep it stuck on them
		return
	end

	poop.CanCollide = false -- once welded it moves with them and would shove nearby players
	poop.Massless = true -- its mass would join their assembly and weaken the same knockback force

	-- WeldConstraint keeps the current offset, a Weld with default C0/C1 would snap the poop to the part's center
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = target
	weld.Part1 = poop
	weld.Parent = poop -- parented to the poop so it's destroyed with it and doesn't linger in the character
	poop.Anchored = false -- unanchored after the weld exists, otherwise it would drop for a frame

	ragdollTarget(targetCharacter, targetHumanoid)
	tagAttacker(targetCharacter, attacker)
	applyKnockback(targetRoot, attackerRoot.Position)

	local hitSound = Instance.new("Sound")
	hitSound.SoundId = Settings.playerHitSound
	hitSound.Volume = Settings.playerHitSoundVol
	hitSound:AddTag("EffectSound")
	hitSound.Parent = poop
	hitSound:Play()

	local targetPlayer = Players:GetPlayerFromCharacter(targetCharacter) -- NPCs have no player, so there's no client to send effects to
	if targetPlayer then
		splatRemote:FireClient(targetPlayer) -- screen splat is a first person effect, firing to everyone would cover the wrong screens
		hapticRemote:FireClient(targetPlayer, "Fall")
	end

	Debris:AddItem(poop, RAGDOLL_DURATION) -- matched to the ragdoll so the poop disappears as they get back up
end

local function handleWorldHit(attacker, poop, target)
	poop.Transparency = Settings.poopTransparency

	if target:HasTag("Slip") then
		ThrowFunctions.Slip(poop)
	end

	-- the thrower already has their client copy at this spot, so they hide this one to avoid seeing two
	throwRemote:FireClient(attacker, poop)
	Debris:AddItem(poop, Settings.timeUntilRemove) -- same lifetime as the client copy so they disappear together
end

local function onThrow(player, hitPosition, target)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or humanoid.Health <= 0 or humanoid:HasTag("Ragdoll") then
		return -- the client blocks this too, but exploiters can fire the remote directly
	end

	local state = getState(player)
	local now = os.clock() -- os.time() only has one second resolution, which would break sub-second cooldowns
	if now - state.lastThrow < Settings.debWait * COOLDOWN_LENIENCY then
		return
	end
	-- set before validation so invalid spam still costs a cooldown, otherwise an exploiter could
	-- flood fake throws and force a raycast on every single one
	state.lastThrow = now

	local localOffset = validateThrow(character, root, hitPosition, target)
	if not localOffset then
		return
	end

	playThrowAnimation(state, humanoid)

	-- travel time is recalculated here instead of trusted from the client, a client sending 0
	-- would get instant hits. ping is subtracted because the client copy was already flying
	-- while the remote travelled here, waiting the full time would make the server copy land late
	local travelTime = (hitPosition - root.Position).Magnitude / Settings.speed
	task.wait(math.max(travelTime - player:GetNetworkPing(), 0))

	if not player.Parent or not character.Parent or not target.Parent then
		return -- this thread yielded, so anything could have been removed during the flight
	end

	local impactPosition = target.CFrame:PointToWorldSpace(localOffset) -- rebuilt from the target's current CFrame so moving targets still get hit
	local poop = spawnServerPoop(player, impactPosition)
	if not poop then
		return
	end

	local targetCharacter, targetHumanoid = getCharacterFromPart(target)
	if not targetHumanoid then
		handleWorldHit(player, poop, target)
	elseif character:FindFirstChild("Ice") or isProtected(character) then
		-- checked after the flight since the thrower could have been frozen or hit while it was in the air
		Debris:AddItem(poop, 0.1)
	else
		handleCharacterHit(player, root, poop, target, targetCharacter, targetHumanoid)
	end
end

Players.PlayerRemoving:Connect(function(player)
	playerState[player] = nil -- the table holds the player as a key, which would keep them in memory forever
end)

throwRemote.OnServerEvent:Connect(onThrow) -- roblox fills in the first argument itself, so the player can't be spoofed
