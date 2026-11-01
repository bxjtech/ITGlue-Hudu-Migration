function ConvertTo-SyncFieldKey {
    param([Parameter(Mandatory)][string]$Label)
    return ($Label.Trim().ToLowerInvariant() -replace '\s+', '_')
}

function Get-SyncHuduLayout {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Name, [switch]$Refresh)
    $key = "hudu:layout:$($Name.ToLowerInvariant())"
    if ($Refresh -or -not $Context.Cache.ContainsKey($key)) {
        $found = @(Get-HuduCollection -Config $Context.Config -Path '/api/v1/asset_layouts' -Property 'asset_layouts' -Query @{ name = $Name } -PageSize 25) |
            Where-Object { $_.name -eq $Name } | Select-Object -First 1
        $Context.Cache[$key] = $found
    }
    return $Context.Cache[$key]
}

# Creates the layout when missing (never modifies an existing one). Returns $null in a dry run
# when the layout does not exist yet.
function Confirm-SyncHuduLayout {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Icon,
        [Parameter(Mandatory)][object[]]$Fields
    )
    $layout = Get-SyncHuduLayout $Context $Name
    if ($layout) { return $layout }
    if ($Context.DryRun) {
        Add-SyncResult $Context 'would-create-layout' $null $Name $null
        return $null
    }
    $cfg = $Context.Config.Layouts
    $body = @{
        asset_layout = [ordered]@{
            name = $Name; icon = $Icon; color = $cfg.Color; icon_color = $cfg.IconColor
            include_passwords = $true; include_photos = $true; include_comments = $true; include_files = $true
            fields = @($Fields)
        }
    }
    $created = (Invoke-SyncHuduWrite $Context 'POST' '/api/v1/asset_layouts' $body).asset_layout
    if (-not $created.id) { throw "Hudu did not return the created asset layout '$Name'." }
    $null = Invoke-SyncHuduWrite $Context 'PUT' "/api/v1/asset_layouts/$($created.id)" @{ asset_layout = @{ active = $true } }
    Add-SyncResult $Context 'created-layout' $null $Name $created.id
    return (Get-SyncHuduLayout $Context $Name -Refresh)
}

# An existing layout may lack fields this stage writes. Layouts.MissingFields decides:
# stop (fail before writing), add (append them, keeping every existing field), ignore (sync the rest).
function Resolve-SyncLayoutFields {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Entity,
        $Layout,
        [Parameter(Mandatory)][string]$LayoutName,
        [Parameter(Mandatory)][object[]]$LayoutFields
    )
    $wanted = @($LayoutFields | ForEach-Object { [string]$_.label })
    if (-not $Layout) { return [System.Collections.Generic.HashSet[string]]::new([string[]]$wanted, [System.StringComparer]::OrdinalIgnoreCase) }

    $existing = @($Layout.fields | Where-Object { $_ })
    $have = [System.Collections.Generic.HashSet[string]]::new([string[]]@($existing | ForEach-Object { [string]$_.label }), [System.StringComparer]::OrdinalIgnoreCase)
    $missing = @($LayoutFields | Where-Object { -not $have.Contains($_.label) })
    if ($missing.Count -eq 0) { return $have }

    $missingText = ($missing.label | ForEach-Object { "'$_'" }) -join ', '
    switch ($Context.Config.Layouts.MissingFields) {
        'ignore' {
            Write-SyncLog -Level WARN -Message "[$Entity] Hudu layout '$LayoutName' has no $missingText field(s); those values are not synced (Layouts.MissingFields=ignore)."
            return $have
        }
        'add' {
            if ($Context.DryRun) {
                Add-SyncResult $Context 'would-update-layout' $null $LayoutName $Layout.id "would add $missingText"
            } else {
                $keep = foreach ($f in $existing) {
                    $h = [ordered]@{}
                    foreach ($p in $f.PSObject.Properties) { $h[$p.Name] = $p.Value }
                    $h
                }
                $next = [int](@($existing | ForEach-Object { [int]$_.position }) + 0 | Measure-Object -Maximum).Maximum
                $added = foreach ($f in $missing) {
                    $next++
                    $n = [ordered]@{}
                    foreach ($k in $f.Keys) { $n[$k] = $f[$k] }
                    $n.position = $next
                    $n
                }
                $body = @{ asset_layout = @{ fields = @($keep) + @($added) } }
                $null = Invoke-SyncHuduWrite $Context 'PUT' "/api/v1/asset_layouts/$($Layout.id)" $body
                $null = Get-SyncHuduLayout $Context $LayoutName -Refresh
                Add-SyncResult $Context 'updated-layout' $null $LayoutName $Layout.id "added $missingText"
            }
            foreach ($f in $missing) { [void]$have.Add($f.label) }
            return $have
        }
        default {
            throw ("Hudu layout '$LayoutName' already exists without these fields: $missingText. Nothing was written for this stage. " +
                "Set Layouts.MissingFields to 'add' to add them to the existing layout (its current fields are kept), " +
                "'ignore' to sync only the fields it has, or point Layouts.$(if ($Entity -eq 'contacts') {'Contacts'} else {'Locations'}) at a different layout name.")
        }
    }
}

