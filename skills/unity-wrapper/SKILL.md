---
name: unity-wrapper
description: Drive the Unity editor through the external Unity MCP server (server key unityMCP) — inspect and edit scenes, GameObjects, components and assets, enter and exit Play mode, capture screenshots, run Unity Test Runner tests (run_tests, EditMode and PlayMode), and read the Unity console for compilation errors after a script write, instead of guessing project state. Also covers booting a per-worktree Unity editor with environment_start (headless vs GUI variants, UNITY_MCP_STATUS_DIR isolation), cold-start Library re-import expectations and acceleration, standalone builds, and recovering when a tool call reports no Unity Editor instances or Unity refuses to open a project because of a stale Temp/UnityLockfile. Use when working inside a Unity project, starting or connecting to a Unity editor, or when a Unity MCP tool call fails.
---

# unity-wrapper

## What this skill is for

Reach for this skill when the task involves a **Unity project** — exploring its scene
graph, locating or editing GameObjects and components, or inspecting assets. The skill
routes that work through the Unity MCP server's structured tools rather than reading or
guessing at serialized scene/asset files.

For git-merging serialized Unity assets (scenes, prefabs, and other YAML asset types),
see the `unity-yaml-merge` skill instead — that is a separate concern from driving the
live editor.

For exercising VR/XR behaviour headset-free — forcing an OpenXR mock session, moving
head/controller poses, and driving a virtual grab — see the `unity-xr-sim` skill
instead; that is a separate, MCP-free-of-its-own concern layered on top of the editor
this skill drives.

## Mental model

The Unity MCP has two halves that must both be running for any tool call to succeed:

1. **Python MCP server** (`mcpforunityserver==9.7.1`, launched via `uvx`) — this is the
   process the MCP host (Claude Code / Codex) connects to over `stdio`. It translates
   MCP tool calls into messages sent to the Unity editor.

2. **C# bridge package** — a Unity package (`MCP For Unity`, installed from the
   `CoplayDev/unity-mcp` git URL) that runs inside the target Unity project. It opens a
   local socket and listens for commands from the Python server. Without it loaded in the
   editor, the Python server has nothing to connect to and all calls fail.

The flow is: **MCP host → Python server (stdio) → local socket → C# bridge → Unity editor**.

Key entities the MCP exposes:

- **Scenes** — the currently open scene(s) in the editor; operations read/write their
  serialized state live (unsaved changes are visible immediately but not persisted until
  saved).
- **GameObjects** — named nodes in the scene hierarchy, each carrying an active state,
  transform, tag, and layer.
- **Components** — MonoBehaviour and built-in components attached to GameObjects; fields
  are readable and writable by name.
- **Assets** — files under `Assets/` (scripts, prefabs, materials, textures, etc.);
  listable and queryable by path or type.
- **Edit / Play mode lifecycle** — the editor starts in Edit mode; entering Play mode
  runs the game loop. Some tools behave differently or are unavailable during Play mode.

## Tool inventory

The tools below are exposed by the Unity MCP server (MCP server key: `unityMCP`).
These are the **real MCP tool identifiers** — call them by these names. They were read
from the `mcpforunityserver` package source (9.7.3); the manifests currently pin
`mcpforunityserver==9.7.1`, so if a name is rejected, list the live surface with
`manage_tools` or read the `mcpforunity://tool-groups` resource rather than guessing.

**Reads are resources, writes are tools.** Several read paths are MCP *resources*
(`mcpforunity://…`), not tools — most importantly component reads, which have no tool.

**Tools are grouped, and groups can be off.** Group `core` is always on. `execute_code`
is in `scripting_ext`; `run_tests` and `get_test_job` are in `testing`; `manage_tools`
and `set_active_instance` are always visible. Over stdio all groups start enabled and
then sync with Unity's own tool states — so a tool that is *missing from the list* is a
disabled group (fix with `manage_tools`), which is a different failure from a tool that
is listed but *fails to call* (bridge unreachable — see Pitfall 1).

| Tool | What it is best for |
|---|---|
| `manage_scene` | Scene CRUD and inspection — `get_hierarchy` (paged: `page_size`, `cursor`, `max_depth`), `get_active`, `get_loaded_scenes`, `create`, `load`, `save`, `close_scene`, `set_active_scene` |
| `find_gameobjects` | Searching the scene by name, tag, layer, component type, or path; returns paged **instance IDs** only |
| `manage_gameobject` | GameObject CRUD — `create`, `modify`, `delete`, `duplicate`, `move_relative`, `look_at`. Not for searching, not for components |
| `manage_components` | Component **writes** — `add`, `remove`, `set_property` on a target GameObject. It has no read action |
| `mcpforunity://scene/gameobject/{id}` · `.../components` · `.../component/{name}` | Component and GameObject **reads** (resources, not tools). Get `{id}` from `find_gameobjects` |
| `manage_asset` | Assets under `Assets/` — `search` (page it and keep `generate_preview=false`), import, create, modify, delete |
| `manage_editor` | Entering/exiting Play mode (`play`, `pause`, `stop`) plus tags, layers, active tool, `undo`/`redo` |
| `mcpforunity://editor/state` | Current editor state — read this to know whether you are in Edit or Play mode before editing |
| `manage_camera` | Screenshots — `screenshot`, `screenshot_multiview` (optionally `include_image` for an inline PNG). The first-class capture path |
| `read_console` | Unity console — `get` (paged; errors/warnings/info) or `clear`. This is how you see **compilation errors** after writing a script |
| `execute_code` | Arbitrary C# inside the editor — `execute`, `get_history`, `replay`, `clear_history`. Group `scripting_ext` |
| `manage_script`, `apply_text_edits`, `script_apply_edits`, `create_script`, `delete_script`, `validate_script`, `get_sha`, `find_in_file` | C# script files in the project — create, read, edit, validate, hash-verify |
| `run_tests` + `get_test_job` | Unity Test Runner. `run_tests` starts an `EditMode`/`PlayMode` run **asynchronously** and returns a `job_id`; poll `get_test_job`. PlayMode needs a longer `init_timeout` (~120000 ms). Group `testing` — see Pitfall 6 before using it |
| `manage_build` | Standalone player builds and the build-settings scene list (`action='scenes'`) |
| `manage_prefabs` | Prefab CRUD and the prefab stage (open/save/close) |
| `execute_menu_item` | Invoking a Unity editor menu item by path |
| `refresh_unity` | Asset-database refresh / recompile; reports `recovered_from_disconnect: true` after a bridge drop (Pitfall 1) |
| `batch_execute` | Bundling several MCP commands into one round-trip — strongly preferred for repetitive edits |
| `manage_tools` | Listing tool groups and enabling/disabling them. Always visible; reach for it when an expected tool is absent |
| `set_active_instance` | Selecting among multiple discovered Unity instances — normally unnecessary here (status-dir isolation guarantees exactly one) |

