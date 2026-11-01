function ConvertTo-SyncCanonical {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $out = [ordered]@{}
        foreach ($k in ($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive)) {
            $out[$k] = ConvertTo-SyncCanonical $Value[$k]
        }
        return $out
    }
    if ($Value -is [pscustomobject]) {
        $out = [ordered]@{}
        foreach ($k in ($Value.PSObject.Properties.Name | Sort-Object -CaseSensitive)) {
            $out[$k] = ConvertTo-SyncCanonical $Value.$k
        }
        return $out
    }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [System.Collections.IEnumerable]) {
        return , @($Value | ForEach-Object { ConvertTo-SyncCanonical $_ })
    }
    return $Value
}

function Get-SyncHash {
    param($Value)
    $json = ConvertTo-SyncCanonical $Value | ConvertTo-Json -Depth 50 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

function Get-SyncUtcNow {
    if ($script:SyncClock) { return (& $script:SyncClock) }
    return [datetime]::UtcNow
}

function ConvertTo-SyncUtc {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    $parsed = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse("$Value", [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
        return $parsed.UtcDateTime
    }
    return $null
}

function Format-SyncTime {
    param($Value)
    if ($null -eq $Value) { return $null }
    return ([datetime]$Value).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [cultureinfo]::InvariantCulture)
}

function Get-SyncProp {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function ConvertTo-SyncText {
    param($Value)
    if ($null -eq $Value) { return '' }
    return [string]$Value
}

function Split-SyncList {
    param([string[]]$Values)
    @($Values | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Write-SyncLog {
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')][string]$Level = 'INFO',
        [Parameter(Mandatory)][string]$Message
    )
    if ($Level -eq 'DEBUG' -and -not $script:SyncVerbose) { return }
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($script:SyncLogPath) {
        try { [System.IO.File]::AppendAllText($script:SyncLogPath, $line + [Environment]::NewLine) } catch {}
    }
    if ($script:SyncQuiet) { return }
    switch ($Level) {
        'ERROR' { [Console]::Error.WriteLine($line) }
        default { Write-Host $line }
    }
}
