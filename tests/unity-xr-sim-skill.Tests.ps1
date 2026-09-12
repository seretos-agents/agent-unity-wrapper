#Requires -Version 5.1
<#
.SYNOPSIS
  Pester 3.x tests for skills/unity-xr-sim/SKILL.md and skills/unity-xr-sim/XRSim.cs
  (ticket #54). This is a third, standalone skill teaching the headless-free
  OpenXR loop (Mock Runtime + Conformance Automation): force the mock loader,
  enable an interaction profile, confirm the mock devices really appear
  before moving on, drive head/controller poses and a virtual grip, verify
  from game state, and fully restore the OpenXR settings asset afterwards.
  It carries no MCP/manifest change of its own - it rides execute_code,
  manage_editor, and read_console on the already-wired unityMCP server.
  Run with:  Invoke-Pester .\tests\unity-xr-sim-skill.Tests.ps1 -Verbose
#>

$global:xrsim_repoRoot = Split-Path -Parent $PSScriptRoot
$global:xrsim_path     = Join-Path $global:xrsim_repoRoot 'skills\unity-xr-sim\SKILL.md'
$global:xrsim_exists   = Test-Path $global:xrsim_path
$global:xrsim_text     = if ($global:xrsim_exists) { [System.IO.File]::ReadAllText($global:xrsim_path) } else { '' }

$global:xrsim_csPath   = Join-Path $global:xrsim_repoRoot 'skills\unity-xr-sim\XRSim.cs'
$global:xrsim_csExists = Test-Path $global:xrsim_csPath
$global:xrsim_csText   = if ($global:xrsim_csExists) { [System.IO.File]::ReadAllText($global:xrsim_csPath) } else { '' }

# Returns the single "description:" line's value from the leading frontmatter
# block (text between the opening --- and the next \n---), key stripped.
# Returns '' if no such block/line is found. Copied from tests/skill-md.Tests.ps1
# / tests/unity-yaml-merge-skill.Tests.ps1 (each test file keeps its own copy).
function Get-FrontmatterDescription {
    param([string]$Text)
    $start = $Text.IndexOf('---')
    if ($start -eq -1) { return '' }
    $end = $Text.IndexOf("`n---", $start + 3)
    if ($end -eq -1) { return '' }
    $frontmatter = $Text.Substring($start, $end - $start)
    foreach ($line in ($frontmatter -split "`n")) {
        if ($line -match '^description:\s*(.*)$') {
            return $Matches[1]
        }
    }
    return ''
}

# Returns the substring from a given "## Heading" (inclusive) up to (not
# including) the next top-level "## " heading. Copied from tests/skill-md.Tests.ps1.
function Get-Section {
    param([string]$Text, [string]$Heading)
    $sIdx = $Text.IndexOf($Heading)
    if ($sIdx -eq -1) { return '' }
    $eIdx = $Text.IndexOf("`n## ", $sIdx + $Heading.Length)
    if ($eIdx -eq -1) { return $Text.Substring($sIdx) }
    return $Text.Substring($sIdx, $eIdx - $sIdx)
}

# Returns a numbered "N. **...**" region from within a given top-level "##
# Heading" section: from "\n<Number>. **" up to (not including) "\n<Next
# Number>. **". Scoped to start searching only after the given heading so it
# cannot match an unrelated numbered list elsewhere in the file. This is the
# same shape as skill-md.Tests.ps1's Get-PitfallRegion, generalized to take
# the heading as a parameter since this file uses it for both "## Recipe"
# and "## Pitfalls". Returns '' if the start marker is absent.
function Get-NumberedRegion {
    param([string]$Text, [string]$Heading, [int]$Number, [int]$NextNumber)
    $sectionStart = $Text.IndexOf($Heading)
    if ($sectionStart -eq -1) { return '' }
    $section = $Text.Substring($sectionStart)
    $startMarker = "`n$Number. **"
    $endMarker   = "`n$NextNumber. **"
    $sIdx = $section.IndexOf($startMarker)
    if ($sIdx -eq -1) { return '' }
    $eIdx = $section.IndexOf($endMarker, $sIdx)
    if ($eIdx -eq -1) { return $section.Substring($sIdx) }
    return $section.Substring($sIdx, $eIdx - $sIdx)
}

# Returns the substring of $Text from the first occurrence of $Marker to the
# end of the file. Used to scope XRSim.cs assertions (e.g. Restore()) to
# "everything from this point on" without needing a brace-matching C# parser.
function Get-TailFrom {
    param([string]$Text, [string]$Marker)
    $idx = $Text.IndexOf($Marker)
    if ($idx -eq -1) { return '' }
    return $Text.Substring($idx)
}

# The structural counterpart to Get-TailFrom above: returns the substring of
# $Text from the start of the file up to (not including) the first
# occurrence of $Marker. Used to scope XRSim.cs assertions to "the
# snapshot-capture code" as everything that necessarily precedes Restore()'s
# definition, without needing a brace-matching C# parser. Capture and restore
# must be checked in separate regions, not as a whole-file count, or an
# assertion meant for Setup()'s capture code could just as easily be
# satisfied by matching text inside Restore() instead.
function Get-HeadUntil {
    param([string]$Text, [string]$Marker)
    $idx = $Text.IndexOf($Marker)
    if ($idx -eq -1) { return $Text }
    return $Text.Substring(0, $idx)
}

# Dependency-free, spec-informed check that a value would be valid as a bare
# YAML plain scalar if parsed in isolation. No powershell-yaml module (or
# any other YAML parser) is available in this environment, so this
# hand-implements the relevant plain-scalar production rules from the YAML
# spec (no leading indicator character, no embedded "': '"/trailing ':',
# no " #" comment start, no tabs, single physical line) rather than calling
# a real parser. Deliberately independent of Get-FrontmatterDescription's own
# extraction regex/capture group, so it can't just re-observe that helper's
# own normalization the way an assertion built only from the helper's output
# would.
function Test-YamlPlainScalarIsValid {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return $false }
    if ($Value -ne $Value.Trim()) { return $false }
    if ($Value.Contains("`t")) { return $false }
    if ($Value.Contains("`n")) { return $false }
    if ($Value -match '^[-?:,\[\]{}#&*!|>''"%@`]') { return $false }
    if ($Value -match ':(\s|$)') { return $false }
    if ($Value -match '\s#') { return $false }
    return $true
}

