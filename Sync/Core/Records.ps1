# Shared create/update flow for every stage, so dry runs, change detection, conflict handling
# and mapping writes behave identically everywhere.

function Get-SyncMapHuduIndex {
    param([Parameter(Mandatory)]$Map)
    $index = @{}
    foreach ($k in $Map.Records.Keys) { $index[[string]$Map.Records[$k].huduId] = $k }
    return $index
}

function Invoke-SyncCreateRecord {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Entity,
        [Parameter(Mandatory)]$ItgId,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Hash,
        $ItgUpdatedAt,
        [Parameter(Mandatory)][scriptblock]$Write,
        [hashtable]$Extra = @{}
    )
    if ($Context.DryRun) {
        Add-SyncResult $Context 'would-create' $ItgId $Name $null
        return $null
    }
    $created = & $Write
    if (-not $created -or -not $created.id) { throw 'Hudu did not return the created record.' }
    $record = @{
        huduId = [string]$created.id; huduName = $Name; managed = $true; matchedBy = 'created'
        sourceHash = $Hash; huduUpdatedAt = $created.updated_at
        itgUpdatedAt = Format-SyncTime $ItgUpdatedAt; lastSyncedAt = Format-SyncTime (Get-SyncUtcNow)
    }
    foreach ($k in $Extra.Keys) { $record[$k] = $Extra[$k] }
    Save-SyncMapping $Context $Entity $ItgId $record
    Add-SyncResult $Context 'created' $ItgId $Name $created.id
    return $created
}

function Invoke-SyncExistingRecord {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Entity,
        [Parameter(Mandatory)]$ItgId,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][hashtable]$Record,
        [Parameter(Mandatory)][string]$Hash,
        $ItgUpdatedAt,
        $Current,
        [Parameter(Mandatory)][scriptblock]$Write,
        [hashtable]$Extra = @{}
    )
    $action = Resolve-SyncAction -Context $Context -MapRecord $Record -DesiredHash $Hash -ItgUpdatedAt $ItgUpdatedAt
    switch ($action) {
        'reference' { Add-SyncResult $Context 'reference' $ItgId $Name $Record.huduId 'pre-existing Hudu record (not managed)' }
        'unchanged' { Add-SyncResult $Context 'unchanged' $ItgId $Name $Record.huduId }
        'baseline' {
            $Record.sourceHash = $Hash
            $Record.itgUpdatedAt = Format-SyncTime $ItgUpdatedAt
            $Record.huduUpdatedAt = Get-SyncProp $Current 'updated_at'
            Save-SyncMapping $Context $Entity $ItgId $Record
            Add-SyncResult $Context 'baseline' $ItgId $Name $Record.huduId 'unchanged since the earlier migration; recorded as baseline'
        }
        'update' {
            if ($Current -and (Test-SyncHuduModified -MapRecord $Record -HuduRecord $Current)) {
                if ($Context.Config.ConflictPolicy -eq 'hudu-wins') {
                    Add-SyncFlag $Context 'hudu-modified' $ItgId $Record.huduId $Name 'Changed in both IT Glue and Hudu since the last sync; kept the Hudu version (ConflictPolicy=hudu-wins).'
                    Add-SyncResult $Context 'skipped' $ItgId $Name $Record.huduId 'conflict'
                    return
                }
                Add-SyncFlag $Context 'hudu-modified' $ItgId $Record.huduId $Name 'Changed in both IT Glue and Hudu since the last sync; IT Glue version applied (ConflictPolicy=itglue-wins).'
            }
            if ($Context.DryRun) {
                Add-SyncResult $Context 'would-update' $ItgId $Name $Record.huduId
                return
            }
            $updated = & $Write
            $Record.sourceHash = $Hash
            $Record.huduName = $Name
            $Record.huduUpdatedAt = Get-SyncProp $updated 'updated_at'
            $Record.itgUpdatedAt = Format-SyncTime $ItgUpdatedAt
            $Record.lastSyncedAt = Format-SyncTime (Get-SyncUtcNow)
            foreach ($k in $Extra.Keys) { $Record[$k] = $Extra[$k] }
            Save-SyncMapping $Context $Entity $ItgId $Record
            Add-SyncResult $Context 'updated' $ItgId $Name $Record.huduId
        }
    }
}

function Add-SyncDeletedFlags {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Map, [Parameter(Mandatory)]$Items, [string]$What = 'record')
    if ($null -ne $Context.Scope) { return }
    $present = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Items | ForEach-Object { [string]$_.id }))
    foreach ($k in @($Map.Records.Keys)) {
        if (-not $present.Contains($k)) {
            $r = $Map.Records[$k]
            $label = if ($r.huduName) { $r.huduName } else { $r.itgName }
            Add-SyncFlag $Context 'deleted-in-itglue' $k $r.huduId $label "The $What no longer exists in IT Glue; Hudu record left alone."
        }
    }
}

function Get-SyncCompanyHuduId {
    param([Parameter(Mandatory)]$Context, $OrganizationId)
    $rec = Get-SyncMapRecord (Get-SyncContextMap $Context 'companies') ([string]$OrganizationId)
    if ($rec) { return [string]$rec.huduId }
    return $null
}

function Get-SyncLatestTime {
    param([object[]]$Values)
    @($Values | ForEach-Object { ConvertTo-SyncUtc $_ } | Where-Object { $_ } | Sort-Object -Descending) | Select-Object -First 1
}

function ConvertTo-SyncDateField {
    param($Value)
    $dt = ConvertTo-SyncUtc $Value
    if (-not $dt) { return '' }
    return $dt.ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture)
}

function ConvertTo-SyncHtml {
    param($Value)
    return [System.Net.WebUtility]::HtmlEncode((ConvertTo-SyncText $Value))
}
