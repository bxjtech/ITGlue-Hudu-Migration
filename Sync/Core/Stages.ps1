$script:SyncStages = [ordered]@{}

$script:SyncRecipes = [ordered]@{
    core      = @('companies', 'locations', 'contacts', 'websites')
    assets    = @('configurations', 'networks', 'flexlayouts', 'flexassets')
    knowledge = @('articles', 'passwordfolders', 'passwords', 'checklists', 'relations', 'urlrewrite')
}

function Register-SyncStage {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Description,
        [string[]]$Requires = @(),
        [string[]]$After = @(),
        [scriptblock]$Run
    )
    $script:SyncStages[$Name] = [pscustomobject]@{
        Name        = $Name
        Description = $Description
        Requires    = @($Requires)
        After       = @($After)
        Run         = $Run
        Implemented = $null -ne $Run
    }
}

function Set-SyncStageRunner {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Run)
    if (-not $script:SyncStages.Contains($Name)) { throw "Stage '$Name' is not in the stage catalog." }
    $script:SyncStages[$Name].Run = $Run
    $script:SyncStages[$Name].Implemented = $true
}

function Get-SyncStageDefinitions { $script:SyncStages.Values }

function Get-SyncRecipes { $script:SyncRecipes }

function Expand-SyncStageNames {
    param([string[]]$Names)
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($n in (Split-SyncList $Names)) {
        $key = $n.ToLowerInvariant()
        $expanded = if ($key -eq 'all') { @($script:SyncStages.Keys) }
        elseif ($script:SyncRecipes.Contains($key)) { $script:SyncRecipes[$key] }
        elseif ($script:SyncStages.Contains($key)) { @($key) }
        else {
            throw "Unknown stage or recipe '$n'. Stages: $($script:SyncStages.Keys -join ', '). Recipes: all, $($script:SyncRecipes.Keys -join ', ')."
        }
        foreach ($e in $expanded) { if (-not $out.Contains($e)) { $out.Add($e) } }
    }
    return , $out.ToArray()
}

function Test-SyncStageSatisfied {
    param([string]$Name, [hashtable]$StageState)
    return ($StageState.ContainsKey($Name) -and $StageState[$Name].lastSuccessAt)
}

# Hard dependencies (Requires) must have succeeded before or be part of this plan. Soft
# dependencies (After) only influence ordering when both stages are in the same plan.
function Resolve-SyncPlan {
    param(
        [Parameter(Mandatory)][string[]]$Requested,
        [hashtable]$StageState = @{},
        [switch]$WithDependencies,
        [switch]$IncludeUnimplemented
    )
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($n in (Expand-SyncStageNames $Requested)) { $names.Add($n) }

    if ($WithDependencies) {
        $i = 0
        while ($i -lt $names.Count) {
            foreach ($req in $script:SyncStages[$names[$i]].Requires) {
                if (-not $names.Contains($req) -and -not (Test-SyncStageSatisfied $req $StageState)) { $names.Add($req) }
            }
            $i++
        }
    }

    if (-not $IncludeUnimplemented) {
        $pending = @($names | Where-Object { -not $script:SyncStages[$_].Implemented })
        if ($pending.Count) {
            throw "Not implemented yet: $($pending -join ', '). Implemented stages: $((@($script:SyncStages.Values | Where-Object Implemented).Name) -join ', ')."
        }
    }

    $priority = @{}
    for ($i = 0; $i -lt $names.Count; $i++) { $priority[$names[$i]] = $i }
    $edges = @{}
    $inDegree = @{}
    foreach ($n in $names) { $edges[$n] = [System.Collections.Generic.List[string]]::new(); $inDegree[$n] = 0 }
    foreach ($n in $names) {
        $def = $script:SyncStages[$n]
        foreach ($dep in @($def.Requires + $def.After | Select-Object -Unique)) {
            if ($names.Contains($dep)) { $edges[$dep].Add($n); $inDegree[$n]++ }
        }
    }
    $ordered = [System.Collections.Generic.List[string]]::new()
    $ready = [System.Collections.Generic.List[string]]::new()
    foreach ($n in $names) { if ($inDegree[$n] -eq 0) { $ready.Add($n) } }
    while ($ready.Count) {
        $next = $ready | Sort-Object { $priority[$_] } | Select-Object -First 1
        [void]$ready.Remove($next)
        $ordered.Add($next)
        foreach ($m in $edges[$next]) {
            $inDegree[$m]--
            if ($inDegree[$m] -eq 0) { $ready.Add($m) }
        }
    }
    if ($ordered.Count -ne $names.Count) { throw 'Stage dependency cycle detected.' }

    foreach ($n in $ordered) {
        $missing = @($script:SyncStages[$n].Requires | Where-Object { -not $ordered.Contains($_) -and -not (Test-SyncStageSatisfied $_ $StageState) })
        if ($missing.Count) {
            throw "Stage '$n' requires $($missing -join ', ') to have been synced first. Run those stages, or add -WithDependencies."
        }
    }
    return , $ordered.ToArray()
}