# =============================================================================
# R1 - exists and triggers on XR intent
# =============================================================================

# R1's evidence kind is declared structural in the plan (frontmatter
# presence/shape), not behavioural. The keyword-presence checks below can be
# satisfied by eleven bare tokens concatenated with no real sentence between
# them - that is an inherent limitation of R1's declared evidence kind, not
# something a regex can fully close. The YAML-validity + length-floor check
# adds one further real, non-tautological constraint (a truly degenerate
# stub still fails it), but does not by itself prove the description reads
# as prose a human would trigger on.
Describe 'unity-xr-sim SKILL.md -- exists and triggers on XR intent (R1)' {

    It 'the skill file exists' {
        $global:xrsim_exists | Should Be $true
    }

    It 'starts with frontmatter delimiter ---' {
        $global:xrsim_text.TrimStart().StartsWith('---') | Should Be $true
    }

    It 'frontmatter name is unity-xr-sim' {
        $global:xrsim_text | Should Match 'name: unity-xr-sim'
    }

    It 'contains no CR bytes' {
        if (-not $global:xrsim_exists) { throw 'file does not exist' }
        $bytes = [System.IO.File]::ReadAllBytes($global:xrsim_path)
        ($bytes -contains 13) | Should Be $false
    }

    $description = Get-FrontmatterDescription -Text $global:xrsim_text

    It 'description names the com.unity.xr.openxr package' {
        $description | Should Match 'com\.unity\.xr\.openxr'
    }

    It 'description names XRGeneralSettings' {
        $description | Should Match 'XRGeneralSettings'
    }

    It 'description names the OpenXR loader' {
        $description | Should Match '(?i)OpenXR loader'
    }

    It 'description names the mock runtime' {
        $description | Should Match '(?i)mock runtime'
    }

    It 'description names conformance automation' {
        $description | Should Match '(?i)conformance automation'
    }

    It 'description names interaction profile intent' {
        $description | Should Match '(?i)interaction profile'
    }

    It 'description names headset intent' {
        $description | Should Match '(?i)headset'
    }

    It 'description names VR intent' {
        $description | Should Match '(?i)\bVR\b'
    }

    It 'description names controller intent' {
        $description | Should Match '(?i)controller'
    }

    It 'description names grab intent' {
        $description | Should Match '(?i)grab'
    }

    It 'description stays one physical line (raw frontmatter, catches folded/literal block scalars)' {
        # Get-FrontmatterDescription already splits on newlines and returns a
        # single line via its regex capture group, so asserting against its
        # *output* can never observe a multi-line description - it always
        # passes, even for a YAML folded scalar (`description: >`) spread
        # across several physical lines in the raw file. This asserts
        # directly against the raw frontmatter text instead.
        if (-not $global:xrsim_exists) { throw 'file does not exist' }
        $start = $global:xrsim_text.IndexOf('---')
        $end   = $global:xrsim_text.IndexOf("`n---", $start + 3)
        $frontmatter = $global:xrsim_text.Substring($start, $end - $start)
        $rawLines = $frontmatter -split "`n"

        $descIdx = -1
        for ($i = 0; $i -lt $rawLines.Count; $i++) {
            if ($rawLines[$i] -match '^description:') { $descIdx = $i; break }
        }
        $descIdx | Should BeGreaterThan -1

        # No folded (>) or literal (|) block scalar indicator immediately
        # after the key.
        $rawLines[$descIdx] | Should Not Match '^description:\s*[>|]'

        # The value's physical line count in the raw text must be exactly
        # 1: the "description:" line itself, plus any following lines that
        # are a continuation (indented, not a new top-level "key:" line, not
        # blank) - a real multi-line plain scalar would add to this count.
        $valueLineCount = 1
        for ($j = $descIdx + 1; $j -lt $rawLines.Count; $j++) {
            if ($rawLines[$j] -match '^\S+:') { break }
            if ($rawLines[$j].Trim() -eq '') { break }
            $valueLineCount++
        }
        $valueLineCount | Should Be 1
    }

    It 'description is at most 1024 characters' {
        $description.Length | Should BeLessThan 1025
    }

    It 'description is a structurally valid YAML plain scalar in isolation, and is not a degenerate stub (at least 80 chars)' {
        (Test-YamlPlainScalarIsValid -Value $description) | Should Be $true
        $description.Length | Should BeGreaterThan 79
    }

    It 'description contains no colon-whitespace sequence (YAML plain-scalar guard)' {
        $description | Should Not Match ':\s'
    }
}

# =============================================================================
# R2 - recipe steps in order, step 4's mocked-session confirmation gate,
# restore completeness, and the numbered Pitfalls region
# =============================================================================

Describe 'unity-xr-sim SKILL.md -- recipe steps present in order (R2)' {

    $recipeSection = Get-Section -Text $global:xrsim_text -Heading '## Recipe'

    It 'has a non-empty Recipe section to check' {
        $recipeSection.Length | Should BeGreaterThan 0
    }

    # Ordered content markers spanning the seven recipe steps: snapshot,
    # enable an interaction profile, enable MockRuntime + Conformance
    # Automation, force the loader, head/controller pose + grip, verify from
    # game state, restore. Individual `It`s (rather than one combined regex)
    # so a partial draft shows exactly which marker is missing.
    $orderedMarkers = @(
        'OpenXRSettings.ActiveBuildTargetInstance',
        'GetFeature<',
        'ValveIndexControllerProfile',
        '/interaction_profiles/valve/index_controller',
        'MockRuntime',
        'ConformanceAutomationFeature',
        'InitializeLoader',
        'StartSubsystems',
        'XrReferenceSpaceType.View',
        '/user/hand/right/input/squeeze/value',
        'SerializedObject',
        'openxrExtensionStrings'
    )

    foreach ($marker in $orderedMarkers) {
        It "recipe section contains marker: $marker" {
            $recipeSection.Contains($marker) | Should Be $true
        }
    }

    It 'the ordered markers appear in the stated order' {
        $lastIndex = -1
        foreach ($marker in $orderedMarkers) {
            $idx = $recipeSection.IndexOf($marker)
            $idx | Should BeGreaterThan $lastIndex
            $lastIndex = $idx
        }
    }

    It 'the Recipe section contains exactly seven numbered top-level steps' {
        $stepMatches = [regex]::Matches($recipeSection, '(?m)^\d+\.\s+\*\*')
        $stepMatches.Count | Should Be 7
    }
}

