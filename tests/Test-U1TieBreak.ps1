# Offline test for the U1 material-tag matching in Watch2Print_Engine_MP.ps1.
#
# Nothing here talks to SimplyPrint or touches a queue. The test lifts the real
# "PATH A: U1 DYNAMIC MATCH" block and its three helper functions out of the
# engine file with the PowerShell parser, feeds them canned filament types and
# canned analysis.materialData, and checks which filename material lands on
# which nozzle.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-U1TieBreak.ps1
#
# -BaselinePath <engine.ps1>  also runs every case through an older engine and
#                             checks that the cases marked "same as before"
#                             produce identical tags, and that the cases marked
#                             as fixed really were wrong there.
# -ShowEngineLog              prints the engine's own "U1: ext N -> ..." lines.

param(
    [string]$EnginePath = (Join-Path $PSScriptRoot '..\src\Watch2Print_Engine_MP.ps1'),
    [string]$BaselinePath,
    [switch]$ShowEngineLog
)

$ErrorActionPreference = 'Stop'

# --- Fixtures -----------------------------------------------------------------

# Trimmed copy of GET filament/type/Get (Prevolve account, 11-11-2026).
$script:TestFilamentTypes = @(
    [pscustomobject]@{ id = 196641; material_type_name = 'PLA';      profile_name = 'Generic PLA' }
    [pscustomobject]@{ id = 231507; material_type_name = 'RoamrTPU'; profile_name = 'RoamrTPU' }
    [pscustomobject]@{ id = 378541; material_type_name = '85ATPU';   profile_name = '85ATPU' }
    [pscustomobject]@{ id = 539620; material_type_name = 'PEBA';     profile_name = 'Rebound PEBA 95A' }
)

$PLA   = 196641
$ROAMR = 231507
$TPU85 = 378541
$PEBA  = 539620

function New-Mat { param($Type, $Color, $Hex) @{ type = $Type; color = $Color; hex = $Hex } }

$cases = @(
    @{
        name = 'PEBA case, 11-11-2026 (4 triplets, tool 0 idle)'
        note = '2RnD_NilBallPremium-Pocket_Pv0.30_L_Black_Kingroon_Generic_Lilac_Siraya Tech_RoamrTPU_Transparent_Siraya Tech_85ATPU_Black_Siraya Tech_Rebound PEBA 95A_U1.gcode'
        mats = @( (New-Mat $PLA 'Black' '#000000'), (New-Mat $ROAMR 'Lilac' '#9C27B0'), (New-Mat $TPU85 'Transparent' '#D9DAD1'), (New-Mat $PEBA 'Black' '#000000') )
        # materialData exactly as SimplyPrint returned it for this gcode.
        analysis = '[{"nozzle":0},{"type":"TPU","color":"#9C27B0","nozzle":1},{"type":"TPU","color":"#D9DAD1","nozzle":2},{"type":"TPU","color":"#000000","nozzle":3}]'
        expect = "n1e0=$ROAMR n2e0=$TPU85 n3e0=$PEBA"
        fixed  = $true
    }
    @{
        name = 'Normal 4 of 4 (every tool used, distinct colours)'
        mats = @( (New-Mat $PLA 'Black' '#000000'), (New-Mat $ROAMR 'Lilac' '#9C27B0'), (New-Mat $TPU85 'Transparent' '#D9DAD1'), (New-Mat $PEBA 'White' '#FFFFFF') )
        analysis = '[{"type":"PLA","color":"#000000","nozzle":0},{"type":"TPU","color":"#9C27B0","nozzle":1},{"type":"TPU","color":"#D9DAD1","nozzle":2},{"type":"TPU","color":"#FFFFFF","nozzle":3}]'
        expect = "n0e0=$PLA n1e0=$ROAMR n2e0=$TPU85 n3e0=$PEBA"
    }
    @{
        name = '4 of 4 with two black filaments, both in use'
        mats = @( (New-Mat $PLA 'Black' '#000000'), (New-Mat $ROAMR 'Lilac' '#9C27B0'), (New-Mat $TPU85 'Transparent' '#D9DAD1'), (New-Mat $PEBA 'Black' '#000000') )
        analysis = '[{"type":"PLA","color":"#000000","nozzle":0},{"type":"TPU","color":"#9C27B0","nozzle":1},{"type":"TPU","color":"#D9DAD1","nozzle":2},{"type":"TPU","color":"#000000","nozzle":3}]'
        expect = "n0e0=$PLA n1e0=$ROAMR n2e0=$TPU85 n3e0=$PEBA"
    }
    @{
        name = 'Single material, one analysis slot'
        mats = @( (New-Mat $ROAMR 'Lilac' '#9C27B0') )
        analysis = '[{"type":"TPU","color":"#9C27B0","nozzle":0}]'
        expect = "n0e0=$ROAMR"
    }
    @{
        name = 'Single material on tool 2, other tools idle (counts differ)'
        mats = @( (New-Mat $TPU85 'Transparent' '#D9DAD1') )
        analysis = '[{"nozzle":0},{"nozzle":1},{"type":"TPU","color":"#D9DAD1","nozzle":2},{"nozzle":3}]'
        expect = "n2e0=$TPU85"
    }
    @{
        name = 'Single material, flat analysis shape (no nozzle field)'
        mats = @( (New-Mat $ROAMR 'Lilac' '#9C27B0') )
        analysis = '[{"type":"TPU","color":"#9C27B0"}]'
        expect = "n0e0=$ROAMR"
    }
    @{
        name = '3 triplets, 4 slots (the staged workaround copy; counts differ)'
        mats = @( (New-Mat $ROAMR 'Lilac' '#9C27B0'), (New-Mat $TPU85 'Transparent' '#D9DAD1'), (New-Mat $PEBA 'Black' '#000000') )
        analysis = '[{"nozzle":0},{"type":"TPU","color":"#9C27B0","nozzle":1},{"type":"TPU","color":"#D9DAD1","nozzle":2},{"type":"TPU","color":"#000000","nozzle":3}]'
        expect = "n1e0=$ROAMR n2e0=$TPU85 n3e0=$PEBA"
    }
    @{
        name = 'Triplets out of extruder order: colour and family still beat position'
        mats = @( (New-Mat $PEBA 'White' '#FFFFFF'), (New-Mat $TPU85 'Transparent' '#D9DAD1'), (New-Mat $ROAMR 'Lilac' '#9C27B0'), (New-Mat $PLA 'Black' '#000000') )
        analysis = '[{"type":"PLA","color":"#000000","nozzle":0},{"type":"TPU","color":"#9C27B0","nozzle":1},{"type":"TPU","color":"#D9DAD1","nozzle":2},{"type":"TPU","color":"#FFFFFF","nozzle":3}]'
        expect = "n0e0=$PLA n1e0=$ROAMR n2e0=$TPU85 n3e0=$PEBA"
    }
    @{
        name = 'Position alone never tags: no colour or family signal stays untagged'
        mats = @( (New-Mat $PLA 'Black' '#000000'), (New-Mat $PEBA 'White' '#FFFFFF') )
        analysis = '[{"type":"PLA","color":"#000000","nozzle":0},{"type":"PETG","color":"#FF0000","nozzle":1}]'
        expect = "n0e0=$PLA"
    }
)

