Test 'plan: hard dependencies are ordered first regardless of requested order' {
    Set-SyncStageRunner -Name 'passwords' -Run { param($c) }
    try {
        $plan = Resolve-SyncPlan -Requested @('passwords', 'companies')
        Assert-Equal 'companies,passwords' ($plan -join ',')
    } finally { (Get-SyncStageDefinitions | Where-Object Name -eq 'passwords').Implemented = $false }
}

Test 'plan: a stage whose dependency never synced is refused' {
    Set-SyncStageRunner -Name 'passwords' -Run { param($c) }
    try {
        Assert-Throws { Resolve-SyncPlan -Requested @('passwords') } -Like "*requires companies*"
        $plan = Resolve-SyncPlan -Requested @('passwords') -StageState @{ companies = @{ lastSuccessAt = '2026-01-01T00:00:00Z' } }
        Assert-Equal 'passwords' ($plan -join ',')
        $plan = Resolve-SyncPlan -Requested @('passwords') -WithDependencies
        Assert-Equal 'companies,passwords' ($plan -join ',')
    } finally { (Get-SyncStageDefinitions | Where-Object Name -eq 'passwords').Implemented = $false }
}

Test 'plan: soft ordering applies only when both stages are in the run' {
    foreach ($n in 'passwords', 'flexassets', 'flexlayouts') { Set-SyncStageRunner -Name $n -Run { param($c) } }
    try {
        $state = @{ companies = @{ lastSuccessAt = 'x' } }
        Assert-Equal 'flexlayouts,flexassets,passwords' ((Resolve-SyncPlan -Requested @('passwords', 'flexassets', 'flexlayouts') -StageState $state) -join ',')
        Assert-Equal 'passwords' ((Resolve-SyncPlan -Requested @('passwords') -StageState $state) -join ',')
    } finally { foreach ($n in 'passwords', 'flexassets', 'flexlayouts') { (Get-SyncStageDefinitions | Where-Object Name -eq $n).Implemented = $false } }
}

Test 'plan: recipes expand, comma lists split, unknown names and planned stages are rejected' {
    $plan = Resolve-SyncPlan -Requested @('core') -IncludeUnimplemented
    Assert-Equal 'companies,locations,contacts,websites' ($plan -join ',')
    Assert-Equal 'companies' ((Resolve-SyncPlan -Requested @('companies, companies')) -join ',')
    Assert-Throws { Resolve-SyncPlan -Requested @('nope') } -Like "*Unknown stage*"
    Assert-Throws { Resolve-SyncPlan -Requested @('assets') -StageState @{ companies = @{ lastSuccessAt = 'x' } } } -Like "*Not implemented yet*"
}