Describe 'unity-xr-sim SKILL.md -- step 4 confirms the mocked session before proceeding (R2)' {

    $step4 = Get-NumberedRegion -Text $global:xrsim_text -Heading '## Recipe' -Number 4 -NextNumber 5

    It 'has a non-empty step 4 region to check' {
        $step4.Length | Should BeGreaterThan 0
    }

    It 'step 4 forces the loader via InitializeLoader' {
        $step4 | Should Match 'InitializeLoader'
    }

    It 'step 4 forces the loader via StartSubsystems' {
        $step4 | Should Match 'StartSubsystems'
    }

    It 'step 4 names the forced-loader console line verbatim' {
        $step4.Contains('Using forced custom loader override provided by the OpenXR Feature Mock Runtime') | Should Be $true
    }

    It 'step 4 names the mocked head device by its exact name' {
        $step4.Contains('Head Tracking - OpenXR') | Should Be $true
    }

    It 'step 4 names the mocked controller device by the "<Profile name> Controller OpenXR" pattern' {
        $step4 | Should Match 'Controller OpenXR'
    }

    It 'step 4 uses the worked Valve Index example device name exactly' {
        # Index Controller OpenXR is the real registered device name
        # (com.unity.xr.openxr ValveIndexControllerProfile.kDeviceLocalizedName) - Valve
        # Index is the one profile that drops the manufacturer prefix from the
        # "<Profile name> Controller OpenXR" pattern.
        $step4.Contains('Index Controller OpenXR') | Should Be $true
    }

    It 'step 4 does not use the incorrect "Valve Index Controller OpenXR" form' {
        $step4 | Should Not Match 'Valve Index Controller OpenXR'
    }

    It 'step 4 never uses the wrong device-name form "Index Controller (OpenXR)"' {
        $step4 | Should Not Match 'Index Controller \(OpenXR\)'
    }

    It 'step 4 instructs not to proceed until both devices are confirmed' {
        $step4 | Should Match '(?i)do not proceed'
    }

    # XRSim.cs owns no loader lifecycle at all - no pre-existing-loader
    # capture, no DeinitializeLoader(), no best-effort restore. The one
    # surviving InitializeLoaderSync()/StartSubsystems() call is
    # documentation only, issued by the agent via execute_code once Play
    # mode has already been entered - Setup() already forced the settings
    # into mock mode in Edit mode beforehand, so this call is always safe in
    # this position.
    It 'step 4 names entering Play mode before the InitializeLoaderSync call' {
        $playModeIdx = $step4.IndexOf('Play mode')
        $initSyncIdx = $step4.IndexOf('InitializeLoaderSync')
        $playModeIdx | Should BeGreaterThan -1
        $initSyncIdx | Should BeGreaterThan $playModeIdx
    }

    It 'step 4 names entering Play mode before the StartSubsystems call' {
        $playModeIdx = $step4.IndexOf('Play mode')
        $startSubsystemsIdx = $step4.IndexOf('StartSubsystems')
        $playModeIdx | Should BeGreaterThan -1
        $startSubsystemsIdx | Should BeGreaterThan $playModeIdx
    }

    It 'step 4 no longer documents deinitializing an already-active loader' {
        $step4 | Should Not Match 'DeinitializeLoader'
    }

    It 'step 4 no longer documents an activeLoader guard' {
        $step4 | Should Not Match 'activeLoader'
    }

    It 'step 4 no longer documents a best-effort loader restore' {
        $step4 | Should Not Match '(?i)best-effort'
    }
}

Describe 'unity-xr-sim SKILL.md -- distinct profile-qualified and null-profile activation (R2)' {

    $recipeSection = Get-Section -Text $global:xrsim_text -Heading '## Recipe'

    It 'documents the profile-qualified ConformanceAutomationSetActive call' {
        $recipeSection | Should Match 'ConformanceAutomationSetActive\([^,\r\n]*[Pp]rofile'
    }

    It 'documents the null-profile ConformanceAutomationSetActive call, distinctly' {
        $recipeSection | Should Match 'ConformanceAutomationSetActive\(\s*null'
    }

    It 'documents ConformanceAutomationSetVelocity' {
        $recipeSection | Should Match 'ConformanceAutomationSetVelocity'
    }

    It 'ties TrackedPoseDriver.isTracked to needing both calls' {
        $global:xrsim_text | Should Match 'TrackedPoseDriver'
        $global:xrsim_text | Should Match 'isTracked'
    }
}

Describe 'unity-xr-sim SKILL.md -- Restoring the settings asset via the whole-object backup file (R2)' {

    $restoreSection = Get-Section -Text $global:xrsim_text -Heading '## Restoring the settings asset'

    It 'has a non-empty Restore section to check' {
        $restoreSection.Length | Should BeGreaterThan 0
    }

    # The recipe uses one whole-object EditorJsonUtility backup file: Setup()
    # writes ToJson(feature) for the three feature objects into this file,
    # Restore() FromJsonOverwrite's each object back from it. There is no
    # field-by-field SerializedObject/FindProperty restore.
    It 'names the backup file path under Library/XRSim' {
        $restoreSection | Should Match 'Library[/\\]XRSim[/\\]openxr-settings-backup\.json'
    }

    It 'documents restoring each feature object via FromJsonOverwrite' {
        $restoreSection | Should Match 'FromJsonOverwrite'
    }

    It 'names the OpenXR Package Settings asset path' {
        $restoreSection.Contains('Assets/XR/Settings/OpenXR Package Settings.asset') | Should Be $true
    }

    It 'instructs a git diff check to confirm full restoration' {
        $restoreSection | Should Match '(?i)git diff'
    }

    # G4 (plan Approach, bullet "Guards kept"): Restore() throws if the
    # backup file is missing rather than fabricating a default - this must be
    # a documented, deliberate refusal, not just something the code happens
    # to do silently.
    It 'documents that restore refuses to run when no backup file is present' {
        $restoreSection | Should Match '(?i)without a backup'
        $restoreSection | Should Match '(?i)throws|refuses'
    }
}

