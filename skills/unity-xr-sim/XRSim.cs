// XRSim.cs - headless-free OpenXR simulation template (Mock Runtime + Conformance
// Automation). Part of the unity-xr-sim skill (ticket #54) - see
// skills/unity-xr-sim/SKILL.md for the full recipe this drives.
//
// RECONSTRUCTED, NOT FETCHED VERBATIM: the plan asked for this file to be fetched
// read-only from Seretos/unity-experimental@2f0c205f (Assets/_Experiments/XRSim/XRSim.cs)
// and adapted for template use. That fetch was attempted (gh api against the private
// repo, then an unauthenticated raw.githubusercontent.com request as a fallback) and
// both failed - `gh` is disabled in this environment (repo policy) and the raw URL
// 404s without authentication. Per the plan's documented fallback, this file is
// reconstructed from the API signatures in the plan instead; treat it as a
// well-reasoned reconstruction, not the verified original, until someone with `gh`
// access can diff it against the source commit.
//
// Editor-only: place under an Editor/ folder with an asmdef that sets
// "includePlatforms": [ "Editor" ] and references Unity.XR.OpenXR, the Mock Runtime
// and Conformance Automation Features assemblies, Unity.XR.Management, and
// Unity.InputSystem - see SKILL.md Pitfall 3 for the exact asmdef JSON.
//
// This is a stateless copy-paste template, not a lifecycle-owning module: it carries
// no mutable static state and owns no loader lifecycle at all - entering/exiting Play
// mode is the caller's job (see SKILL.md's "Operator rules" and step 4), and the one
// loader-init call the recipe still needs lives only in SKILL.md, issued by the agent
// after Play mode is already entered. Setup()/Restore() carry exactly four guards:
// (G1) no OpenXR settings for the active build target, (G2) one of the three required
// OpenXR features missing from the project, (G3) a leftover backup file from an
// unrestored prior run, (G4) no backup file to restore from. See SKILL.md's
// "Restoring the settings asset" for the full mechanism.

using System;
using System.IO;
using UnityEditor;
using UnityEngine;
using UnityEngine.XR.OpenXR;
using UnityEngine.XR.OpenXR.Features.Mock;
using UnityEngine.XR.OpenXR.Features.ConformanceAutomation;
using UnityEngine.XR.OpenXR.Features.Interactions;
using UnityEngine.XR.OpenXR.NativeTypes;

namespace Seretos.UnityXRSim.Editor
{
    public static class XRSim
    {
        // Single source of truth for the backup file's location, referenced by every
        // existence check, read and write call site below (Setup()'s G3 check and
        // capture, Restore()'s G4 check, read and final delete) - never re-typed as a
        // literal at any of those call sites. Rooted under Library/ (gitignored, not
        // imported by the AssetDatabase): a file survives an Editor crash or process
        // restart, and its own presence/absence *is* the G3/G4 guard - no separate
        // in-memory flag needed.
        private const string BackupPath = "Library/XRSim/openxr-settings-backup.json";

        // Plain serializable wrapper (not a UnityEngine.Object) holding the three
        // feature objects' own EditorJsonUtility.ToJson() output as opaque strings, so
        // JsonUtility can round-trip the wrapper itself while each inner string is
        // later handed to EditorJsonUtility.FromJsonOverwrite() verbatim, against a
        // live feature instance re-acquired via GetFeature<T>() at restore time.
        [Serializable]
        private class BackupFile
        {
            public string mockRuntimeJson;
            public string conformanceAutomationFeatureJson;
            public string valveIndexControllerProfileJson;
        }

