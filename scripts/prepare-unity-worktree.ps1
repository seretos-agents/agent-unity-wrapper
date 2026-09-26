<#
.SYNOPSIS
  Idempotent, repo-level preparation for per-worktree Unity instances.

.DESCRIPTION
  Ticket #3 (per-worktree Unity instances); migrated in ticket #47 to the
  `agent-worktree` Environment model. Run this ONCE at the root of a Unity
  project repository. It prepares the repo so that `agent-worktree`'s
  `environment_start` / `environment_stop` bring a per-environment (linked
  worktree, or the main checkout via `checkout_path=<repo root>`), headless
  Unity Editor up and down, each bound to its own session's MCP server via
  status-dir isolation.

  Because a worktree is a checkout of the same repo, everything this script writes is
  tracked repo content that inherits to every future worktree automatically - so you
  prepare once at repo level, not per worktree. Commit the changes afterwards.

  `.seretos/worktree-setup.yml` is created only when absent. Once the file exists -
  whether it carries the managed block, a foreign contract, or no start:/stop: at all -
  the script never touches it again, under any flag or condition: no read, no append,
  no isolation flip, no reconcile, no advisory. Existence (`Test-Path`) is the only
  check ever made; the script does not open the file, so it cannot and does not
  comment on its contents. Re-running is a no-op once the repo is fully prepared.

  `.seretos/unity-mcp-launch.ps1` is the opposite ownership model (ticket #47):
  it is generated content owned outright by this plugin and is **always
  overwritten** on every run - even without `-Force` - carrying a
  "do not hand-edit" header. It holds the launch decision + Unity launch
  logic; Unity Hub adoption itself lives in the plugin-owned
  `scripts/unity-mcp-adopt.ps1` (ticket #52), materialized verbatim into
  `.seretos/unity-mcp-adopt.ps1` (same always-overwritten ownership model,
  see step 2 below) and dot-sourced by the generated launch script, so
  `environment_start`'s launcher and the `PreToolUse` hook
  (`hooks/hooks.json` -> `scripts/unity-mcp-adopt.ps1`) run the exact same
  adoption implementation without duplicating it.

  What it ensures:
    1. `.seretos/worktree-setup.yml` carries a managed `start:`/`stop:` block with two
       named start variants: `default` (headless) and `gui` (visible editor), each a
       thin call into `.seretos/unity-mcp-launch.ps1 -Variant <default|gui>` (below).
       `isolation` is set to `full` in a freshly-created contract (the contract forbids
       start/stop under `none`); an existing file's `isolation` is never read or edited.
    2. `.seretos/unity-mcp-adopt.ps1` is a verbatim copy of
       `scripts/unity-mcp-adopt.ps1` (ticket #52 Unity Hub adoption), always
       regenerated so an updated adoption implementation reaches every
       already-prepared repo the next time this script runs.
    3. `.seretos/unity-mcp-launch.ps1` carries the launch body: dot-sources its
       sibling `unity-mcp-adopt.ps1` and runs it as a preamble, then decides
       already-connected vs. launch, resolves the editor, sets
       `UNITY_MCP_STATUS_DIR=<checkout>/.unity-mcp` (absolute), boots via
       `-executeMethod MCPForUnity.Editor.McpCiBoot.StartStdioForCi`, mirrors
       the Library, applies the cache-server flags, and writes the
       `unity.pid` file. Always regenerated.
    4. The Unity MCP bridge package (`com.coplaydev.unity-mcp`) is referenced in
       `Packages/manifest.json`.
    5. `.gitignore` ignores the runtime `.unity-mcp/` status dir.

.PARAMETER RepoRoot
  Target Unity repository root. Defaults to `git rev-parse --show-toplevel` (works
  inside a worktree - its `.git` is a file, not a dir), falling back to the current
  directory.

.PARAMETER UnityMcpVersion
  Version tag for the bridge package / status-dir contract. Defaults to 9.7.1 to match
  the MCP server pin in the plugin manifests.

.PARAMETER Force
  Reconciles a mismatched `com.coplaydev.unity-mcp` pin in `Packages/manifest.json`.
  Without it, a version mismatch is reported and left untouched. -Force has no effect on
  `.seretos/worktree-setup.yml`: that file is created only when absent, and once it
  exists - with a managed block, a foreign contract, or no `start:`/`stop:` at all - it
  is never read or written to, by any flag. Existence, not content, is the only thing
  that is ever checked.

.NOTES
  Requires PowerShell 7+ for the launched start/stop steps (they run via `shell: pwsh`).
  The prepare-script itself runs under Windows PowerShell 5.1 or PowerShell 7+.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$UnityMcpVersion = '9.7.1',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# PowerShell 5.1 does not define $IsWindows; treat its absence as Windows.
$script:OnWindows = if ($null -ne $IsWindows) { $IsWindows } else { $true }

function Write-Info  { param($m) Write-Host "[prepare-unity-worktree] $m" }
function Write-Warn2 { param($m) Write-Warning "[prepare-unity-worktree] $m" }

function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

# --- Resolve repo root --------------------------------------------------------
if (-not $RepoRoot) {
    try {
        $top = (& git rev-parse --show-toplevel 2>$null)
        if ($LASTEXITCODE -eq 0 -and $top) { $RepoRoot = $top.Trim() }
    } catch { }
}
if (-not $RepoRoot) { $RepoRoot = (Get-Location).Path }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
Write-Info "Repo root: $RepoRoot"

if (-not (Test-Path (Join-Path $RepoRoot 'ProjectSettings'))) {
    Write-Warn2 "No 'ProjectSettings/' under repo root - this may not be a Unity project. Continuing anyway."
}

# The managed start/stop block. Single-quoted here-string: NO interpolation - every
# `$` below belongs to the pwsh that the worktree runner executes at start/stop time,
# not to this prepare-script.
$managedBlock = @'
# >>> agent-unity-wrapper managed: per-worktree Unity bridge (generated by agent-unity-wrapper; this project owns this block - edit it freely)
start:
  - name: default
    shell: pwsh
    run: |
      $ErrorActionPreference = 'Stop'
      $proj = if ($env:WORKTREE_PATH) { $env:WORKTREE_PATH } else { (Get-Location).Path }
      & (Join-Path $proj '.seretos/unity-mcp-launch.ps1') -Variant default -CheckoutPath $proj
  - name: gui
    shell: pwsh
    run: |
      $ErrorActionPreference = 'Stop'
      $proj = if ($env:WORKTREE_PATH) { $env:WORKTREE_PATH } else { (Get-Location).Path }
      & (Join-Path $proj '.seretos/unity-mcp-launch.ps1') -Variant gui -CheckoutPath $proj
stop:
  - name: mcp-unity-bridge-stop
    shell: pwsh
    run: |
      $ErrorActionPreference = 'SilentlyContinue'
      $proj = if ($env:WORKTREE_PATH) { $env:WORKTREE_PATH } else { (Get-Location).Path }
      $statusDir = Join-Path $proj '.unity-mcp'
      $pidFile = Join-Path $statusDir 'unity.pid'
      if (Test-Path $pidFile) {
          $unityPid = (Get-Content $pidFile | Select-Object -First 1)
          if ($unityPid) {
              $unityPid = $unityPid.Trim()
              if ($IsWindows) {
                  Start-Process -FilePath 'taskkill' -ArgumentList @('/PID', $unityPid, '/T', '/F') -NoNewWindow -Wait
              } else {
                  & kill -TERM $unityPid 2>$null
              }
          }
          Remove-Item -Force $pidFile
      }
# <<< agent-unity-wrapper managed
'@

# Shared launch body (ticket #47); Unity Hub adoption itself lives in the
# sibling scripts/unity-mcp-adopt.ps1 (ticket #52), dot-sourced below.
# Written into <repo>/.seretos/unity-mcp-launch.ps1 (always overwritten - see
# step 3 below). Single-quoted here-string: every `$` below belongs to the
# pwsh that later runs this file, not to this prepare-script.
$launchScript = @'
# >>> agent-unity-wrapper generated: unity-mcp-launch.ps1 - do not hand-edit; re-run scripts/prepare-unity-worktree.ps1 to update
<#
.SYNOPSIS
  Shared Unity MCP launch logic (ticket #47). Unity Hub adoption is
  delegated to the sibling unity-mcp-adopt.ps1 (ticket #52), dot-sourced by
  $PSScriptRoot so both live side by side in .seretos/.

.DESCRIPTION
  Generated into <repo>/.seretos/unity-mcp-launch.ps1 by
  scripts/prepare-unity-worktree.ps1 - always regenerated on every run, never
  hand-edited (unlike .seretos/worktree-setup.yml, which stays
  existence-based - see that script's header).

  The managed start: steps (default/gui) run it as a full launch:
    & unity-mcp-launch.ps1 -Variant <default|gui> -CheckoutPath <path>
  This runs the Hub-adoption pass as a preamble (via the dot-sourced
  unity-mcp-adopt.ps1), decides whether a live editor is already connected
  (adopted or this session's own prior instance), and launches Unity only
  when neither is true.

  A Hub-started editor is separately discovered before every Unity MCP tool
  call by hooks/hooks.json's PreToolUse hook, which runs
  scripts/unity-mcp-adopt.ps1 directly - not through this launch script.
#>
param(
    [ValidateSet('default', 'gui')]
    [string]$Variant = 'default',
    [string]$CheckoutPath,
    [string]$GlobalStatusDir = (Join-Path $HOME '.unity-mcp')
)

$ErrorActionPreference = 'Stop'
# PowerShell 5.1 does not define $IsWindows; treat its absence as Windows.
$script:OnWindows = if ($null -ne $IsWindows) { $IsWindows } else { $true }

# Unity Hub adoption (ticket #52) - Test-TcpPortOpen, Get-ComparablePath,
# Test-StatusFileLive, Find-AdoptionCandidate, Sync-AdoptedCopies,
# Invoke-UnityMcpAdoption, Get-UnityMcpLaunchDecision all come from here.
. (Join-Path $PSScriptRoot 'unity-mcp-adopt.ps1')

function Test-ShouldSkipLibraryMirror {
    # Ticket #47 / Finding stays fixed: the pre-existing IsNullOrEmpty/Test-Path
    # guard cannot detect $mainRoot -eq $proj (the resolved path DOES exist -
    # it IS the checkout itself, when run from the main checkout), so a
    # same-path guard is required in addition to that guard.
    param(
        [Parameter(Mandatory)][string]$mainRoot,
        [Parameter(Mandatory)][string]$proj
    )
    $mainRoot = $mainRoot.TrimEnd('\', '/')
    $proj     = $proj.TrimEnd('\', '/')
    return ($mainRoot -eq $proj)
}

function Invoke-LibraryRobocopy {
    # The actual robocopy/rsync call, extracted so it is mockable. Real source
    # existence is re-checked here (not in Invoke-LibraryMirror) so a mocked
    # call in tests always fires regardless of fixture contents.
    param(
        [Parameter(Mandatory)][string]$SourceLib,
        [Parameter(Mandatory)][string]$DestLib
    )
    if (-not (Test-Path -LiteralPath $SourceLib)) {
        Write-Host "UNITY_WORKTREE_MIRROR_LIBRARY=1: no Library/ found in main checkout ($SourceLib) - skipping"
        return
    }
    if ($script:OnWindows) {
        robocopy $SourceLib $DestLib /MIR /MT:16
        if ($LASTEXITCODE -gt 7) { throw "robocopy Library mirror failed (exit $LASTEXITCODE)" }
    } else {
        & rsync -a --delete "$SourceLib/" "$DestLib/"
        if ($LASTEXITCODE -ne 0) { throw "rsync Library mirror failed (exit $LASTEXITCODE)" }
    }
}

function Invoke-LibraryMirror {
    param(
        [Parameter(Mandatory)][string]$MainRoot,
        [Parameter(Mandatory)][string]$Proj
    )
    if (Test-ShouldSkipLibraryMirror -MainRoot $MainRoot -Proj $Proj) {
        Write-Host "UNITY_WORKTREE_MIRROR_LIBRARY=1: could not resolve a distinct main checkout (running from main checkout?) - skipping Library mirror"
        return
    }
    $srcLib = Join-Path $MainRoot 'Library'
    $dstLib = Join-Path $Proj 'Library'
    Write-Host "UNITY_WORKTREE_MIRROR_LIBRARY=1: mirroring Library from $srcLib -> $dstLib"
    Invoke-LibraryRobocopy -SourceLib $srcLib -DestLib $dstLib
    Write-Host "UNITY_WORKTREE_MIRROR_LIBRARY=1: Library mirror complete"
}

function Start-UnityEditor {
    # The actual Unity launch: editor resolution, cache server, Library
    # mirror, UNITY_MCP_STATUS_DIR env, pid file - moved here unchanged from
    # the old per-variant inline $managedBlock body (ticket #47). -batchmode
    # -nographics and the two "launched ..." messages are the only $Variant
    # branches; everything else exists once.
    param(
        [Parameter(Mandatory)][ValidateSet('default', 'gui')][string]$Variant,
        [Parameter(Mandatory)][string]$CheckoutPath,
        [Parameter(Mandatory)][string]$StatusDir
    )
    $proj = $CheckoutPath
    New-Item -ItemType Directory -Force -Path $StatusDir | Out-Null

    # Resolve the Unity Editor: UNITY_EDITOR_PATH wins; else derive from
    # ProjectVersion.txt against the Unity Hub default install location.
    $editor = $env:UNITY_EDITOR_PATH
    if ([string]::IsNullOrWhiteSpace($editor)) {
        $verFile = Join-Path $proj 'ProjectSettings/ProjectVersion.txt'
        if (-not (Test-Path $verFile)) {
            throw "UNITY_EDITOR_PATH unset and ProjectSettings/ProjectVersion.txt not found"
        }
        $verLine = Get-Content $verFile | Where-Object { $_ -match '^m_EditorVersion:' } | Select-Object -First 1
        $ver = ($verLine -replace 'm_EditorVersion:\s*', '').Trim()
        if ($script:OnWindows) { $editor = "C:/Program Files/Unity/Hub/Editor/$ver/Editor/Unity.exe" }
        elseif ($IsMacOS)      { $editor = "/Applications/Unity/Hub/Editor/$ver/Unity.app/Contents/MacOS/Unity" }
        else                   { $editor = "$HOME/Unity/Hub/Editor/$ver/Editor/Unity" }
    }
    if (-not (Test-Path $editor)) {
        throw "Unity Editor not found at '$editor' - set UNITY_EDITOR_PATH to your editor binary"
    }

    # Status-dir isolation: both the editor bridge and the session MCP server must
    # point at this exact ABSOLUTE dir so the server discovers exactly one instance
    # and auto-connects with no UI step.
    $env:UNITY_MCP_STATUS_DIR = $StatusDir
    $env:UNITY_MCP_ALLOW_BATCH = '1'
    $log = Join-Path $StatusDir 'editor.log'
    $unityArgs = @(
        '-logFile', $log,
        '-projectPath', $proj,
        '-executeMethod', 'MCPForUnity.Editor.McpCiBoot.StartStdioForCi'
    )
    if ($Variant -eq 'default') {
        $unityArgs = @('-batchmode', '-nographics') + $unityArgs
    }
    # GUI mode: UNITY_MCP_ALLOW_BATCH=1 does not suppress EditorUtility.DisplayDialog;
    # use the default (headless) variant for unattended automation.

    if ($env:UNITY_WORKTREE_MIRROR_LIBRARY -eq '1') {
        $gitCommonDir = (& git rev-parse --git-common-dir 2>$null)
        if ($LASTEXITCODE -eq 0 -and $gitCommonDir) {
            $gitCommonDirAbs = Convert-Path -LiteralPath $gitCommonDir.Trim() -ErrorAction SilentlyContinue
            $mainRoot = if ($gitCommonDirAbs) { Split-Path -Parent $gitCommonDirAbs } else { $null }
            if ([string]::IsNullOrEmpty($mainRoot) -or -not (Test-Path $mainRoot)) {
                Write-Host "UNITY_WORKTREE_MIRROR_LIBRARY=1: could not resolve a distinct main checkout (running from main checkout?) - skipping Library mirror"
            } else {
                $lockfile = Join-Path $mainRoot 'Temp/UnityLockfile'
                if (Test-Path $lockfile) {
                    Write-Host "UNITY_WORKTREE_MIRROR_LIBRARY=1: main checkout Unity is running (lockfile present) - skipping Library mirror"
                } else {
                    Invoke-LibraryMirror -MainRoot $mainRoot -Proj $proj
                }
            }
        } else {
            Write-Host "UNITY_WORKTREE_MIRROR_LIBRARY=1: could not resolve main checkout via git rev-parse - skipping Library mirror"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:UNITY_WORKTREE_CACHE_SERVER)) {
        $unityArgs += @('-EnableCacheServer', '-cacheServerEndpoint', $env:UNITY_WORKTREE_CACHE_SERVER)
        Write-Host "UNITY_WORKTREE_CACHE_SERVER=$($env:UNITY_WORKTREE_CACHE_SERVER): enabling asset cache server"
    }
    if ([string]::IsNullOrWhiteSpace($env:UNITY_WORKTREE_CACHE_SERVER) -and $env:UNITY_WORKTREE_MIRROR_LIBRARY -ne '1') { Write-Host "COLD START: No acceleration active. Cold import on an asset-heavy project can take 5-65 min. Set UNITY_WORKTREE_CACHE_SERVER=<host:port> (fastest) or UNITY_WORKTREE_MIRROR_LIBRARY=1 (no server needed). On Windows, add the worktree-store root and Unity install path to Windows Defender exclusions to halve scan overhead." }

    $p = Start-Process -FilePath $editor -ArgumentList $unityArgs -PassThru
    Set-Content -Path (Join-Path $StatusDir 'unity.pid') -Value $p.Id
    if ($Variant -eq 'default') {
        Write-Host "Unity bridge launched headless (pid $($p.Id)) -> $StatusDir"
    } else {
        Write-Host "Unity bridge launched with visible editor (pid $($p.Id)) -> $StatusDir"
    }
}

function Invoke-UnityMcpLauncherFlow {
    # Full launch flow (the managed start: steps use this): adopt, decide,
    # and launch only if needed. -Variant is declared explicitly (review
    # round 1 nit) rather than relying on implicit PowerShell scope chaining
    # up to the top-level param() block.
    param(
        [Parameter(Mandatory)][string]$CheckoutPath,
        [Parameter(Mandatory)][string]$GlobalStatusDir,
        [ValidateSet('default', 'gui')][string]$Variant = 'default'
    )
    # Diagnostics for any rejected candidate are deliberately NOT suppressed
    # here - they flow through to this launcher's own stdout too, so a human
    # watching environment_start's launch output sees the same rejection
    # reasons the PreToolUse hook would print (ticket #52 / R9).
    Invoke-UnityMcpAdoption -CheckoutPath $CheckoutPath -GlobalStatusDir $GlobalStatusDir
    $statusDir = Join-Path $CheckoutPath '.unity-mcp'
    $decision = Get-UnityMcpLaunchDecision -StatusDir $statusDir
    if ($decision -eq 'already-connected') {
        # Ticket #52: adoption is a COPY, not a symlink - self-identified by
        # filename (unity-mcp-status-adopted-*.json) rather than
        # Test-EntryIsLink/reparse-point inspection (that whole apparatus is
        # gone; see scripts/unity-mcp-adopt.ps1).
        $realFile = Get-ChildItem -LiteralPath $statusDir -Force -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^unity-mcp-.*status.*\.json$' -and $_.Name -notmatch '^unity-mcp-status-adopted-' } |
            Select-Object -First 1
        if ($realFile) {
            Write-Host "Unity bridge already running for this checkout (this session's own prior instance) -> $statusDir"
        } else {
            Write-Host "Already connected to an adopted Unity Hub instance for this checkout -> $statusDir"
        }
        return
    }
    Start-UnityEditor -Variant $Variant -CheckoutPath $CheckoutPath -StatusDir $statusDir
}

# Entry point - only runs on a real invocation (`&` / direct execution), never
# when dot-sourced (". path") purely to load the functions above for testing
# or mocking; $MyInvocation.InvocationName is '.' in that case.
if ($MyInvocation.InvocationName -ne '.') {
    if (-not $CheckoutPath) {
        throw "unity-mcp-launch.ps1: -CheckoutPath is required"
    }
    # Canonicalize before use: a caller invoking this manually with a relative
    # path (e.g. -CheckoutPath .) must still get the plan's "UNITY_MCP_STATUS_DIR
    # is absolute in both cases" guarantee. [System.IO.Path]::GetFullPath is
    # deliberately NOT used here: it resolves against .NET's process-wide
    # [Environment]::CurrentDirectory, which PowerShell 7+'s Set-Location does
    # NOT keep in sync with $PWD (verified empirically - GetFullPath('leaf')
    # after Set-Location into a different directory still resolved against the
    # process's original directory, not $PWD). Resolve-Path IS PowerShell
    # provider-aware and tracks $PWD correctly, but throws when the path
    # doesn't exist yet - so it's used only when the path already exists;
    # otherwise fall back to joining against the current PowerShell location
    # (Get-Location, not GetFullPath) so a not-yet-created checkout still
    # canonicalizes correctly. An already-absolute path is left untouched
    # (Join-Path would otherwise mangle a rooted child path - verified
    # empirically: Join-Path 'C:\a' 'D:\b' -> 'C:\a\D:\b', not 'D:\b').
    if (-not [System.IO.Path]::IsPathRooted($CheckoutPath)) {
        if (Test-Path -LiteralPath $CheckoutPath) {
            $CheckoutPath = (Resolve-Path -LiteralPath $CheckoutPath).Path
        } else {
            $CheckoutPath = Join-Path -Path (Get-Location).Path -ChildPath $CheckoutPath
        }
    }
    Invoke-UnityMcpLauncherFlow -CheckoutPath $CheckoutPath -GlobalStatusDir $GlobalStatusDir -Variant $Variant
}
# <<< agent-unity-wrapper generated
'@

# Freshly-created contract (when no .seretos/worktree-setup.yml exists yet).
$freshContract = @"
version: 1
isolation: full

$managedBlock
"@

# --- 1. .seretos/worktree-setup.yml ------------------------------------------
$setupPath = Join-Path $RepoRoot '.seretos/worktree-setup.yml'
if (-not (Test-Path $setupPath)) {
    Write-Utf8NoBom -Path $setupPath -Content $freshContract
    Write-Info "Created .seretos/worktree-setup.yml with managed Unity start/stop block."
}
else {
    # The file already exists. Existence, not content, is the sole ownership rule
    # (ticket #37): no append, no isolation flip, no reconcile, under any flag. Ticket
    # #39 carries this the rest of the way - the script does not read the file at all,
    # so it cannot classify it as missing/foreign/outdated, and it never comments on
    # `isolation` or any other field. Test-Path above is the only permitted check.
    Write-Info ".seretos/worktree-setup.yml exists - leaving it untouched."
}

# --- 2. Packages/manifest.json (bridge package) ------------------------------
$manifestPath = Join-Path $RepoRoot 'Packages/manifest.json'
$pkgName = 'com.coplaydev.unity-mcp'
$pkgUrl  = "https://github.com/CoplayDev/unity-mcp.git?path=/MCPForUnity#v$UnityMcpVersion"
if (Test-Path $manifestPath) {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if (-not $manifest.dependencies) {
        $manifest | Add-Member -NotePropertyName dependencies -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $hasPkg = $manifest.dependencies.PSObject.Properties.Name -contains $pkgName
    if ($hasPkg) {
        $currentPin = $manifest.dependencies.$pkgName
        if ($currentPin -eq $pkgUrl) {
            Write-Info "Packages/manifest.json already references $pkgName at the correct version."
        } elseif ($Force) {
            $manifest.dependencies.$pkgName = $pkgUrl
            Write-Utf8NoBom -Path $manifestPath -Content (($manifest | ConvertTo-Json -Depth 32))
            Write-Info "Updated $pkgName pin from '$currentPin' to '$pkgUrl' (-Force)."
        } else {
            # Extract the #fragment for a readable current-vs-expected display.
            $currentTag  = if ($currentPin  -match '#(.+)$') { $Matches[1] } else { $currentPin }
            $expectedTag = if ($pkgUrl      -match '#(.+)$') { $Matches[1] } else { $pkgUrl }
            Write-Warn2 "Packages/manifest.json references $pkgName at a different version: current='$currentTag' ($currentPin), expected='$expectedTag' ($pkgUrl). Re-run with -Force to reconcile."
        }
    } else {
        $manifest.dependencies | Add-Member -NotePropertyName $pkgName -NotePropertyValue $pkgUrl -Force
        Write-Utf8NoBom -Path $manifestPath -Content (($manifest | ConvertTo-Json -Depth 32))
        Write-Info "Added $pkgName -> $pkgUrl to Packages/manifest.json."
    }
} else {
    Write-Warn2 "No Packages/manifest.json found - add the bridge package manually:"
    Write-Warn2 "  `"$pkgName`": `"$pkgUrl`""
}

# --- 3. .gitignore (.unity-mcp runtime dir) ----------------------------------
$gitignorePath = Join-Path $RepoRoot '.gitignore'
$ignoreLine = '.unity-mcp/'
$gi = if (Test-Path $gitignorePath) { Get-Content -LiteralPath $gitignorePath -Raw } else { '' }
if ($gi -match '(?m)^\s*/?\.unity-mcp/?\s*$') {
    Write-Info ".gitignore already ignores .unity-mcp/."
} else {
    $newGi = ($gi.TrimEnd() + "`n`n# Per-worktree Unity MCP status dir (agent-unity-wrapper)`n$ignoreLine`n").TrimStart("`n")
    Write-Utf8NoBom -Path $gitignorePath -Content $newGi
    Write-Info "Added $ignoreLine to .gitignore."
}

# --- 4. .seretos/unity-mcp-adopt.ps1 (ticket #52 - always regenerated) ------
# A verbatim copy of scripts/unity-mcp-adopt.ps1 (the authoritative,
# plugin-owned implementation) - read from $PSScriptRoot so this works
# regardless of how the plugin is invoked. Same always-overwritten ownership
# model as unity-mcp-launch.ps1 below: environment_start's launcher runs
# inside the target repo with no ${CLAUDE_PLUGIN_ROOT} and no plugin path at
# all, so this mirror is the only way its preamble can dot-source the exact
# same adoption logic the PreToolUse hook runs directly via
# ${CLAUDE_PLUGIN_ROOT}/scripts/unity-mcp-adopt.ps1. It is a generated mirror
# of one source file, never an editable second implementation.
$adoptScriptSource = Join-Path $PSScriptRoot 'unity-mcp-adopt.ps1'
$adoptScriptDest   = Join-Path $RepoRoot '.seretos/unity-mcp-adopt.ps1'
if (Test-Path -LiteralPath $adoptScriptSource) {
    $adoptScriptContent = Get-Content -LiteralPath $adoptScriptSource -Raw
    Write-Utf8NoBom -Path $adoptScriptDest -Content $adoptScriptContent
    Write-Info "Wrote .seretos/unity-mcp-adopt.ps1 (always regenerated)."
} else {
    Write-Warn2 "scripts/unity-mcp-adopt.ps1 not found next to this script - skipping .seretos/unity-mcp-adopt.ps1 materialization."
}

# --- 5. .seretos/unity-mcp-launch.ps1 (ticket #47 - always regenerated) -----
# Unlike .seretos/worktree-setup.yml above, this file is owned outright by
# this plugin: it is written on every run, with no -Force gate and no
# existence check, so an update to the launch logic reaches every
# already-prepared repo the next time this script runs. Never added to
# .gitignore - it is tracked repo content, matching $managedBlock's model.
$launchScriptPath = Join-Path $RepoRoot '.seretos/unity-mcp-launch.ps1'
Write-Utf8NoBom -Path $launchScriptPath -Content $launchScript
Write-Info "Wrote .seretos/unity-mcp-launch.ps1 (always regenerated)."

Write-Info "Done. Review and commit the changes, then environment_start will boot Unity per environment (linked worktree, or the main checkout via checkout_path)."
