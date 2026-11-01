function Get-SyncITGlueContacts {
    param([Parameter(Mandatory)]$Context)
    if (-not $Context.Cache.ContainsKey('itg:contacts')) {
        Write-SyncLog -Message 'Fetching contacts from IT Glue'
        $Context.Cache['itg:contacts'] = @(Get-ITGlueCollection -Config $Context.Config -Path '/contacts')
    }
    return $Context.Cache['itg:contacts']
}

function ConvertTo-SyncContactMethodsHtml {
    param($Methods)
    $items = foreach ($m in @($Methods | Where-Object { $_ -and (Get-SyncProp $_ 'value') })) {
        $text = ConvertTo-SyncHtml (Get-SyncProp $m 'value')
        $ext = Get-SyncProp $m 'extension'
        if ($ext) { $text += " ext. $(ConvertTo-SyncHtml $ext)" }
        $label = Get-SyncProp $m 'label-name'
        if ($label) { $text = "$(ConvertTo-SyncHtml $label): $text" }
        if ((Get-SyncProp $m 'primary') -eq $true) { $text += ' (primary)' }
        "<li>$text</li>"
    }
    if (-not $items) { return '' }
    return "<ul>$($items -join '')</ul>"
}

function Invoke-SyncContactsStage {
    param([Parameter(Mandatory)]$Context)
    $locationLayout = Get-SyncHuduLayout $Context $Context.Config.Layouts.Locations
    $locationMap = Get-SyncContextMap $Context 'locations'

    $fields = @(
        New-SyncLayoutField 'First Name' -ShowInList $true -Position 1
        New-SyncLayoutField 'Last Name' -Position 2
        New-SyncLayoutField 'Title' -ShowInList $true -Position 3
        New-SyncLayoutField 'Contact Type' -ShowInList $true -Position 4
        New-SyncLayoutField 'Important' -Position 6
        New-SyncLayoutField 'Notes' -Type 'RichText' -Position 7
        New-SyncLayoutField 'Emails' -Type 'RichText' -Position 8
        New-SyncLayoutField 'Phones' -Type 'RichText' -Position 9
        New-SyncLayoutField 'ITG Date Created' -Type 'Date' -ShowInList $true -Position 10
        New-SyncLayoutField 'ITG Date Last Updated' -Type 'Date' -ShowInList $true -Position 11
    )
    if ($locationLayout) { $fields += New-SyncLayoutField 'Location' -Type 'AssetTag' -Position 5 -LinkableId $locationLayout.id }
    else { Write-SyncLog -Level WARN -Message "[contacts] No '$($Context.Config.Layouts.Locations)' layout yet; a new People layout would be created without the Location link. Sync locations first." }
    if ($Context.Config.IncludeITGlueIdField) { $fields += New-SyncLayoutField 'ITGlue ID' -Position 502 }

    Invoke-SyncAssetStage -Context $Context -Entity 'contacts' -What 'contact' `
        -LayoutName $Context.Config.Layouts.Contacts -Icon 'fas fa-users' -LayoutFields $fields `
        -Items @(Get-SyncITGlueContacts $Context | Sort-Object { [long]$_.id }) `
        -Describe {
            param($c)
            $a = $c.attributes
            $values = [ordered]@{
                'First Name'            = $a.'first-name'
                'Last Name'             = $a.'last-name'
                'Title'                 = $a.title
                'Contact Type'          = $a.'contact-type-name'
                'Important'             = if ($a.important -eq $true) { 'Yes' } else { '' }
                'Notes'                 = $a.notes
                'Emails'                = ConvertTo-SyncContactMethodsHtml $a.'contact-emails'
                'Phones'                = ConvertTo-SyncContactMethodsHtml $a.'contact-phones'
                'ITG Date Created'      = ConvertTo-SyncDateField $a.'created-at'
                'ITG Date Last Updated' = ConvertTo-SyncDateField $a.'updated-at'
            }
            $loc = if ($a.'location-id') { Get-SyncMapRecord $locationMap ([string]$a.'location-id') } else { $null }
            if ($loc) { $values['Location'] = (@([ordered]@{ id = [long]$loc.huduId; name = $loc.huduName }) | ConvertTo-Json -AsArray -Compress) }
            elseif ($a.'location-id') { $values['Location'] = '' }
            $name = if ($a.name) { $a.name } else { ("$($a.'first-name') $($a.'last-name')").Trim() }
            @{ Name = $name; OrgId = $a.'organization-id'; UpdatedAt = $a.'updated-at'; AltNames = @(); Fields = $values }
        }
}

Set-SyncStageRunner -Name 'contacts' -Run { param($ctx) Invoke-SyncContactsStage $ctx }