Further groups exist for domain work — `vfx` (`manage_vfx`, `manage_shader`, `manage_texture`),
`ui` (`manage_ui`), `animation` (`manage_animation`), `docs` (`unity_docs`, `unity_reflect`),
`probuilder`, `profiling` — plus `manage_material`, `manage_graphics`, `manage_physics`,
`manage_packages`, `manage_scriptable_object`. Enumerate the live set with `manage_tools`.

## Patterns and recipes

Play-mode screenshots are available as a capability: with Unity booted under
`environment_start variant=gui`, an agent can capture the running scene to
`<worktree>/.unity-mcp/screenshot.png`. Capture one when a human will want to see the
result. See "Capture a screenshot from Play mode" below.

### Inspect the scene hierarchy

1. Use `manage_scene action=get_loaded_scenes` (or `action=get_active`) to confirm which
   scene is active.
2. Use `manage_scene action=get_hierarchy` to retrieve the root GameObjects and
   recursively expand the hierarchy to the depth you need (page it with `page_size`,
   `cursor`, `max_depth`).
3. Use `find_gameobjects` (find by name/tag) when you know what you are looking for
   rather than walking the whole tree.

### Read a component value on a specific GameObject

1. Use `find_gameobjects` (find by name or path) to confirm the target GameObject exists
   and to get its **instance ID**.
2. Read `mcpforunity://scene/gameobject/{id}/components` (or `.../component/{name}` for a
   single component) with that ID to retrieve all field values.
3. Inspect the returned fields — field names follow Unity's serialized property naming.

### Modify a component field

1. Confirm the target via the components resource first (see above) so you know current
   values and correct field names.
2. Use `manage_components action=set_property` supplying the GameObject, component type,
   and a dict of `{fieldName: newValue}`.
3. Re-read the components resource to verify the change took effect.
4. Save the scene explicitly (`manage_scene action=save`) if the change must survive a
   crash or reload.

### List and inspect project assets

1. Use `manage_asset action=search` to enumerate files under a specific folder (e.g.
   `Assets/Scripts`) or filtered by extension/type — page it and keep
   `generate_preview=false`.
2. Use `manage_asset` with the returned project-relative path to read a specific asset's
   content or metadata.

### Enter and exit Play mode

1. Read `mcpforunity://editor/state` to confirm you are in Edit mode before entering.
2. Use `manage_editor action=play` to enter Play mode and wait for confirmation that the
   editor has transitioned.
3. Perform any play-mode-specific queries (e.g. reading runtime component values).
4. Use `manage_editor action=stop` to exit Play mode before making any scene edits.

### Capture a screenshot from Play mode

The Unity MCP can capture a screenshot of the running scene from Play mode. Capture one
when a human will want to see the result — for example, when the runtime appearance of a
UI or scene change is worth showing.

`manage_camera action=screenshot` is the first-class capture path. The `execute_code`
recipe below is the fallback for when `scripting_ext` is unavailable or you need custom
framing/output paths.

**Prerequisites:** Unity must be running under `variant=gui` (not headless). In headless
mode (`-batchmode -nographics`), `ScreenCapture.CaptureScreenshot` produces no output and
the display subsystem is not initialized, so the RenderTexture path also produces a blank
image on headless configurations without a display subsystem. Boot with
`environment_start variant=gui` before executing the recipe below.

**Recipe — execute via `execute_code`:**

````csharp
// Visual verification screenshot — execute in Play mode via the Unity MCP execute_code tool.
// Output path: <worktree>/.unity-mcp/screenshot.png
// Run AFTER entering Play mode and waiting for the scene to finish loading.

// 1. Resolve output path into the worktree-local status dir (always present when the bridge is up).
string statusDir = System.Environment.GetEnvironmentVariable("UNITY_MCP_STATUS_DIR");
if (string.IsNullOrEmpty(statusDir))
    statusDir = System.IO.Path.Combine(UnityEngine.Application.dataPath, "..", ".unity-mcp");
string outputPath = System.IO.Path.GetFullPath(System.IO.Path.Combine(statusDir, "screenshot.png"));

// 2. Capture via RenderTexture + ReadPixels. Requires GUI mode — see prerequisites above;
//    headless (-nographics) yields a blank image.
int width  = UnityEngine.Screen.width  > 0 ? UnityEngine.Screen.width  : 1920;
int height = UnityEngine.Screen.height > 0 ? UnityEngine.Screen.height : 1080;

UnityEngine.RenderTexture rt = new UnityEngine.RenderTexture(width, height, 24);
UnityEngine.Camera cam = UnityEngine.Camera.main ?? UnityEngine.Object.FindObjectOfType<UnityEngine.Camera>();
if (cam == null) throw new System.Exception("No camera found in scene.");