Describe 'unity-xr-sim SKILL.md -- Operator rules are documented (R2)' {

    # XRSim.cs carries no loader-lifecycle code - entering/exiting Play mode
    # and calling Restore() at the right time is the operator's
    # responsibility alone, so it must be spelled out explicitly in an
    # "Operator rules" block after the preconditions.
    $recipeIdx = $global:xrsim_text.IndexOf('## Recipe')
    $preRecipeSection = if ($recipeIdx -eq -1) { $global:xrsim_text } else { $global:xrsim_text.Substring(0, $recipeIdx) }

    It 'has content before the Recipe section to check' {
        $preRecipeSection.Length | Should BeGreaterThan 0
    }

    It 'documents an Operator rules block' {
        $global:xrsim_text | Should Match '(?i)Operator rules'
    }

    It 'rule 1: Setup() runs in Edit mode before entering Play mode' {
        $preRecipeSection | Should Match 'Setup\(\)'
        $preRecipeSection | Should Match '(?i)Edit mode'
        $preRecipeSection | Should Match '(?i)before entering Play mode'
    }

    It 'rule 2: enter Play mode, initialize the loader, and do all driving inside Play mode' {
        $preRecipeSection | Should Match '(?i)enter Play mode'
        $preRecipeSection | Should Match 'InitializeLoaderSync'
    }

    It 'rule 3: exit Play mode, then Restore(); if the backup is gone, git checkout the asset' {
        $preRecipeSection | Should Match '(?i)exit Play mode'
        $preRecipeSection | Should Match 'Restore\(\)'
        $preRecipeSection | Should Match 'git checkout'
    }
}

Describe 'unity-xr-sim SKILL.md -- no review-process residue survives in the shipped doc (R2)' {

    It 'contains no "reviewer round" or "[blocking]" commentary' {
        $global:xrsim_text | Should Not Match '(?i)reviewer round|\[blocking\]'
    }
}

Describe 'unity-xr-sim SKILL.md -- numbered Pitfalls region (R2)' {

    It 'has a Pitfalls section to check' {
        $global:xrsim_text | Should Match '## Pitfalls'
    }

    $pitfall1 = Get-NumberedRegion -Text $global:xrsim_text -Heading '## Pitfalls' -Number 1 -NextNumber 2
    It 'pitfall 1 covers full vs. partial interaction-profile paths' {
        $pitfall1 | Should Match '(?i)full'
        $pitfall1 | Should Match '(?i)partial'
    }

    $pitfall2 = Get-NumberedRegion -Text $global:xrsim_text -Heading '## Pitfalls' -Number 2 -NextNumber 3
    It 'pitfall 2 covers stale Editor-context Input System reads' {
        $pitfall2 | Should Match '(?i)stale'
        $pitfall2 | Should Match '(?i)Input System'
    }

    $pitfall3 = Get-NumberedRegion -Text $global:xrsim_text -Heading '## Pitfalls' -Number 3 -NextNumber 4
    It 'pitfall 3 covers the autoReferenced: false asmdef requirement' {
        $pitfall3 | Should Match 'autoReferenced'
        $pitfall3 | Should Match 'false'
    }

    $pitfall4 = Get-NumberedRegion -Text $global:xrsim_text -Heading '## Pitfalls' -Number 4 -NextNumber 5
    It 'pitfall 4 covers reaching internal fields via SerializedObject' {
        $pitfall4 | Should Match '(?i)internal field'
        $pitfall4 | Should Match 'SerializedObject'
    }

    # ignoreValidationErrors is a PUBLIC field on MockRuntime, set by direct
    # assignment - as step 3 (line ~134), the Restore prose (line ~210) and
    # XRSim.cs:172 (`mockRuntime.ignoreValidationErrors = true;`) already do.
    # Only priority, required, and openxrExtensionStrings are genuinely
    # internal and need SerializedObject/FindProperty (XRSim.cs:193-194).
    It 'pitfall 4 classifies ignoreValidationErrors as a public, directly-assigned field' {
        # Scoped to the first clause boundary of any kind (comma, semicolon, or
        # period) after the field name, not just a period - and the positive
        # claims additionally refuse to match through a negation token ("not",
        # "n't", "never") sitting between the field name and the claim. This
        # guards against a rewrite that states the OPPOSITE of the truth (e.g.
        # "ignoreValidationErrors is not public; it is an internal field too,
        # set that way rather than by direct assignment.") - unscoped/period-only
        # matching would let that prose satisfy all three assertions too, since
        # the negation sits between the field name and "public", and "internal
        # field"/"direct assignment" sit in later, differently-punctuated clauses.
        $pitfall4 | Should Match '(?i)ignoreValidationErrors(?:(?!\bnot\b|n''t|\bnever\b)[^.,;])*\bpublic\b'
        $pitfall4 | Should Match '(?i)ignoreValidationErrors(?:(?!\bnot\b|n''t|\bnever\b)[^.,;])*direct assignment'
        $pitfall4 | Should Not Match '(?i)ignoreValidationErrors[^.,;]*internal field'
    }

    It 'XRSim.cs assigns ignoreValidationErrors directly and never via FindProperty' {
        $global:xrsim_csText | Should Match 'mockRuntime\.ignoreValidationErrors\s*=\s*true;'
        $global:xrsim_csText | Should Not Match 'FindProperty\("ignoreValidationErrors"\)'
    }

    $pitfall5 = Get-NumberedRegion -Text $global:xrsim_text -Heading '## Pitfalls' -Number 5 -NextNumber 6
    It 'pitfall 5 covers the execute_code timeout' {
        $pitfall5 | Should Match 'execute_code'
        $pitfall5 | Should Match '(?i)timeout'
    }

    # Pitfall 5 must name the same method step 4 actually calls -
    # InitializeLoaderSync() - not the bare InitializeLoader()/
    # StartSubsystems() names, which would point a reader at a method that
    # doesn't exist in the recipe.
    It 'pitfall 5 uses the corrected InitializeLoaderSync() name, matching step 4' {
        $pitfall5 | Should Match 'InitializeLoaderSync\(\)'
    }

    It 'pitfall 5 does not use the stale bare InitializeLoader()/StartSubsystems() phrasing' {
        $pitfall5 | Should Not Match '\(`InitializeLoader\(\)`/`StartSubsystems\(\)`\)'
    }

    # This pitfall is anchored to Play-mode entry (the call happens there,
    # per step 4 and the Operator rules), not to "forcing the loader" as its
    # own destructive operation.
    It 'pitfall 5 is anchored to Play-mode entry, not to a bare "force the loader" framing' {
        $pitfall5 | Should Match '(?i)Play mode'
    }

    $pitfall6 = Get-NumberedRegion -Text $global:xrsim_text -Heading '## Pitfalls' -Number 6 -NextNumber 7
    It 'pitfall 6 covers TrackedPoseDriver needing both SetVelocity and the null-profile SetActive' {
        $pitfall6 | Should Match 'TrackedPoseDriver'
        $pitfall6 | Should Match 'SetVelocity'
        $pitfall6 | Should Match 'SetActive'
    }

    $pitfall7 = Get-NumberedRegion -Text $global:xrsim_text -Heading '## Pitfalls' -Number 7 -NextNumber 8
    It 'pitfall 7 covers a missing interaction profile yielding no controller device' {
        $pitfall7 | Should Match '(?i)interaction profile'
        $pitfall7 | Should Match '(?i)no controller device|missing controller'
    }

    $pitfall8 = Get-NumberedRegion -Text $global:xrsim_text -Heading '## Pitfalls' -Number 8 -NextNumber 9
    It 'pitfall 8 covers the Mock Environment / XR_UNITY_null_gfx caveat' {
        $pitfall8 | Should Match 'XR_UNITY_null_gfx'
    }
}

