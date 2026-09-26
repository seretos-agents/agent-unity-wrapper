#Requires -Version 5.1
<#
.SYNOPSIS
  Unity Hub adoption (ticket #52): finds a Hub-started (or otherwise
  externally-started) Unity editor whose global status file matches this
  checkout, and copies that status file into <checkout>/.unity-mcp so the
  checkout-local status-dir isolation contract picks it up automatically.

.DESCRIPTION
  A real, dot-sourceable *and* directly invokable script - not a here-string
  generated into .seretos/. Two callers reach it:
    - `hooks/hooks.json`'s PreToolUse hook, matched on the unityMCP tools,
      runs it before every Unity MCP tool call (`${CLAUDE_PLUGIN_ROOT}/scripts/unity-mcp-adopt.ps1`).
    - `scripts/prepare-unity-worktree.ps1` materializes this file verbatim
      into `<repo>/.seretos/unity-mcp-adopt.ps1`, and the generated
      `.seretos/unity-mcp-launch.ps1` dot-sources that sibling copy so
      `environment_start`'s launcher runs the identical adoption pass as its
      preamble before deciding whether to launch a new Unity process.
  A human, or a Codex session (no hook surface), can also run it by hand:
    pwsh -NoProfile -File scripts/unity-mcp-adopt.ps1 -CheckoutPath <path>

  Algorithm, run once per invocation:
    1. In `<CheckoutPath>/.unity-mcp` (if it exists), probe each
       `unity-mcp-status-adopted-*.json` - delete only the dead ones (port no
       longer answers); a live one is kept even when this run cannot re-obtain
       its source.
    2. If any *real* (non-adopted) `unity-mcp-*status*.json` in that same
       directory is live, stop - nothing else happens (the prepared/worktree/
       environment_start case: this session's own instance is already
       connected).
    3. Otherwise scan `<GlobalStatusDir>` (default `~/.unity-mcp`) for
       `unity-mcp-*status*.json` files whose normalized `project_path` equals
       `<CheckoutPath>/Assets` and whose `unity_port` accepts a TCP connect
       within 500 ms; copy the first match (name-sorted, deterministic) to
       `<CheckoutPath>/.unity-mcp/unity-mcp-status-adopted-<suffix>.json`
       (`<suffix>` = the source file's basename minus the `unity-mcp-status-`
       prefix), creating the status dir only at that point - an unprepared
       repo gets no stray untracked directory when there is nothing to adopt.
       An existing adopted copy at the same destination is overwritten with
       fresh content when a live source is re-found.

  Status file only, no port file, no symlink: upstream's discovery globs
  `unity-mcp-status-*.json` and reads `unity_port`/`last_heartbeat` from its
  contents directly - there is no hashed port-file precondition to satisfy.
  Liveness is a TCP probe of `unity_port`, not a heartbeat-age gate: a copy
  carries whatever `last_heartbeat` the source editor last wrote (copying
  does not refresh it), so an age gate would only measure the *editor's*
  write cadence, not whether it is actually reachable right now - a socket
  probe re-run on every call is both fresher and stricter evidence.

  Diagnostics for rejected candidates go to stdout via Write-Output, one line
  per event, prefixed `unity-mcp-adopt:`; nothing is printed when there is
  nothing to report. This keeps the script silent as a PreToolUse hook (whose
  stdout is transcript-only, not injected context) while remaining
  capturable by `$out = & $script ... | Out-String` in tests.

  The whole body runs inside a try/catch and this script **always exits 0**
  on a real invocation (never when dot-sourced) - a PreToolUse hook must
  never block a tool call, so an internal failure here prints one line and
  is otherwise swallowed rather than surfaced as a blocking error.

.PARAMETER CheckoutPath
  The checkout to adopt into. Defaults to `$env:CLAUDE_PROJECT_DIR`, then the
  current working directory.

.PARAMETER GlobalStatusDir
  Where Unity Hub-started (and other externally-started) editors write their
  status files. Defaults to `<HOME>/.unity-mcp`.
#>
[CmdletBinding()]
param(
    [string]$CheckoutPath,
    [string]$GlobalStatusDir
)

