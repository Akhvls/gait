# Gait

This is the same procedural walking system I use for creatures in my horror games. It animates a pair of ground-contact limbs on a skinned rig and times steps from the distance the root travels, so the limbs follow the actual direction of travel even when the rig slides sideways. Each tip plants in world space, lifts in an arc, and lands using a ground raycast. When the rig stops, the limbs settle beside the body.

The module runs locally on each player's client. Your movement script, NPC AI, or player controller moves the root and decides when the rig is rushing.

## Setup

1. Copy [Gait.luau](ReplicatedStorage/Gait.luau) into a **ModuleScript** called `Gait` in `ReplicatedStorage`.
2. Put your rig model in `Workspace`. It needs an upright root `BasePart` and two skinned bone chains. Each chain must have three bones parented directly in this order: upper limb, lower limb, then the tip at the wrist or ankle. The first bone can sit under a part or another bone. In the bind pose, place the palms or soles on the ground and the shoulders or hips above them. Keep the gait's six bones free of other animation tracks that write their transforms.
3. Add a **Script** inside your rig model and set its **RunContext** to **Client**. Paste in [RunGait.luau](Examples/RunGait.luau) and change the child lookups to match your rig. The module takes the bone instances directly, so your model and bones can use any names. With instance streaming enabled, use **Atomic** model streaming so the whole rig comes in together.
4. Click **Play** and move the rig with your own controller on a flat floor. Check that each limb takes a step, holds its contact point while planted, and settles after the root stops. Set the model's `IsRushing` attribute to `true` to try longer steps with the limbs swinging closer together in time.

The example uses this hierarchy. It works with the same arm bones as the original ArmCat rig.

```text
ReplicatedStorage
└── Gait (ModuleScript)
Workspace
└── YourRig (Model)
    ├── HumanoidRootPart (BasePart)
    ├── Arms (skinned MeshPart)
    │   └── ArmsRootBone (Bone)
    │       ├── LeftUpperArmBone
    │       │   └── LeftForearmBone
    │       │       └── LeftHandBone
    │       └── RightUpperArmBone
    │           └── RightForearmBone
    │               └── RightHandBone
    └── RunGait (Script, RunContext = Client)
```

## Configuration

Call `Gait.start(model, rig, options?)` once per model on each client. In `rig`, pass `Root` and the `Left` and `Right` limb bindings. Each limb binding takes `Upper`, `Lower`, and `Tip` bones. For knees that bend toward the front, set `BendDirection = Vector3.new(0, 0, -1)` on each limb. The default bends backward and outward like the original arms. Bend directions are relative to the root.

You can also pass `BodyJoint` in the rig binding for a body lean, sway, and height adjustment during steps. Use a `Motor6D` with `Part0` set to the root and `Part1` set to the body. Both skinned limb mounts must move with that body part. Use the movement root and its collision geometry for gameplay and keep the animated body assembly non-colliding.

The third argument is an optional table.

| Option | Meaning |
| --- | --- |
| `GroundOffset` | Vertical distance in studs from the root center to the floor in the bind pose. Defaults to half the root's height plus `Humanoid.HipHeight` if the rig has a Humanoid. Set it explicitly if the hands land too high or too low. |
| `Stride` and `RushStride` | Studs the root travels in one normal or rushing step cycle. Defaults scale with the average limb length. For a 7.16-stud limb they are 8 and 13 studs. |
| `Lift` and `RushLift` | Normal and rushing swing heights in studs on flat ground. At the same limb length the defaults are 0.65 and 1.15 studs. |
| `Ignore` | Array of extra instances to exclude from the ground raycasts. The rig is always excluded and the rays look for collidable surfaces. |

Call `controller:SetRushing(true)` or `controller:SetRushing(false)` whenever your movement logic changes pace. Call `controller:Destroy()` to stop animating a model that's still in `Workspace` and restore the original transforms. Gait also stops automatically when the model or a required rig part leaves the hierarchy. Call `Gait.start` again if your own controller reuses the model after removal.

Gait expects a custom skinned rig with two bone chains, such as a creature with two walking arms or a skinned biped. If the tip cannot reach its planned contact, the solver stops at the limb's reach limit. Try a shorter stride or adjust the bind pose if a limb regularly slips.
