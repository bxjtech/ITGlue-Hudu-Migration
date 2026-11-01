$script:SyncLegacyFiles = [ordered]@{
    'Companies.json'      = 'companies'
    'Locations.json'      = 'locations'
    'Websites.json'       = 'websites'
    'Configurations.json' = 'configurations'
    'Contacts.json'       = 'contacts'
    'AssetLayouts.json'   = 'flexlayouts'
    'Assets.json'         = 'flexassets'
    'Articles.json'       = 'articles'
    'Passwords.json'      = 'passwords'
}

# Seeds the ID maps from the original migration script's MigrationLogs, so records it created
# are updated in place instead of re-created. Their first sync compares IT Glue's updated-at
# with the log file's timestamp to decide between recording a baseline and updating.
function Import-SyncLegacyLogs {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Path,
        [switch]$Overwrite,
        [switch]$DryRun
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "MigrationLogs folder not found: $Path" }
    $articlesFile = if (Test-Path -LiteralPath (Join-Path $Path 'Articles.json')) { 'Articles.json' } else { 'ArticleBase.json' }
    $files = [ordered]@{} + $script:SyncLegacyFiles
    if ($articlesFile -ne 'Articles.json') { $files.Remove('Articles.json'); $files[$articlesFile] = 'articles' }

    $summary = foreach ($file in $files.Keys) {
        $entity = $files[$file]
        $full = Join-Path $Path $file
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        $loggedAt = Format-SyncTime (Get-Item -LiteralPath $full).LastWriteTimeUtc
        $entries = @(Get-Content -LiteralPath $full -Raw | ConvertFrom-Json)
        $map = Open-SyncMap -Config $Config -Entity $entity
        $added = 0; $skipped = 0; $unmatched = 0
        foreach ($e in $entries) {
            if ($null -eq $e) { continue }
            $itgId = [string](Get-SyncProp $e 'ITGID')
            $huduId = [string](Get-SyncProp $e 'HuduID')
            if (-not $itgId -or -not $huduId) { $unmatched++; continue }
            if ((Get-SyncMapRecord $map $itgId) -and -not $Overwrite) { $skipped++; continue }
            $imported = [string](Get-SyncProp $e 'Imported')
            $itgName = $null; $huduName = $null
            if ($entity -eq 'companies') {
                $itgName = Get-SyncProp (Get-SyncProp $e 'ITGCompanyObject') 'attributes' | ForEach-Object { Get-SyncProp $_ 'name' }
                $huduName = Get-SyncProp $e 'CompanyName'
            } else {
                $itgName = Get-SyncProp $e 'Name'
            }
            $record = @{
                huduId       = $huduId
                itgName      = $itgName
                huduName     = $huduName
                managed      = ($imported -ne 'Pre-Existing')
                matchedBy    = 'legacy'
                legacyStatus = $imported
                sourceHash   = $null
                lastSyncedAt = $loggedAt
            }
            if (-not $DryRun) { Set-SyncMapRecord -Map $map -ItgId $itgId -Record $record }
            $added++
        }
        if (-not $DryRun) { Save-SyncMap $map }
        [pscustomobject]@{ File = $file; Entity = $entity; Imported = $added; AlreadyMapped = $skipped; NotMigrated = $unmatched }
    }
    return @($summary)
}