        /// <summary>
        /// Recipe steps 1-3: fail fast on the four guards below, then back up the
        /// three feature objects' full serialized state to disk before making any
        /// write, then enable the interaction profile, MockRuntime, and Conformance
        /// Automation.
        /// </summary>
        public static void Setup()
        {
            OpenXRSettings settings = OpenXRSettings.ActiveBuildTargetInstance;

            // G1: `com.unity.xr.openxr` being installed does not guarantee a
            // per-platform OpenXR settings asset exists - that asset is only created
            // once a loader is actually configured for the active build target. See
            // SKILL.md's precondition section.
            if (settings == null)
            {
                throw new InvalidOperationException(
                    "No OpenXR settings found for the active build target - configure an OpenXR " +
                    "loader for this platform in XR Plug-in Management > OpenXR (Project Settings) " +
                    "before running this template.");
            }

            MockRuntime mockRuntime = settings.GetFeature<MockRuntime>();
            ConformanceAutomationFeature conformanceAutomationFeature = settings.GetFeature<ConformanceAutomationFeature>();
            ValveIndexControllerProfile valveIndexControllerProfile = settings.GetFeature<ValveIndexControllerProfile>();

            // G2: MockRuntime, ConformanceAutomationFeature, and the interaction
            // profile feature are each OPTIONAL OpenXR features - a project can have
            // the package installed and a loader configured (G1 above) without having
            // added these specific features to its OpenXR feature set.
            // GetFeature<T>() returns null, not a usable-but-disabled instance, for a
            // feature type that isn't in that list - fail fast naming exactly which
            // feature is missing and where to add it, instead of an unhelpful
            // NullReferenceException on first use below.
            if (mockRuntime == null)
            {
                throw new InvalidOperationException(
                    "MockRuntime feature not found in this project's OpenXR feature set - add it in " +
                    "Project Settings > XR Plug-in Management > OpenXR > [platform] > OpenXR Feature " +
                    "Groups before running this template.");
            }

            if (conformanceAutomationFeature == null)
            {
                throw new InvalidOperationException(
                    "ConformanceAutomationFeature feature not found in this project's OpenXR feature " +
                    "set - add it in Project Settings > XR Plug-in Management > OpenXR > [platform] > " +
                    "OpenXR Feature Groups before running this template.");
            }

            if (valveIndexControllerProfile == null)
            {
                throw new InvalidOperationException(
                    "ValveIndexControllerProfile feature not found in this project's OpenXR feature " +
                    "set - add it in Project Settings > XR Plug-in Management > OpenXR > [platform] > " +
                    "OpenXR Feature Groups before running this template.");
            }

            // G3: refuse to clobber an unrestored prior run. A leftover backup file
            // means a previous Setup() was never followed by a Restore(), so that
            // file is the only remaining record of what the settings asset looked
            // like before that run - silently overwriting or skipping it here would
            // lose that record for good.
            if (File.Exists(BackupPath))
            {
                throw new InvalidOperationException(
                    "A backup already exists at " + BackupPath + " - a previous Setup() run was never " +
                    "restored. Call Restore() first if that run's mock session is still usable, or " +
                    "otherwise `git checkout -- \"Assets/XR/Settings/OpenXR Package Settings.asset\"` " +
                    "and delete the stale backup file before running Setup() again.");
            }

            // Whole-object capture, before ANY write below - both the .enabled writes
            // and the SerializedObject internal-field write further down. The backup
            // is exactly the serialized state of the three feature objects at this
            // point, so Restore() can never drift from what Setup() actually changed,
            // whatever that turns out to be - see SKILL.md's "Restoring the settings
            // asset".
            BackupFile backup = new BackupFile
            {
                mockRuntimeJson = EditorJsonUtility.ToJson(mockRuntime),
                conformanceAutomationFeatureJson = EditorJsonUtility.ToJson(conformanceAutomationFeature),
                valveIndexControllerProfileJson = EditorJsonUtility.ToJson(valveIndexControllerProfile),
            };
            Directory.CreateDirectory(Path.GetDirectoryName(BackupPath));
            File.WriteAllText(BackupPath, JsonUtility.ToJson(backup));

            // No EditorUtility.SetDirty()/AssetDatabase.SaveAssets() here, and that is
            // deliberate, not an oversight: these are live in-memory writes on
            // ScriptableObject-derived feature instances, and Unity's domain-reload
            // preservation (entering/exiting Play mode) serializes and restores the
            // current in-memory state of every loaded object regardless of its dirty
            // flag - "dirty" only gates whether AssetDatabase treats the asset as
            // modified-on-disk (Editor save prompts, VCS), not whether a domain reload
            // preserves the value. Any code re-fetching the same feature via
            // GetFeature<T>() later in this session - including after entering Play
            // mode in step 4 - sees these writes immediately. Persisting to disk only
            // matters once Restore() is ready to hand the asset back, which is why
            // SetDirty()+SaveAssetIfDirty() live there instead (see Restore() below).

            // --- enable the interaction profile ---
            valveIndexControllerProfile.enabled = true;

            // --- enable MockRuntime + Conformance Automation ---
            mockRuntime.enabled = true;
            conformanceAutomationFeature.enabled = true;
            mockRuntime.ignoreValidationErrors = true;

            // `priority` and `required` are internal on OpenXRFeature, reachable only
            // through its serialized representation (SKILL.md step 3). Force
            // `required` true so a failure to initialize MockRuntime fails the whole
            // OpenXR session loudly instead of silently continuing without the mock,
            // mirroring the ignoreValidationErrors force above. `priority = 0` is
            // OpenXRFeatureAttribute's own default (MockRuntime's attribute doesn't
            // override it) - it is NOT a "run first" guarantee: OpenXRLoader sorts
            // features `OrderByDescending(priority).ThenBy(nameUi)`, so higher values
            // run first and priority alone never determines MockRuntime's place ahead
            // of the other two features this recipe enables, both of which also sit at
            // the default. Nothing in this recipe depends on a specific
            // processing-order between MockRuntime, ConformanceAutomationFeature, and
            // ValveIndexControllerProfile, so leaving `priority` at the shared default
            // is deliberate and sufficient here - it is set explicitly only so
            // Restore() has a captured, known value to revert to, not to pin an
            // ordering. The backup captured above already covers every field on this
            // object, both of these included, so Restore() reverts them along with
            // everything else without needing its own per-field logic.
            SerializedObject _serializedMockRuntime = new SerializedObject(mockRuntime);
            _serializedMockRuntime.FindProperty("priority").intValue = 0;
            _serializedMockRuntime.FindProperty("required").boolValue = true;
            _serializedMockRuntime.ApplyModifiedProperties();
        }