# =============================================================================
# R3 lives in tests/skill-md.Tests.ps1 (cross-reference from unity-wrapper).
# =============================================================================

# =============================================================================
# R4 - the real, verified XRSim.cs template
# =============================================================================

Describe 'unity-xr-sim XRSim.cs -- exists and matches the documented API (R4)' {

    It 'the template file exists' {
        $global:xrsim_csExists | Should Be $true
    }

    It 'contains no CR bytes' {
        if (-not $global:xrsim_csExists) { throw 'file does not exist' }
        $bytes = [System.IO.File]::ReadAllBytes($global:xrsim_csPath)
        ($bytes -contains 13) | Should Be $false
    }

    It 'calls ConformanceAutomationSetPose' {
        $global:xrsim_csText | Should Match 'ConformanceAutomationSetPose'
    }

    It 'calls ConformanceAutomationSetFloat' {
        $global:xrsim_csText | Should Match 'ConformanceAutomationSetFloat'
    }

    It 'calls ConformanceAutomationSetVelocity' {
        $global:xrsim_csText | Should Match 'ConformanceAutomationSetVelocity'
    }

    It 'calls the profile-qualified ConformanceAutomationSetActive' {
        $global:xrsim_csText | Should Match 'ConformanceAutomationSetActive\([^,\r\n]*[Pp]rofile'
    }

    It 'separately calls the null-profile ConformanceAutomationSetActive' {
        $global:xrsim_csText | Should Match 'ConformanceAutomationSetActive\(\s*null'
    }

    It 'calls MockRuntime.SetSpace' {
        $global:xrsim_csText | Should Match 'MockRuntime\.SetSpace'
    }

    It 'fetches the interaction profile feature via GetFeature<ValveIndexControllerProfile>' {
        $global:xrsim_csText | Should Match 'GetFeature<ValveIndexControllerProfile>'
    }

    It 'builds an input path from ValveIndexControllerProfile.squeeze rather than a hand-typed literal' {
        $global:xrsim_csText | Should Match 'ValveIndexControllerProfile\.squeeze'
    }
}

Describe 'unity-xr-sim XRSim.cs -- stateless: no SessionState, no mutable static field, no loader API (R4)' {

    # XRSim.cs is a stateless copy-paste template - no loader lifecycle
    # ownership, no mutable static state, a whole-object JSON backup file
    # instead of SessionState.
    It 'does not reference SessionState anywhere' {
        $global:xrsim_csText | Should Not Match 'SessionState'
    }

    It 'declares no mutable static field - every static field is const or static readonly string' {
        # Approximation, not a full C# parser: matches a single-line field
        # declaration of the shape "<modifier> static <Type> <name> ...;"
        # that is neither a method ("static void ...") nor an allowed
        # "static readonly string" constant. const fields don't carry the
        # literal word "static" in this codebase's style, so they never
        # match this pattern and need no explicit allowance here.
        $mutableStaticFieldMatches = [regex]::Matches(
            $global:xrsim_csText,
            '(?m)^\s*(?:public|private|internal)\s+static\s+(?!void\b|readonly\s+string\b)\S.*;\s*$')
        $mutableStaticFieldMatches.Count | Should Be 0
    }

    It 'does not reference any loader lifecycle API (InitializeLoaderSync/DeinitializeLoader/StartSubsystems/activeLoader) - that call lives only in SKILL.md' {
        $global:xrsim_csText | Should Not Match 'InitializeLoaderSync|DeinitializeLoader|StartSubsystems|activeLoader'
    }
}

