function Get-SyncStateDir {
    param([Parameter(Mandatory)]$Config)
    $dir = Join-Path $Config.DataDir 'state'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Write-SyncFileAtomic {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
    $tmp = "$Path.tmp-$PID"
    [System.IO.File]::WriteAllText($tmp, $Content, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::Move($tmp, $Path, $true)
}

function Read-SyncJson {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $raw = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json -AsHashtable)
}

# Each map is a snapshot file plus an append-only journal, so mappings for records created
# mid-run survive a crash without rewriting the whole snapshot on every create.
function Open-SyncMap {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Entity)
    $dir = Get-SyncStateDir $Config
    $map = @{
        Entity      = $Entity
        Path        = Join-Path $dir "map-$Entity.json"
        JournalPath = Join-Path $dir "map-$Entity.journal.jsonl"
        Records     = @{}
        Dirty       = $false
    }
    $snapshot = Read-SyncJson $map.Path
    if ($snapshot -and $snapshot.records) {
        foreach ($k in $snapshot.records.Keys) { $map.Records[[string]$k] = $snapshot.records[$k] }
    }
    if (Test-Path -LiteralPath $map.JournalPath) {
        foreach ($line in [System.IO.File]::ReadAllLines($map.JournalPath)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $entry = $line | ConvertFrom-Json -AsHashtable } catch { continue }
            if ($entry.op -eq 'set') { $map.Records[[string]$entry.itgId] = $entry.record }
            elseif ($entry.op -eq 'remove') { $map.Records.Remove([string]$entry.itgId) }
        }
        $map.Dirty = $true
    }
    return $map
}

function Get-SyncMapRecord {
    param([Parameter(Mandatory)]$Map, [Parameter(Mandatory)]$ItgId)
    return $Map.Records[[string]$ItgId]
}

function Set-SyncMapRecord {
    param([Parameter(Mandatory)]$Map, [Parameter(Mandatory)]$ItgId, [Parameter(Mandatory)][hashtable]$Record)
    $key = [string]$ItgId
    $Map.Records[$key] = $Record
    $line = @{ op = 'set'; itgId = $key; record = $Record } | ConvertTo-Json -Depth 20 -Compress
    [System.IO.File]::AppendAllText($Map.JournalPath, $line + "`n")
    $Map.Dirty = $true
}

function Save-SyncMap {
    param([Parameter(Mandatory)]$Map)
    if (-not $Map.Dirty) { return }
    $doc = [ordered]@{ version = 1; entity = $Map.Entity; savedAt = Format-SyncTime (Get-SyncUtcNow); records = $Map.Records }
    Write-SyncFileAtomic -Path $Map.Path -Content ($doc | ConvertTo-Json -Depth 20)
    if (Test-Path -LiteralPath $Map.JournalPath) { Remove-Item -LiteralPath $Map.JournalPath -Force }
    $Map.Dirty = $false
}

function Get-SyncStageState {
    param([Parameter(Mandatory)]$Config)
    $state = Read-SyncJson (Join-Path (Get-SyncStateDir $Config) 'stages.json')
    if (-not $state) { $state = @{} }
    return $state
}

function Save-SyncStageState {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][hashtable]$State)
    Write-SyncFileAtomic -Path (Join-Path (Get-SyncStateDir $Config) 'stages.json') -Content ($State | ConvertTo-Json -Depth 10)
}

function Get-SyncFlags {
    param([Parameter(Mandatory)]$Config)
    $doc = Read-SyncJson (Join-Path (Get-SyncStateDir $Config) 'flags.json')
    if (-not $doc -or -not $doc.flags) { return @{} }
    return $doc.flags
}

function Save-SyncFlags {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][hashtable]$Flags)
    $doc = [ordered]@{ version = 1; savedAt = Format-SyncTime (Get-SyncUtcNow); flags = $Flags }
    Write-SyncFileAtomic -Path (Join-Path (Get-SyncStateDir $Config) 'flags.json') -Content ($doc | ConvertTo-Json -Depth 10)
}

function Enter-SyncLock {
    param([Parameter(Mandatory)]$Config, [switch]$Force)
    $path = Join-Path (Get-SyncStateDir $Config) 'sync.lock'
    $info = @{ pid = $PID; host = [Environment]::MachineName; startedAt = Format-SyncTime (Get-SyncUtcNow) } | ConvertTo-Json -Compress
    for ($i = 0; $i -lt 2; $i++) {
        try {
            $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
            try {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($info)
                $fs.Write($bytes, 0, $bytes.Length)
            } finally { $fs.Dispose() }
            return $path
        } catch [System.IO.IOException] {
            $existing = Read-SyncJson $path
            $started = if ($existing) { ConvertTo-SyncUtc $existing.startedAt } else { $null }
            $stale = $started -and ((Get-SyncUtcNow) - $started).TotalHours -ge [double]$Config.LockStaleHours
            if ($Force -or $stale) {
                Write-SyncLog -Level WARN -Message "Removing $(if ($stale) {'stale '})lock held by pid $($existing.pid) on $($existing.host) since $($existing.startedAt)."
                Remove-Item -LiteralPath $path -Force
                continue
            }
            throw "Another sync is running (pid $($existing.pid) on $($existing.host) since $($existing.startedAt)). If it is not, run 'unlock' or pass -Force."
        }
    }
    throw "Could not acquire sync lock at $path."
}

function Exit-SyncLock {
    param([string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path)) { Remove-Item -LiteralPath $Path -Force }
}