function Get-SyncHuduAssets {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$LayoutId)
    $key = "hudu:assets:$LayoutId"
    if (-not $Context.Cache.ContainsKey($key)) {
        $byId = [ordered]@{}
        foreach ($archived in $false, $true) {
            $q = @{ asset_layout_id = $LayoutId }
            if ($archived) { $q.archived = 'true' }
            foreach ($a in (Get-HuduCollection -Config $Context.Config -Path '/api/v1/assets' -Property 'assets' -Query $q)) { $byId[[string]$a.id] = $a }
        }
        $Context.Cache[$key] = @($byId.Values)
    }
    return $Context.Cache[$key]
}

function Get-SyncAssetFieldValue {
    param($Asset, [Parameter(Mandatory)][string]$Label)
    foreach ($f in @($Asset.fields)) {
        if ($f -and "$($f.label)" -eq $Label) { return $f.value }
    }
    return $null
}

function New-SyncLayoutField {
    param([string]$Label, [string]$Type = 'Text', [bool]$ShowInList = $false, [int]$Position, $LinkableId)
    $f = [ordered]@{ label = $Label; field_type = $Type; show_in_list = $ShowInList; position = $Position }
    if ($LinkableId) { $f.linkable_id = $LinkableId }
    return $f
}

# Generic stage for IT Glue records that become assets under one Hudu asset layout.
# $Describe returns @{ Name; OrgId; Fields = [ordered] label -> value; AltNames; UpdatedAt }.
function Invoke-SyncAssetStage {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Entity,
        [Parameter(Mandatory)][string]$LayoutName,
        [Parameter(Mandatory)][string]$Icon,
        [Parameter(Mandatory)][object[]]$LayoutFields,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items,
        [Parameter(Mandatory)][scriptblock]$Describe,
        [string]$What = 'record'
    )
    $map = Get-SyncContextMap $Context $Entity
    $owners = Get-SyncMapHuduIndex $map
    $idLabel = 'ITGlue ID'

    $layout = Confirm-SyncHuduLayout -Context $Context -Name $LayoutName -Icon $Icon -Fields $LayoutFields
    $allowedSet = Resolve-SyncLayoutFields -Context $Context -Entity $Entity -Layout $layout -LayoutName $LayoutName -LayoutFields $LayoutFields
    if ($layout) { $layout = Get-SyncHuduLayout $Context $LayoutName }

    $assets = if ($layout) { @(Get-SyncHuduAssets $Context $layout.id) } else { @() }
    $byId = @{}
    $byName = @{}
    $byBackRef = @{}
    foreach ($a in $assets) {
        $byId[[string]$a.id] = $a
        $nk = '{0}|{1}' -f $a.company_id, ([string]$a.name).ToLowerInvariant()
        if (-not $byName.ContainsKey($nk)) { $byName[$nk] = $a }
        $ref = Get-SyncAssetFieldValue $a $idLabel
        if ($ref) { $byBackRef[[string]$ref] = $a }
    }

    foreach ($item in $Items) {
        $itgId = [string]$item.id
        try {
            $d = & $Describe $item
            if (-not (Test-SyncInScope $Context $d.OrgId)) { continue }
            $name = ([string]$d.Name).Trim()
            if (-not $name) { $name = "Unnamed $What $itgId" }
            $companyId = Get-SyncCompanyHuduId $Context $d.OrgId
            if (-not $companyId) {
                Add-SyncFlag $Context 'parent-not-synced' $itgId $null $name "IT Glue organization $($d.OrgId) has not been synced to a Hudu company; skipped."
                Add-SyncResult $Context 'skipped' $itgId $name $null 'company not synced'
                continue
            }

            $fields = [ordered]@{}
            foreach ($label in $d.Fields.Keys) {
                if ($allowedSet.Contains($label)) { $fields[(ConvertTo-SyncFieldKey $label)] = ConvertTo-SyncText $d.Fields[$label] }
            }
            if ($allowedSet.Contains($idLabel)) { $fields[(ConvertTo-SyncFieldKey $idLabel)] = $itgId }
            $payload = [ordered]@{ name = $name; company_id = $companyId; fields = $fields }
            $hash = Get-SyncHash $payload
            $updateBody = @{ asset = [ordered]@{ name = $name; custom_fields = @($fields) } }

            $rec = Get-SyncMapRecord $map $itgId
            if ($rec) {
                $current = $byId[[string]$rec.huduId]
                if (-not $current -and $layout) {
                    Add-SyncFlag $Context 'missing-in-hudu' $itgId $rec.huduId $name "Mapped Hudu asset no longer exists; left alone."
                    Add-SyncResult $Context 'skipped' $itgId $name $rec.huduId 'mapped Hudu asset missing'
                    continue
                }
                if ($current -and [string]$current.company_id -ne $companyId) {
                    Add-SyncFlag $Context 'moved-company' $itgId $rec.huduId $name "Moved to a different organization in IT Glue; Hudu asset left under its current company."
                    Add-SyncResult $Context 'skipped' $itgId $name $rec.huduId 'company changed'
                    continue
                }
                Invoke-SyncExistingRecord -Context $Context -Entity $Entity -ItgId $itgId -Name $name -Record $rec -Hash $hash -ItgUpdatedAt $d.UpdatedAt -Current $current -Write {
                    (Invoke-SyncHuduWrite $Context 'PUT' "/api/v1/companies/$companyId/assets/$($rec.huduId)" $updateBody).asset
                }.GetNewClosure()
                continue
            }

            $match = $byBackRef[$itgId]
            $matchedBy = 'backref'
            if (-not $match) {
                $matchedBy = 'name'
                foreach ($candidate in @($name) + @($d.AltNames | Where-Object { $_ })) {
                    $nk = '{0}|{1}' -f $companyId, ([string]$candidate).ToLowerInvariant()
                    if ($byName.ContainsKey($nk)) {
                        $hit = $byName[$nk]
                        $owner = $owners[[string]$hit.id]
                        if (-not $owner -or $owner -eq $itgId) { $match = $hit; break }
                    }
                }
            }
            if ($match) {
                $managed = ($matchedBy -eq 'backref') -or [bool]$Context.Config.UpdatePreExisting
                $rec = @{ huduId = [string]$match.id; huduName = $match.name; managed = $managed; matchedBy = $matchedBy; lastSyncedAt = $null; huduUpdatedAt = $match.updated_at }
                Save-SyncMapping $Context $Entity $itgId $rec
                $owners[[string]$match.id] = $itgId
                Add-SyncResult $Context 'matched' $itgId $name $match.id $(if ($matchedBy -eq 'backref') { 're-linked via ITGlue ID field' } else { 'existing Hudu asset with the same name' })
                if ($managed) {
                    Invoke-SyncExistingRecord -Context $Context -Entity $Entity -ItgId $itgId -Name $name -Record $rec -Hash $hash -ItgUpdatedAt $d.UpdatedAt -Current $match -Write {
                        (Invoke-SyncHuduWrite $Context 'PUT' "/api/v1/companies/$companyId/assets/$($match.id)" $updateBody).asset
                    }.GetNewClosure()
                }
                continue
            }

            $created = Invoke-SyncCreateRecord -Context $Context -Entity $Entity -ItgId $itgId -Name $name -Hash $hash -ItgUpdatedAt $d.UpdatedAt -Write {
                $body = @{ asset = [ordered]@{ name = $name; asset_layout_id = $layout.id; custom_fields = @($fields) } }
                (Invoke-SyncHuduWrite $Context 'POST' "/api/v1/companies/$companyId/assets" $body).asset
            }.GetNewClosure()
            if ($created) { $owners[[string]$created.id] = $itgId }
        } catch {
            Add-SyncResult $Context 'error' $itgId "$($item.attributes.name)" $null "$($_.Exception.Message)"
        }
    }
    Add-SyncDeletedFlags -Context $Context -Map $map -Items $Items -What $What
}
