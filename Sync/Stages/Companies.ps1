function Get-SyncITGlueLocations {
    param([Parameter(Mandatory)]$Context)
    if (-not $Context.Cache.ContainsKey('itg:locations')) {
        Write-SyncLog -Message 'Fetching locations from IT Glue'
        $Context.Cache['itg:locations'] = @(Get-ITGlueCollection -Config $Context.Config -Path '/locations')
    }
    return $Context.Cache['itg:locations']
}

function Get-SyncHuduCompanies {
    param([Parameter(Mandatory)]$Context, [switch]$Refresh)
    if ($Refresh -or -not $Context.Cache.ContainsKey('hudu:companies')) {
        Write-SyncLog -Message 'Fetching companies from Hudu'
        $Context.Cache['hudu:companies'] = @(Get-HuduCollection -Config $Context.Config -Path '/api/v1/companies' -Property 'companies')
    }
    return $Context.Cache['hudu:companies']
}

function Get-SyncExportOrganizations {
    param([Parameter(Mandatory)]$Context)
    $byId = @{}
    $path = $Context.Config.ITGlueExportPath
    if (-not $path) { return $byId }
    $csv = Join-Path $path 'organizations.csv'
    if (-not (Test-Path -LiteralPath $csv)) { return $byId }
    foreach ($row in (Import-Csv -LiteralPath $csv)) { $byId[[string]$row.id] = $row }
    return $byId
}

# Hudu company names must be unique; IT Glue's need not be. Names already given to mapped
# companies are kept so a re-run never renames them; new duplicates get -1, -2... by IT Glue ID.
function Get-SyncCompanyNameAssignments {
    param([Parameter(Mandatory)]$Organizations, [Parameter(Mandatory)]$Map)
    $reserved = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $assigned = @{}
    $sorted = @($Organizations | Sort-Object { [long]$_.id })
    foreach ($org in $sorted) {
        $rec = Get-SyncMapRecord $Map $org.id
        if ($rec -and $rec.huduName -and $rec.itgName -eq $org.attributes.name -and -not $reserved.Contains($rec.huduName)) {
            $assigned[[string]$org.id] = $rec.huduName
            [void]$reserved.Add($rec.huduName)
        }
    }
    foreach ($org in $sorted) {
        if ($assigned.ContainsKey([string]$org.id)) { continue }
        $base = ([string]$org.attributes.name).Trim()
        $candidate = $base
        $n = 0
        while ($reserved.Contains($candidate)) { $n++; $candidate = "$base-$n" }
        $assigned[[string]$org.id] = $candidate
        [void]$reserved.Add($candidate)
    }
    return $assigned
}

function New-SyncCompanyPayload {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Org, [string]$Name, $PrimaryLocation, $ExportRow)
    $a = $Org.attributes
    $quickNotes = ConvertTo-SyncText $a.'quick-notes'
    $alert = ConvertTo-SyncText $a.alert
    if ($ExportRow) {
        if (-not $quickNotes) { $quickNotes = ConvertTo-SyncText $ExportRow.quick_notes }
        if (-not $alert) { $alert = ConvertTo-SyncText $ExportRow.alert }
    }
    $notes = if ($alert) { "<div class='callout callout-warning'>$alert</div>$quickNotes" } else { $quickNotes }
    $loc = if ($PrimaryLocation) { $PrimaryLocation.attributes } else { $null }

    $payload = [ordered]@{
        name           = $Name
        nickname       = ConvertTo-SyncText $a.'short-name'
        company_type   = ConvertTo-SyncText $a.'organization-type-name'
        address_line_1 = ConvertTo-SyncText (Get-SyncProp $loc 'address-1')
        address_line_2 = ConvertTo-SyncText (Get-SyncProp $loc 'address-2')
        city           = ConvertTo-SyncText (Get-SyncProp $loc 'city')
        state          = ConvertTo-SyncText (Get-SyncProp $loc 'region-name')
        zip            = ConvertTo-SyncText (Get-SyncProp $loc 'postal-code')
        country_name   = ConvertTo-SyncText (Get-SyncProp $loc 'country-name')
        phone_number   = ConvertTo-SyncText (Get-SyncProp $loc 'phone')
        fax_number     = ConvertTo-SyncText (Get-SyncProp $loc 'fax')
        notes          = $notes
    }
    if ($Context.Config.Companies.WriteBackReference) { $payload.id_number = "ITG:$($Org.id)" }
    return $payload
}

