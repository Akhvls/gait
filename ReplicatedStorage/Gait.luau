-- Procedural two-limb gait for skinned Roblox rigs.
local RunService = game:GetService("RunService")

export type Limb = {
	Upper: Bone,
	Lower: Bone,
	Tip: Bone,
	BendDirection: Vector3?,
}

export type Rig = {
	Root: BasePart,
	Left: Limb,
	Right: Limb,
	BodyJoint: Motor6D?,
}

export type Options = {
	GroundOffset: number?,
	Stride: number?,
	RushStride: number?,
	Lift: number?,
	RushLift: number?,
	Ignore: {Instance}?,
}

export type Controller = {
	SetRushing: (Controller, boolean) -> (),
	Destroy: (Controller) -> (),
}

local Gait = {}
local activeModels = {}

local function flat(vector: Vector3): Vector3
	return Vector3.new(vector.X, 0, vector.Z)
end

local function smooth(alpha: number): number
	return alpha * alpha * (3 - 2 * alpha)
end

-- Rotate one unit vector onto another, including a 180-degree reversal.
local function turnOnto(from: Vector3, to: Vector3): CFrame
	local axis = from:Cross(to)
	local alignment = math.clamp(from:Dot(to), -1, 1)
	if axis.Magnitude < 1e-6 then
		if alignment >= 0 then
			return CFrame.identity
		end
		local perpendicular = if math.abs(from.Y) < 0.9 then Vector3.yAxis else Vector3.xAxis
		return CFrame.fromAxisAngle(from:Cross(perpendicular).Unit, math.pi)
	end
	return CFrame.fromAxisAngle(axis.Unit, math.acos(alignment))
end

local function readDistance(name: string, value: number?, default: number, allowZero: boolean): number
	if value == nil then
		return default
	end
	if type(value) ~= "number" or value < 0 or value >= math.huge or value ~= value or (value == 0 and not allowZero) then
		error("Gait option " .. name .. " must be " .. (if allowZero then "nonnegative" else "positive") .. " and finite", 3)
	end
	return value
end

local function readLimb(model: Model, root: BasePart, chain: Limb, side: number, groundOffset: number)
	local label = if side < 0 then "Left" else "Right"
	if type(chain) ~= "table" then
		error("Gait requires a " .. label .. " limb", 3)
	end

	local upper, lower, tip = chain.Upper, chain.Lower, chain.Tip
	for _, name in { "Upper", "Lower", "Tip" } do
		local bone = chain[name]
		if typeof(bone) ~= "Instance" or not bone:IsA("Bone") or not bone:IsDescendantOf(model) then
			error("Gait " .. label .. "." .. name .. " must be a Bone inside the model", 3)
		end
	end

	local mount = upper.Parent
	if not mount or not (mount:IsA("Bone") or mount:IsA("BasePart")) or lower.Parent ~= upper or tip.Parent ~= lower then
		error("Gait " .. label .. " must be a direct Upper > Lower > Tip bone chain mounted on a Bone or BasePart", 3)
	end

	local upperLength = lower.CFrame.Position.Magnitude
	local lowerLength = tip.CFrame.Position.Magnitude
	if math.min(upperLength, lowerLength) < 0.001 then
		error("Gait " .. label .. " requires two bone segments at least 0.001 studs long", 3)
	end

	local shoulder = root.CFrame:PointToObjectSpace(upper.WorldPosition)
	local restTip = root.CFrame:ToObjectSpace(tip.WorldCFrame)
	local bendDirection = chain.BendDirection or Vector3.new(side * 0.45, 0, 1)
	if typeof(bendDirection) ~= "Vector3" or not (bendDirection.Magnitude > 0 and bendDirection.Magnitude < math.huge) then
		error("Gait " .. label .. ".BendDirection must be a finite, nonzero Vector3", 3)
	end

	return {
		upper = upper,
		lower = lower,
		tip = tip,
		mount = mount,
		bendDirection = bendDirection.Unit,
		upperLength = upperLength,
		lowerLength = lowerLength,
		shoulder = shoulder,
		home = Vector3.new(restTip.X * 0.85, 0, shoulder.Z),
		clearance = restTip.Y + groundOffset,
		tipRotation = restTip.Rotation,
		originalUpper = upper.Transform,
		originalLower = lower.Transform,
		originalTip = tip.Transform,

		cycle = nil,
		phase = 0,
		plant = nil,
		plantRotation = nil,
		swingFrom = nil,
		liftAt = nil,
		settleFrom = nil,
		settleTime = 0,
		lastTip = nil,
		flatReach = 0,
	}
