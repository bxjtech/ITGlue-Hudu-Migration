# In-memory stand-ins for the IT Glue and Hudu REST APIs, plugged in via Set-SyncTransport.
$script:ItgBase = 'https://itg.test'
$script:HuduBase = 'https://hudu.test'

function New-FakeHttpError {
    param([int]$Status)
    [System.Net.Http.HttpRequestException]::new("Response status code does not indicate success: $Status", $null, [System.Net.HttpStatusCode]$Status)
}

function ConvertTo-FakeResponse { param($Value) $Value | ConvertTo-Json -Depth 20 | ConvertFrom-Json }

function Get-FakeNowText { $global:FakeNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }

function Reset-FakeApis {
    $global:FakeNow = [datetime]::new(2026, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
    $global:Fake = @{
        Orgs      = [System.Collections.Generic.List[object]]::new()
        Locations = [System.Collections.Generic.List[object]]::new()
        Companies = [System.Collections.Generic.List[object]]::new()
        NextId    = 100
        Calls     = [System.Collections.Generic.List[object]]::new()
        FailNext  = @()
        PostLimit = $null
    }
}

function Step-FakeClock { param([int]$Minutes = 60) $global:FakeNow = $global:FakeNow.AddMinutes($Minutes) }

function Add-FakeOrg {
    param([string]$Id, [string]$Name, [string]$ShortName = '', [string]$Type = 'Customer', [string]$QuickNotes = '', [string]$Alert = '')
    $global:Fake.Orgs.Add(@{
        id = $Id; type = 'organizations'
        attributes = @{ name = $Name; 'short-name' = $ShortName; 'organization-type-name' = $Type; 'quick-notes' = $QuickNotes; alert = $Alert; 'updated-at' = (Get-FakeNowText) }
    })
}

function Set-FakeOrg {
    param([string]$Id, [hashtable]$Attributes)
    $org = $global:Fake.Orgs | Where-Object { $_.id -eq $Id }
    foreach ($k in $Attributes.Keys) { $org.attributes[$k] = $Attributes[$k] }
    $org.attributes['updated-at'] = Get-FakeNowText
}

function Remove-FakeOrg { param([string]$Id) [void]$global:Fake.Orgs.Remove(($global:Fake.Orgs | Where-Object { $_.id -eq $Id })) }

function Add-FakeLocation {
    param([string]$Id, [string]$OrgId, [bool]$Primary = $true, [string]$City = 'Springfield', [string]$Address = '1 Main St')
    $global:Fake.Locations.Add(@{
        id = $Id; type = 'locations'
        attributes = @{ 'organization-id' = [int]$OrgId; primary = $Primary; 'address-1' = $Address; 'address-2' = ''; city = $City; 'region-name' = 'IL'; 'postal-code' = '62701'; 'country-name' = 'United States'; phone = '555-0100'; fax = ''; 'updated-at' = (Get-FakeNowText) }
    })
}

function Set-FakeLocation {
    param([string]$Id, [hashtable]$Attributes)
    $loc = $global:Fake.Locations | Where-Object { $_.id -eq $Id }
    foreach ($k in $Attributes.Keys) { $loc.attributes[$k] = $Attributes[$k] }
    $loc.attributes['updated-at'] = Get-FakeNowText
}

function Add-FakeHuduCompany {
    param([string]$Name, [hashtable]$Fields = @{})
    $c = @{ id = $global:Fake.NextId++; name = $Name; updated_at = (Get-FakeNowText); created_at = (Get-FakeNowText) }
    foreach ($k in $Fields.Keys) { $c[$k] = $Fields[$k] }
    $global:Fake.Companies.Add($c)
    return $c
}

function Get-FakeHuduCompany { param($Id) $global:Fake.Companies | Where-Object { [string]$_.id -eq [string]$Id } }

function Get-FakeCalls { param([string]$Method, [string]$Like = '*') @($global:Fake.Calls | Where-Object { $_.Method -eq $Method -and $_.Path -like $Like }) }

function Get-FakeQuery {
    param([string]$Uri)
    $q = @{}
    $u = [uri]$Uri
    foreach ($pair in ($u.Query.TrimStart('?') -split '&' | Where-Object { $_ })) {
        $kv = $pair -split '=', 2
        $q[[uri]::UnescapeDataString($kv[0])] = [uri]::UnescapeDataString($kv[1])
    }
    return $q
}

function Invoke-FakeItgPage {
    param($Items, $Query)
    $size = [int]($Query['page[size]'] ?? 50)
    $number = [int]($Query['page[number]'] ?? 1)
    $all = @($Items)
    $pages = [math]::Max(1, [math]::Ceiling($all.Count / $size))
    $slice = @($all | Select-Object -Skip (($number - 1) * $size) -First $size)
    return @{ data = $slice; meta = @{ 'current-page' = $number; 'total-pages' = $pages; 'total-count' = $all.Count } }
}

$global:FakeTransport = {
    param($Method, $Uri, $Headers, $Body)
    $u = [uri]$Uri
    $path = $u.AbsolutePath
    $query = Get-FakeQuery $Uri
    $global:Fake.Calls.Add([pscustomobject]@{ Method = $Method; Path = $path; Body = $Body; Host = $u.Host })

    if ($global:Fake.FailNext.Count) {
        $f = $global:Fake.FailNext[0]
        if ($Method -eq $f.Method -and $path -like $f.Path) {
            $global:Fake.FailNext = @($global:Fake.FailNext | Select-Object -Skip 1)
            throw (New-FakeHttpError $f.Status)
        }
    }

    if ($u.Host -eq 'itg.test') {
        if ($Headers['x-api-key'] -ne 'itg-key') { throw (New-FakeHttpError 401) }
        switch ($path) {
            '/organizations' { return ConvertTo-FakeResponse (Invoke-FakeItgPage $global:Fake.Orgs $query) }
            '/locations' { return ConvertTo-FakeResponse (Invoke-FakeItgPage $global:Fake.Locations $query) }
        }
        throw (New-FakeHttpError 404)
    }

    if ($Headers['x-api-key'] -ne 'hudu-key') { throw (New-FakeHttpError 401) }
    if ($path -eq '/api/v1/api_info') { return ConvertTo-FakeResponse @{ version = '2.41.0' } }
    if ($path -eq '/api/v1/companies' -and $Method -eq 'GET') {
        $size = [int]($query.page_size ?? 25); $page = [int]($query.page ?? 1)
        $slice = @($global:Fake.Companies | Select-Object -Skip (($page - 1) * $size) -First $size)
        return ConvertTo-FakeResponse @{ companies = $slice }
    }
    if ($path -eq '/api/v1/companies' -and $Method -eq 'POST') {
        if ($null -ne $global:Fake.PostLimit) {
            if ($global:Fake.PostLimit -le 0) { throw (New-FakeHttpError 500) }
            $global:Fake.PostLimit--
        }
        $data = ($Body | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable).company
        if ($global:Fake.Companies | Where-Object { $_.name -eq $data.name }) { throw (New-FakeHttpError 422) }
        $c = Add-FakeHuduCompany -Name $data.name -Fields $data
        return ConvertTo-FakeResponse @{ company = $c }
    }
    if ($path -match '^/api/v1/companies/(\d+)$') {
        $c = Get-FakeHuduCompany $Matches[1]
        if (-not $c) { throw (New-FakeHttpError 404) }
        if ($Method -eq 'GET') { return ConvertTo-FakeResponse @{ company = $c } }
        if ($Method -eq 'PUT') {
            $data = ($Body | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable).company
            if ($data.name -and ($global:Fake.Companies | Where-Object { $_.name -eq $data.name -and $_.id -ne $c.id })) { throw (New-FakeHttpError 422) }
            foreach ($k in $data.Keys) { $c[$k] = $data[$k] }
            $c.updated_at = Get-FakeNowText
            return ConvertTo-FakeResponse @{ company = $c }
        }
    }
    throw (New-FakeHttpError 404)
}

function New-FakeConfig {
    param([string]$DataDir, [hashtable]$Companies = @{}, [string]$ConflictPolicy = 'itglue-wins', [string]$ExportPath = '')
    $cfg = [ordered]@{
        HuduBaseUrl = $script:HuduBase; HuduApiKey = 'hudu-key'
        ITGlueApiUrl = $script:ItgBase; ITGlueApiKey = 'itg-key'
        ITGlueExportPath = $ExportPath; DataDir = $DataDir
        ConflictPolicy = $ConflictPolicy; LockStaleHours = 12
        Companies = [ordered]@{ UpdatePreExisting = $false; WriteBackReference = $false; MergeOrgTypes = @(); MergeTargetHuduCompany = $null }
    }
    foreach ($k in $Companies.Keys) { $cfg.Companies[$k] = $Companies[$k] }
    return $cfg
}
