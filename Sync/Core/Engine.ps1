function New-SyncContext {
    param(
        [Parameter(Mandatory)]$Config,
        [ValidateSet('initial', 'incremental', 'cutover')][string]$Mode = 'incremental',
        [switch]$DryRun,
        [switch]$Reapply
    )
    $now = Get-SyncUtcNow
    @{
        Config     = $Config
        Mode       = $Mode
        DryRun     = [bool]$DryRun
        Reapply    = [bool]$Reapply
        RunId      = '{0}-{1}{2}' -f $now.ToString('yyyyMMdd-HHmmss'), $Mode, $(if ($DryRun) { '-dryrun' } else { '' })
        StartedAt  = $now
        StageState = Get-SyncStageState $Config
        Scope      = $null
        ScopeLabel = ''
        Cache      = @{}
        Maps       = @{}
        Stage      = $null
        Results    = [System.Collections.Generic.List[object]]::new()
        Flags      = [System.Collections.Generic.List[object]]::new()
        Stages     = [ordered]@{}
    }
}

function Get-SyncContextMap {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Entity)
    if (-not $Context.Maps.ContainsKey($Entity)) { $Context.Maps[$Entity] = Open-SyncMap -Config $Context.Config -Entity $Entity }
    return $Context.Maps[$Entity]
}

function Save-SyncMapping {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Entity, [Parameter(Mandatory)]$ItgId, [Parameter(Mandatory)][hashtable]$Record)
    if ($Context.DryRun) { return }
    Set-SyncMapRecord -Map (Get-SyncContextMap $Context $Entity) -ItgId $ItgId -Record $Record
}

function Invoke-SyncHuduWrite {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Method, [Parameter(Mandatory)][string]$Path, $Body)
    if ($Context.DryRun) { throw "Refusing $Method $Path during a dry run." }
    Invoke-HuduApi -Config $Context.Config -Method $Method -Path $Path -Body $Body
}

function Add-SyncResult {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Action,
        $ItgId, [string]$Name, $HuduId, [string]$Detail
    )
    $r = [pscustomobject]@{
        stage  = $Context.Stage
        action = $Action
        itgId  = if ($null -ne $ItgId) { [string]$ItgId } else { $null }
        huduId = if ($null -ne $HuduId -and "$HuduId" -ne '') { [string]$HuduId } else { $null }
        name   = $Name
        detail = $Detail
    }
    $Context.Results.Add($r)
    $level = if ($Action -eq 'error') { 'ERROR' } elseif ($Action -in @('unchanged', 'matched-reference')) { 'DEBUG' } else { 'INFO' }
    $text = "[$($Context.Stage)] $Action '$Name'"
    if ($r.itgId) { $text += " itg=$($r.itgId)" }
    if ($r.huduId) { $text += " hudu=$($r.huduId)" }
    if ($Detail) { $text += " - $Detail" }
    Write-SyncLog -Level $level -Message $text
}

function Add-SyncFlag {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Type,
        $ItgId, $HuduId, [string]$Name, [string]$Message
    )
    $f = [pscustomobject]@{
        stage   = $Context.Stage
        type    = $Type
        itgId   = if ($null -ne $ItgId) { [string]$ItgId } else { $null }
        huduId  = if ($null -ne $HuduId -and "$HuduId" -ne '') { [string]$HuduId } else { $null }
        name    = $Name
        message = $Message
    }
    $Context.Flags.Add($f)
    Write-SyncLog -Level WARN -Message "[$($Context.Stage)] FLAG $Type '$Name' - $Message"
}

# initial: create/match only. incremental/cutover: also update managed records whose source changed.
function Resolve-SyncAction {
    param([Parameter(Mandatory)]$Context, $MapRecord, [Parameter(Mandatory)][string]$DesiredHash, $ItgUpdatedAt)
    if (-not $MapRecord) { return 'create' }
    if (-not $MapRecord.managed) { return 'reference' }
    if ($Context.Mode -eq 'initial') { return 'unchanged' }
    if ($Context.Reapply) { return 'update' }
    if (-not $MapRecord.sourceHash) {
        $last = ConvertTo-SyncUtc $MapRecord.lastSyncedAt
        $itgAt = ConvertTo-SyncUtc $ItgUpdatedAt
        if ($last -and $itgAt -and $itgAt -le $last) { return 'baseline' }
        return 'update'
    }
    if ($MapRecord.sourceHash -eq $DesiredHash) { return 'unchanged' }
    return 'update'
}

function Test-SyncHuduModified {
    param($MapRecord, $HuduRecord)
    $known = ConvertTo-SyncUtc $MapRecord.huduUpdatedAt
    $current = ConvertTo-SyncUtc (Get-SyncProp $HuduRecord 'updated_at')
    if (-not $known -or -not $current) { return $false }
    return ($current - $known).TotalSeconds -gt 1
}

function Get-SyncITGlueOrganizations {
    param([Parameter(Mandatory)]$Context)
    if (-not $Context.Cache.ContainsKey('itg:organizations')) {
        Write-SyncLog -Message 'Fetching organizations from IT Glue'
        $Context.Cache['itg:organizations'] = @(Get-ITGlueCollection -Config $Context.Config -Path '/organizations')
    }
    return $Context.Cache['itg:organizations']
}

