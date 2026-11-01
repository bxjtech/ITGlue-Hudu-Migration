function Get-SyncRunSummary {
    param([Parameter(Mandatory)]$Context)
    $rows = foreach ($name in $Context.Stages.Keys) {
        $res = @($Context.Results | Where-Object stage -eq $name)
        $counts = [ordered]@{}
        foreach ($g in ($res | Group-Object action)) { $counts[$g.Name] = $g.Count }
        [pscustomobject]@{
            stage   = $name
            status  = $Context.Stages[$name].status
            counts  = $counts
            flags   = @($Context.Flags | Where-Object stage -eq $name).Count
            errors  = @($res | Where-Object action -eq 'error').Count
            seconds = if ($Context.Stages[$name].finishedAt) { [int]($Context.Stages[$name].finishedAt - $Context.Stages[$name].startedAt).TotalSeconds } else { 0 }
            message = $Context.Stages[$name].error
        }
    }
    return @($rows)
}

function Write-SyncReport {
    param([Parameter(Mandatory)]$Context)
    $dir = Join-Path $Context.Config.DataDir 'reports'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $summary = Get-SyncRunSummary $Context
    $ok = -not ($summary | Where-Object { $_.status -ne 'succeeded' -or $_.errors -gt 0 })

    $doc = [ordered]@{
        runId     = $Context.RunId
        mode      = $Context.Mode
        dryRun    = $Context.DryRun
        scope     = $Context.ScopeLabel
        startedAt = Format-SyncTime $Context.StartedAt
        endedAt   = Format-SyncTime (Get-SyncUtcNow)
        success   = $ok
        stages    = $summary
        flags     = $Context.Flags
        results   = @($Context.Results | Where-Object { $_.action -notin @('unchanged', 'reference') })
    }
    $jsonPath = Join-Path $dir "$($Context.RunId).json"
    Write-SyncFileAtomic -Path $jsonPath -Content ($doc | ConvertTo-Json -Depth 10)

    $md = [System.Text.StringBuilder]::new()
    [void]$md.AppendLine("# Sync run $($Context.RunId)")
    [void]$md.AppendLine()
    [void]$md.AppendLine("- Mode: **$($Context.Mode)**$(if ($Context.DryRun) {' (dry run - nothing was written)'})")
    if ($Context.ScopeLabel) { [void]$md.AppendLine("- Scope: $($Context.ScopeLabel)") }
    [void]$md.AppendLine("- Started: $($doc.startedAt)  Ended: $($doc.endedAt)")
    [void]$md.AppendLine("- Result: $(if ($ok) {'success'} else {'completed with errors'})")
    [void]$md.AppendLine()
    [void]$md.AppendLine('| Stage | Status | Actions | Flags | Errors | Seconds |')
    [void]$md.AppendLine('|---|---|---|---|---|---|')
    foreach ($s in $summary) {
        $actions = ($s.counts.GetEnumerator() | ForEach-Object { "$($_.Key): $($_.Value)" }) -join ', '
        [void]$md.AppendLine("| $($s.stage) | $($s.status) | $actions | $($s.flags) | $($s.errors) | $($s.seconds) |")
    }
    if ($Context.Flags.Count) {
        [void]$md.AppendLine()
        [void]$md.AppendLine('## Flags (left alone - review manually)')
        [void]$md.AppendLine()
        [void]$md.AppendLine('| Stage | Type | Name | IT Glue ID | Hudu ID | Detail |')
        [void]$md.AppendLine('|---|---|---|---|---|---|')
        foreach ($f in $Context.Flags) {
            [void]$md.AppendLine("| $($f.stage) | $($f.type) | $($f.name -replace '\|','/') | $($f.itgId) | $($f.huduId) | $($f.message -replace '\|','/') |")
        }
    }
    $errs = @($Context.Results | Where-Object action -eq 'error')
    if ($errs.Count) {
        [void]$md.AppendLine()
        [void]$md.AppendLine('## Errors')
        [void]$md.AppendLine()
        foreach ($e in $errs) { [void]$md.AppendLine("- [$($e.stage)] $($e.name) (itg $($e.itgId)): $($e.detail)") }
    }
    $mdPath = Join-Path $dir "$($Context.RunId).md"
    Write-SyncFileAtomic -Path $mdPath -Content $md.ToString()

    Write-SyncLog -Message "Report: $mdPath"
    foreach ($s in $summary) {
        $actions = ($s.counts.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '
        Write-SyncLog -Level $(if ($s.status -eq 'succeeded' -and $s.errors -eq 0) { 'INFO' } else { 'WARN' }) -Message ("  {0,-16} {1,-10} {2} flags={3}" -f $s.stage, $s.status, $actions, $s.flags)
    }
    return [pscustomobject]@{ Success = $ok; RunId = $Context.RunId; ReportPath = $mdPath; JsonPath = $jsonPath; Summary = $summary; Flags = $Context.Flags; Results = $Context.Results }
}