end

-- A two-segment IK solve. The child offsets give each segment's local axis.
local function poseLimb(limb, target: Vector3, tipRotation: CFrame, rootFrame: CFrame, bodyCorrection: CFrame)
	local mount = limb.mount
	local mountFrame = if mount:IsA("Bone") then mount.TransformedWorldCFrame else mount.CFrame
	local upperRest = bodyCorrection * mountFrame * limb.upper.CFrame
	local shoulder = upperRest.Position
	local reach = target - shoulder
	local along = if reach.Magnitude > 1e-5 then reach.Unit else -rootFrame.UpVector
	local upperLength, lowerLength = limb.upperLength, limb.lowerLength
	local margin = math.min(upperLength, lowerLength) * 0.001
	local distance = math.clamp(reach.Magnitude, math.abs(upperLength - lowerLength) + margin, upperLength + lowerLength - margin)
	local wrist = shoulder + along * distance

	local pole = rootFrame:VectorToWorldSpace(limb.bendDirection)
	pole -= along * pole:Dot(along)
	if pole.Magnitude < 1e-5 then
		local fallback = if math.abs(rootFrame.UpVector:Dot(along)) < 0.9 then rootFrame.UpVector else rootFrame.RightVector
		pole = fallback - along * fallback:Dot(along)
	end
	local elbowAlong = (upperLength ^ 2 - lowerLength ^ 2 + distance ^ 2) / (2 * distance)
	local elbowOut = math.sqrt(math.max(upperLength ^ 2 - elbowAlong ^ 2, 0))
	local elbow = shoulder + along * elbowAlong + pole.Unit * elbowOut

	local upperAxis = upperRest:VectorToWorldSpace(limb.lower.CFrame.Position.Unit)
	local upperPose = CFrame.new(shoulder) * turnOnto(upperAxis, (elbow - shoulder).Unit) * upperRest.Rotation
	limb.upper.Transform = upperRest:ToObjectSpace(upperPose)

	local lowerRest = upperPose * limb.lower.CFrame
	local lowerAxis = lowerRest:VectorToWorldSpace(limb.tip.CFrame.Position.Unit)
	local lowerPose = CFrame.new(lowerRest.Position) * turnOnto(lowerAxis, (wrist - lowerRest.Position).Unit) * lowerRest.Rotation
	limb.lower.Transform = lowerRest:ToObjectSpace(lowerPose)

	local tipRest = lowerPose * limb.tip.CFrame
	limb.tip.Transform = tipRest:ToObjectSpace(CFrame.new(tipRest.Position) * tipRotation)
end