UnityEngine.RenderTexture prev = cam.targetTexture;
cam.targetTexture = rt;
cam.Render();

UnityEngine.RenderTexture.active = rt;
UnityEngine.Texture2D tex = new UnityEngine.Texture2D(width, height, UnityEngine.TextureFormat.RGB24, false);
tex.ReadPixels(new UnityEngine.Rect(0, 0, width, height), 0, 0);
tex.Apply();

// Restore state.
cam.targetTexture = prev;
UnityEngine.RenderTexture.active = null;
UnityEngine.Object.DestroyImmediate(rt);

// 3. Write PNG.
System.IO.File.WriteAllBytes(outputPath, tex.EncodeToPNG());
UnityEngine.Object.DestroyImmediate(tex);

UnityEngine.Debug.Log($"[VisualVerify] Screenshot saved: {outputPath}");
````

**Step-by-step workflow:**

1. Boot with `environment_start variant=gui` (GUI mode is required — see prerequisite above).
2. Wait for `unity-mcp-status-*.json` to appear in `.unity-mcp/` (bridge ready signal).
3. Enter Play mode via `manage_editor action=play` and wait for the transition to complete.
4. Allow the scene one or two frames to finish its startup sequence (if the project has a
   loading screen, wait for it to resolve — inspect a known UI element's active state via
   the components resource if you need to gate on scene readiness).
5. Execute the code block above via `execute_code action=execute` (note its `scripting_ext`
   group).
6. Read the path from the Debug.Log console output (`[VisualVerify] Screenshot saved: ...`) and inspect the image at `<worktree>/.unity-mcp/screenshot.png`.
7. Exit Play mode before making any structural edits.

> **GUI mode — dismiss blocking dialogs first.** Because this recipe runs exclusively
> in GUI mode, blocking modal dialogs can hang in-flight MCP calls until a human
> dismisses them. Dismiss any open dialogs before executing the code block above.
> See "GUI / interactive launch" for the full warning.

**Output path convention:** `<worktree>/.unity-mcp/screenshot.png`. The `.unity-mcp/`
directory is always present when the bridge is up (it is the status dir), so no directory
creation step is needed. Overwriting a previous capture is intentional — rename if you
need to retain multiple captures.

## Unity environments (worktree, main checkout, adopted)

`agent-worktree`'s Environment model addresses **three** kinds of Unity target the same
way — a linked worktree, the repo's own main checkout, or an editor someone already
started by hand through Unity Hub:

1. **Linked worktree** — `environment_start environment_id=<id> variant=default|gui`.
   Each worktree needs its **own** Unity Editor instance, and this session's MCP server
   must bind to *that* instance with no manual "select instance" UI step.
2. **Main checkout** — `environment_start checkout_path=<repo root> variant=default|gui`.
   Addresses the repo's own primary clone directly (no linked worktree involved) — the
   same `start:`/`stop:` contract runs there, with `<repo root>` standing in for
   `<worktree>` everywhere in this document.
3. **Unity Hub adoption** — a human (or a prior session) already started Unity through
   Hub, outside any `environment_start` call. See "Unity Hub adoption" below — this case
   needs no `environment_start` call at all.

All three are achieved with **status-dir isolation** — no runtime routing logic in the
skill.

### Status-dir isolation contract

Both halves of the Unity MCP point at the **same, worktree-local** status directory via
`UNITY_MCP_STATUS_DIR`:

- **MCP server side** — already wired in the manifests' `unityMCP.env`:
  - Claude: `UNITY_MCP_STATUS_DIR=${CLAUDE_PROJECT_DIR}/.unity-mcp` (absolute).
  - Codex: `UNITY_MCP_STATUS_DIR=.unity-mcp` (relative; the server resolves it against
    its working directory, which Codex sets to the project/worktree root).
- **Unity editor side** — the `start` step (below) launches Unity with the **absolute**
  `<worktree>/.unity-mcp`.

Both the Unity C# bridge and the Python server use this value **literally** (no `~`
expansion, no relative-path rewriting on the Unity side), so the editor launch must pass
an **absolute** path. When both sides resolve to the same directory, the server discovers
**exactly one** instance and auto-connects.