Describe 'unity-xr-sim XRSim.cs -- Setup() backs up before any write, including internal-field writes (R4)' {

    $setupStart  = $global:xrsim_csText.IndexOf('public static void Setup()')
    $setupEnd    = $global:xrsim_csText.IndexOf('public static void SetHeadPose')
    $setupRegion = $global:xrsim_csText.Substring($setupStart, $setupEnd - $setupStart)

    It 'has a non-empty Setup() region to check' {
        $setupStart | Should BeGreaterThan -1
        $setupRegion.Length | Should BeGreaterThan 0
    }

    # G3 (plan): Setup() throws if the backup file already exists - a
    # previous run was never restored - rather than silently overwriting it.
    It 'throws if the backup file already exists (G3)' {
        $setupRegion | Should Match 'File\.Exists'
        $setupRegion | Should Match 'throw new InvalidOperationException'
    }

    It 'writes the backup via EditorJsonUtility.ToJson' {
        $setupRegion | Should Match 'EditorJsonUtility\.ToJson'
    }

    It 'the backup-exists check and the ToJson call precede the first .enabled = write' {
        $existsIdx = $setupRegion.IndexOf('File.Exists')
        $toJsonIdx = $setupRegion.IndexOf('EditorJsonUtility.ToJson')
        $enabledWriteMatch = [regex]::Match($setupRegion, '\.enabled\s*=\s*true')
        $existsIdx | Should BeGreaterThan -1
        $toJsonIdx | Should BeGreaterThan -1
        $enabledWriteMatch.Success | Should Be $true
        $existsIdx | Should BeLessThan $enabledWriteMatch.Index
        $toJsonIdx | Should BeLessThan $enabledWriteMatch.Index
    }

    # The ordering guarantee above must also cover the
    # SerializedObject/FindProperty internal-field writes
    # (openxrExtensionStrings/priority/required), not just the .enabled
    # writes - both are writes to the live settings asset that the backup
    # must exist ahead of.
    It 'the backup-exists check and the ToJson call precede the SerializedObject/FindProperty internal-field writes too, not just the .enabled writes' {
        $existsIdx = $setupRegion.IndexOf('File.Exists')
        $toJsonIdx = $setupRegion.IndexOf('EditorJsonUtility.ToJson')
        $findPropertyWriteMatch = [regex]::Match($setupRegion, 'FindProperty\([^)]*\)\s*\.\s*\w+Value\s*=')
        $existsIdx | Should BeGreaterThan -1
        $toJsonIdx | Should BeGreaterThan -1
        $findPropertyWriteMatch.Success | Should Be $true
        $existsIdx | Should BeLessThan $findPropertyWriteMatch.Index
        $toJsonIdx | Should BeLessThan $findPropertyWriteMatch.Index
    }
}

Describe 'unity-xr-sim XRSim.cs -- Restore() refuses without a backup, then restores via FromJsonOverwrite, saves, and deletes the backup (R4)' {

    $restoreRegion = Get-TailFrom -Text $global:xrsim_csText -Marker 'public static void Restore()'

    It 'has a non-empty Restore() region to check' {
        $restoreRegion.Length | Should BeGreaterThan 0
    }

    # G4 (plan): Restore() throws if the backup file is missing - it never
    # fabricates a default.
    It 'throws InvalidOperationException if the backup file is missing (G4)' {
        $restoreRegion | Should Match 'File\.Exists'
        $restoreRegion | Should Match 'throw new InvalidOperationException'
    }

    It 'the File.Exists guard precedes any FromJsonOverwrite call' {
        $existsIdx = $restoreRegion.IndexOf('File.Exists')
        $firstFromJsonIdx = $restoreRegion.IndexOf('FromJsonOverwrite')
        $existsIdx | Should BeGreaterThan -1
        $firstFromJsonIdx | Should BeGreaterThan -1
        $existsIdx | Should BeLessThan $firstFromJsonIdx
    }

    It 'calls FromJsonOverwrite exactly three times, one per backed-up feature object' {
        ([regex]::Matches($restoreRegion, 'FromJsonOverwrite')).Count | Should Be 3
    }

    # A bare, project-wide AssetDatabase.SaveAssets() call would flush EVERY
    # dirty asset in the project, not just the three objects Restore() just
    # overwrote - it must never appear in this region. Only the scoped,
    # per-object SaveAssetIfDirty() is allowed.
    It 'never calls the bare, project-wide AssetDatabase.SaveAssets()' {
        $restoreRegion | Should Not Match 'AssetDatabase\.SaveAssets\(\)'
    }

    It 'calls AssetDatabase.SaveAssetIfDirty exactly three times, once per restored object, after all FromJsonOverwrite calls' {
        $lastFromJsonIdx = $restoreRegion.LastIndexOf('FromJsonOverwrite')
        $firstSaveIdx = $restoreRegion.IndexOf('AssetDatabase.SaveAssetIfDirty')
        $lastFromJsonIdx | Should BeGreaterThan -1
        $firstSaveIdx | Should BeGreaterThan -1
        $firstSaveIdx | Should BeGreaterThan $lastFromJsonIdx
        ([regex]::Matches($restoreRegion, 'AssetDatabase\.SaveAssetIfDirty')).Count | Should Be 3
    }

    It 'deletes the backup file after saving' {
        $lastSaveIdx = $restoreRegion.LastIndexOf('AssetDatabase.SaveAssetIfDirty')
        $deleteIdx = $restoreRegion.IndexOf('File.Delete')
        $lastSaveIdx | Should BeGreaterThan -1
        $deleteIdx | Should BeGreaterThan -1
        $deleteIdx | Should BeGreaterThan $lastSaveIdx
    }

    It 'declares the backup file path under Library/XRSim' {
        $global:xrsim_csText | Should Match 'Library[/\\]XRSim[/\\]openxr-settings-backup\.json'
    }
}

Describe 'unity-xr-sim SKILL.md -- references XRSim.cs by path (R4)' {

    It 'SKILL.md names the XRSim.cs file' {
        $global:xrsim_text | Should Match 'XRSim\.cs'
    }
}

# =============================================================================
# R4 - Setup()'s optional-feature guards: it must fail fast with a clear,
# actionable error (not a NullReferenceException) when an optional OpenXR
# feature is missing from the project's feature set, and SKILL.md must
# document that this is a real precondition gap distinct from the
# package/loader precondition already documented (R1's Describe block above).
# =============================================================================