if (-not $CheckoutPath) {
    $CheckoutPath = if ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR } else { (Get-Location).Path }
}
if (-not $GlobalStatusDir) {
    $GlobalStatusDir = Join-Path $HOME '.unity-mcp'
}

# Shared default - both Find-AdoptionCandidate and Test-StatusFileLive accept
# an override for tests; real callers always use this value.
$PortProbeTimeoutMs = 500

function Test-TcpPortOpen {
    # A bare, non-blocking-with-timeout TCP connect probe - shared by
    # Test-StatusFileLive (checkout-local files) and Find-AdoptionCandidate
    # (global scan), so both agree on exactly one definition of "reachable".
    param(
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMs = 500
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        try { $client.EndConnect($async) } catch { return $false }
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Get-ComparablePath {
    # The single path-comparison normalizer (ticket #52 / R2): trim
    # whitespace and surrounding quotes, absolutize via
    # [System.IO.Path]::GetFullPath() (collapses . / .. segments, unifies
    # separators), unify to forward slashes, drop a trailing separator.
    # Deliberately does NOT fold case - case-insensitivity belongs to the
    # *comparison* (Test-ComparablePathEquals below), not the normalizer, so
    # a caller that wants a case-preserving key (e.g. for a diagnostic
    # message) still gets one.
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $p = $Path.Trim()
    $p = $p.Trim('"', "'")
    if ([string]::IsNullOrWhiteSpace($p)) { return '' }
    try {
        $full = [System.IO.Path]::GetFullPath($p)
    } catch {
        # A genuinely unparsable path (illegal characters, etc.) - fall back
        # to a best-effort normalization rather than throwing; the caller
        # decides whether the result is usable.
        $full = $p
    }
    $full = $full.Replace('\', '/')
    return $full.TrimEnd('/')
}

function Test-ComparablePathEquals {
    # Case-insensitive on Windows (OrdinalIgnoreCase), case-sensitive
    # elsewhere - the ONE comparison rule for two Get-ComparablePath keys.
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$A,
        [Parameter(Mandatory)][AllowEmptyString()][string]$B
    )
    if ([string]::IsNullOrEmpty($A) -or [string]::IsNullOrEmpty($B)) { return $false }
    if ([System.IO.Path]::DirectorySeparatorChar -eq '\') {
        return [string]::Equals($A, $B, [System.StringComparison]::OrdinalIgnoreCase)
    }
    return [string]::Equals($A, $B, [System.StringComparison]::Ordinal)
}

function Test-StatusFileLive {
    # Liveness = parses + has unity_port + the port answers. No heartbeat-age
    # gate (ticket #52 / R11 - see script header). A malformed/non-numeric
    # port must be treated as "not live", never allowed to throw and abort a
    # caller's scanning loop.
    param(
        [Parameter(Mandatory)][string]$StatusFilePath,
        [int]$PortProbeTimeoutMs = $PortProbeTimeoutMs
    )
    $data = $null
    try { $data = Get-Content -LiteralPath $StatusFilePath -Raw | ConvertFrom-Json } catch { return $false }
    if (-not $data.unity_port) { return $false }
    $port = $null
    try { $port = [int]$data.unity_port } catch { return $false }
    return (Test-TcpPortOpen -Port $port -TimeoutMs $PortProbeTimeoutMs)
}

function Find-AdoptionCandidate {
    # Scans GlobalStatusDir for a unity-mcp-*status*.json file whose
    # normalized project_path matches <CheckoutPath>/Assets and whose port is
    # live; returns @{ StatusFile; Port; Suffix } for the first match
    # (name-sorted, deterministic), or $null. -Diagnostics is optional: when
    # supplied (a System.Collections.Generic.List[string]) one line is
    # appended per rejected candidate, naming the file and a reason token
    # (`unreadable` / `project_path mismatch` / `port closed`) - kept OUT of
    # this function's own return/output stream on purpose, so a direct caller
    # (this script's own R2 tests) still gets exactly one clean return value
    # regardless of how many candidates were rejected along the way.
    param(
        [Parameter(Mandatory)][string]$CheckoutPath,
        [Parameter(Mandatory)][string]$GlobalStatusDir,
        [int]$PortProbeTimeoutMs = $PortProbeTimeoutMs,
        [System.Collections.Generic.List[string]]$Diagnostics
    )
    if (-not (Test-Path -LiteralPath $GlobalStatusDir)) { return $null }
    $targetKey = Get-ComparablePath -Path (Join-Path $CheckoutPath 'Assets')
    $candidates = @(
        Get-ChildItem -LiteralPath $GlobalStatusDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^unity-mcp-.*status.*\.json$' } |
            Sort-Object Name
    )
    foreach ($sf in $candidates) {
        $data = $null
        try { $data = Get-Content -LiteralPath $sf.FullName -Raw | ConvertFrom-Json } catch {
            if ($null -ne $Diagnostics) { $Diagnostics.Add("unity-mcp-adopt: $($sf.Name) - unreadable (invalid JSON)") }
            continue
        }
        $rawProjectPath = [string]$data.project_path
        if ([string]::IsNullOrWhiteSpace($rawProjectPath)) {
            if ($null -ne $Diagnostics) { $Diagnostics.Add("unity-mcp-adopt: $($sf.Name) - unreadable (empty project_path)") }
            continue
        }
        $candidateKey = Get-ComparablePath -Path $rawProjectPath
        if (-not (Test-ComparablePathEquals -A $candidateKey -B $targetKey)) {
            if ($null -ne $Diagnostics) { $Diagnostics.Add("unity-mcp-adopt: $($sf.Name) - project_path mismatch (target=$targetKey, candidate=$candidateKey)") }
            continue
        }
        if (-not $data.unity_port) {
            if ($null -ne $Diagnostics) { $Diagnostics.Add("unity-mcp-adopt: $($sf.Name) - unreadable (missing unity_port)") }
            continue
        }
        $port = $null
        try { $port = [int]$data.unity_port } catch {
            if ($null -ne $Diagnostics) { $Diagnostics.Add("unity-mcp-adopt: $($sf.Name) - unreadable (invalid unity_port)") }
            continue
        }
        if (-not (Test-TcpPortOpen -Port $port -TimeoutMs $PortProbeTimeoutMs)) {
            if ($null -ne $Diagnostics) { $Diagnostics.Add("unity-mcp-adopt: $($sf.Name) - port closed (port=$port)") }
            continue
        }
        $suffix = $sf.BaseName -replace '^unity-mcp-status-', ''
        return @{ StatusFile = $sf.FullName; Port = $port; Suffix = $suffix }
    }
    return $null
}

function Sync-AdoptedCopies {
    # Step 1 of Invoke-UnityMcpAdoption: probe every existing adopted copy in
    # StatusDir, delete only the dead ones. A live one survives even when
    # this run's global scan cannot re-obtain its source (that is the
    # invariant this ticket exists to protect - a live adopted copy is never
    # dropped merely because a later run couldn't re-find its origin).
    param(
        [Parameter(Mandatory)][string]$StatusDir,
        [int]$PortProbeTimeoutMs = $PortProbeTimeoutMs
    )
    if (-not (Test-Path -LiteralPath $StatusDir)) { return @() }
    $adopted = @(Get-ChildItem -LiteralPath $StatusDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^unity-mcp-status-adopted-.*\.json$' })
    $survivors = @()
    foreach ($f in $adopted) {
        if (Test-StatusFileLive -StatusFilePath $f.FullName -PortProbeTimeoutMs $PortProbeTimeoutMs) {
            $survivors += $f
        } else {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    return $survivors
}

function Invoke-UnityMcpAdoption {
    # The full pass, run unconditionally by every caller (PreToolUse hook,
    # the generated launcher's preamble, or a manual invocation): clean dead
    # adopted copies, short-circuit if a real local instance is already live,
    # otherwise adopt a live Hub-started editor for this checkout if one
    # exists. Diagnostics for rejected global candidates are written to
    # stdout via Write-Output (see script header) - nothing is printed when
    # there is nothing to report.
    param(
        [Parameter(Mandatory)][string]$CheckoutPath,
        [Parameter(Mandatory)][string]$GlobalStatusDir,
        [int]$PortProbeTimeoutMs = $PortProbeTimeoutMs
    )
    $statusDir = Join-Path $CheckoutPath '.unity-mcp'

    # Step 1 - clean dead adopted copies, keep live ones. Only ever runs
    # against an EXISTING status dir - never creates one, so an unprepared
    # repo with nothing to adopt gets no stray untracked directory.
    if (Test-Path -LiteralPath $statusDir) {
        Sync-AdoptedCopies -StatusDir $statusDir -PortProbeTimeoutMs $PortProbeTimeoutMs | Out-Null
    }

    # Step 2 - a live REAL (non-adopted) local status file means this
    # session's own instance (worktree / environment_start case) is already
    # connected: stop here, the global dir is never scanned.
    if (Test-Path -LiteralPath $statusDir) {
        $realFiles = @(Get-ChildItem -LiteralPath $statusDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^unity-mcp-.*status.*\.json$' -and $_.Name -notmatch '^unity-mcp-status-adopted-' })
        foreach ($rf in $realFiles) {
            if (Test-StatusFileLive -StatusFilePath $rf.FullName -PortProbeTimeoutMs $PortProbeTimeoutMs) {
                return
            }
        }
    }

    # Step 3 - scan the global dir for a live candidate matching this
    # checkout; copy the first match. Diagnostics for every rejected
    # candidate are surfaced here, at the one call site that owns stdout.
    $diagnostics = New-Object 'System.Collections.Generic.List[string]'
    $candidate = Find-AdoptionCandidate -CheckoutPath $CheckoutPath -GlobalStatusDir $GlobalStatusDir -PortProbeTimeoutMs $PortProbeTimeoutMs -Diagnostics $diagnostics
    foreach ($line in $diagnostics) { Write-Output $line }
    if (-not $candidate) { return }

    New-Item -ItemType Directory -Force -Path $statusDir | Out-Null
    $destPath = Join-Path $statusDir "unity-mcp-status-adopted-$($candidate.Suffix).json"
    Copy-Item -LiteralPath $candidate.StatusFile -Destination $destPath -Force
    Write-Output "unity-mcp-adopt: adopted $($candidate.StatusFile) -> $destPath"
}

function Get-UnityMcpLaunchDecision {
    # 'already-connected' when any unity-mcp-*status*.json in StatusDir
    # (real or a freshly-adopted copy) is live; otherwise 'launch'. Called by
    # the generated launcher (.seretos/unity-mcp-launch.ps1) AFTER it has
    # already run Invoke-UnityMcpAdoption, so "adopted" and "this session's
    # own prior instance" are just two shapes of the same "live status file
    # present" input by the time this runs.
    param(
        [Parameter(Mandatory)][string]$StatusDir,
        [int]$PortProbeTimeoutMs = $PortProbeTimeoutMs
    )
    if (-not (Test-Path -LiteralPath $StatusDir)) { return 'launch' }
    $statusFiles = @(Get-ChildItem -LiteralPath $StatusDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^unity-mcp-.*status.*\.json$' })
    foreach ($sf in $statusFiles) {
        if (Test-StatusFileLive -StatusFilePath $sf.FullName -PortProbeTimeoutMs $PortProbeTimeoutMs) {
            return 'already-connected'
        }
    }
    return 'launch'
}

# Entry point - only runs on a real invocation (`&` / direct execution), never
# when dot-sourced (". path") purely to load the functions above for testing,
# mocking, or use by the generated launcher. $MyInvocation.InvocationName is
# '.' in that case. Wrapped in try/catch and always exits 0: this script runs
# as a PreToolUse hook, which must never block a tool call on an internal
# failure - a failure prints one line and is otherwise swallowed.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        Invoke-UnityMcpAdoption -CheckoutPath $CheckoutPath -GlobalStatusDir $GlobalStatusDir
    } catch {
        Write-Output "unity-mcp-adopt: internal error - $($_.Exception.Message)"
    }
    exit 0
}