function Gait.start(model: Model, rig: Rig, options: Options?): Controller
	if not RunService:IsClient() then
		error("Gait.start must run on the client", 2)
	end
	if typeof(model) ~= "Instance" or not model:IsA("Model") or not model:IsDescendantOf(workspace) then
		error("Gait.start requires a Model in Workspace", 2)
	end
	if activeModels[model] then
		error("Gait is already running for " .. model:GetFullName(), 2)
	end
	if type(rig) ~= "table" then
		error("Gait.start requires a rig binding", 2)
	end

	local root = rig.Root
	if typeof(root) ~= "Instance" or not root:IsA("BasePart") or not root:IsDescendantOf(model) then
		error("Gait rig.Root must be a BasePart inside the model", 2)
	end

	local bodyJoint = rig.BodyJoint
	local bodyPart
	local originalBody
	if bodyJoint then
		if typeof(bodyJoint) ~= "Instance" or not bodyJoint:IsA("Motor6D") or not bodyJoint:IsDescendantOf(model)
			or bodyJoint.Part0 ~= root or not bodyJoint.Part1 or not bodyJoint.Part1:IsDescendantOf(model) then
			error("Gait rig.BodyJoint must be a Motor6D connecting Root (Part0) to the body (Part1)", 2)
		end
		bodyPart = bodyJoint.Part1
		originalBody = bodyJoint.Transform
	end

	local settings = options or {}
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local defaultGroundOffset = math.max(root.Size.Y / 2 + (if humanoid then humanoid.HipHeight else 0), 0)
	local groundOffset = readDistance("GroundOffset", settings.GroundOffset, defaultGroundOffset, true)
	local left = readLimb(model, root, rig.Left, -1, groundOffset)
	local right = readLimb(model, root, rig.Right, 1, groundOffset)
	local leftChain = { [left.upper] = true, [left.lower] = true, [left.tip] = true }
	for _, bone in { right.upper, right.lower, right.tip } do
		if leftChain[bone] then
			error("Gait requires two separate limb chains", 2)
		end
	end
	if left.upper:IsDescendantOf(right.upper) or right.upper:IsDescendantOf(left.upper) then
		error("Gait limb chains cannot be nested inside each other", 2)
	end

	local limbs = { left, right }
	local scale = (left.upperLength + left.lowerLength + right.upperLength + right.lowerLength) / (2 * 7.16)
	local strideNormal = readDistance("Stride", settings.Stride, 8 * scale, false)
	local strideRush = readDistance("RushStride", settings.RushStride, 13 * scale, false)
	local liftNormal = readDistance("Lift", settings.Lift, 0.65 * scale, true)
	local liftRush = readDistance("RushLift", settings.RushLift, 1.15 * scale, true)
	local maxDrop = if bodyJoint then 2.2 * scale else 0

	for _, limb in limbs do
		local length = (limb.upperLength + limb.lowerLength) * 0.95
		local vertical = math.max(limb.shoulder.Y + groundOffset - limb.clearance - maxDrop, 0)
		limb.flatReach = math.sqrt(math.max(length ^ 2 - vertical ^ 2, 0))
	end

	local ignored = table.clone(settings.Ignore or {})
	table.insert(ignored, model)
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = ignored
	rayParams.RespectCanCollide = true

	local function contact(point: Vector3, limb): Vector3
		local origin = Vector3.new(point.X, root.Position.Y + 4 * scale, point.Z)
		local hit = workspace:Raycast(origin, -Vector3.yAxis * (groundOffset + 10 * scale), rayParams)
		local groundY = if hit and hit.Normal.Y >= 0.45 then hit.Position.Y else root.Position.Y - groundOffset
		return Vector3.new(point.X, groundY + limb.clearance, point.Z)
	end

	local phase = 0
	local rushing = false
	local rushWeight = 0
	local moveWeight = 0
	local height = 0
	local stillTime = 0
	local previousPosition = root.Position
	local heading = flat(root.CFrame.LookVector)
	local stopped = false
	local connection: RBXScriptConnection
	local controller = {} :: Controller

	function controller:SetRushing(enabled: boolean)
		rushing = enabled
	end

	function controller:Destroy()
		if stopped then
			return
		end
		stopped = true
		connection:Disconnect()
		activeModels[model] = nil
		for _, limb in limbs do
			limb.upper.Transform = limb.originalUpper
			limb.lower.Transform = limb.originalLower
			limb.tip.Transform = limb.originalTip
		end
		if bodyJoint then
			bodyJoint.Transform = originalBody
		end
	end

	local function updateLimb(limb, rootFrame: CFrame, offset: number, stride: number, plantedShare: number, moved: number, dt: number)
		-- Rushing reduces the phase offset. Keep the swing moving forward during the blend.
		limb.phase = math.max(limb.phase, phase + offset)
		local cycle = math.floor(limb.phase)
		local progress = limb.phase - cycle
		local home = rootFrame:PointToWorldSpace(limb.home)
		local rotation = rootFrame.Rotation * limb.tipRotation
		local standing = home + flat(rootFrame.LookVector) * (0.55 * scale)
		local lead = math.min(0.55 * scale + stride * plantedShare / 2, limb.flatReach * 0.85)
		local landing = home + heading * lead

		if not limb.plant then
			limb.plant = contact(standing, limb)
			limb.plantRotation = rotation
			limb.cycle = cycle
		end

		if stillTime > 0.08 and limb.swingFrom and not limb.settleFrom then
			limb.settleFrom = limb.lastTip
			limb.settleTime = 0
			limb.swingFrom = nil
		end

		if limb.settleFrom then
			limb.settleTime += dt
			local alpha = math.min(limb.settleTime / 0.3, 1)
			local target = contact(standing, limb)
			if alpha < 1 then
				local arc = math.sin(math.pi * alpha) ^ 2 * 0.5 * scale
				return limb.settleFrom:Lerp(target, smooth(alpha)) + Vector3.yAxis * arc, rotation, false
			end
			limb.settleFrom = nil
			limb.liftAt = nil
			limb.plant = target
			limb.plantRotation = rotation
			limb.cycle = cycle
		end

		if cycle > limb.cycle then
			limb.cycle = cycle
			limb.liftAt = nil
			if limb.swingFrom then
				limb.plant = contact(landing, limb)
				limb.plantRotation = rotation
				limb.swingFrom = nil
			end
		end

		if moved > 0 and cycle == limb.cycle and not limb.swingFrom then
			local shoulder = rootFrame:PointToWorldSpace(limb.shoulder)
			local nearLimit = flat(limb.plant - shoulder).Magnitude > limb.flatReach - (0.35 * scale + moved * 0.6)
			if progress >= plantedShare or nearLimit then
				limb.liftAt = progress
				limb.swingFrom = limb.plant
			end
		end

		if limb.swingFrom then
			local alpha = math.clamp((progress - limb.liftAt) / (1 - limb.liftAt), 0, 1)
			local target = contact(landing + heading * (stride * (1 - progress)), limb)
			local lift = liftNormal + (liftRush - liftNormal) * rushWeight
			local terrainLift = math.min((target.Y - limb.swingFrom.Y) * 0.75, 2.5 * scale)
			local arc = math.sin(math.pi * alpha) ^ 2 * math.max(lift, terrainLift)
			return limb.swingFrom:Lerp(target, smooth(alpha)) + Vector3.yAxis * arc, rotation, false
		end
		return limb.plant, limb.plantRotation, true
	end

	activeModels[model] = true
	connection = RunService.PreSimulation:Connect(function(dt)
		if not model:IsDescendantOf(workspace) or not root:IsDescendantOf(model)
			or not left.tip:IsDescendantOf(model) or not right.tip:IsDescendantOf(model)
			or (bodyJoint and (not bodyJoint:IsDescendantOf(model) or not bodyPart:IsDescendantOf(model)
				or bodyJoint.Part0 ~= root or bodyJoint.Part1 ~= bodyPart)) then
			controller:Destroy()
			return
		end
		if dt <= 0 then
			return
		end
		local rootFrame = root.CFrame
		local previous = previousPosition
		previousPosition = rootFrame.Position
		local displacement = rootFrame.Position - previous
		local step = flat(displacement)
		local moved = step.Magnitude
		if displacement.Magnitude > math.max(12 * scale, 100 * scale * dt) then
			-- A teleport should start a fresh plant beside the rig.
			moved = 0
			phase = 0
			stillTime = 0
			heading = flat(rootFrame.LookVector)
			for _, limb in limbs do
				limb.phase = 0
				limb.plant = nil
				limb.swingFrom = nil
				limb.settleFrom = nil
				limb.liftAt = nil
			end
		end

		dt = math.min(dt, 0.1)
		if moved > 0.001 * scale then
			heading = step.Unit
			stillTime = 0
		else
			moved = 0
			stillTime += dt
		end
		rushWeight += ((if rushing then 1 else 0) - rushWeight) * (1 - math.exp(-5 * dt))
		moveWeight += ((if moved > 0 then 1 else 0) - moveWeight) * (1 - math.exp(-10 * dt))

		local stride = strideNormal + (strideRush - strideNormal) * rushWeight
		phase += moved / stride
		local plantedShare = 0.64 - 0.19 * rushWeight
		local gap = 0.5 - 0.36 * rushWeight

		-- Return a hand left out of place to its standing spot, one at a time.
		if stillTime > 0.25 and not (left.settleFrom or right.settleFrom or left.swingFrom or right.swingFrom) then
			local farthest, distance = nil, 1.2 * scale
			for _, limb in limbs do
				local standing = rootFrame:PointToWorldSpace(limb.home) + flat(rootFrame.LookVector) * (0.55 * scale)
				local gapFromHome = if limb.plant then flat(limb.plant - standing).Magnitude else 0
				if gapFromHome > distance then
					farthest, distance = limb, gapFromHome
				end
			end
			if farthest then
				farthest.settleFrom = farthest.plant
				farthest.settleTime = 0
			end
		end

		local leftTarget, leftRotation, leftPlanted = updateLimb(left, rootFrame, 0, stride, plantedShare, moved, dt)
		local rightTarget, rightRotation, rightPlanted = updateLimb(right, rootFrame, gap, stride, plantedShare, moved, dt)
		left.lastTip = leftTarget
		right.lastTip = rightTarget

		local bodyCorrection = CFrame.identity
		if bodyJoint then
			-- Lower the shoulders when a planted limb is nearing full extension.
			local wantedHeight = 0.3 * scale
			for index, limb in limbs do
				local planted = if index == 1 then leftPlanted else rightPlanted
				if planted then
					local target = if index == 1 then leftTarget else rightTarget
					local shoulder = rootFrame:PointToWorldSpace(limb.shoulder)
					local reach = (limb.upperLength + limb.lowerLength) * 0.95
					local across = flat(target - shoulder).Magnitude
					local up = math.sqrt(math.max(reach ^ 2 - across ^ 2, 0))
					wantedHeight = math.min(wantedHeight, target.Y + up - shoulder.Y)
				end
			end
			if leftPlanted or rightPlanted then
				height += (math.clamp(wantedHeight, -maxDrop, 0.3 * scale) - height) * (1 - math.exp(-14 * dt))
			end

			local sway = math.sin(phase * math.pi * 2) * 0.14 * scale * (1 - 0.65 * rushWeight) * moveWeight
			local lean = math.rad((4 + 4 * rushWeight) * moveWeight)
			local pose = CFrame.new(sway, height, 0) * CFrame.Angles(-lean, 0, 0)
			bodyJoint.Transform = bodyJoint.C0:ToObjectSpace(pose * bodyJoint.C0) * originalBody
			-- Motor6D applies after PreSimulation. Solve the limbs against its next pose.
			local nextBody = rootFrame * pose * bodyJoint.C0 * originalBody * bodyJoint.C1:Inverse()
			bodyCorrection = nextBody * bodyPart.CFrame:Inverse()
		end

		poseLimb(left, leftTarget, leftRotation, rootFrame, bodyCorrection)
		poseLimb(right, rightTarget, rightRotation, rootFrame, bodyCorrection)
	end)
	return controller
end

return Gait