Describe 'unity-xr-sim XRSim.cs -- Setup() fails fast with a clear error when an optional OpenXR feature is missing (R4)' {

    # Scope to Setup()'s own body, from its declaration to the next method
    # (SetHeadPose() - XRSim.cs has no ForceLoader() method, so Setup() is
    # immediately followed by SetHeadPose() in the file).
    $setupStart  = $global:xrsim_csText.IndexOf('public static void Setup()')
    $setupEnd    = $global:xrsim_csText.IndexOf('public static void SetHeadPose')
    $setupRegion = $global:xrsim_csText.Substring($setupStart, $setupEnd - $setupStart)

    It 'has a non-empty Setup() region to check' {
        $setupStart | Should BeGreaterThan -1
        $setupRegion.Length | Should BeGreaterThan 0
    }

    It 'checks mockRuntime for null' {
        $setupRegion | Should Match 'mockRuntime\s*==\s*null'
    }

    It 'checks conformanceAutomationFeature for null' {
        $setupRegion | Should Match 'conformanceAutomationFeature\s*==\s*null'
    }

    It 'checks valveIndexControllerProfile for null' {
        $setupRegion | Should Match 'valveIndexControllerProfile\s*==\s*null'
    }

    # Each exception's message is built from several concatenated string
    # literals split across lines, so it is checked as a sliced region -
    # "from this null check up to the next one" - rather than one combined
    # regex trying to cross string/quote boundaries (fragile: a `[^"]*` can't
    # jump over the closing quote between two concatenated literals).
    $mockBlockStart = $setupRegion.IndexOf('mockRuntime == null')
    $confBlockStart = $setupRegion.IndexOf('conformanceAutomationFeature == null')
    $profileBlockStart = $setupRegion.IndexOf('valveIndexControllerProfile == null')
    $firstUseIdxForBlocks = $setupRegion.IndexOf('_serializedMockRuntime = new SerializedObject(mockRuntime);')
    $mockBlock    = $setupRegion.Substring($mockBlockStart, $confBlockStart - $mockBlockStart)
    $confBlock    = $setupRegion.Substring($confBlockStart, $profileBlockStart - $confBlockStart)
    $profileBlock = $setupRegion.Substring($profileBlockStart, $firstUseIdxForBlocks - $profileBlockStart)

    It 'throws InvalidOperationException naming MockRuntime and the OpenXR Feature Groups location' {
        $mockBlock | Should Match 'throw new InvalidOperationException'
        $mockBlock | Should Match '"MockRuntime feature not found'
        $mockBlock | Should Match 'OpenXR Feature'
        $mockBlock | Should Match 'Groups'
    }

    It 'throws InvalidOperationException naming ConformanceAutomationFeature and the OpenXR Feature Groups location' {
        $confBlock | Should Match 'throw new InvalidOperationException'
        $confBlock | Should Match '"ConformanceAutomationFeature feature not found'
        $confBlock | Should Match 'OpenXR Feature'
        $confBlock | Should Match 'Groups'
    }

    It 'throws InvalidOperationException naming ValveIndexControllerProfile and the OpenXR Feature Groups location' {
        $profileBlock | Should Match 'throw new InvalidOperationException'
        $profileBlock | Should Match '"ValveIndexControllerProfile feature not found'
        $profileBlock | Should Match 'OpenXR Feature'
        $profileBlock | Should Match 'Groups'
    }

    It 'every InvalidOperationException message names Project Settings > XR Plug-in Management > OpenXR' {
        # Anchor to the literal navigation breadcrumb so a vague "configure OpenXR"
        # message wouldn't satisfy this - it must actually tell the operator where
        # to click.
        ([regex]::Matches($setupRegion, [regex]::Escape('Project Settings > XR Plug-in Management > OpenXR'))).Count | Should Be 3
    }

    It 'the null checks textually precede the first dereference of any of the three features' {
        # _serializedMockRuntime = new SerializedObject(mockRuntime) is the first
        # point Setup() actually uses one of the three GetFeature<T>() results -
        # every null check must come before it, or a missing feature would still
        # reach a raw null-argument failure instead of the clear, named error.
        $mockNullIdx   = $setupRegion.IndexOf('mockRuntime == null')
        $confNullIdx   = $setupRegion.IndexOf('conformanceAutomationFeature == null')
        $profileNullIdx = $setupRegion.IndexOf('valveIndexControllerProfile == null')
        $firstUseIdx   = $setupRegion.IndexOf('_serializedMockRuntime = new SerializedObject(mockRuntime);')

        $mockNullIdx | Should BeGreaterThan -1
        $confNullIdx | Should BeGreaterThan -1
        $profileNullIdx | Should BeGreaterThan -1
        $firstUseIdx | Should BeGreaterThan -1

        $mockNullIdx | Should BeLessThan $firstUseIdx
        $confNullIdx | Should BeLessThan $firstUseIdx
        $profileNullIdx | Should BeLessThan $firstUseIdx
    }

    It 'uses System.Exception types, so the file must import System' {
        $global:xrsim_csText | Should Match '(?m)^using System;'
    }
}

Describe 'unity-xr-sim SKILL.md -- documents the OpenXR Feature Groups precondition gap, distinct from package/loader presence (R4)' {

    It 'documents that the OpenXR features must be added to the project feature list, not just the package/loader' {
        $global:xrsim_text | Should Match '(?i)OpenXR Feature Groups'
    }

    It 'names GetFeature<T>() returning null as the mechanism' {
        $global:xrsim_text | Should Match 'GetFeature<T>\(\)'
        $global:xrsim_text | Should Match '(?i)returns.*null'
    }

    It 'names Setup() failing fast with InvalidOperationException instead of NullReferenceException' {
        $global:xrsim_text | Should Match 'InvalidOperationException'
        $global:xrsim_text | Should Match 'NullReferenceException'
    }

    It 'this gap is documented before the Recipe section begins, alongside the existing precondition' {
        $gapIdx    = $global:xrsim_text.IndexOf('OpenXR Feature Groups')
        $recipeIdx = $global:xrsim_text.IndexOf('## Recipe')
        $gapIdx | Should BeGreaterThan -1
        $recipeIdx | Should BeGreaterThan -1
        $gapIdx | Should BeLessThan $recipeIdx
    }
}

# =============================================================================
# R4 - Setup()'s active-build-target guard: the "package installed OR loader
# configured" precondition alone still lets a project through where
# OpenXRSettings.ActiveBuildTargetInstance is null - package presence alone
# does not guarantee the per-platform settings asset exists. Setup() must
# guard against this itself, and SKILL.md's stated precondition must require
# a loader actually configured for the active build target, not an
# either/or with bare package presence.
#
# XRSim.cs owns no loader lifecycle and no mutable static state at all (see
# the "stateless" Describe above), so there is nothing to persist across a
# domain reload in the first place.
# =============================================================================

