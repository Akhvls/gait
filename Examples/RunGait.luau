-- Create a Script inside your rig and set RunContext to Client.
-- Change these child names to match your model.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Gait = require(ReplicatedStorage:WaitForChild("Gait"))

local model = script.Parent
local root = model:WaitForChild("HumanoidRootPart")
local arms = model:WaitForChild("Arms")
local armsRoot = arms:WaitForChild("ArmsRootBone")

local leftUpper = armsRoot:WaitForChild("LeftUpperArmBone")
local leftLower = leftUpper:WaitForChild("LeftForearmBone")
local rightUpper = armsRoot:WaitForChild("RightUpperArmBone")
local rightLower = rightUpper:WaitForChild("RightForearmBone")

local controller = Gait.start(model, {
	Root = root,
	Left = {
		Upper = leftUpper,
		Lower = leftLower,
		Tip = leftLower:WaitForChild("LeftHandBone"),
	},
	Right = {
		Upper = rightUpper,
		Lower = rightLower,
		Tip = rightLower:WaitForChild("RightHandBone"),
	},
	-- BodyJoint = root:WaitForChild("RootJoint"), -- optional
})

-- Set this attribute from your movement or AI script when the rig starts rushing.
local function updateRush()
	controller:SetRushing(model:GetAttribute("IsRushing") == true)
end

model:GetAttributeChangedSignal("IsRushing"):Connect(updateRush)
updateRush()
