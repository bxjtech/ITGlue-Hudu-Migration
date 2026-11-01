#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('run', 'stages', 'status', 'flags', 'import-legacy', 'check', 'unlock', 'help')]
    [string]$Command = 'help',
    [string[]]$Stage,
    [string[]]$Recipe,
    [ValidateSet('initial', 'incremental', 'cutover')]
    [string]$Mode,
    [string[]]$Company,
    [switch]$DryRun,
    [switch]$Reapply,
    [switch]$WithDependencies,
    [switch]$Force,
    [string]$Config,
    [string]$Path,
    [switch]$Overwrite,
    [switch]$Json,
    [switch]$LogDebug
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'SyncEngine.psm1') -Force
Set-SyncLogOptions -Verbose:$LogDebug

function Show-Help {
    @'
IT Glue -> Hudu sync

USAGE
  sync <command> [options]

COMMANDS
  run            Sync one or more stages
  stages         List stages, dependencies and recipes
  status         Last run, watermark and mapped-record count per stage
  flags          Open flags (records left alone for manual review)
  import-legacy  Seed ID maps from an earlier migration's MigrationLogs folder
  check          Test connectivity and API keys for IT Glue and Hudu
  unlock         Remove a stale run lock

RUN OPTIONS
  -Stage <a,b>         Stages to run (dependency order is enforced)
  -Recipe <name>       core | assets | knowledge | all
  -Mode <mode>         initial     create + match only, never update
                       incremental create new, update changed since last run
                       cutover     re-evaluate every record, final reconciliation
  -Company <id|name>   Limit to IT Glue organizations (comma-separated); does not advance watermarks
  -DryRun              Report what would change, write nothing
  -Reapply             With incremental/cutover: rewrite managed records even if unchanged
  -WithDependencies    Also run required upstream stages that have never synced
  -Force               Take over the run lock

EXAMPLES
  sync run -Stage companies -Mode initial
  sync run -Recipe core -Mode incremental
  sync run -Recipe all -Mode cutover -DryRun
  sync run -Stage companies -Mode incremental -Company 123456,"Acme Corp"
  sync import-legacy -Path /data/MigrationLogs
'@ | Write-Host
}

