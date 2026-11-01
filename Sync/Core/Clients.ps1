function Get-ITGlueHeaders {
    param([Parameter(Mandatory)]$Config)
    @{
        'x-api-key'    = $Config.ITGlueApiKey
        'Content-Type' = 'application/vnd.api+json'
        'Accept'       = 'application/vnd.api+json'
    }
}

function Get-ITGlueCollection {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Query = @{},
        [int]$PageSize = 1000
    )
    $page = 1
    while ($true) {
        $q = @{} + $Query
        $q['page[size]'] = $PageSize
        $q['page[number]'] = $page
        $uri = '{0}{1}{2}' -f $Config.ITGlueApiUrl, $Path, (ConvertTo-SyncQueryString $q)
        $resp = Invoke-SyncHttp -Method GET -Uri $uri -Headers (Get-ITGlueHeaders $Config)
        $data = @($resp.data | Where-Object { $null -ne $_ })
        foreach ($d in $data) { $d }
        $totalPages = Get-SyncProp $resp.meta 'total-pages'
        if ($data.Count -eq 0) { break }
        if ($null -ne $totalPages -and $page -ge [int]$totalPages) { break }
        if ($null -eq $totalPages -and $data.Count -lt $PageSize) { break }
        $page++
    }
}

function Get-HuduHeaders {
    param([Parameter(Mandatory)]$Config)
    @{ 'x-api-key' = $Config.HuduApiKey }
}

function Invoke-HuduApi {
    param(
        [Parameter(Mandatory)]$Config,
        [string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Query = @{},
        $Body,
        [switch]$AllowNotFound
    )
    $uri = '{0}{1}{2}' -f $Config.HuduBaseUrl, $Path, (ConvertTo-SyncQueryString $Query)
    Invoke-SyncHttp -Method $Method -Uri $uri -Headers (Get-HuduHeaders $Config) -Body $Body -AllowNotFound:$AllowNotFound
}

function Get-HuduCollection {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Property,
        [hashtable]$Query = @{},
        [int]$PageSize = 1000
    )
    $page = 1
    while ($true) {
        $q = @{} + $Query
        $q.page = $page
        $q.page_size = $PageSize
        $resp = Invoke-HuduApi -Config $Config -Path $Path -Query $q
        $items = @((Get-SyncProp $resp $Property) | Where-Object { $null -ne $_ })
        foreach ($i in $items) { $i }
        if ($items.Count -lt $PageSize) { break }
        $page++
    }
}
