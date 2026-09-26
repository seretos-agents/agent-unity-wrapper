---
name: unity-yaml-merge
description: Check whether a Unity YAML merge actually came out clean, resolve a conflict in a .unity scene, .prefab, .asset, or .controller file, investigate why a merged Unity branch reported git success despite broken fileID references, handle a conflicted Unity asset with no conflict markers, or set up a .gitattributes merge driver for a Unity project using UnityYAMLMerge (SmartMerge) — covers detecting fileID-graph conflicts that leave no markers, wiring merge=unityyamlmerge plus a matching git config driver entry, unattended-safe flags (--fallback none, -h, -p), the merge argument order and the %O %B %A %A placeholder mapping, and mechanically resolving conflicts via git stage extraction.
---

# unity-yaml-merge

## What this skill is for

Reach for this skill to determine whether a git merge of Unity YAML assets —
`.unity` scenes, `.prefab` prefabs, `.asset` ScriptableObjects, `.controller`
Animator controllers, and similar serialized types — actually came out clean,
or to resolve a conflict in one of them. These asset types are commonly
routed through the `UnityYAMLMerge` (SmartMerge) driver via `.gitattributes`
rather than git's default line-based merge, and that changes what a conflict
looks like: **conflicted output is still valid, markerless YAML**, so the
usual "grep for `<<<<<<<`" check gives a false negative. This also covers the
case where a Unity branch merge reported success in git despite leaving
broken `fileID` references, and setting up the `.gitattributes` merge driver
for a Unity project in the first place.

This skill documents the mechanism only — detection, wiring, invocation, and
resolution — for autonomous, unattended runs.

## Mental model