function Resolve-SyncCompanyScope {
    param([Parameter(Mandatory)]$Context, [string[]]$Company)
    $wanted = Split-SyncList $Company
    if ($wanted.Count -eq 0) { return }
    $orgs = Get-SyncITGlueOrganizations $Context
    $ids = [System.Collections.Generic.HashSet[string]]::new()
    $labels = @()
    foreach ($w in $wanted) {
        $hits = if ($w -match '^\d+$') { @($orgs | Where-Object { [string]$_.id -eq $w }) }
        else { @($orgs | Where-Object { $_.attributes.name -eq $w }) }
        if ($hits.Count -eq 0) { throw "Scope: no IT Glue organization matches '$w' (use the IT Glue organization ID or exact name)." }
        if ($hits.Count -gt 1) { Write-SyncLog -Level WARN -Message "Scope: '$w' matches $($hits.Count) organizations; including all of them." }
        foreach ($h in $hits) { [void]$ids.Add([string]$h.id); $labels += "$($h.attributes.name) ($($h.id))" }
    }
    $Context.Scope = $ids
    $Context.ScopeLabel = $labels -join ', '
}

function Test-SyncInScope {
    param([Parameter(Mandatory)]$Context, $OrganizationId)
    if ($null -eq $Context.Scope) { return $true }
    return $Context.Scope.Contains([string]$OrganizationId)
}

function Update-SyncFlagStore {
    param([Parameter(Mandatory)]$Context, [string[]]$FullyEvaluatedStages)
    $store = Get-SyncFlags $Context.Config
    $existing = @{} + $store
    $now = Format-SyncTime (Get-SyncUtcNow)
    foreach ($key in @($store.Keys)) {
        if ($store[$key].stage -in $FullyEvaluatedStages) { $store.Remove($key) }
    }
    foreach ($f in $Context.Flags) {
        $key = '{0}|{1}|{2}|{3}' -f $f.stage, $f.type, $f.itgId, $f.huduId
        $first = if ($existing.ContainsKey($key)) { $existing[$key].firstSeenAt } else { $now }
        $store[$key] = @{
            stage = $f.stage; type = $f.type; itgId = $f.itgId; huduId = $f.huduId; name = $f.name
            message = $f.message; firstSeenAt = $first; lastSeenAt = $now; runId = $Context.RunId
        }
    }
    Save-SyncFlags -Config $Context.Config -Flags $store
}

function Invoke-SyncRun {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string[]]$Stage,
        [ValidateSet('initial', 'incremental', 'cutover')][string]$Mode = 'incremental',
        [string[]]$Company,
        [switch]$DryRun,
        [switch]$Reapply,
        [switch]$WithDependencies,
        [switch]$Force
    )
    $ctx = New-SyncContext -Config $Config -Mode $Mode -DryRun:$DryRun -Reapply:$Reapply
    $plan = Resolve-SyncPlan -Requested $Stage -StageState $ctx.StageState -WithDependencies:$WithDependencies

    $logDir = Join-Path $Config.DataDir 'logs'
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $script:SyncLogPath = Join-Path $logDir "$($ctx.RunId).log"

    $lock = Enter-SyncLock -Config $Config -Force:$Force
    try {
        Write-SyncLog -Message "Run $($ctx.RunId): mode=$Mode$(if ($DryRun) {' (dry run, no writes)'}) stages=$($plan -join ' -> ')"
        if ($Company) {
            Resolve-SyncCompanyScope -Context $ctx -Company $Company
            Write-SyncLog -Message "Scoped to: $($ctx.ScopeLabel)"
        }

        $failed = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($name in $plan) {
            $def = $script:SyncStages[$name]
            $ctx.Stage = $name
            $summary = [ordered]@{ status = 'running'; startedAt = Get-SyncUtcNow; finishedAt = $null; error = $null }
            $ctx.Stages[$name] = $summary

            $blockedBy = @($def.Requires | Where-Object { $failed.Contains($_) })
            if ($blockedBy.Count) {
                $summary.status = 'skipped'
                $summary.error = "upstream stage failed: $($blockedBy -join ', ')"
                [void]$failed.Add($name)
                Write-SyncLog -Level WARN -Message "[$name] skipped because $($summary.error)"
                continue
            }

            Write-SyncLog -Message "[$name] starting"
            try {
                & $def.Run $ctx
                $summary.status = 'succeeded'
            } catch {
                $summary.status = 'failed'
                $summary.error = "$($_.Exception.Message)"
                [void]$failed.Add($name)
                Write-SyncLog -Level ERROR -Message "[$name] failed: $($_.Exception.Message)"
                Write-SyncLog -Level DEBUG -Message $_.ScriptStackTrace
            } finally {
                $summary.finishedAt = Get-SyncUtcNow
                foreach ($m in $ctx.Maps.Values) { if (-not $ctx.DryRun) { Save-SyncMap $m } }
            }

            if ($summary.status -eq 'succeeded' -and -not $ctx.DryRun) {
                $st = if ($ctx.StageState[$name]) { $ctx.StageState[$name] } else { @{} }
                $st.lastSuccessAt = Format-SyncTime $summary.finishedAt
                $st.lastMode = $Mode
                $st.lastRunId = $ctx.RunId
                if ($null -eq $ctx.Scope) { $st.watermark = Format-SyncTime $summary.startedAt }
                else { $st.lastScopedAt = Format-SyncTime $summary.finishedAt }
                $ctx.StageState[$name] = $st
                Save-SyncStageState -Config $Config -State $ctx.StageState
            }
        }

        if (-not $ctx.DryRun) {
            $evaluated = if ($null -eq $ctx.Scope) { @($ctx.Stages.Keys | Where-Object { $ctx.Stages[$_].status -eq 'succeeded' }) } else { @() }
            Update-SyncFlagStore -Context $ctx -FullyEvaluatedStages $evaluated
        }
    } finally {
        Exit-SyncLock $lock
    }

    $report = Write-SyncReport -Context $ctx
    return $report
}
