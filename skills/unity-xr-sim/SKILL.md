---
name: unity-xr-sim
description: Use when testing VR/XR behaviour in a Unity project that has the com.unity.xr.openxr package or an OpenXR loader configured in XRGeneralSettings — teaches driving the OpenXR Mock Runtime and Conformance Automation feature pair to force mock loader sessions, move head/controller poses, and simulate VR controller/grab input without a physical headset, for projects using an interaction profile such as Valve Index.
---

# unity-xr-sim

## What this skill is for

Reach for this skill when a ticket needs to exercise **VR/XR behaviour in a Unity
project without a physical headset attached** — forcing an OpenXR mock session, moving
virtual head/controller poses, driving a virtual grip/grab, and confirming the result
from game state, all through the OpenXR **Mock Runtime** and **Conformance Automation**
feature pair.

**Precondition — check this before doing anything else.** Confirm the target project has
an OpenXR loader actually **configured for the active build target** before proceeding —
not merely the package installed. Reading `Packages/manifest.json` for a
`com.unity.xr.openxr` entry **only confirms the package is installed, not that a loader
is configured for any platform** —
`OpenXRSettings.ActiveBuildTargetInstance` (used throughout `XRSim.cs`'s `Setup()`) is
only non-null once a loader has actually been configured for the active build target in
Project Settings → XR Plug-in Management → OpenXR; package-without-loader is a real,
reachable state, not a hypothetical one. Confirm this properly instead: open Project
Settings → XR Plug-in Management, select the active build target's tab, and check that an
OpenXR loader is ticked there (not just present in `Packages/manifest.json`), or inspect
`XRGeneralSettingsPerBuildTarget`/`XRGeneralSettings.Instance.Manager.activeLoader` /
`AssignedSettings` for that target. **If no loader is configured for the active build
target, do not load or act on this skill's recipe** — the project has no per-platform
OpenXR settings asset for the Mock Runtime / Conformance Automation features to attach to,
`Setup()` fails fast with an `InvalidOperationException` naming exactly this
(`OpenXRSettings.ActiveBuildTargetInstance` null-check), and forcing the loader without
one configured will either fail outright or silently create an OpenXR settings asset the
project never asked for.

**A second, narrower precondition gap: package/loader presence is not the same as
having these specific OpenXR features added to the project's feature list.**
`com.unity.xr.openxr` being installed and an OpenXR loader
being configured (the precondition above) is necessary but not sufficient —
`MockRuntime`, `ConformanceAutomationFeature`, and whichever interaction-profile
feature the project targets (e.g. `ValveIndexControllerProfile`) are each **optional**
OpenXR features that must *additionally* already be present in the project's OpenXR
Feature Groups (Project Settings → XR Plug-in Management → OpenXR → [platform] →
OpenXR Feature Groups) before step 1 below can run. `OpenXRSettings.GetFeature<T>()`
returns `null` — not a usable-but-disabled instance — for a feature type that hasn't
been added there. `Setup()` (`XRSim.cs`) checks for this explicitly and fails fast with
an `InvalidOperationException` naming exactly which feature is missing and where to add
it, instead of an unhelpful `NullReferenceException`. Add all three (Mock Runtime,
Conformance Automation, and the target interaction profile) to the feature list before
running this recipe if they aren't already there.

**Operator rules — the discipline that keeps this safe now that `XRSim.cs` owns no
loader lifecycle of its own.**

1. Call `Setup()` in **Edit mode**, before entering Play mode.
2. Enter Play mode, then call `InitializeLoaderSync()`/`StartSubsystems()` (step 4) and
   do all pose/grip driving inside Play mode.
3. Exit Play mode, then call `Restore()`; if the backup file is gone, fall back to
   `git checkout -- "Assets/XR/Settings/OpenXR Package Settings.asset"` (adjust this path
   if your project's OpenXR settings asset lives elsewhere).
4. **Do not change the active build target between `Setup()` and `Restore()`.**
   `Restore()` re-fetches `OpenXRSettings.ActiveBuildTargetInstance` at restore time
   rather than reusing whatever target `Setup()` captured — it operates on whichever
   build target is active when it runs. Switching the active build target in between
   will restore the wrong target's settings asset from the backup, and can leave the
   target `Setup()` actually modified permanently dirty. This is an operator discipline,
   not something `XRSim.cs` defends against in code — keep the active build target fixed
   for the whole `Setup()`/`Restore()` span.

**When this does NOT apply.** This is not the skill for driving the live Unity editor in
general — scenes, GameObjects, components, Play mode, Test Runner — see the
`unity-wrapper` skill for that; this skill only covers the headset-free OpenXR
mock-session loop layered on top of it. It is also not for git-merging Unity's
YAML-serialized assets — see `unity-yaml-merge` for that, a separate, MCP-free concern.

Drive it through the already-wired `unityMCP` server's `execute_code` (to run the C#
below), `manage_editor` (to reach Play mode), and `read_console` (to confirm the
forced-loader log line and enumerated devices) tools — this skill adds no new MCP server
or manifest entry of its own.

## Mental model

OpenXR's **Mock Runtime** feature (`MockRuntime`, package `com.unity.xr.openxr`)
replaces the real OpenXR runtime with an in-process fake: instead of talking to a
physical headset driver, it satisfies the OpenXR session/device calls itself.
**Conformance Automation** (`ConformanceAutomationFeature`) is Mock Runtime's
companion — it exposes the actual input-injection surface (pose, float, bool, vec2,
velocity, and active/inactive state per input path) that a script uses to *drive* the
fake devices Mock Runtime enumerates. Neither feature alone is enough: Mock Runtime
supplies the fake session, Conformance Automation supplies the input.

Both features, plus whichever interaction-profile feature the project targets (Valve
Index in the worked examples below), are toggled on the project's single OpenXR
settings asset (`Assets/XR/Settings/OpenXR Package Settings.asset`) — the same asset a
human would edit through Project Settings → XR Plug-in Management → OpenXR. Toggling a
feature here is a **global, persistent, serialized write** to a project asset, not a
Play-mode-scoped runtime flag, which is why every recipe run must end with a full,
symmetric restore (see "Restoring the settings asset" below) — leaving the asset
modified pollutes the next `git status` and the next person's editor session alike.

That restore is a whole-object file backup, not in-memory bookkeeping. Before any write,
`Setup()` serializes the three feature objects it is about to touch
(`EditorJsonUtility.ToJson`) into `Library/XRSim/openxr-settings-backup.json`, so nothing
needs to survive the domain reload Unity performs when Play mode is entered or exited.
`Restore()` reads that file back, overwrites each feature object from it
(`EditorJsonUtility.FromJsonOverwrite`), and deletes the file — its own presence or
absence doubles as the guard against ever running `Setup()` twice without an intervening
`Restore()` (see "Restoring the settings asset" below).

## Recipe

1. **Snapshot the settings state first, before any write.** Capture the current
   `enabled` state of the mock-runtime feature, the conformance-automation feature, and
   the interaction-profile feature you are about to enable in step 2, plus the
   validation-error toggle and the three fields reachable only through that feature's
   serialized representation (`priority`, `required`, and its extension-strings list).
   Store all of it in a snapshot value, and initialize the empty activated-path list.
   All of this — in the actual code, not just in this document — must happen strictly
   before step 2 writes anything; see `XRSim.cs`'s `Setup()` method below for the exact
   ordering.
2. **Enable an interaction profile.** Before any mock session can start, enable the
   OpenXR interaction-profile feature the project targets:
   `OpenXRSettings.ActiveBuildTargetInstance.GetFeature<TProfile>().enabled = true;` —
   the general pattern for any interaction-profile feature type `TProfile`. Worked
   example for Valve Index:
   `OpenXRSettings.ActiveBuildTargetInstance.GetFeature<ValveIndexControllerProfile>().enabled = true;`.
   Once enabled, the mock loader will expose devices under the interaction-profile path
   `/interaction_profiles/valve/index_controller` (confirmed in step 4).
3. **Enable MockRuntime and Conformance Automation.** With the interaction profile
   enabled, turn on the two features that make the mock session possible: `MockRuntime`
   (`OpenXRSettings.ActiveBuildTargetInstance.GetFeature<MockRuntime>().enabled = true;`)
   and `ConformanceAutomationFeature`
   (`...GetFeature<ConformanceAutomationFeature>().enabled = true;`). Also set
   `mockRuntime.ignoreValidationErrors = true;` (some profile/runtime combinations
   otherwise reject the forced session), and reach that same feature's `priority` and
   `required` internal fields via `FindProperty("priority")` / `FindProperty("required")`
   on its serialized representation (see "Restoring the settings asset" below for the
   third, extension-strings field, and how all three are undone).
4. **Enter Play mode, then start the mock session and confirm it before proceeding.**
   `Setup()` (steps 1-3) already forced the settings asset into mock mode while still in
   **Edit mode**, before Play mode is entered. Once Play mode has actually started,
   initialize the loader against those already-mocked settings:
   `XRGeneralSettings.Instance.Manager.InitializeLoaderSync();` then
   `XRGeneralSettings.Instance.Manager.StartSubsystems();` — issue both calls only after
   Play mode has been entered, never before. This ordering is always safe here: if the
   project auto-initializes XR on startup (`Initialize XR on Startup`), the loader that
   comes up automatically on entering Play mode is already the mock-overridden one from
   `Setup()`'s Edit-mode writes, so this call is a redundant no-op with no real loader to
   tear down; if the project does not auto-initialize, this call is what brings the mock
   session up at all. Either way there is no "a real loader was active" case to destroy.

   Use `InitializeLoaderSync()`, not the bare `InitializeLoader()` — that one is `public
   IEnumerator InitializeLoader()`, an iterator method; calling it as a plain statement
   only constructs the enumerator and never runs its body, so `StartSubsystems()`
   immediately afterward finds initialization was never completed, logs `Call to
   StartSubsystems without an initialized manager...`, and starts nothing.
   `InitializeLoaderSync()` is the package's own synchronous replacement for exactly
   this call site.

   Wait for `MockRuntime.sessionState` to reach `Focused` (poll or await the transition;
   do not assume it completed the instant `StartSubsystems()` returns). Then read the
   console (`read_console`) and confirm both of the following actually appear.
   Do not proceed to step 5 until both hold:
   - The console line `Using forced custom loader override provided by the OpenXR Feature Mock Runtime` (verbatim).
   - **Both** mocked devices enumerated: `Head Tracking - OpenXR` and, for the Valve
     Index worked example, `Index Controller OpenXR` — the general pattern other
     profiles follow is `<Manufacturer/Profile> Controller OpenXR` (e.g. `HTC Vive
     Controller OpenXR`), but **Valve Index is the one exception**: its device string
     drops the manufacturer prefix, so it is `Index Controller OpenXR`, not `Valve Index
     Controller OpenXR`. Don't assume every profile drops the manufacturer name from
     this pattern — Valve Index is the odd one out, not the rule.

   A missing controller device here almost always means step 2 was skipped or targeted
   the wrong profile — see Pitfall 7.
5. **Move head/controller poses and drive a virtual grip.** Move the head pose via
   `MockRuntime.SetSpace(XrReferenceSpaceType.View, position, rotation,
   XrSpaceLocationFlags.PositionValid | XrSpaceLocationFlags.OrientationValid);` (repeat
   with the matching per-hand space type for a controller pose). Drive the grip input
   through Conformance Automation on the **full** input path — for the Valve Index
   worked example, the squeeze (grip) axis is
   `/user/hand/right/input/squeeze/value`, built from a top-level user path
   (`/user/hand/right`) plus the profile's input-source path constant
   (`ValveIndexControllerProfile.squeeze`), never a hand-typed partial suffix like
   `squeeze/value` alone (see Pitfall 1).

   Two activation calls are needed together, not just one — this is easy to under-do:
   `ConformanceAutomationSetActive(ValveIndexControllerProfile.profile,
   "/user/hand/right", true)` (the profile-qualified activation) **and, separately**,
   `ConformanceAutomationSetActive(null, "/user/hand/right", true)` (the distinct
   null-profile activation). Both of those, **plus**
   `ConformanceAutomationSetVelocity(...)` for the same input source, are required for a
   legacy `TrackedPoseDriver` component's `isTracked` flag to become `true` — the
   profile-qualified activation alone leaves `isTracked` stuck at `false` even though
   the pose itself is moving (see Pitfall 6).
6. **Verify from game state, not from editor-context reads.** Confirm the grab actually
   took effect by reading **runtime/game state** rather than polling the Input System
   from editor context (see Pitfall 2) — for example, with the AutoHand asset, read
   `hand.GetGripAxis()` (should track the driven squeeze value) and `hand.holdingObj`
   (should reference the grabbed object once the grip crosses AutoHand's grab
   threshold); or, without AutoHand, read the controller GameObject's transform
   position/rotation directly and confirm it tracks the pose driven in step 5.
7. **Restore.** Call `Restore()` (see `XRSim.cs` below). It reads back the whole-object
   JSON backup file `Setup()` wrote in step 1 and overwrites the three feature objects
   from it (`EditorJsonUtility.FromJsonOverwrite`) — `MockRuntime`,
   `ConformanceAutomationFeature`, and the interaction-profile feature all revert
   together, field for field, exactly as they were serialized before step 2 made its
   first write. That single whole-object overwrite also restores the `SerializedObject`
   internals step 3 reached via `FindProperty` — `priority`, `required`, and
   `openxrExtensionStrings` — with no separate per-field restore code needed, since the
   backup already covers them along with the public `enabled`/`ignoreValidationErrors`
   writes. `Restore()` then saves only these three restored objects and deletes the
   backup file. See "Restoring the settings asset" below for the full mechanism and the
   `git diff` check that confirms the asset itself is fully restored.

## Restoring the settings asset

Every step above writes into `Assets/XR/Settings/OpenXR Package Settings.asset`
(Project Settings → XR Plug-in Management → OpenXR), Unity's single OpenXR settings
asset for the active build target. Because it is one shared, serialized asset, every
write made across steps 1-4 must be undone before you hand the project back — otherwise
a teammate's next `git status` shows a dirty settings asset with no source-controlled
reason.

`Setup()` captures the fix with a whole-object JSON backup, not a per-field snapshot.
Before making any write, it serializes the three feature objects it is about to touch —
`MockRuntime`, `ConformanceAutomationFeature`, and the interaction-profile feature — via
`EditorJsonUtility.ToJson`, and writes the result to
`Library/XRSim/openxr-settings-backup.json` (`Library/` is gitignored and not imported by
the AssetDatabase). If that file already exists, `Setup()` throws instead of silently
overwriting or skipping it — a leftover backup means a previous run was never restored,
and overwriting it would lose that run's only remaining record of the real pre-change
state.

`Restore()` (see `XRSim.cs` below) reads that file back and overwrites each of the three
feature objects from it via `EditorJsonUtility.FromJsonOverwrite`, so every field the
backup captured — the `enabled` flags steps 2-3 wrote, `ignoreValidationErrors`, and the
`SerializedObject` internals (`priority`, `required`, `openxrExtensionStrings`) step 3
reached via `FindProperty` — reverts together, exactly as it was serialized before step 2
made its first write. It then calls `EditorUtility.SetDirty()` on each restored object,
followed by a scoped `AssetDatabase.SaveAssetIfDirty()` per object — never the bare,
project-wide `AssetDatabase.SaveAssets()` — so only these three feature objects are
flushed to disk. A bare `SaveAssets()` would persist every other dirty asset in the
project too (an unrelated open scene or prefab, for example), which could leave a
non-empty `git diff` elsewhere even though the OpenXR settings asset itself is clean.
`Restore()` finally deletes the backup file so the next `Setup()` run doesn't trip its
own guard.

**`Restore()` refuses to run without a backup file.** If
`Library/XRSim/openxr-settings-backup.json` does not exist, `Restore()` throws an
`InvalidOperationException` rather than fabricating a default state to write — there is
nothing it could safely revert to. If the backup file is genuinely gone (deleted or moved
outside this recipe), fall back to
`git checkout -- "Assets/XR/Settings/OpenXR Package Settings.asset"` (adjust this path if
your project's OpenXR settings asset lives elsewhere) to revert the asset by hand instead.

Confirm full restoration with `git diff` on
`Assets/XR/Settings/OpenXR Package Settings.asset` — after `Restore()` runs, that diff
must be **empty**, and `Library/XRSim/` should no longer contain the backup file. A
non-empty diff means a field the backup didn't cover, or a write made outside `Setup()`'s
capture.

## Pitfalls

1. **Full vs. partial input paths.** Conformance Automation calls expect a **full**
   OpenXR input path (e.g. `/user/hand/right/input/squeeze/value`), not the **partial**
   suffix (`squeeze/value`, or `/squeeze/value` alone) that some profile constant
   fields expose by name. Pass the full path built from the top-level user path plus
   the profile's input-source path constant (`ValveIndexControllerProfile.squeeze`), or
   the call silently no-ops — no device motion, no error, nothing in the console to
   flag it.
2. **Stale Editor-context Input System reads.** Reading `UnityEngine.InputSystem`
   device state from **editor-context** code (an `execute_code` call, a custom editor
   script) can return a **stale** snapshot from before the mock activation took effect,
   because the Input System's device list is only guaranteed current inside the running
   Play-mode/game loop. Verify via game/MonoBehaviour state instead (step 6's concrete
   example), not an editor-side poll.
3. **`MockRuntime` needs its own editor-only asmdef — `autoReferenced: false`.**
   `Unity.XR.OpenXR.Features.MockRuntime` and the Conformance Automation assembly are
   not auto-referenced by every assembly (`autoReferenced: false` in their own
   asmdef), so a script calling into them needs an explicit assembly definition that
   references them by name, restricted to the Editor platform:

   ```json
   {
       "name": "Seretos.UnityXRSim.Editor",
       "references": [
           "Unity.XR.OpenXR",
           "Unity.XR.OpenXR.Features.MockRuntime",
           "Unity.XR.OpenXR.Features.ConformanceAutomation",
           "Unity.XR.Management",
           "Unity.InputSystem"
       ],
       "includePlatforms": [
           "Editor"
       ],
       "autoReferenced": false
   }
   ```

   Without this, the project either fails to compile (`XRSim.cs` sitting in an
   assembly with no reference to the Features assemblies) or — worse — a runtime
   assembly picks up `autoReferenced: false` assemblies it was never meant to ship.
4. **Reach internal fields via `SerializedObject`, not direct field access.**
   `priority`, `required`, and `openxrExtensionStrings` are internal fields on
   the feature type — not exposed as public settable properties — so reach
   them through a `SerializedObject` wrapped around the feature asset and
   `FindProperty(...)`, never direct field access, which won't compile from
   outside the declaring assembly (Unity's `InternalsVisibleTo` grant on this
   assembly never extends to a consumer's own project assembly).
   `ignoreValidationErrors`
   is the exception — a public field on `MockRuntime` set by direct assignment,
   not through `SerializedObject`/`FindProperty` (step 3 already does this:
   `mockRuntime.ignoreValidationErrors = true;`).
5. **Mock loader init can trip the MCP `execute_code` timeout.** Calling
   `InitializeLoaderSync()`/`StartSubsystems()` right after entering Play mode (step 4)
   inside `execute_code` can run long enough on a cold editor to trip the tool's own
   timeout — Play mode's own domain reload plus a cold loader init is real elapsed time,
   not just the mock feature toggles from `Setup()`. A timed-out call does **not** mean
   the loader failed — query `mcpforunity://editor/state` or `read_console` afterward to
   confirm the actual outcome before assuming failure and retrying.
6. **`TrackedPoseDriver.isTracked` needs both `SetVelocity` and the null-profile
   `SetActive`.** A legacy `TrackedPoseDriver` component's `isTracked` flag only flips
   to `true` once **both** `ConformanceAutomationSetVelocity(...)` has been called for
   the relevant input source **and** the distinct null-profile
   `ConformanceAutomationSetActive(null, path, true)` activation has been made — the
   profile-qualified `SetActive` call by itself is not sufficient for this legacy
   component (step 5 above).
7. **A missing interaction profile means no controller device.** If step 2 was skipped
   or targeted the wrong profile, step 4's device list shows `Head Tracking - OpenXR`
   alone — no controller device appears, and every subsequent Conformance Automation
   call for that profile's input paths silently no-ops. Confirm the interaction profile
   is enabled before forcing the loader.
8. **The Mock Environment renders nothing — this is expected.** Unity's own docs note
   the Mock Runtime is provided for logic/automation testing, not visual verification.
   Rendering may fail to initialize entirely (`XR_UNITY_null_gfx` in the OpenXR loader
   log) since there is no real graphics runtime backing the mock session — that is
   expected behaviour, not a sign of a broken mock setup.
9. **A controller pose call must drive both the aim/pointer pose and the device/grip
   pose — and so must `SetVelocity`.** `ValveIndexControllerProfile` exposes two
   distinct poses: `aim` (bound to `/input/aim/pose`, the pointing-ray pose) and `grip`
   (bound to `/input/grip/pose`, which backs `devicePosition`/`deviceRotation` — the
   XRSDK-compatible "Device" usage that most controller-transform bindings, e.g. a
   `TrackedPoseDriver` on the default Device usage, actually read). Driving only `aim`
   leaves anything reading `devicePosition`/`deviceRotation` completely motionless, with
   no error or console signal to indicate why. This applies to **both**
   `ConformanceAutomationSetPose` (position/rotation) and `ConformanceAutomationSetVelocity`
   (Pitfall 6's tracked-state requirement) — "the relevant input source" in Pitfall 6 means
   the grip/device path for a default-usage `TrackedPoseDriver`, not the aim path alone.
   `SetControllerPose()` (`XRSim.cs`) calls `ConformanceAutomationSetPose` twice — once
   for `ValveIndexControllerProfile.aim`, once for `ValveIndexControllerProfile.grip` —
   with the same position/rotation, and `SetGrip()` likewise calls
   `ConformanceAutomationSetVelocity` twice, once per pose, with the same zeroed
   velocity sample — so a single call each drives the controller as a whole.

## XRSim.cs template

`skills/unity-xr-sim/XRSim.cs` is a ready-to-drop, stateless editor template
implementing the recipe above: `Setup()` performs step 1's whole-object backup and steps
2-3's writes, `SetHeadPose()`/`SetControllerPose()`/`SetGrip()` perform step 5's
pose/grip driving (including the paired profile-qualified + null-profile activation from
Pitfall 6), and `Restore()` performs the full undo described in "Restoring the settings
asset". `SetControllerPose()` drives both the aim/pointer pose and the device/grip pose
together, not just one, and `SetGrip()` likewise calls `ConformanceAutomationSetVelocity`
for both poses (see Pitfall 9) — a single call each moves/tracks the controller as a
whole.
It owns no loader lifecycle of its own — the `InitializeLoaderSync()`/
`StartSubsystems()` call in step 4 is issued directly via `execute_code`, per the
Operator rules above, not by a method in this file. Copy it into an `Editor/` folder
alongside the asmdef from Pitfall 3, adjusting the namespace and the Valve Index
specifics for whichever interaction profile the target project actually uses.
