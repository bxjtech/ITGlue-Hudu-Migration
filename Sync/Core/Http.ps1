$script:SyncTransport = $null
$script:SyncSleep = { param([double]$Seconds) Start-Sleep -Milliseconds ([int]($Seconds * 1000)) }

function Set-SyncTransport {
    param([scriptblock]$Transport)
    $script:SyncTransport = $Transport
}

function Get-SyncHttpStatus {
    param($ErrorRecord)
    $ex = $ErrorRecord.Exception
    while ($ex) {
        $resp = $ex.PSObject.Properties['Response']
        if ($resp -and $resp.Value -and $resp.Value.StatusCode) { return [int]$resp.Value.StatusCode }
        if ($ex -is [System.Net.Http.HttpRequestException] -and $ex.StatusCode) { return [int]$ex.StatusCode }
        $ex = $ex.InnerException
    }
    return 0
}

function Get-SyncRetryAfter {
    param($ErrorRecord)
    try {
        $delta = $ErrorRecord.Exception.Response.Headers.RetryAfter.Delta
        if ($delta) { return [double]$delta.TotalSeconds }
    } catch {}
    return $null
}

function ConvertTo-SyncQueryString {
    param([System.Collections.IDictionary]$Query)
    if (-not $Query -or $Query.Count -eq 0) { return '' }
    $parts = foreach ($k in ($Query.Keys | Sort-Object)) {
        if ($null -eq $Query[$k]) { continue }
        '{0}={1}' -f [uri]::EscapeDataString([string]$k), [uri]::EscapeDataString([string]$Query[$k])
    }
    return '?' + ($parts -join '&')
}

# POST is never retried after the server may have processed it (5xx/timeouts): a blind retry could
# create a duplicate record. The next run's name/ID matching picks up anything that did land.
function Invoke-SyncHttp {
    param(
        [string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Uri,
        [hashtable]$Headers = @{},
        $Body,
        [string]$ContentType = 'application/json; charset=utf-8',
        [int]$MaxRetries = 6,
        [switch]$AllowNotFound
    )
    $idempotent = $Method -in @('GET', 'PUT', 'DELETE', 'HEAD')
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            if ($script:SyncTransport) {
                return & $script:SyncTransport $Method $Uri $Headers $Body
            }
            $params = @{ Method = $Method; Uri = $Uri; Headers = $Headers; ErrorAction = 'Stop' }
            if ($null -ne $Body) {
                $params.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 50 -Compress }
                $params.ContentType = $ContentType
            }
            return Invoke-RestMethod @params
        } catch {
            $status = Get-SyncHttpStatus $_
            if ($status -eq 404 -and $AllowNotFound) { return $null }
            $retryable = ($status -eq 429) -or ($idempotent -and ($status -ge 500 -or $status -eq 0))
            if (-not $retryable -or $attempt -gt $MaxRetries) { throw }
            $wait = Get-SyncRetryAfter $_
            if (-not $wait) { $wait = [math]::Min(300, [math]::Pow(2, $attempt) * 2) }
            Write-SyncLog -Level WARN -Message ("{0} {1} returned {2}; retry {3}/{4} in {5}s" -f $Method, ($Uri -replace '\?.*$', ''), $status, $attempt, $MaxRetries, [int]$wait)
            & $script:SyncSleep $wait
        }
    }
}