Describe 'unity-xr-sim XRSim.cs -- Setup() null-checks OpenXRSettings.ActiveBuildTargetInstance before touching it (R4)' {

    $setupStart  = $global:xrsim_csText.IndexOf('public static void Setup()')
    $setupEnd    = $global:xrsim_csText.IndexOf('public static void SetHeadPose')
    $setupRegion = $global:xrsim_csText.Substring($setupStart, $setupEnd - $setupStart)

    It 'has a non-empty Setup() region to check' {
        $setupStart | Should BeGreaterThan -1
        $setupRegion.Length | Should BeGreaterThan 0
    }

    It 'checks settings for null' {
        $setupRegion | Should Match 'settings\s*==\s*null'
    }

    It 'throws InvalidOperationException naming that no OpenXR settings were found for the active build target' {
        $setupRegion | Should Match 'throw new InvalidOperationException'
        $setupRegion | Should Match '"No OpenXR settings found for the active build target'
    }

    It 'the settings null check textually precedes the first GetFeature<T>() call (the first dereference of settings)' {
        $settingsNullIdx = $setupRegion.IndexOf('settings == null')
        $firstGetFeatureIdx = $setupRegion.IndexOf('GetFeature<')
        $settingsNullIdx | Should BeGreaterThan -1
        $firstGetFeatureIdx | Should BeGreaterThan -1
        $settingsNullIdx | Should BeLessThan $firstGetFeatureIdx
    }

    It 'does not add a fourth occurrence of the OpenXR Feature Groups breadcrumb (this is a distinct gap from the missing-feature checks)' {
        # The exact-count-of-3 assertion in the Describe block above already
        # pins the three feature-missing messages; this settings null check
        # is a different, earlier gap (settings itself, not one of its
        # features) and must not reuse that exact breadcrumb text.
        ([regex]::Matches($setupRegion, [regex]::Escape('Project Settings > XR Plug-in Management > OpenXR'))).Count | Should Be 3
    }
}

Describe 'unity-xr-sim SKILL.md -- precondition requires a loader configured for the active build target, not package-or-loader either/or (R4)' {

    $preconditionEnd = $global:xrsim_text.IndexOf('## Recipe')
    $preconditionSection = $global:xrsim_text.Substring(0, $preconditionEnd)

    It 'states the requirement is a loader configured for the active build target' {
        $preconditionSection | Should Match '(?i)configured for the active build target'
    }

    It 'names ActiveBuildTargetInstance as the thing that can still be null' {
        $preconditionSection | Should Match 'ActiveBuildTargetInstance'
    }

    It 'states package installation alone is not sufficient' {
        $preconditionSection | Should Match '(?i)not (itself )?(sufficient|enough)|only confirms the package is installed'
    }
}

# =============================================================================
# R4 - a controller pose call must drive both the aim/pointer pose
# (ValveIndexControllerProfile.aim) and the device/grip pose
# (ValveIndexControllerProfile.grip): devicePosition/deviceRotation and most
# controller-transform bindings read the grip pose, not the aim pose, so
# SetControllerPose() must drive both poses together.
# =============================================================================

Describe 'unity-xr-sim XRSim.cs -- SetControllerPose() drives both the aim/pointer pose and the device/grip pose (R4)' {

    $scpStart  = $global:xrsim_csText.IndexOf('public static void SetControllerPose')
    $scpEnd    = $global:xrsim_csText.IndexOf('public static void SetGrip')
    $scpRegion = $global:xrsim_csText.Substring($scpStart, $scpEnd - $scpStart)

    It 'has a non-empty SetControllerPose() region to check' {
        $scpStart | Should BeGreaterThan -1
        $scpRegion.Length | Should BeGreaterThan 0
    }

    It 'drives the aim/pointer pose via ValveIndexControllerProfile.aim' {
        $scpRegion | Should Match 'ValveIndexControllerProfile\.aim'
    }

    It 'drives the device/grip pose via ValveIndexControllerProfile.grip' {
        $scpRegion | Should Match 'ValveIndexControllerProfile\.grip'
    }

    It 'calls ConformanceAutomationSetPose exactly twice, once per pose target' {
        ([regex]::Matches($scpRegion, 'ConformanceAutomationSetPose')).Count | Should Be 2
    }
}

Describe 'unity-xr-sim XRSim.cs -- SetGrip() sets velocity on both the aim/pointer pose and the device/grip pose (R4)' {

    $sgStart  = $global:xrsim_csText.IndexOf('public static void SetGrip')
    $sgEnd    = $global:xrsim_csText.IndexOf('private static void ActivateInput')
    $sgRegion = $global:xrsim_csText.Substring($sgStart, $sgEnd - $sgStart)

    It 'has a non-empty SetGrip() region to check' {
        $sgStart | Should BeGreaterThan -1
        $sgRegion.Length | Should BeGreaterThan 0
    }

    It 'sets velocity on the aim/pointer pose via ValveIndexControllerProfile.aim' {
        $sgRegion | Should Match 'ConformanceAutomationSetVelocity[\s\S]*?ValveIndexControllerProfile\.aim'
    }

    It 'sets velocity on the device/grip pose via ValveIndexControllerProfile.grip' {
        $sgRegion | Should Match 'ConformanceAutomationSetVelocity[\s\S]*?ValveIndexControllerProfile\.grip'
    }

    It 'calls ConformanceAutomationSetVelocity exactly twice, once per pose target' {
        ([regex]::Matches($sgRegion, 'ConformanceAutomationSetVelocity')).Count | Should Be 2
    }
}

Describe 'unity-xr-sim SKILL.md -- documents that a controller pose call must drive both the aim/pointer pose and the device/grip pose (R4)' {

    $pitfall9 = Get-NumberedRegion -Text $global:xrsim_text -Heading '## Pitfalls' -Number 9 -NextNumber 10

    It 'has a non-empty pitfall 9 region to check' {
        $pitfall9.Length | Should BeGreaterThan 0
    }

    It 'pitfall 9 names both the aim/pointer pose and the device/grip pose' {
        $pitfall9 | Should Match '(?i)aim'
        $pitfall9 | Should Match '(?i)grip'
    }

    It 'pitfall 9 names devicePosition/deviceRotation as what silently fails to move otherwise' {
        $pitfall9 | Should Match 'devicePosition'
        $pitfall9 | Should Match 'deviceRotation'
    }

    It 'pitfall 9 states that SetVelocity needs the same aim-vs-grip treatment as pose-setting' {
        $pitfall9 | Should Match 'SetVelocity'
    }
}