# --- Harness ------------------------------------------------------------------

function Get-U1Harness {
    # Pulls the helper functions and the U1 branch body out of an engine file.
    param([string]$Path)
    $full = (Resolve-Path -LiteralPath $Path).Path
    $tokens = $null; $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$tokens, [ref]$errs)
    if ($errs -and $errs.Count) { throw "Engine does not parse: $($errs[0].Message)" }

    $helpers = foreach ($name in 'Normalize-Hex', 'Normalize-Family', 'Get-FamilyTextForTypeId') {
        $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
        if (-not $fn) { throw "Helper $name not found in $full" }
        $fn.Extent.Text
    }

    $branch = $ast.Find({ param($n)
        $n -is [System.Management.Automation.Language.IfStatementAst] -and
        $n.Clauses[0].Item1.Extent.Text -eq '$meta.machineModel -match "U1"' }, $true)
    if (-not $branch) { throw "U1 branch not found in $full" }
    $body = $branch.Clauses[0].Item2.Extent.Text
    $body = $body.Substring(1, $body.Length - 2)      # drop the outer { }

    return @{ helpers = ($helpers -join "`r`n"); body = $body; path = $full }
}

function Invoke-U1Match {
    # Runs one case through one engine's U1 block; returns e.g. "n1e0=231507 n3e0=539620".
    param($Harness, $Case, [switch]$ShowLog)

    function Get-FilamentTypes { return $script:TestFilamentTypes }
    . ([scriptblock]::Create($Harness.helpers))

    # Same inputs the engine has in scope when it reaches the U1 branch.
    $u1MinMatchScore = 2
    $tagsObj         = @{ material = @($Case.mats) }
    $meta            = [pscustomobject]@{ machineModel = 'U1'; materials = @($Case.mats) }
    $materialData    = ConvertFrom-Json $Case.analysis
    if ($materialData -and $materialData.GetType().Name -notmatch 'Array') { $materialData = @($materialData) }
    $mappedMaterials = @()

    $block = [scriptblock]::Create($Harness.body)
    if ($ShowLog) { . $block } else { . $block 6>$null }

    return (@($mappedMaterials | ForEach-Object { 'n{0}e{1}={2}' -f $_.nozzle, $_.ext, $_.type }) -join ' ')
}

$engine   = Get-U1Harness $EnginePath
$baseline = if ($BaselinePath) { Get-U1Harness $BaselinePath } else { $null }

Write-Host "Engine:   $($engine.path)"
if ($baseline) { Write-Host "Baseline: $($baseline.path)" }
Write-Host ''

$failed = 0
foreach ($case in $cases) {
    $got = Invoke-U1Match -Harness $engine -Case $case -ShowLog:$ShowEngineLog
    $ok  = ($got -eq $case.expect)
    $lines = @("  tags: $got")
    if (-not $ok) { $lines += "  WANT: $($case.expect)" }

    if ($baseline) {
        $was = Invoke-U1Match -Harness $baseline -Case $case
        if ($case.fixed) {
            $lines += "  baseline (the bug): $was"
            if ($was -eq $case.expect) { $ok = $false; $lines += '  baseline already passed, so this case does not show the bug' }
        } elseif ($was -eq $got) {
            $lines += '  same as baseline'
        } else {
            $ok = $false
            $lines += "  CHANGED from baseline: $was"
        }
    }

    if ($ok) { Write-Host "PASS  $($case.name)" -ForegroundColor Green }
    else     { Write-Host "FAIL  $($case.name)" -ForegroundColor Red; $failed++ }
    $lines | ForEach-Object { Write-Host $_ }
}

Write-Host ''
if ($failed) { Write-Host "$failed of $($cases.Count) cases failed." -ForegroundColor Red; exit 1 }
Write-Host "All $($cases.Count) cases passed." -ForegroundColor Green
