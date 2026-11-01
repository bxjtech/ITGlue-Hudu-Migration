function Get-SyncHuduWebsiteFromResponse {
    param($Response)
    $inner = Get-SyncProp $Response 'website'
    if ($inner) { return $inner }
    return $Response
}

function Invoke-SyncWebsitesStage {
    param([Parameter(Mandatory)]$Context)
    $map = Get-SyncContextMap $Context 'websites'
    $owners = Get-SyncMapHuduIndex $map
    Write-SyncLog -Message 'Fetching domains from IT Glue'
    $domains = @(Get-ITGlueCollection -Config $Context.Config -Path '/domains' | Sort-Object { [long]$_.id })
    Write-SyncLog -Message 'Fetching websites from Hudu'
    $sites = @(Get-HuduCollection -Config $Context.Config -Path '/api/v1/websites')
    $disable = [bool]$Context.Config.Websites.DisableMonitoring

    $byId = @{}
    $byName = @{}
    foreach ($s in $sites) {
        $byId[[string]$s.id] = $s
        $nk = '{0}|{1}' -f $s.company_id, ([string]$s.name).ToLowerInvariant().TrimEnd('/')
        if (-not $byName.ContainsKey($nk)) { $byName[$nk] = $s }
    }

    foreach ($dom in $domains) {
        $itgId = [string]$dom.id
        $a = $dom.attributes
        if (-not (Test-SyncInScope $Context $a.'organization-id')) { continue }
        $domainName = ([string]$a.name).Trim()
        $name = if ($domainName -match '^https?://') { $domainName } else { "https://$domainName" }
        try {
            $companyId = Get-SyncCompanyHuduId $Context $a.'organization-id'
            if (-not $companyId) {
                Add-SyncFlag $Context 'parent-not-synced' $itgId $null $name "IT Glue organization $($a.'organization-id') has not been synced to a Hudu company; skipped."
                Add-SyncResult $Context 'skipped' $itgId $name $null 'company not synced'
                continue
            }
            $payload = [ordered]@{ name = $name; notes = ConvertTo-SyncText $a.notes; company_id = $companyId }
            $hash = Get-SyncHash $payload
            $update = @{ website = [ordered]@{ name = $name; notes = $payload.notes } }

            $rec = Get-SyncMapRecord $map $itgId
            if ($rec) {
                $current = $byId[[string]$rec.huduId]
                if (-not $current) {
                    Add-SyncFlag $Context 'missing-in-hudu' $itgId $rec.huduId $name 'Mapped Hudu website no longer exists; left alone.'
                    Add-SyncResult $Context 'skipped' $itgId $name $rec.huduId 'mapped Hudu website missing'
                    continue
                }
                if ([string]$current.company_id -ne $companyId) {
                    Add-SyncFlag $Context 'moved-company' $itgId $rec.huduId $name 'Moved to a different organization in IT Glue; Hudu website left under its current company.'
                    Add-SyncResult $Context 'skipped' $itgId $name $rec.huduId 'company changed'
                    continue
                }
                Invoke-SyncExistingRecord -Context $Context -Entity 'websites' -ItgId $itgId -Name $name -Record $rec -Hash $hash -ItgUpdatedAt $a.'updated-at' -Current $current -Write {
                    Get-SyncHuduWebsiteFromResponse (Invoke-SyncHuduWrite $Context 'PUT' "/api/v1/websites/$($rec.huduId)" $update)
                }.GetNewClosure()
                continue
            }

            $nk = '{0}|{1}' -f $companyId, $name.ToLowerInvariant().TrimEnd('/')
            $match = if ($byName.ContainsKey($nk)) { $byName[$nk] } else { $null }
            if ($match -and $owners[[string]$match.id] -and $owners[[string]$match.id] -ne $itgId) {
                Add-SyncFlag $Context 'name-collision' $itgId $match.id $name "Hudu website is already mapped to IT Glue domain $($owners[[string]$match.id])."
                Add-SyncResult $Context 'skipped' $itgId $name $match.id 'name collision'
                continue
            }
            if ($match) {
                $managed = [bool]$Context.Config.UpdatePreExisting
                $rec = @{ huduId = [string]$match.id; huduName = $match.name; managed = $managed; matchedBy = 'name'; lastSyncedAt = $null; huduUpdatedAt = $match.updated_at }
                Save-SyncMapping $Context 'websites' $itgId $rec
                $owners[[string]$match.id] = $itgId
                Add-SyncResult $Context 'matched' $itgId $name $match.id 'existing Hudu website'
                if ($managed) {
                    Invoke-SyncExistingRecord -Context $Context -Entity 'websites' -ItgId $itgId -Name $name -Record $rec -Hash $hash -ItgUpdatedAt $a.'updated-at' -Current $match -Write {
                        Get-SyncHuduWebsiteFromResponse (Invoke-SyncHuduWrite $Context 'PUT' "/api/v1/websites/$($match.id)" $update)
                    }.GetNewClosure()
                }
                continue
            }

            $created = Invoke-SyncCreateRecord -Context $Context -Entity 'websites' -ItgId $itgId -Name $name -Hash $hash -ItgUpdatedAt $a.'updated-at' -Write {
                $body = @{ website = [ordered]@{
                        name = $name; notes = $payload.notes; company_id = [long]$companyId
                        paused = $disable; disable_dns = $disable; disable_ssl = $disable; disable_whois = $disable
                    }
                }
                Get-SyncHuduWebsiteFromResponse (Invoke-SyncHuduWrite $Context 'POST' '/api/v1/websites' $body)
            }.GetNewClosure()
            if ($created) { $owners[[string]$created.id] = $itgId; $byName[$nk] = $created }
        } catch {
            Add-SyncResult $Context 'error' $itgId $name $null "$($_.Exception.Message)"
        }
    }
    Add-SyncDeletedFlags -Context $Context -Map $map -Items $domains -What 'domain'
}

Set-SyncStageRunner -Name 'websites' -Run { param($ctx) Invoke-SyncWebsitesStage $ctx }