**No manifest change needed for the Environment model (ticket #47).** The manifests'
`UNITY_MCP_STATUS_DIR` above already reads as `<checkout>/.unity-mcp` on both hosts, and
"checkout" is exactly as true for the main checkout (`${CLAUDE_PROJECT_DIR}` = the repo
root when `environment_start` addresses it via `checkout_path=`) as it is for a linked
worktree (`${CLAUDE_PROJECT_DIR}` = the worktree root) — both cases resolve to the same
`<checkout>/.unity-mcp` pattern, so `.claude-plugin/plugin.json` and
`.codex-plugin/plugin.json` needed no edits for this migration.

### Unity Hub adoption

A Unity Editor a human started directly through **Unity Hub** — not via `environment_start`
— writes its status file into the **global** `~/.unity-mcp` directory (see Pitfall 5), not
the checkout-local one, so this session's MCP server would normally find no instance.
**Adoption** closes that gap by **copying** the matching Hub instance's
`unity-mcp-status-*.json` into `<checkout>/.unity-mcp/unity-mcp-status-adopted-<suffix>.json`,
so the same status-dir isolation contract above picks it up with no manual "select
instance" step. The copy is identified purely by its filename prefix
(`unity-mcp-status-adopted-`) — no JSON field, no reparse point, no Developer Mode or
Administrator privilege required on Windows, unlike the link-based design this replaced.

A match requires the Hub instance's `project_path` to resolve to `<checkout>/Assets` —
compared via a **normalized** key (absolutized, separators unified, trailing slash
trimmed, case-insensitive on Windows) rather than literal string equality, so a
forward-slash/backslash or drive-letter-casing difference between what Unity wrote and
what this session sees still matches — and a successful TCP connect to its reported port
within 500 ms. There is **no heartbeat-age gate**: liveness is the TCP probe alone,
re-run on every pass, which is both fresher and stricter evidence than a timestamp an
editor busy in a long import/compile might simply have stopped refreshing. A stale
adopted copy (its port no longer answers) is deleted; a live one survives even on a run
that cannot re-find its source; an existing adopted copy is overwritten with fresh
content whenever a live source is re-found.

**Reached from two callers, one implementation: `scripts/unity-mcp-adopt.ps1`.** This is a
real, plugin-owned script (not a here-string generated into `.seretos/`) that needs no
prepare-script precondition at all to run.

- **Claude Code — automatic, before every Unity MCP tool call.** A `PreToolUse` hook
  (`hooks/hooks.json`, matcher `mcp__.*unityMCP__.*`) runs
  `${CLAUDE_PLUGIN_ROOT}/scripts/unity-mcp-adopt.ps1` immediately before each unityMCP tool
  invocation — **not** the old `SessionStart` design, which could only adopt once at the
  start of a session and never noticed an editor started (or restarted) mid-session.
  `PreToolUse` timing catches exactly that case: restart the Hub editor mid-session, issue
  the next Unity tool call, and it is re-adopted before the call runs.
- **Both hosts — via the launcher.** `environment_start`'s own `default`/`gui` steps run
  the identical adoption pass as their preamble (the generated
  `.seretos/unity-mcp-launch.ps1` dot-sources a materialized copy of the same script,
  `.seretos/unity-mcp-adopt.ps1`) before deciding whether to launch a new Unity process at
  all (already-connected to an adopted or prior instance → no launch).

**Codex has no hook surface.** A Codex session never gets the automatic `PreToolUse` pass,
so on Codex a Hub-started editor is discovered only when `environment_start` next runs
(its launcher-preamble path above still adopts it before deciding to launch), or by
running `scripts/unity-mcp-adopt.ps1 -CheckoutPath <path>` by hand. Do not assume Codex
gets the same "found with no agent action" guarantee that Claude Code's hook provides.

**The script always exits 0**, even on an internal failure (it prints one
`unity-mcp-adopt:`-prefixed diagnostic line and continues) — a `PreToolUse` hook must
never block the tool call it runs ahead of. Rejected candidates (mismatched path, closed
port, unreadable JSON) are similarly explained on stdout rather than failing the run, one
line per candidate, naming both the rejection reason and — for a path mismatch — both
normalized keys, so a residual 8.3/junction/`subst` path difference is diagnosable from a
real run's output instead of silently producing no adoption.

**An unprepared repo may want `.unity-mcp/` in its own `.gitignore`** — adoption creates
that directory the first time it actually has something to copy, and
`scripts/prepare-unity-worktree.ps1` only adds that ignore entry as part of full
preparation (see "When to boot" above); a repo that only ever relies on Hub adoption and
never runs the prepare-script should add the entry itself.

### Version-pin strategy

The Python MCP server is pinned `mcpforunityserver==9.7.1` in both manifests
(`.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`), and the same value is the
`-UnityMcpVersion` default in `scripts/prepare-unity-worktree.ps1` (which pins the
`com.coplaydev.unity-mcp` bridge package a target Unity project depends on). A test
(`tests/prepare-unity-worktree.Tests.ps1`) asserts these three values agree with each
other — but that only proves **internal** consistency across this plugin's own
manifests/script, never that the pin matches whatever `mcpforunityserver` build is
actually installed and running for a given session, or whatever bridge-package commit a
given target Unity project happens to have checked out.

To check for drift: read the bridge-reported server version — the C# bridge logs its own
version and the expected server version on connect (check `<checkout>/.unity-mcp/editor.log`
or the Unity console), or call a Unity MCP tool that surfaces version info if the bridge
exposes one — and compare it against the `mcpforunityserver==X` pin above. A mismatch
between the bridge-reported version and the pin is a real signal (an out-of-date bridge
package in the target Unity project, or an out-of-date pin in this plugin) and is worth
investigating even though nothing here checks for it automatically; reconcile by either
updating `Packages/manifest.json`'s `com.coplaydev.unity-mcp` pin (`-Force` on the
prepare-script) or filing a ticket to bump the manifests' pin, whichever side is stale.

### When to boot (opt-in)

Preparing the worktree (running the prepare-script and committing the result) does **not**
require booting Unity. The decision point is whether the ticket actually needs the Unity
editor at all:

- **Editor-touching tickets** (scene edits, component changes, Play-mode testing, asset
  inspection): run `environment_start` to execute the `start:` block and boot Unity, then
  proceed with MCP tool calls.
