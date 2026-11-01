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
        Contacts  = [System.Collections.Generic.List[object]]::new()
        Domains   = [System.Collections.Generic.List[object]]::new()
        Layouts   = [System.Collections.Generic.List[object]]::new()
        Assets    = [System.Collections.Generic.List[object]]::new()
        Websites  = [System.Collections.Generic.List[object]]::new()
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

function Add-FakeContact {
    param([string]$Id, [string]$OrgId, [string]$First, [string]$Last, [string]$LocationId, [string]$Email = '')
    $emails = if ($Email) { @(@{ value = $Email; primary = $true; 'label-name' = 'Work' }) } else { @() }
    $global:Fake.Contacts.Add(@{
        id = $Id; type = 'contacts'
        attributes = @{ name = "$First $Last"; 'first-name' = $First; 'last-name' = $Last; title = ''; 'contact-type-name' = 'Employee'; important = $false
            notes = ''; 'contact-emails' = $emails; 'contact-phones' = @(); 'location-id' = $(if ($LocationId) { [int]$LocationId } else { $null })
            'organization-id' = [int]$OrgId; 'created-at' = (Get-FakeNowText); 'updated-at' = (Get-FakeNowText) }
    })
}

function Set-FakeItgRecord {
    param([string]$Kind, [string]$Id, [hashtable]$Attributes)
    $r = $global:Fake[$Kind] | Where-Object { $_.id -eq $Id }
    foreach ($k in $Attributes.Keys) { $r.attributes[$k] = $Attributes[$k] }
    $r.attributes['updated-at'] = Get-FakeNowText
}

function Add-FakeDomain {
    param([string]$Id, [string]$OrgId, [string]$Name, [string]$Notes = '')
    $global:Fake.Domains.Add(@{ id = $Id; type = 'domains'; attributes = @{ name = $Name; notes = $Notes; 'organization-id' = [int]$OrgId; 'updated-at' = (Get-FakeNowText) } })
}

function Add-FakeLayout {
    param([string]$Name, [string[]]$Labels)
    $l = @{ id = $global:Fake.NextId++; name = $Name; active = $true; fields = @($Labels | ForEach-Object { @{ label = $_; field_type = 'Text' } }) }
    $global:Fake.Layouts.Add($l)
    return $l
}

function Add-FakeAsset {
    param($LayoutId, $CompanyId, [string]$Name, [hashtable]$Fields = @{})
    $a = @{ id = $global:Fake.NextId++; name = $Name; company_id = [long]$CompanyId; asset_layout_id = [long]$LayoutId; archived = $false
        fields = @($Fields.Keys | ForEach-Object { @{ label = $_; value = $Fields[$_] } }); updated_at = (Get-FakeNowText) }
    $global:Fake.Assets.Add($a)
    return $a
}

function Get-FakeAssetField { param($Asset, [string]$Label) ($Asset.fields | Where-Object { $_.label -eq $Label }).value }

function Set-FakeAssetFields {
    param($Asset, $CustomFields)
    $layout = $global:Fake.Layouts | Where-Object { $_.id -eq $Asset.asset_layout_id }
    foreach ($cf in @($CustomFields)) {
        foreach ($key in $cf.Keys) {
            $label = ($layout.fields | Where-Object { ($_.label.ToLowerInvariant() -replace '\s+', '_') -eq $key }).label
            if (-not $label) { throw (New-FakeHttpError 422) }
            $existing = $Asset.fields | Where-Object { $_.label -eq $label }
            if ($existing) { $existing.value = $cf[$key] } else { $Asset.fields += @{ label = $label; value = $cf[$key] } }
        }
    }
}

function Get-FakeBody { param($Body) $Body | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable }

