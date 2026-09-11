-- server side for the poop throw in Poop Throw Obby
-- ragdoll uses RagdollService by kiy4ku and DataManager uses ProfileStore by loleris

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Debris = game:GetService("Debris")

local Settings = require(ReplicatedStorage.SettingsPoopThrow) -- client uses the same one so values match
local ThrowFunctions = require(ReplicatedStorage.SettingsPoopThrow.ThrowFunctions) -- for Slip so both copies slide the same
local DataManager = require(ServerScriptService.Data.DataManager) -- skin comes from saved data not the client
local Ragdoll = require(workspace.RagdollServiceTempExtension) -- tags the humanoid so RagdollService ragdolls it

local throwRemote = ReplicatedStorage["Server&Client"].Throw -- client fires this after its own poop animation
local splatRemote = ReplicatedStorage.Splat -- EffectScript listens here
local hapticRemote = ReplicatedStorage.PlayHaptic -- SoundHapticPlay listens here
local propsFolder = workspace.Props
local dizzyTemplate = ServerStorage.EffectAcc.Dizzy -- cached so no lookup every hit

assert(#Settings.musicList > 0, "SettingsPoopThrow.musicList needs at least one sound id") -- math.random breaks on empty list

local RANGE_TOLERANCE = 8 -- player moves a bit during lag
local HIT_TOLERANCE = 6 -- how far off a hit can be before its fake
local COOLDOWN_LENIENCY = 0.8 -- lag can push two throws closer together
local SERVER_POOP_SCALE = 0.9 -- smaller so it doesnt clip with the client copy
local RAGDOLL_DURATION = 2
local DIZZY_LINGER = 0.7 -- stars stay a bit after getting up
local KNOCKBACK_LIFT = math.rad(20) -- push a little upward so they dont drag on the floor
local ESCAPE_TOOLS = { -- set so its one lookup
	FlyingCarpet = true, -- could fly away while ragdolled
	GoldenCarpet = true,
	GrappleHook = true, -- could pull out of the knockback
}

local throwAnimation = Instance.new("Animation") -- one shared object since it only holds the id
throwAnimation.AnimationId = "rbxassetid://120710784454545"

local playerState = {} -- cooldown and anim track per player

local raycastParams = RaycastParams.new() -- reused only the filter changes
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
local sharedFilter = { propsFolder } -- same as client filter
local fogFolder = workspace:FindFirstChild("Fog") -- not every map has it
if fogFolder then
	table.insert(sharedFilter, fogFolder) -- fog would block throws
end

local function getState(player)
	local state = playerState[player] -- only made when needed
	if not state then
		state = { lastThrow = 0, animator = nil, track = nil }
		playerState[player] = state
	end
	return state
end

local function isFiniteVector(value)
	-- typeof because type only says userdata
	-- NaN never equals itself so this catches it
	-- Magnitude check catches inf
	return typeof(value) == "Vector3" and value == value and value.Magnitude < math.huge
end

local function isProtected(character)
	-- saves the end time so no countdown loop is needed
	return (character:GetAttribute("ProtectedUntil") or 0) > workspace:GetServerTimeNow()
end

local function getCharacterFromPart(part)
	local model = part:FindFirstAncestorOfClass("Model") -- works for body parts accessories and tools
	local humanoid = model and model:FindFirstChildOfClass("Humanoid") -- no humanoid means its map stuff
	return model, humanoid
end

local function playThrowAnimation(state, humanoid)
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return -- throw works without it
	end
	if state.animator ~= animator then -- new animator means they respawned
		state.animator = animator
		state.track = animator:LoadAnimation(throwAnimation) -- load once per character so tracks dont pile up
	end
	state.track:Play() -- server plays it so everyone sees it
end

local function validateThrow(character, root, hitPosition, target)
	if not isFiniteVector(hitPosition) then
		return nil -- client can send anything
	end
	if typeof(target) ~= "Instance" or not target:IsA("BasePart") or not target:IsDescendantOf(workspace) then
		return nil -- must be a part in the world
	end
	if target:HasTag("Blocked") or target:IsDescendantOf(character) then
		return nil -- real client never sends these
	end

	local distance = (hitPosition - root.Position).Magnitude -- uses server position
	if not (distance <= Settings.throwRange + RANGE_TOLERANCE) then
		return nil -- written this way so NaN fails too
	end

	local localOffset = target.CFrame:PointToObjectSpace(hitPosition) -- hit point relative to the part so rotation doesnt matter
	if not target:IsA("Terrain") then -- terrain size is useless for this
		local overshoot = localOffset:Abs() - (target.Size / 2 + Vector3.one * HIT_TOLERANCE) -- above 0 means outside the box
		if math.max(overshoot.X, overshoot.Y, overshoot.Z) > 0 then
			return nil -- too far from the part
		end
	end

	raycastParams.FilterDescendantsInstances = sharedFilter -- resets the filter from last throw
	raycastParams:AddToFilter(character) -- ray starts inside the thrower
	local obstacle = workspace:Raycast(root.Position, hitPosition - root.Position, raycastParams) -- ray ends at the hit point
	if obstacle and obstacle.Instance:HasTag("Blocked") then
		return nil -- wall in the way
	end

	return localOffset -- lets the poop follow a moving target
end

local function applyKnockback(targetRoot, sourcePosition)
	local attachment = targetRoot:FindFirstChild("RootAttachment") -- VectorForce needs one
	if not attachment then
		return
	end

	local flatSource = Vector3.new(sourcePosition.X, targetRoot.Position.Y, sourcePosition.Z) -- ignore height so push is sideways
	if (targetRoot.Position - flatSource).Magnitude < 0.01 then -- same spot would give NaN
		flatSource = targetRoot.Position + targetRoot.CFrame.LookVector -- push them backwards instead
	end

	local facing = CFrame.lookAt(flatSource, targetRoot.Position) -- points from thrower to victim
	local launchDirection = (facing * CFrame.Angles(KNOCKBACK_LIFT, 0, 0)).LookVector -- tilt it up

	local knockback = Instance.new("VectorForce") -- still works when the client owns the physics
	knockback.Name = "Knockback"
	knockback.RelativeTo = Enum.ActuatorRelativeTo.World -- default pushed the wrong way based on facing
	knockback.ApplyAtCenterOfMass = true -- push without spinning
	knockback.Force = launchDirection * Settings.knockbackForce
	knockback.Attachment0 = attachment
	knockback.Parent = targetRoot -- parent last
	Debris:AddItem(knockback, Settings.knockbackDuration) -- short burst like an impulse
end

local function tagAttacker(targetCharacter, attacker)
	local previousTag = targetCharacter:FindFirstChild("WhoHit") -- kill scripts read this for rewards
	if previousTag then
		previousTag:Destroy() -- new tag restarts the timer
	end

	local tag = Instance.new("StringValue")
	tag.Name = "WhoHit"
	tag.Value = attacker.Name -- kill scripts use the name
	tag.Parent = targetCharacter
	Debris:AddItem(tag, Settings.KillTimer) -- kill credit runs out after this
end

local function spawnServerPoop(player, impactPosition)
	local template = ReplicatedStorage.PoopTypess:FindFirstChild(DataManager.GetEquiped(player) or "") -- empty if profile isnt loaded
	if not template or not template:IsA("BasePart") then
		return nil -- folder has an Attachment too
	end

	local poop = template:Clone()
	poop.Size *= SERVER_POOP_SCALE -- templates are MeshParts so this scales the mesh
	poop.Anchored = true
	poop:PivotTo(CFrame.new(impactPosition)) -- respects custom pivots

	local splat = Instance.new("Sound")
	splat.SoundId = Settings.musicList[math.random(#Settings.musicList)] -- random so it doesnt get repetitive
	splat.Volume = Settings.poopHitSound -- this is the volume setting
	splat:AddTag("EffectSound") -- volume slider uses this tag
	splat.Parent = poop -- plays where it landed

	poop.Parent = propsFolder -- parent after setup
	splat:Play()
	return poop
end

local function ragdollTarget(targetCharacter, targetHumanoid)
	Ragdoll:Ragdoll(targetCharacter) -- module uses methods so colon call
	targetHumanoid.PlatformStand = true -- stops them getting up

	local heldTool = targetCharacter:FindFirstChildOfClass("Tool") -- equipped tool is in the character
	if heldTool and ESCAPE_TOOLS[heldTool.Name] then
		targetHumanoid:UnequipTools()
	end

	local dizzy = dizzyTemplate:Clone()
	targetHumanoid:AddAccessory(dizzy) -- works on R6 and R15
	Debris:AddItem(dizzy, RAGDOLL_DURATION + DIZZY_LINGER)

	targetCharacter:SetAttribute("ProtectedUntil", workspace:GetServerTimeNow() + Settings.protectionTime) -- server time so its the same clock everywhere

	task.delay(RAGDOLL_DURATION, function() -- doesnt block the handler
		if not targetCharacter.Parent then
			return -- died or left
		end
		Ragdoll:Unragdoll(targetCharacter) -- only unragdolls if nothing else is ragdolling them
		targetHumanoid.PlatformStand = false
		local root = targetCharacter:FindFirstChild("HumanoidRootPart")
		if root then
			root.AssemblyLinearVelocity = Vector3.zero -- stop leftover sliding
		end
	end)
end

local function handleCharacterHit(attacker, attackerRoot, poop, target, targetCharacter, targetHumanoid)
	local targetRoot = targetCharacter:FindFirstChild("HumanoidRootPart")
	if not targetRoot or targetHumanoid.Health <= 0 or targetHumanoid:HasTag("Ragdoll") or isProtected(targetCharacter) then
		Debris:AddItem(poop, 0.1) -- hit doesnt count so remove it quickly
		return
	end

	poop.CanCollide = false -- would push other players
	poop.Massless = true -- doesnt change knockback strength
	local weld = Instance.new("WeldConstraint") -- keeps hit spot unlike Weld
	weld.Part0 = target
	weld.Part1 = poop
	weld.Parent = poop -- removed with the poop
	poop.Anchored = false -- unanchor last so it moves with them

	ragdollTarget(targetCharacter, targetHumanoid)
	tagAttacker(targetCharacter, attacker)
	applyKnockback(targetRoot, attackerRoot.Position)

	local hitSound = Instance.new("Sound")
	hitSound.SoundId = Settings.playerHitSound
	hitSound.Volume = Settings.playerHitSoundVol
	hitSound:AddTag("EffectSound")
	hitSound.Parent = poop
	hitSound:Play()

	local targetPlayer = Players:GetPlayerFromCharacter(targetCharacter) -- nil for NPCs
	if targetPlayer then
		splatRemote:FireClient(targetPlayer) -- only the victim sees the splat
		hapticRemote:FireClient(targetPlayer, "Fall") -- effect name in HapticEffects
	end

	Debris:AddItem(poop, RAGDOLL_DURATION) -- falls off when ragdoll ends
end

local function handleWorldHit(attacker, poop, target)
	poop.Transparency = Settings.poopTransparency -- others see a faded copy
	if target:HasTag("Slip") then
		ThrowFunctions.Slip(poop)
	end
	throwRemote:FireClient(attacker, poop) -- thrower deletes it since they have their own
	Debris:AddItem(poop, Settings.timeUntilRemove) -- same lifetime as client
end

local function onThrow(player, hitPosition, target)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid") -- no error if character is nil
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or humanoid.Health <= 0 or humanoid:HasTag("Ragdoll") then
		return -- cant throw while dead or ragdolled
	end

	local state = getState(player)
	local now = os.clock() -- precise timer
	if now - state.lastThrow < Settings.debWait * COOLDOWN_LENIENCY then
		return -- exploiters can remove the client cooldown
	end
	state.lastThrow = now -- set before checks so fake spam hits cooldown too

	local localOffset = validateThrow(character, root, hitPosition, target)
	if not localOffset then
		return
	end

	playThrowAnimation(state, humanoid)

	local travelTime = (hitPosition - root.Position).Magnitude / Settings.speed -- same math as client so client time is ignored
	task.wait(math.max(travelTime - player:GetNetworkPing(), 0)) -- minus ping to stay in sync

	if not player.Parent or not character.Parent or not target.Parent then
		return -- something got removed during the flight
	end

	local impactPosition = target.CFrame:PointToWorldSpace(localOffset) -- lands where the target is now
	local poop = spawnServerPoop(player, impactPosition)
	if not poop then
		return
	end

	local targetCharacter, targetHumanoid = getCharacterFromPart(target)
	if not targetHumanoid then
		handleWorldHit(player, poop, target)
	elseif character:FindFirstChild("Ice") or isProtected(character) then
		Debris:AddItem(poop, 0.1) -- frozen or recently hit players cant knock others
	else
		handleCharacterHit(player, root, poop, target, targetCharacter, targetHumanoid)
	end
end

Players.PlayerRemoving:Connect(function(player)
	playerState[player] = nil -- dont keep players who left
end)

throwRemote.OnServerEvent:Connect(onThrow) -- roblox gives the real player so it cant be faked