- **Backend / non-editor tickets** (pure C# logic, server code, CI config, etc.): skip
  `environment_start` entirely — zero Unity processes, zero resource cost.

`environment_stop` tears Unity down cleanly and is safe to call even if Unity was never
started — the stop script is guarded by a pid-file existence check and exits silently when
the pid file is absent.

### The gate — when config is missing, run the prepare-script

When working in a worktree on a Unity project and the per-worktree Unity config is missing
or incomplete — i.e. `.seretos/worktree-setup.yml` has no `mcp-unity-bridge-*` block, or
`Packages/manifest.json` lacks `com.coplaydev.unity-mcp` — run the idempotent prepare-script
**once at repo level**, then commit:

```
pwsh -File ${CLAUDE_PLUGIN_ROOT}/scripts/prepare-unity-worktree.ps1
```

Existence, not content, decides whether it may touch `.seretos/worktree-setup.yml`: if
the file is absent, it creates it with the full managed block; if the file already
exists — with a managed block, a foreign contract, or no `start:`/`stop:` at all — the
script **never writes to it again**, under any flag or condition. It also never reads
the file's contents (ticket #39) — the only check made is whether the file exists, so
it gives no signal at all about what an existing file contains: no staleness warning, no
`isolation` check, nothing. `-Force` only reconciles a mismatched `com.coplaydev.unity-mcp`
pin in `Packages/manifest.json`; it has no effect on `.seretos/worktree-setup.yml`.
Because a worktree is a checkout of the same repo, the tracked files it writes inherit to
every future worktree — so you prepare once, not per worktree. Requires PowerShell 7+ for
the launched start/stop steps.

> **Stale or missing managed block.** If `.seretos/worktree-setup.yml` already exists but
> has no current managed block — it may predate the `UNITY_WORKTREE_CACHE_SERVER`
> conditional, the `UNITY_WORKTREE_MIRROR_LIBRARY` conditional, or the `COLD START:` hint,
> or it may never have had a managed block at all — the prepare-script gives **no signal**
> about it: it does not read the file, so it cannot tell you it's stale. To adopt a newer
> template, copy the `$managedBlock` here-string out of
> `scripts/prepare-unity-worktree.ps1` by hand and merge it into
> `.seretos/worktree-setup.yml` between the `# >>> agent-unity-wrapper managed` /
> `# <<< agent-unity-wrapper managed` markers (or paste the whole template if there is no
> `start:`/`stop:` yet), then commit. Re-running with `-Force` will not do it for you — the
> file already exists, so the script leaves it alone. A freshly-prepared repo already has
> all conditionals and needs no special action.

### Launch flow

1. `environment_start` (agent-worktree) runs the matching `start` step variant:
   - **`default`** (no variant arg, or `variant=default`): launches a **headless** Unity
     (`-batchmode -nographics -projectPath <worktree>`) — correct for CI and automated MCP
     tool calls.
   - **`gui`** (`variant=gui`): launches a **visible editor** (same flags minus `-batchmode`
     and `-nographics`) — for interactive editing, visual debugging, or Play-mode with
     graphics.
   Both variants set `UNITY_MCP_STATUS_DIR=<worktree>/.unity-mcp`,
   `UNITY_MCP_ALLOW_BATCH=1`, and
   `-executeMethod MCPForUnity.Editor.McpCiBoot.StartStdioForCi` to boot the in-editor
   bridge. The launched PID is recorded in `.unity-mcp/unity.pid`.
2. The bridge writes its status file (`unity-mcp-status-*.json`) into the worktree-local
   `.unity-mcp/` status dir. The appearance of any `unity-mcp-status-*.json` file in
   that directory is the authoritative readiness signal — once it exists, the bridge is
   up. This session's MCP server (pointed at the same dir) discovers the one instance
   and auto-connects.
3. `environment_stop` runs the `stop` step → kills the recorded Unity PID.

Set `UNITY_EDITOR_PATH` to your Unity Editor binary to override editor resolution; if unset,
the start step derives the version from `ProjectSettings/ProjectVersion.txt` and looks under
the Unity Hub default install path.

### Cold-start expectations & acceleration

On a fresh worktree with no `Library/` and no acceleration active, Unity must re-import
every asset from scratch. **Expected duration: 5–65 min on asset-heavy projects** — plan
accordingly before calling `environment_start`.

To reduce or eliminate the cold-import cost, set one or both of the following environment
variables **before** calling `environment_start`:

| Env var | What it does | When to use |
|---|---|---|
| `UNITY_WORKTREE_CACHE_SERVER=<host:port>` | Connects Unity to a Cache Server / Accelerator; already-built artefacts are served from the cache instead of reimporting | **Fastest** — requires a running server (see "Cache Server" section) |
| `UNITY_WORKTREE_MIRROR_LIBRARY=1` | Copies the main checkout's `Library/` into the worktree before opening Unity | **No server needed** — best-effort, see "Warm-start: Mirror Main Library" section |

When neither variable is set the managed start step emits a `COLD START:` warning so the
wait time is expected rather than a surprise.

> **Windows Defender exclusions.** On Windows, Defender's real-time scanning can roughly
> double the import time by scanning every asset file as Unity writes it. To halve the
> overhead, add the following paths to the Windows Defender exclusion list (Settings →
> Windows Security → Virus & threat protection → Exclusions):
>
> - **Worktree-store root** — the directory that holds all your agent worktrees.
> - **Unity install path** — the directory containing the Unity Editor binary (e.g.
>   `C:\Program Files\Unity\Hub\Editor\<version>`).
> - **Unity editor process** — the `Unity.exe` process.
>
> No PowerShell commands are provided here; add these exclusions manually through the
> Windows Security UI or your organisation's endpoint management tool.

> **Cross-drive caveat (Case #86).** If the worktree-store is on a different drive or
> path from the main checkout, `Library/ArtifactDB`'s stored absolute paths are
> invalidated and the Library mirror may still trigger a full reimport despite the copy.
> In that case prefer `UNITY_WORKTREE_CACHE_SERVER` (the Cache Server path is immune to
> project-path changes). See "Warm-start: Mirror Main Library" for the full Case #86
> details.

### GUI / interactive launch

By default `environment_start` boots Unity **headless** (`-batchmode -nographics`), which is
the correct mode for CI and automated MCP tool calls. When you need a visible editor
(interactive editing, visual debugging, Play-mode with graphics), use the named `gui`
variant:

```
environment_start environment_id=<id> variant=gui
```

No environment variable is needed. The `gui` start step runs the same launch sequence as
`default` but omits `-batchmode` and `-nographics`, so a full visible editor window
appears. On Windows `Start-Process -PassThru` detaches the editor from the terminal, so
the worktree shell remains usable. Trade-off: a visible editor window is created and the
full editor UI loads, which costs more memory and startup time than headless mode.

> **Warning — blocking modal dialogs in GUI mode.** In a visible editor (`variant=gui`),
> Unity can display blocking modal dialogs when the MCP triggers a save operation — for
> example "Scene(s) Have Been Modified", overwrite confirmations, or "Auto Save disabled".
> These modals halt Unity's main thread (which is also where the bridge runs), causing all
> in-flight MCP calls to hang until a human dismisses them. `UNITY_MCP_ALLOW_BATCH=1` is
> set by the managed block but does **not** suppress `EditorUtility.DisplayDialog` in GUI
> mode (it only affects Play-mode dialogs). For unattended automation, always use the
> `default` (headless) variant. See "Headless vs. GUI — automation workflow" below.

> **Repos prepared before named-variant steps were introduced:** the managed block must
> contain both `name: default` and `name: gui` start steps. If your repo was prepared by
> an older version of the prepare-script (the block has only a single unnamed start step or
> still contains `UNITY_WORKTREE_GUI`), the prepare-script gives no signal about it — it
> never reads an existing file's contents. To adopt the current block, copy the
> `$managedBlock` here-string out of `scripts/prepare-unity-worktree.ps1` by hand and
> merge it into `.seretos/worktree-setup.yml`, replacing the region between the
> `# >>> agent-unity-wrapper managed` / `# <<< agent-unity-wrapper managed` markers, then
> commit. Re-running with `-Force` will not do it for you. A freshly-prepared repo already
> has both steps and needs no special action.

> **Repos prepared before the launcher extraction (ticket #47):** the managed block's
> `start:` steps used to carry the full launch body inline; they are now a thin call into
> the generated `.seretos/unity-mcp-launch.ps1` script (resolve `$proj`, then run
> `.seretos/unity-mcp-launch.ps1 -Variant default|gui -CheckoutPath $proj`). Per the same
> existence-based ownership rule above, `prepare-unity-worktree.ps1` never rewrites an
> existing `.seretos/worktree-setup.yml` — not even to shrink an old inline `start:` body
> down to the new call-site — so a repo prepared before this ticket keeps its old inline
> body forever unless someone hand-merges it. To adopt the new launcher call-site, copy the
> shrunken `start:` steps out of `scripts/prepare-unity-worktree.ps1`'s `$managedBlock` and
> merge them into the managed region by hand, the same one-time procedure as above. A
> freshly-prepared repo already has the thin call-site and needs no action.

### Headless vs. GUI — automation workflow

- **Headless is the correct mode for all automated and agent-driven phases.** In
  `-batchmode`, `EditorUtility.DisplayDialog` returns its default value immediately with
  no UI, so save operations complete without blocking. Automated MCP tool calls run
  without human intervention.
- **GUI mode is for human review only.** MCP-triggered save operations (scene saves,
  asset writes, etc.) can produce blocking modal dialogs that halt Unity's main thread and
  hang all in-flight MCP calls until a human dismisses the dialog.
- **Recommended workflow:** run headless for all automated or agent-driven phases →
  `environment_stop` → relaunch with `variant=gui` for human review → `environment_stop` the
  GUI instance before resuming automated work.
- The long-term fix (non-interactive bridge save APIs) is an upstream
  `CoplayDev/unity-mcp` concern and is tracked separately.

### Standalone build (build-only, not MCP-connected)

A standalone build is a **third mode** alongside headless MCP and GUI. Unlike
those two, it is **not** MCP-connected: the project's own build script (e.g.
`build.ps1`) launches Unity as a separate `-batchmode -quit` process that writes
the artifact and exits cleanly. It obeys the **same exclusive-lockfile rule** as
the other two modes.

**Lockfile rule.** Unity holds an exclusive lock on `Temp/UnityLockfile` per
project path. Only one editor process — headless MCP, GUI, **or** a standalone
build — can own a worktree at a time. A second process fails immediately, logging
`HandleProjectAlreadyOpenInAnotherInstance` ("Multiple Unity instances cannot
open the same project").

**Recipe — run a standalone build while a session is active:**

1. `environment_stop` — terminate the running MCP or GUI session to release the
   lockfile.
2. Run your standalone build script (the separate `-batchmode -quit` process
   writes the artifact and exits, releasing the lock).
3. `environment_start variant=gui` (or `default`) — bring the editor back up
   afterwards if you need to continue working.

> **Disambiguating the two lockfile-error cases:** the error
> `HandleProjectAlreadyOpenInAnotherInstance` appears in two distinct situations.
> Here it means an *active* session legitimately holds the lock — resolve it with
> `environment_stop` as shown above. If the error appears after a force-killed
> editor with *no* active session, the cause is a *stale* `Temp/UnityLockfile`
> left behind — see the **"Stale-lockfile trap"** note below for that case.

### Cache Server (faster cold starts)

On asset-heavy projects, `environment_start` triggers a full asset re-import into the
worktree-local `Library/` on first open. This can take several minutes before the C#
bridge reports `ready`, and the cost is paid again for every new worktree. A Unity Cache
Server (legacy protocol) or Unity Accelerator (same wire protocol) caches compiled import
artefacts so subsequent worktrees pull from the cache instead of reimporting from scratch.

To opt in, set the environment variable **before** calling `environment_start`:

```
$env:UNITY_WORKTREE_CACHE_SERVER = 'localhost:10080'   # PowerShell
# or
export UNITY_WORKTREE_CACHE_SERVER=localhost:10080      # bash / zsh
```

When the variable is set, the managed `start:` step appends the following flags to the
Unity invocation:

```
-EnableCacheServer -cacheServerEndpoint <host:port>
```

The value is passed verbatim as the endpoint — use `host:port` format (e.g.
`localhost:10080` for a local Accelerator on its default port, or `192.168.1.5:10080`
for a shared server on the network). When the variable is empty, whitespace-only, or
unset, no cache-server flags are injected.

**Sharing `Library/` via symlink is NOT the chosen approach.** Unity acquires an
exclusive `Library/UnityLockfile` so only one editor process can own a `Library/` at a
time. `Library/ArtifactDB` is a single-writer database that corrupts under concurrent
access. When two worktrees track different commits their import metadata diverges,
causing constant cache thrashing if they share a `Library/`. A Cache Server / Accelerator
avoids all three problems: each worktree keeps its own `Library/` but pulls already-built
artefacts from the shared cache over a network socket.

**Running the Cache Server or Accelerator is out of scope for this plugin.** Setting up
and launching a Unity Accelerator (or the legacy Unity Cache Server) on your machine or
CI host is a separate step — see
[Unity Accelerator docs](https://docs.unity3d.com/Manual/UnityAccelerator.html) and
[Cache Server docs](https://docs.unity3d.com/Manual/CacheServer.html) upstream.

> **Cross-drive advantage.** Unlike the Library mirror, the Cache Server path is immune
> to project-path and cross-drive changes — `Library/ArtifactDB` path invalidation does
> not affect cache-server imports. If the worktree-store is on a different drive from the
> main checkout, the Cache Server is the more reliable acceleration choice. See the
> cross-drive callout at the top of the "Warm-start: Mirror Main Library" section below.

> **Repos prepared before this feature was added:** the `UNITY_WORKTREE_CACHE_SERVER`
> conditional lives inside the managed block written by the prepare-script. If your repo
> was prepared by an older version of the script, the existing managed block does not
> contain the conditional, so setting `UNITY_WORKTREE_CACHE_SERVER` is silently inert —
> and the prepare-script gives no signal about it, since it never reads an existing
> file's contents. To adopt the current block, copy the `$managedBlock` here-string out
> of `scripts/prepare-unity-worktree.ps1` by hand and merge it into
> `.seretos/worktree-setup.yml`, replacing the region between the
> `# >>> agent-unity-wrapper managed` / `# <<< agent-unity-wrapper managed` markers, then
> commit. Re-running with `-Force` will not do it for you. A freshly-prepared repo already
> has the conditional and needs no special action.

### Warm-start: Mirror Main Library

> **Cross-drive / cross-path caveat (Case #86).** `Library/ArtifactDB` stores absolute
> paths internally. If the worktree-store is on a different drive or at a different root
> path from the main checkout, those stored paths are invalidated and the mirror may still
> trigger a full reimport despite the copy — best-effort, can also work cross-drive
> (observed on Unity 2022.3.62f3), so measure rather than assume. When the worktree-store
> and main checkout are on different drives, prefer `UNITY_WORKTREE_CACHE_SERVER` (the
> Cache Server path is immune to project-path changes). See the "Cache Server (faster cold
> starts)" section above.

When a Unity Cache Server or Accelerator is not available, you can reduce cold-import
time by pre-populating a new worktree's `Library/` from the main checkout before
`environment_start` opens Unity there. This is a lightweight, zero-infrastructure
alternative to the Cache Server path (see above and #7). It is best-effort only — Unity
may still reimport some or all assets depending on what has changed between the main
checkout and the worktree branch.

**To activate it, set `UNITY_WORKTREE_MIRROR_LIBRARY` to `'1'` before calling `environment_start`:**

```powershell
$env:UNITY_WORKTREE_MIRROR_LIBRARY = '1'
```

Then call the `environment_start` MCP tool (with optional `variant=gui` for a visible editor).
After `environment_start` returns, clear the variable if you do not want subsequent starts to mirror:

```powershell
Remove-Item Env:UNITY_WORKTREE_MIRROR_LIBRARY -ErrorAction SilentlyContinue
```

The managed `start:` block written by `prepare-unity-worktree.ps1` checks this env var
automatically. When set to `1`, it:

1. Resolves the main checkout root via `git rev-parse --git-common-dir` (works from
   inside any worktree without baking in an absolute path).
2. Checks `<main-checkout>/Temp/UnityLockfile` — if the lockfile is present the mirror is
   skipped with a log message and Unity starts normally (no throw). Do not mirror while
   the main-checkout editor is running; partial copies produce corrupt import state.
3. Copies `<main-checkout>/Library/` into the worktree's `Library/` using
   `robocopy /MIR /MT:16` on Windows or `rsync -a --delete` on POSIX.
4. Proceeds to launch the Unity Editor as usual.

If `UNITY_WORKTREE_MIRROR_LIBRARY` is unset or empty the step is skipped entirely — no
change in behaviour for repos that do not opt in.

> **robocopy exit-code note:** robocopy uses non-standard exit codes. Exit code 1 means
> files were copied successfully (not an error). Exit codes 0–7 all indicate success;
> code 8 and above indicate a real error. The managed step treats any exit code ≤ 7 as
> success and throws on 8 or above.

**Stale-lockfile trap (force-killed editor):** if a previous editor run in the
**worktree** was killed forcefully, it may have left a stale lockfile at
`<worktree>/Temp/UnityLockfile`. Unity refuses to open the project while this file
exists, logging `HandleProjectAlreadyOpenInAnotherInstance`. The managed `start:` block
does not automatically clear the worktree lockfile — remove it manually before calling
`environment_start` if the previous run was force-killed.

**Honest caveat — this is best-effort, not guaranteed.** Real-world outcomes vary
depending on how much has changed since the mirrored `Library/` was built:

- Case #81 (branch-only delta, same project path): mirroring eliminated the cold import
  entirely — Unity opened and the bridge reported `ready` without reimporting.
- Case #86 (new project path / cross-drive): see the cross-drive callout at the top of
  this section — measure rather than assume, and prefer Cache Server when drives differ.

Mirroring may help or may not, depending on how much has changed since the `Library/`
was built. When it works, it can save several minutes; when it does not, the only cost
is the time spent copying.

The robust primary flow is plain `environment_start` (headless, no extra env vars required):
call `environment_start` and poll until a `unity-mcp-status-*.json` file appears in the
worktree-local `.unity-mcp/` directory — this is the authoritative readiness signal,
preferred over parsing `editor.log` for the `StartStdioForCi` banner. If a visible
editor is needed (interactive editing, visual debugging, Play-mode with graphics), use
`environment_start variant=gui` — but GUI mode is an optional variant, not a requirement
for reliable MCP usage. Mirroring is an optional accelerator applied *before*
`environment_start` (by the managed start step), not a replacement for the documented launch
flow.

> **Repos prepared before this feature was added:** the `UNITY_WORKTREE_MIRROR_LIBRARY`
> conditional lives inside the managed block written by the prepare-script. If your repo
> was prepared by an older version of the script, the existing managed block does not
> contain the conditional, so setting `UNITY_WORKTREE_MIRROR_LIBRARY=1` is silently
> inert — and the prepare-script gives no signal about it, since it never reads an
> existing file's contents. To adopt the current block, copy the `$managedBlock`
> here-string out of `scripts/prepare-unity-worktree.ps1` by hand and merge it into
> `.seretos/worktree-setup.yml`, replacing the region between the
> `# >>> agent-unity-wrapper managed` / `# <<< agent-unity-wrapper managed` markers, then
> commit. Re-running with `-Force` will not do it for you. A freshly-prepared repo already
> has the conditional and needs no special action.

For a durable, infrastructure-backed alternative that survives project-path changes and
branch switches, see the Cache Server section above.

## Pitfalls

1. **Unity-side bridge is a hard prerequisite — but a failed call is recoverable
   in-session.** The `MCP For Unity` C# package must be installed in the target Unity
   project (Package Manager → Add package by git URL:
   `https://github.com/CoplayDev/unity-mcp.git`), and the Unity editor must be open and
   running for a tool call to succeed. If the editor is not running, the call fails with:
   `No Unity Editor instances found. Please ensure Unity is running with MCP for Unity bridge.`
   **This is not fatal to the session.** The Python server rediscovers Unity instances by
   rescanning `UNITY_MCP_STATUS_DIR` on **every call** — only the status *directory* is
   fixed when the server starts, never a particular editor instance. So:
   - **On that error →** run `environment_start`, wait for a `unity-mcp-status-*.json` file
     to appear in `<worktree>/.unity-mcp/` (the readiness signal described under "Launch
     flow"), then **retry the same call**.
   - **No session restart, no host reconnect, no re-adding the MCP server.** A Unity that
     dropped and came back is picked up the same way — the upstream `refresh_unity` tool
     reports `recovered_from_disconnect: true` in that case.
   The tool list is a **static** server-side definition: `unityMCP`'s tools appear whether
   or not Unity is reachable. Seeing the tools does not mean the bridge is up, and a
   failing call does not mean the tool is missing — it means the bridge is unreachable
   *right now*. The one thing that genuinely cannot be fixed by retrying is a status-dir
   mismatch — see "Status-dir isolation contract" and Pitfall 5.

2. **Edit mode vs. Play mode.** Some tools (especially component writes and scene saves)
   behave differently or are outright unavailable while the editor is in Play mode.
   Always check the editor mode before performing structural edits; exit Play mode first
   if needed.

3. **Unsaved scene state.** The MCP reads and writes the live editor state. Changes made
   via `manage_components` or other mutation tools are visible immediately in the editor but
   are NOT saved to disk until an explicit save. If the editor crashes or the scene is
   reloaded without saving, those changes are lost. Always save explicitly after a
   meaningful batch of edits.

4. **No project-path flag in the manifest by design.** The manifest does not bake in a
   Unity project path. The Python server discovers the running Unity editor via the
   bridge socket automatically. Never add an env-specific *absolute* project path to the
   manifest — it would break the plugin for every other user. The one env the manifest
   *does* set, `UNITY_MCP_STATUS_DIR`, is intentional and host-portable
   (`${CLAUDE_PROJECT_DIR}/.unity-mcp` on Claude, cwd-relative `.unity-mcp` on Codex) — it
   enables per-checkout status-dir isolation (see "Unity environments (worktree, main
   checkout, adopted)"), not a hardcoded path.

5. **Raw `Unity.exe` start is invisible to this session's MCP server — unless adopted.**
   Launching the editor directly (including through Unity Hub) does not set
   `UNITY_MCP_STATUS_DIR`, so the bridge writes its status file into the global
   `~/.unity-mcp` instead of the checkout-local `.unity-mcp`. This session's MCP server
   finds no instance and every tool call fails with the same
   `No Unity Editor instances found. Please ensure Unity is running with MCP for Unity bridge.`
   error as in Pitfall 1 — but unlike the ordinary case, **retrying will keep failing** no
   matter how long Unity has been up, because the bridge wrote its status file to the
   wrong directory. Two fixes: stop the raw editor and restart it via `environment_start`
   (`checkout_path=<repo root>` for the main checkout, `environment_id=<id>` for a linked
   worktree); or, for a Unity Hub-started editor specifically, run **Unity Hub adoption**
   (below) instead of restarting it — Claude Code does this automatically before the very
   next Unity tool call (a `PreToolUse` hook, no privilege required), and
   `environment_start` itself runs the same adoption pass before deciding whether to
   launch a new process.

6. **Test Runner can freeze the editor.**
   On some Unity projects the Test Runner triggers a SQLite flush or a domain reload that
   hangs the editor process. If `run_tests` freezes or the editor becomes unresponsive
   during a test run, do not retry it: kill the Unity process, remove the stale
   `<worktree>/Temp/UnityLockfile`, and restart with `environment_start`. A cold-start
   Library re-import takes roughly 5–65 min depending on project size (see "Cold-start
   expectations & acceleration"). If the Test Runner remains unusable on a project, find
   another way to run its tests.