function Invoke-SyncCompaniesStage {
    param([Parameter(Mandatory)]$Context)
    $cfg = $Context.Config.Companies
    $map = Get-SyncContextMap $Context 'companies'
    $orgs = @(Get-SyncITGlueOrganizations $Context)
    $locations = @(Get-SyncITGlueLocations $Context)
    $exportRows = Get-SyncExportOrganizations $Context
    $hudu = @(Get-SyncHuduCompanies $Context)

    $huduById = @{}
    $huduByName = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $huduByBackRef = @{}
    foreach ($h in $hudu) {
        $huduById[[string]$h.id] = $h
        if ($h.name -and -not $huduByName.ContainsKey($h.name)) { $huduByName[$h.name] = $h }
        if ("$($h.id_number)" -match '^ITG:(\d+)$') { $huduByBackRef[$Matches[1]] = $h }
    }
    $primaryByOrg = @{}
    foreach ($group in ($locations | Where-Object { $_.attributes.primary -eq $true } | Group-Object { [string]$_.attributes.'organization-id' })) {
        if ($group.Count -eq 1) { $primaryByOrg[$group.Name] = $group.Group[0] }
    }

    $mergeTypes = @($cfg.MergeOrgTypes | Where-Object { $_ })
    $mergeTarget = $null
    if ($mergeTypes.Count) {
        if (-not $cfg.MergeTargetHuduCompany) { throw 'Companies.MergeOrgTypes is set but Companies.MergeTargetHuduCompany (a Hudu company ID) is not.' }
        $mergeTarget = $huduById[[string]$cfg.MergeTargetHuduCompany]
        if (-not $mergeTarget) { $mergeTarget = Invoke-HuduApi -Config $Context.Config -Path "/api/v1/companies/$($cfg.MergeTargetHuduCompany)" -AllowNotFound | ForEach-Object { $_.company } }
        if (-not $mergeTarget) { throw "Merge target Hudu company $($cfg.MergeTargetHuduCompany) was not found." }
    }

    $names = Get-SyncCompanyNameAssignments -Organizations $orgs -Map $map
    $now = Format-SyncTime (Get-SyncUtcNow)

    foreach ($org in ($orgs | Sort-Object { [long]$_.id })) {
        $itgId = [string]$org.id
        if (-not (Test-SyncInScope $Context $itgId)) { continue }
        $itgName = [string]$org.attributes.name
        $name = $names[$itgId]
        try {
            $rec = Get-SyncMapRecord $map $itgId
            $primary = $primaryByOrg[$itgId]
            $itgUpdated = @((ConvertTo-SyncUtc $org.attributes.'updated-at'), (ConvertTo-SyncUtc (Get-SyncProp $primary.attributes 'updated-at'))) |
                Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1

            if ($mergeTarget -and $mergeTypes -contains $org.attributes.'organization-type-name') {
                if (-not $rec -or [string]$rec.huduId -ne [string]$mergeTarget.id) {
                    Save-SyncMapping $Context 'companies' $itgId @{ huduId = [string]$mergeTarget.id; itgName = $itgName; huduName = $mergeTarget.name; managed = $false; matchedBy = 'merged'; lastSyncedAt = $now }
                }
                Add-SyncResult $Context 'reference' $itgId $itgName $mergeTarget.id "merged into '$($mergeTarget.name)'"
                continue
            }

            if ($name -ne $itgName) {
                Add-SyncFlag $Context 'duplicate-name' $itgId $null $itgName "IT Glue has several organizations named '$itgName'; this one is named '$name' in Hudu."
            }

            $payload = New-SyncCompanyPayload -Context $Context -Org $org -Name $name -PrimaryLocation $primary -ExportRow $exportRows[$itgId]
            $hash = Get-SyncHash $payload

            if ($rec) {
                $current = $huduById[[string]$rec.huduId]
                if (-not $current) {
                    $current = (Invoke-HuduApi -Config $Context.Config -Path "/api/v1/companies/$($rec.huduId)" -AllowNotFound).company
                }
                if (-not $current) {
                    Add-SyncFlag $Context 'missing-in-hudu' $itgId $rec.huduId $itgName 'Mapped Hudu company no longer exists; left alone. Remove the mapping or restore the company.'
                    Add-SyncResult $Context 'skipped' $itgId $itgName $rec.huduId 'mapped Hudu company missing'
                    continue
                }
            } else {
                $backRef = $huduByBackRef[$itgId]
                $byName = if ($huduByName.ContainsKey($name)) { $huduByName[$name] } else { $null }
                if ($backRef) {
                    $rec = @{ huduId = [string]$backRef.id; itgName = $itgName; huduName = $backRef.name; managed = $true; matchedBy = 'backref'; lastSyncedAt = $null; huduUpdatedAt = $backRef.updated_at }
                    Save-SyncMapping $Context 'companies' $itgId $rec
                    Add-SyncResult $Context 'matched' $itgId $itgName $backRef.id 're-linked via ITG back-reference'
                    $current = $backRef
                } elseif ($byName) {
                    $owner = Find-SyncMapByHuduId $map $byName.id
                    if ($owner -and $owner -ne $itgId) {
                        Add-SyncFlag $Context 'name-collision' $itgId $byName.id $itgName "Hudu company '$($byName.name)' is already mapped to IT Glue organization $owner."
                        Add-SyncResult $Context 'skipped' $itgId $itgName $byName.id 'name collision'
                        continue
                    }
                    $managed = [bool]$cfg.UpdatePreExisting
                    $rec = @{ huduId = [string]$byName.id; itgName = $itgName; huduName = $byName.name; managed = $managed; matchedBy = 'name'; lastSyncedAt = $null; huduUpdatedAt = $byName.updated_at }
                    Save-SyncMapping $Context 'companies' $itgId $rec
                    Add-SyncResult $Context 'matched' $itgId $itgName $byName.id 'existing Hudu company with the same name'
                    if (-not $managed) { continue }
                    $current = $byName
                } else {
                    if ($Context.DryRun) {
                        Add-SyncResult $Context 'would-create' $itgId $name $null
                        continue
                    }
                    $body = [ordered]@{}
                    foreach ($k in $payload.Keys) { if ("$($payload[$k])" -ne '') { $body[$k] = $payload[$k] } }
                    $created = (Invoke-SyncHuduWrite $Context 'POST' '/api/v1/companies' @{ company = $body }).company
                    if (-not $created.id) { throw 'Hudu did not return the created company.' }
                    Save-SyncMapping $Context 'companies' $itgId @{
                        huduId = [string]$created.id; itgName = $itgName; huduName = $name; managed = $true; matchedBy = 'created'
                        sourceHash = $hash; huduUpdatedAt = $created.updated_at; itgUpdatedAt = Format-SyncTime $itgUpdated; lastSyncedAt = $now
                    }
                    $huduById[[string]$created.id] = $created
                    $huduByName[$name] = $created
                    Add-SyncResult $Context 'created' $itgId $name $created.id
                    continue
                }
            }

            $action = Resolve-SyncAction -Context $Context -MapRecord $rec -DesiredHash $hash -ItgUpdatedAt $itgUpdated
            switch ($action) {
                'reference' { Add-SyncResult $Context 'reference' $itgId $itgName $rec.huduId 'pre-existing Hudu company (not managed)' }
                'unchanged' { Add-SyncResult $Context 'unchanged' $itgId $itgName $rec.huduId }
                'baseline' {
                    $rec.sourceHash = $hash
                    $rec.itgUpdatedAt = Format-SyncTime $itgUpdated
                    $rec.huduUpdatedAt = $current.updated_at
                    Save-SyncMapping $Context 'companies' $itgId $rec
                    Add-SyncResult $Context 'baseline' $itgId $itgName $rec.huduId 'unchanged since the earlier migration; recorded as baseline'
                }
                'update' {
                    if (Test-SyncHuduModified -MapRecord $rec -HuduRecord $current) {
                        if ($Context.Config.ConflictPolicy -eq 'hudu-wins') {
                            Add-SyncFlag $Context 'hudu-modified' $itgId $rec.huduId $itgName 'Changed in both IT Glue and Hudu since the last sync; kept the Hudu version (ConflictPolicy=hudu-wins).'
                            Add-SyncResult $Context 'skipped' $itgId $itgName $rec.huduId 'conflict'
                            break
                        }
                        Add-SyncFlag $Context 'hudu-modified' $itgId $rec.huduId $itgName 'Changed in both IT Glue and Hudu since the last sync; IT Glue version applied (ConflictPolicy=itglue-wins).'
                    }
                    if ($Context.DryRun) {
                        Add-SyncResult $Context 'would-update' $itgId $name $rec.huduId
                        break
                    }
                    $updated = (Invoke-SyncHuduWrite $Context 'PUT' "/api/v1/companies/$($rec.huduId)" @{ company = $payload }).company
                    $rec.sourceHash = $hash
                    $rec.huduName = $name
                    $rec.itgName = $itgName
                    $rec.huduUpdatedAt = if ($updated) { $updated.updated_at } else { $null }
                    $rec.itgUpdatedAt = Format-SyncTime $itgUpdated
                    $rec.lastSyncedAt = $now
                    Save-SyncMapping $Context 'companies' $itgId $rec
                    Add-SyncResult $Context 'updated' $itgId $name $rec.huduId
                }
            }
        } catch {
            Add-SyncResult $Context 'error' $itgId $itgName $null "$($_.Exception.Message)"
        }
    }

    if ($null -eq $Context.Scope) {
        $present = [System.Collections.Generic.HashSet[string]]::new([string[]]@($orgs | ForEach-Object { [string]$_.id }))
        foreach ($k in @($map.Records.Keys)) {
            if (-not $present.Contains($k)) {
                $r = $map.Records[$k]
                Add-SyncFlag $Context 'deleted-in-itglue' $k $r.huduId $r.itgName 'Organization no longer exists in IT Glue; Hudu company left alone.'
            }
        }
    }
}

Set-SyncStageRunner -Name 'companies' -Run { param($ctx) Invoke-SyncCompaniesStage $ctx }