        /// <summary>Recipe step 5 - moves the mocked head pose.</summary>
        public static void SetHeadPose(Vector3 position, Quaternion rotation)
        {
            MockRuntime.SetSpace(
                XrReferenceSpaceType.View,
                position,
                rotation,
                XrSpaceLocationFlags.PositionValid | XrSpaceLocationFlags.OrientationValid);
        }

        /// <summary>Recipe step 5 - moves a mocked controller pose. Drives both the
        /// aim/pointer pose (<c>ValveIndexControllerProfile.aim</c>, bound to
        /// <c>/input/aim/pose</c>) and the device/grip pose
        /// (<c>ValveIndexControllerProfile.grip</c>, bound to <c>/input/grip/pose</c>)
        /// together, with the same position/rotation, so both a pointing-ray consumer
        /// and an XRSDK-style <c>devicePosition</c>/<c>deviceRotation</c> consumer (e.g.
        /// a <c>TrackedPoseDriver</c> on the default Device usage) see the controller
        /// move as a whole. See SKILL.md Pitfall 9.</summary>
        public static void SetControllerPose(string topLevelPath, Vector3 position, Quaternion rotation)
        {
            ActivateInput(topLevelPath);
            // inputSourcePath (the 2nd argument) must be the FULL path (e.g.
            // "/user/hand/right/input/aim/pose") - topLevelPath concatenated with the
            // profile constant's relative suffix ("/input/aim/pose") - not the bare
            // profile constant alone. See SKILL.md Pitfall 1.
            ConformanceAutomationFeature.ConformanceAutomationSetPose(
                topLevelPath, topLevelPath + ValveIndexControllerProfile.aim, position, rotation);

            // Grip/device pose, driven together with the aim/pointer pose above (see
            // SKILL.md Pitfall 9) - without this second call, anything reading
            // devicePosition/deviceRotation (the XRSDK-compatible "Device" usage most
            // controller-transform bindings actually read) sees no movement at all, with
            // no error or console signal to indicate why.
            ConformanceAutomationFeature.ConformanceAutomationSetPose(
                topLevelPath, topLevelPath + ValveIndexControllerProfile.grip, position, rotation);
        }

