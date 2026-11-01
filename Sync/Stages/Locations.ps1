function Get-SyncLocationLayoutFields {
    param([Parameter(Mandatory)]$Context)
    $fields = @(
        New-SyncLayoutField 'Address 1' -ShowInList $true -Position 1
        New-SyncLayoutField 'Address 2' -Position 2
        New-SyncLayoutField 'City' -ShowInList $true -Position 3
        New-SyncLayoutField 'Postal Code' -ShowInList $true -Position 4
        New-SyncLayoutField 'Region' -Position 5
        New-SyncLayoutField 'Country' -Position 6
        New-SyncLayoutField 'Phone' -Position 7
        New-SyncLayoutField 'Fax' -Position 8
        New-SyncLayoutField 'Notes' -Type 'RichText' -Position 9
        New-SyncLayoutField 'ITG Date Created' -Type 'Date' -ShowInList $true -Position 10
        New-SyncLayoutField 'ITG Date Last Updated' -Type 'Date' -ShowInList $true -Position 11
    )
    if ($Context.Config.IncludeITGlueIdField) { $fields += New-SyncLayoutField 'ITGlue ID' -Position 502 }
    return $fields
}

function Invoke-SyncLocationsStage {
    param([Parameter(Mandatory)]$Context)
    $primaryAliases = @($Context.Config.Layouts.PrimaryLocationAliases)
    Invoke-SyncAssetStage -Context $Context -Entity 'locations' -What 'location' `
        -LayoutName $Context.Config.Layouts.Locations -Icon 'fas fa-building' `
        -LayoutFields (Get-SyncLocationLayoutFields $Context) `
        -Items @(Get-SyncITGlueLocations $Context | Sort-Object { [long]$_.id }) `
        -Describe {
            param($loc)
            $a = $loc.attributes
            @{
                Name      = $a.name
                OrgId     = $a.'organization-id'
                UpdatedAt = $a.'updated-at'
                AltNames  = if ($a.primary -eq $true) { $primaryAliases } else { @() }
                Fields    = [ordered]@{
                    'Address 1'             = $a.'address-1'
                    'Address 2'             = $a.'address-2'
                    'City'                  = $a.city
                    'Postal Code'           = $a.'postal-code'
                    'Region'                = $a.'region-name'
                    'Country'               = $a.'country-name'
                    'Phone'                 = $a.phone
                    'Fax'                   = $a.fax
                    'Notes'                 = $a.notes
                    'ITG Date Created'      = ConvertTo-SyncDateField $a.'created-at'
                    'ITG Date Last Updated' = ConvertTo-SyncDateField $a.'updated-at'
                }
            }
        }
}

Set-SyncStageRunner -Name 'locations' -Run { param($ctx) Invoke-SyncLocationsStage $ctx }