$exitCode = 0
try {
$cfg = Get-SyncConfig -Path $Config

switch ($Command) {
    'help' { Show-Help }

    'stages' {
        $state = Get-SyncStageState $cfg
        $rows = foreach ($s in (Get-SyncStageDefinitions)) {
            [pscustomobject]@{
                Stage    = $s.Name
                Ready    = if ($s.Implemented) { 'yes' } else { 'planned' }
                Requires = $s.Requires -join ', '
                After    = $s.After -join ', '
                LastSync = Format-SyncTime $state[$s.Name].lastSuccessAt
            }
        }
        if ($Json) { $rows | ConvertTo-Json -Depth 5 } else {
            $rows | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
            Write-Host 'Recipes:'
            foreach ($r in (Get-SyncRecipes).GetEnumerator()) { Write-Host ("  {0,-10} {1}" -f $r.Key, ($r.Value -join ', ')) }
            Write-Host '  all        every stage'
        }
    }

    'status' {
        $state = Get-SyncStageState $cfg
        $flags = Get-SyncFlags $cfg
        $rows = foreach ($s in (Get-SyncStageDefinitions)) {
            $map = Open-SyncMap -Config $cfg -Entity $s.Name
            $st = $state[$s.Name]
            [pscustomobject]@{
                Stage      = $s.Name
                Ready      = if ($s.Implemented) { 'yes' } else { 'planned' }
                Mapped     = $map.Records.Count
                LastSync   = Format-SyncTime $st.lastSuccessAt
                LastMode   = $st.lastMode
                Watermark  = Format-SyncTime $st.watermark
                OpenFlags  = @($flags.Values | Where-Object stage -eq $s.Name).Count
            }
        }
        if ($Json) { $rows | ConvertTo-Json -Depth 5 } else { $rows | Format-Table -AutoSize | Out-String -Width 220 | Write-Host }
    }

    'flags' {
        $flags = @((Get-SyncFlags $cfg).Values)
        $wanted = Split-SyncList $Stage
        if ($wanted.Count) { $flags = @($flags | Where-Object { $_.stage -in $wanted }) }
        $rows = $flags | Sort-Object stage, type, name | ForEach-Object {
            [pscustomobject]@{ Stage = $_.stage; Type = $_.type; Name = $_.name; ITGlueId = $_.itgId; HuduId = $_.huduId; Since = Format-SyncTime $_.firstSeenAt; Detail = $_.message }
        }
        if ($Json) { @($rows) | ConvertTo-Json -Depth 5 }
        elseif (-not $rows) { Write-Host 'No open flags.' }
        else { $rows | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Host }
    }

    'import-legacy' {
        if (-not $Path) { throw 'import-legacy needs -Path <MigrationLogs folder>.' }
        $rows = Import-SyncLegacyLogs -Config $cfg -Path $Path -Overwrite:$Overwrite -DryRun:$DryRun
        if ($Json) { $rows | ConvertTo-Json -Depth 5 } else { $rows | Format-Table -AutoSize | Out-String | Write-Host }
        if ($DryRun) { Write-Host 'Dry run: nothing was written.' }
    }

    'check' {
        Assert-SyncConfigForApi $cfg
        $ok = $true
        try {
            $info = Invoke-HuduApi -Config $cfg -Path '/api/v1/api_info'
            $version = [version]($info.version -replace '[^\d\.].*$', '')
            $status = if ($version -lt [version]'2.39.6' -or $version -eq [version]'2.37.0') { $ok = $false; 'UNSUPPORTED (need 2.39.6+)' } else { 'ok' }
            Write-Host "Hudu    $($cfg.HuduBaseUrl)  version $($info.version)  $status"
        } catch { $ok = $false; Write-Host "Hudu    $($cfg.HuduBaseUrl)  FAILED: $($_.Exception.Message)" }
        try {
            $resp = Invoke-SyncHttp -Uri "$($cfg.ITGlueApiUrl)/organizations?page[size]=1" -Headers (Get-ITGlueHeaders $cfg)
            Write-Host "IT Glue $($cfg.ITGlueApiUrl)  ok  ($($resp.meta.'total-count') organizations)"
        } catch { $ok = $false; Write-Host "IT Glue $($cfg.ITGlueApiUrl)  FAILED: $($_.Exception.Message)" }
        if ($cfg.ITGlueExportPath) {
            $exists = Test-Path -LiteralPath $cfg.ITGlueExportPath
            Write-Host "Export  $($cfg.ITGlueExportPath)  $(if ($exists) {'found'} else {'NOT FOUND'})"
        }
        Write-Host "Data    $($cfg.DataDir)"
        if (-not $ok) { $exitCode = 1 }
    }

    'unlock' {
        $lock = Join-Path (Get-SyncStateDir $cfg) 'sync.lock'
        if (Test-Path -LiteralPath $lock) { Remove-Item -LiteralPath $lock -Force; Write-Host 'Lock removed.' } else { Write-Host 'No lock present.' }
    }

    'run' {
        $requested = @(Split-SyncList $Stage) + @(Split-SyncList $Recipe)
        if ($requested.Count -eq 0) { throw 'run needs -Stage and/or -Recipe. See: sync stages' }
        if (-not $Mode) { throw 'run needs -Mode initial|incremental|cutover.' }
        Assert-SyncConfigForApi $cfg
        $report = Invoke-SyncRun -Config $cfg -Stage $requested -Mode $Mode -Company $Company -DryRun:$DryRun -Reapply:$Reapply -WithDependencies:$WithDependencies -Force:$Force
        if ($Json) { $report | Select-Object Success, RunId, ReportPath, JsonPath, Summary | ConvertTo-Json -Depth 6 }
        if (-not $report.Success) { $exitCode = 1 }
    }
}
} catch {
    [Console]::Error.WriteLine("ERROR: $($_.Exception.Message)")
    $exitCode = 2
}
exit $exitCode