Unity's YAML serialization format represents each object in a `.unity`,
`.prefab`, `.asset`, or `.controller` file as a block identified by a
`fileID`, and objects reference each other by that ID rather than by textual
position. Line order inside the file carries no semantic meaning — Unity can
and does rewrite it freely on save. A line-based text merge (git's default)
operates purely on line position: two branches can each touch different
lines of the same file, merge without a single `<<<<<<<` marker, and still
leave the file **referentially broken** — for example, a component pointing
at a `fileID` that one branch deleted. Git reports this as a clean merge
because, from a pure text-diff point of view, it was.

`UnityYAMLMerge` (also called SmartMerge) exists to fix this: it parses the
file as a graph of objects and merges **per object**, so a change that
actually conflicts at the object level is reported as a conflict — instead
of silently producing line-clean-but-broken output.

## Detecting a conflict (the no-markers property)

When `.gitattributes` routes a YAML asset type through `merge=unityyamlmerge`,
a conflicted file contains **no conflict markers of any kind** — nothing
resembling git's usual `<<<<<<<` markers appears, even when the merge
genuinely failed to resolve. The driver resolves per object and, at any
point it cannot decide, writes out valid, parseable YAML holding one side's
value (see Flags below for which side). Because of that, **scanning file
content for `<<<<<<<` is the wrong check** for a UnityYAMLMerge-routed file:
that check finds nothing whether the merge succeeded or failed, so it
silently reports a false "clean" either way.

The correct detection ladder:

1. **`git status` / `git status --porcelain`** — an unresolved merge
   conflict for a tracked path shows as `UU <path>` (both-modified /
   unmerged) in the index, regardless of what the file's content looks
   like. This is the authoritative git-level signal.
2. **The driver's own stdout and exit code** — invoking `UnityYAMLMerge
   merge` directly (see Argument order below) prints its own success/
   conflict determination to stdout, and its exit code reflects the
   outcome. Measured as `0` = clean, non-zero = unresolved conflicts
   remained on Unity 2022.3.62f3 — treat the exact non-zero value as
   version-dependent and confirm against stdout together with the exit
   code rather than a hardcoded number.
3. **`-o <file>`** — pass this flag to have the driver write the list of
   unresolved conflicts to `<file>`, instead of (or in addition to) relying
   on the exit code alone; read that file to enumerate exactly which
   objects/fields are still conflicted.

## Wiring the merge driver

Two independent pieces must both be present for the routing to work as
intended — and how each half's absence fails is **not uniform** (see the
incomplete-wiring breakdown further down for the specifics):

1. **`.gitattributes`** — the asset-type patterns must route through the
   driver, e.g.:

   ```
   *.unity      merge=unityyamlmerge
   *.prefab     merge=unityyamlmerge
   *.asset      merge=unityyamlmerge
   *.controller merge=unityyamlmerge
   *.anim       merge=unityyamlmerge
   *.mat        merge=unityyamlmerge
   ```

2. **`merge.unityyamlmerge.driver`** — a matching git config entry naming
   the actual command line, e.g. on Windows:

   ```
   git config merge.unityyamlmerge.driver "\"C:\\Program Files\\Unity\\Hub\\Editor\\<version>\\Editor\\Data\\Tools\\UnityYAMLMerge.exe\" merge -h -p --force --fallback none <driver-placeholders>"
   ```

   (see Argument order below for the exact `<driver-placeholders>` line, and
   Flags below for what `--force` does).
   macOS and Linux ship the same tool as `UnityYAMLMerge` inside
   `Unity.app/Contents/Tools/` (macOS) or the Editor's `Data/Tools/`
   directory (Linux) respectively — same flags, same argument order, only
   the binary path differs.

Incomplete wiring does not fail in one consistent way — which of the two
pieces above is missing determines whether the failure is silent or loud:

1. **`.gitattributes` names `merge=unityyamlmerge`, but no
   `[merge "unityyamlmerge"]` section exists in git config at all.** This
   is a **silent no-op**: git falls back to its default line-based merge
   for that path, with no warning printed anywhere that the driver was
   never invoked. This is the dangerous case — the merge looks clean and
   nothing in the output says the driver never ran.
2. **A `[merge "unityyamlmerge"]` section exists in git config but has no
   `driver =` line** (e.g. only a `name = ...` entry, from a
   half-followed setup tutorial). This is **not** a silent no-op — it is a
   loud, immediate failure. Git prints:

   ```
   fatal: custom merge driver unityyamlmerge lacks command line.
   ```

   and the merge command aborts on the spot: no `MERGE_HEAD` gets created,
   no `UU` conflict state exists, there is nothing to `git add` or
   resolve. Recognize this exact message as the signal that the config
   section is present but incomplete, as distinct from case 1's silence.
3. **The reverse direction: `merge.unityyamlmerge.driver` is configured,
   but no `.gitattributes` line routes the path through
   `merge=unityyamlmerge`.** This behaves like case 1, not case 2 — git
   never looks up the `unityyamlmerge` driver for that path in the first
   place, because nothing tells it to consult it. The path merges through
   whatever attribute (or the default line-based merge) actually applies
   to it, silently, with the configured driver entry simply unused.

## Flags for unattended / agent use

- **`--fallback none`** — critical for any unattended run. The driver ships
  a default `mergespecfile.txt` listing fallback tools for conflicts it
  can't resolve on its own, and every one of them is an **interactive GUI**
  diff/merge tool (Beyond Compare, p4merge, Araxis, etc.). Without
  `--fallback none`, a conflict the driver can't auto-resolve launches one
  of those GUI windows and **blocks — the process just hangs, waiting for
  interactive input that never arrives** in an unattended run.
  `--fallback none` disables that fallback entirely: an unresolved conflict
  is reported (see Detecting a conflict above) instead of opening a window.
- **`-h`** — headless mode; suppresses any Unity GUI chrome the tool would
  otherwise try to show.
- **`-p`** — premerge. Without `-p`, an unresolved conflict point in the
  output is left holding the **base** (ancestor) value, not either side's
  change — easy to mistake for "theirs" or "mine" if you don't know to
  expect it. With `-p`, the driver runs its object-level premerge pass
  before falling back, so more conflicts resolve automatically and the ones
  that remain are marked as genuine conflicts rather than silently
  defaulting to the base value.
- **`--force`** — appears in real-world driver command lines, including
  the one reproduced against a live git config for the Unity version this
  skill's exit-code notes cite (2022.3.62f3), but is **not explained by
  Unity's own reference material** — the official manual lists it in a
  config example without documenting what it does. The commonly cited
  rationale, from community-documented driver setups rather than from
  Unity's own docs: git invokes the merge driver with randomly-named temp
  files via the `%O %B %A %A` placeholders (see Argument order below), and
  UnityYAMLMerge's file-type detection normally keys off the path's
  extension — a randomly-named temp file has no such extension for it to
  key off of. `--force` is understood to make the driver attempt the merge
  regardless of what type it inferred (or failed to infer) from the input
  paths. Treat that rationale as reasonably well corroborated but
  **unverified against Unity's own source or authoritative docs**, unlike
  the other flags on this list. The flag set documented here is not
  exhaustive either way — an example driver line copied from elsewhere may
  carry flags this skill doesn't cover.

## Argument order

The tool's command-line signature is:

```
UnityYAMLMerge merge [flags] <base> <left> <right> [dest]
```

`UnityYAMLMerge` defines **left = theirs** and **right = mine** — the
opposite of how many people instinctively read "left/right" in a three-way
merge. `dest` is optional; when omitted, the driver writes the merged
result over `<right>` (mine) in place.

Git's own merge-driver placeholders map onto that signature as:

- **`%O`** — the common ancestor (base) blob's temp-file path.
- **`%A`** — **our** version — both the "ours" input *and* the path git
  expects the final merged output to be written to (git substitutes the
  same `%A` twice for this reason).
- **`%B`** — **their** version — the incoming change from the branch being
  merged in.

Putting that mapping into the tool's `<base> <left> <right> [dest]` order
(left = theirs = `%B`, right = mine = `%A`) gives the correct driver command
line:

```
%O %B %A %A
```

— ancestor, theirs, mine, and mine again as the output destination.

## Resolving a conflict

When `git status` shows `UU <path>` for a UnityYAMLMerge-routed file:

1. **Extract the three stages.** The index still holds all three sides of
   the unresolved merge:
   - `git show :1:<path>` — the common ancestor (base) blob.
   - `git show :2:<path>` — our version (stage 2).
   - `git show :3:<path>` — their version (stage 3).

   Redirect each to a temp file, or use
   `git checkout-index --stage=all --temp -- <path>` to have git write out
   all three stage blobs to temp paths in one call.

2. **Re-run the driver manually on the extracted stages**, with the same
   unattended flags described above:

   ```
   UnityYAMLMerge merge -h -p --force --fallback none <base> <theirs> <mine> <dest>
   ```

   (base = stage 1, theirs = stage 3 / left, mine = stage 2 / right — see
   Argument order above.) Inspect the driver's stdout/exit code and any
   `-o <file>` output to determine whether it resolved cleanly this time.

3. **`git checkout --theirs <path>` / `git checkout --ours <path>`** select
   an entire stage's blob wholesale — stage 3 or stage 2 respectively.
   Under a merge driver, that is **not** the same thing as a per-object merge:
   it discards the other side's changes to the whole file rather than
   merging at the object level. Use it only when you've determined (via
   step 2, or otherwise) that one whole side should simply win.

4. **`git add <path>`** is the action that actually clears the `UU`
   state — writing a resolved file to the working tree is not enough by
   itself; the index must be updated to mark the path resolved.

5. **`git merge --abort`** unwinds the in-progress merge entirely,
   restoring the pre-merge working tree and index, if you need to back out
   rather than resolve.

**Exit codes.** `UnityYAMLMerge merge` exits `0` when the merge (or
premerge) completed with no unresolved conflicts, and non-zero when
conflicts remain unresolved — measured as `0`/`1` on Unity 2022.3.62f3.
Treat the specific non-zero value as version-dependent and confirm the
outcome via stdout / `-o <file>` rather than the exit code alone.

## Pitfalls

1. **A clean `git merge` exit code does not mean the driver ran.** Of the
   two incomplete-wiring cases above, the two cases where the driver never
   gets looked up (case 1/3) fail this way: git silently falls back to its
   own line-based merge,
   which can itself report success on a referentially broken file. (The
   incomplete-config-section case (case 2) does not — it fails loudly with
   `fatal: custom merge driver ... lacks command line.` before any merge
   happens at all.) Confirm the driver actually ran (its stdout, or the
   presence of `merge.unityyamlmerge.driver` in the repo's effective git
   config) rather than trusting a clean overall merge exit code alone.
2. **`--fallback none` must be present on every invocation, including
   manual re-runs.** Omitting it during manual resolution (step 2 above)
   reintroduces the GUI-launch hang described in "Flags for unattended /
   agent use", even if the original automated merge had it set correctly.
3. **Left/right is the reverse of what "ours/theirs" intuition suggests.**
   Re-check the Argument order mapping (left = theirs = `%B`, right = mine
   = `%A`) before hand-constructing a driver command line — swapping them
   produces a merge in the wrong direction with no error reported.