        /// <summary>
        /// Recipe step 5 - drives the Valve Index squeeze (grip) axis. Activates the
        /// input source on both the profile-qualified and null-profile paths (both are
        /// required for a legacy TrackedPoseDriver.isTracked to become true, alongside
        /// SetVelocity - see SKILL.md Pitfall 6) and sets the squeeze value, then sets a
        /// zeroed velocity sample on BOTH the aim/pointer pose and the device/grip pose
        /// (SetVelocity sets the velocity of a pose input, not a scalar float axis, so
        /// it targets a pose path, not the squeeze path - see SKILL.md Pitfall 6), for
        /// the same two-pose reason SetControllerPose() drives both poses above (see
        /// SKILL.md Pitfall 9): a TrackedPoseDriver bound to the default Device usage
        /// reads the grip/device pose's tracking state, not the aim pose's, so
        /// isTracked only becomes true once the grip pose also has a velocity sample.
        /// </summary>
        public static void SetGrip(string topLevelPath, float squeezeValue)
        {
            ActivateInput(topLevelPath);

            // inputSourcePath (the 2nd argument) is the full path built from
            // topLevelPath + the profile's relative suffix - see SKILL.md Pitfall 1; a
            // bare profile constant silently no-ops.
            ConformanceAutomationFeature.ConformanceAutomationSetFloat(
                topLevelPath, topLevelPath + ValveIndexControllerProfile.squeeze, squeezeValue);

            ConformanceAutomationFeature.ConformanceAutomationSetVelocity(
                topLevelPath, topLevelPath + ValveIndexControllerProfile.aim,
                linearValid: true, linear: Vector3.zero,
                angularValid: true, angular: Vector3.zero);

            // Device/grip pose velocity, driven together with the aim/pointer pose
            // above for the same reason SetControllerPose() drives both poses (see
            // SKILL.md Pitfall 9) - without this second call, a TrackedPoseDriver on
            // the default Device usage (the common case Pitfall 9 calls out) never
            // sees a velocity sample on the pose it actually reads, so isTracked stays
            // false with no error or console signal to indicate why.
            ConformanceAutomationFeature.ConformanceAutomationSetVelocity(
                topLevelPath, topLevelPath + ValveIndexControllerProfile.grip,
                linearValid: true, linear: Vector3.zero,
                angularValid: true, angular: Vector3.zero);
        }

        // Conformance Automation input state is scoped to the current OpenXR session
        // (every ConformanceAutomationSet* call is parameterized by
        // ConformanceAutomationFeature.xrSession, which is zeroed in OnSessionDestroy)
        // and so cannot outlive Play mode - there is nothing here for this template to
        // track or walk back on restore, unlike the settings-asset writes above.
        // SetActive is idempotent, so calling both activations unconditionally on
        // every pose/grip call is correct, not merely convenient.
        private static void ActivateInput(string topLevelPath)
        {
            ConformanceAutomationFeature.ConformanceAutomationSetActive(ValveIndexControllerProfile.profile, topLevelPath, true);
            ConformanceAutomationFeature.ConformanceAutomationSetActive(null, topLevelPath, true);
        }