function Get-FakePage {
    param($Items, $Query)
    $size = [int]($Query.page_size ?? 25); $page = [int]($Query.page ?? 1)
    return @($Items | Select-Object -Skip (($page - 1) * $size) -First $size)
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
            '/contacts' { return ConvertTo-FakeResponse (Invoke-FakeItgPage $global:Fake.Contacts $query) }
            '/domains' { return ConvertTo-FakeResponse (Invoke-FakeItgPage $global:Fake.Domains $query) }
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
    if ($path -eq '/api/v1/asset_layouts' -and $Method -eq 'GET') {
        $items = @($global:Fake.Layouts | Where-Object { -not $query.name -or $_.name -eq $query.name })
        return ConvertTo-FakeResponse @{ asset_layouts = @(Get-FakePage $items $query) }
    }
    if ($path -eq '/api/v1/asset_layouts' -and $Method -eq 'POST') {
        $data = (Get-FakeBody $Body).asset_layout
        $l = @{ id = $global:Fake.NextId++; name = $data.name; active = $false; fields = @($data.fields); icon = $data.icon }
        $global:Fake.Layouts.Add($l)
        return ConvertTo-FakeResponse @{ asset_layout = $l }
    }
    if ($path -match '^/api/v1/asset_layouts/(\d+)$' -and $Method -eq 'PUT') {
        $l = $global:Fake.Layouts | Where-Object { [string]$_.id -eq $Matches[1] }
        $data = (Get-FakeBody $Body).asset_layout
        foreach ($k in $data.Keys) { $l[$k] = $data[$k] }
        return ConvertTo-FakeResponse @{ asset_layout = $l }
    }
    if ($path -eq '/api/v1/assets' -and $Method -eq 'GET') {
        $wantArchived = $query.archived -eq 'true'
        $items = @($global:Fake.Assets | Where-Object { [string]$_.asset_layout_id -eq $query.asset_layout_id -and [bool]$_.archived -eq $wantArchived })
        return ConvertTo-FakeResponse @{ assets = @(Get-FakePage $items $query) }
    }
    if ($path -match '^/api/v1/companies/(\d+)/assets$' -and $Method -eq 'POST') {
        $cid = $Matches[1]
        if (-not (Get-FakeHuduCompany $cid)) { throw (New-FakeHttpError 404) }
        $data = (Get-FakeBody $Body).asset
        $a = Add-FakeAsset -LayoutId $data.asset_layout_id -CompanyId $cid -Name $data.name
        Set-FakeAssetFields $a $data.custom_fields
        return ConvertTo-FakeResponse @{ asset = $a }
    }
    if ($path -match '^/api/v1/companies/(\d+)/assets/(\d+)$' -and $Method -eq 'PUT') {
        $a = $global:Fake.Assets | Where-Object { [string]$_.id -eq $Matches[2] -and [string]$_.company_id -eq $Matches[1] }
        if (-not $a) { throw (New-FakeHttpError 404) }
        $data = (Get-FakeBody $Body).asset
        if ($data.name) { $a.name = $data.name }
        Set-FakeAssetFields $a $data.custom_fields
        $a.updated_at = Get-FakeNowText
        return ConvertTo-FakeResponse @{ asset = $a }
    }
    if ($path -eq '/api/v1/websites' -and $Method -eq 'GET') { return ConvertTo-FakeResponse @(Get-FakePage $global:Fake.Websites $query) }
    if ($path -eq '/api/v1/websites' -and $Method -eq 'POST') {
        $data = (Get-FakeBody $Body).website
        $w = @{ id = $global:Fake.NextId++; updated_at = (Get-FakeNowText) }
        foreach ($k in $data.Keys) { $w[$k] = $data[$k] }
        $global:Fake.Websites.Add($w)
        return ConvertTo-FakeResponse $w
    }
    if ($path -match '^/api/v1/websites/(\d+)$' -and $Method -eq 'PUT') {
        $w = $global:Fake.Websites | Where-Object { [string]$_.id -eq $Matches[1] }
        if (-not $w) { throw (New-FakeHttpError 404) }
        $data = (Get-FakeBody $Body).website
        foreach ($k in $data.Keys) { $w[$k] = $data[$k] }
        $w.updated_at = Get-FakeNowText
        return ConvertTo-FakeResponse $w
    }
    throw (New-FakeHttpError 404)
}

function New-FakeConfig {
    param([string]$DataDir, [hashtable]$Companies = @{}, [string]$ConflictPolicy = 'itglue-wins', [string]$ExportPath = '', [hashtable]$Settings = @{})
    $cfg = Get-SyncConfig
    $cfg.HuduBaseUrl = $script:HuduBase; $cfg.HuduApiKey = 'hudu-key'
    $cfg.ITGlueApiUrl = $script:ItgBase; $cfg.ITGlueApiKey = 'itg-key'
    $cfg.ITGlueExportPath = $ExportPath; $cfg.DataDir = $DataDir; $cfg.ConflictPolicy = $ConflictPolicy
    foreach ($k in $Companies.Keys) { $cfg.Companies[$k] = $Companies[$k] }
    foreach ($k in $Settings.Keys) { $cfg[$k] = $Settings[$k] }
    return $cfg
}