        /// <summary>
        /// Recipe step 7: undo everything Setup() did to the settings asset, restoring
        /// the three feature objects' full serialized state from the backup file
        /// Setup() wrote - never a hard-coded or fabricated value. Saves only these
        /// three restored objects (AssetDatabase.SaveAssetIfDirty per object) rather
        /// than a project-wide AssetDatabase.SaveAssets() - the latter would persist
        /// every other dirty asset in the project too, not just the ones this recipe
        /// touched.
        ///
        /// <para>Build-target note: this method re-fetches
        /// <c>OpenXRSettings.ActiveBuildTargetInstance</c> fresh below, on whichever
        /// build target is active when it runs - it does not record or re-verify the
        /// target <see cref="Setup"/> captured. If the active build target changed
        /// between the matching <see cref="Setup"/> call and this call, this will
        /// restore the wrong platform's settings asset from the other platform's
        /// backup. That is deliberately not guarded in code - see SKILL.md's Operator
        /// rule 4 ("Do not change the active build target between Setup() and
        /// Restore()"), the documented (not code-enforced) mitigation, consistent with
        /// this file's reference-template-not-hardened-library design bar.</para>
        /// </summary>
        public static void Restore()
        {
            // G4: never fabricate a default. If there is no backup, there is nothing
            // this method can safely revert to, so it refuses outright instead of
            // guessing at what the pre-Setup() state might have been.
            if (!File.Exists(BackupPath))
            {
                throw new InvalidOperationException(
                    "No backup found at " + BackupPath + " - Restore() has nothing to restore from. " +
                    "If Setup() was never called this run there is nothing to undo; otherwise the " +
                    "backup was deleted or moved externally - fall back to " +
                    "`git checkout -- \"Assets/XR/Settings/OpenXR Package Settings.asset\"` " +
                    "to revert the settings asset by hand.");
            }

            string backupFileJson = File.ReadAllText(BackupPath);
            BackupFile backup = JsonUtility.FromJson<BackupFile>(backupFileJson);

            OpenXRSettings settings = OpenXRSettings.ActiveBuildTargetInstance;
            MockRuntime mockRuntime = settings.GetFeature<MockRuntime>();
            ConformanceAutomationFeature conformanceAutomationFeature = settings.GetFeature<ConformanceAutomationFeature>();
            ValveIndexControllerProfile valveIndexControllerProfile = settings.GetFeature<ValveIndexControllerProfile>();

            // Overwrite each feature object from the actual backup content read above
            // - never a hard-coded/empty JSON string - so the restored values
            // genuinely come from what Setup() captured before it wrote anything.
            EditorJsonUtility.FromJsonOverwrite(backup.mockRuntimeJson, mockRuntime);
            EditorJsonUtility.FromJsonOverwrite(backup.conformanceAutomationFeatureJson, conformanceAutomationFeature);
            EditorJsonUtility.FromJsonOverwrite(backup.valveIndexControllerProfileJson, valveIndexControllerProfile);

            EditorUtility.SetDirty(mockRuntime);
            EditorUtility.SetDirty(conformanceAutomationFeature);
            EditorUtility.SetDirty(valveIndexControllerProfile);

            // Scoped saves only - never the bare, no-argument, project-wide
            // AssetDatabase.SaveAssets call. That overload flushes EVERY dirty asset in
            // the project, not just these three, so it could silently write out an
            // unrelated scene/prefab the user had open and unsaved, defeating the "clean
            // git diff" guarantee this recipe promises for the OpenXR settings asset
            // specifically. SaveAssetIfDirty (Unity 2021.1+, well below this recipe's
            // 6000.3 target) persists exactly the object passed in.
            AssetDatabase.SaveAssetIfDirty(mockRuntime);
            AssetDatabase.SaveAssetIfDirty(conformanceAutomationFeature);
            AssetDatabase.SaveAssetIfDirty(valveIndexControllerProfile);

            // Clear the guard now that the asset is back to its pre-Setup() state, so
            // the next Setup() run doesn't trip G3.
            File.Delete(BackupPath);
        }
    }
}
