function Invoke-StageRun {
    param($Config, [string[]]$Stage, [string]$Mode = 'incremental', [string[]]$Company, [switch]$DryRun)
    Step-FakeClock 5
    $global:Fake.Calls.Clear()
    Invoke-SyncRun -Config $Config -Stage $Stage -Mode $Mode -Company $Company -DryRun:$DryRun
}

function Get-FakeWrites { @($global:Fake.Calls | Where-Object { $_.Method -in 'POST', 'PUT' -and $_.Host -eq 'hudu.test' }) }

function New-CoreFixture {
    Add-FakeOrg -Id '1' -Name 'Acme Corp'
    Add-FakeOrg -Id '2' -Name 'Globex'
    Add-FakeLocation -Id '11' -OrgId '1' -City 'Springfield'
    Add-FakeLocation -Id '12' -OrgId '1' -Primary $false -City 'Shelbyville'
    ($global:Fake.Locations | Where-Object id -eq '11').attributes.name = 'Main Office'
    ($global:Fake.Locations | Where-Object id -eq '12').attributes.name = 'Warehouse'
    Add-FakeLocation -Id '21' -OrgId '2' -City 'Cypress Creek'
    ($global:Fake.Locations | Where-Object id -eq '21').attributes.name = 'HQ'
    Add-FakeContact -Id '31' -OrgId '1' -First 'Wile' -Last 'Coyote' -LocationId '12' -Email 'wile@acme.test'
    Add-FakeContact -Id '32' -OrgId '2' -First 'Hank' -Last 'Scorpio'
    Add-FakeDomain -Id '41' -OrgId '1' -Name 'acme.test' -Notes 'registrar: example'
    Add-FakeDomain -Id '42' -OrgId '2' -Name 'globex.test'
}

Test 'core recipe: initial sync builds layouts, locations, contacts with location links, and websites' { param($dir)
    New-CoreFixture
    $cfg = New-FakeConfig $dir
    $r = Invoke-StageRun $cfg @('core') 'initial'
    Assert-True $r.Success 'run should succeed'
    Assert-Equal 'companies,locations,contacts,websites' (@($r.Summary.stage) -join ',')
    $locLayout = $global:Fake.Layouts | Where-Object name -eq 'Locations'
    $peopleLayout = $global:Fake.Layouts | Where-Object name -eq 'People'
    Assert-True ($locLayout.active -and $peopleLayout.active) 'layouts created and activated'
    Assert-True ($peopleLayout.fields | Where-Object { $_.label -eq 'Location' -and $_.linkable_id -eq $locLayout.id }) 'People layout links to Locations'

    $warehouse = $global:Fake.Assets | Where-Object name -eq 'Warehouse'
    Assert-Equal 'Shelbyville' (Get-FakeAssetField $warehouse 'City')
    Assert-Equal '12' (Get-FakeAssetField $warehouse 'ITGlue ID')
    $wile = $global:Fake.Assets | Where-Object name -eq 'Wile Coyote'
    Assert-Equal "[{`"id`":$($warehouse.id),`"name`":`"Warehouse`"}]" (Get-FakeAssetField $wile 'Location')
    Assert-True ((Get-FakeAssetField $wile 'Emails') -like '*wile@acme.test*(primary)*') 'emails rendered'
    Assert-Equal ($global:Fake.Companies | Where-Object name -eq 'Acme Corp').id $wile.company_id

    Assert-Equal 2 $global:Fake.Websites.Count
    $site = $global:Fake.Websites | Where-Object name -eq 'https://acme.test'
    Assert-Equal 'registrar: example' $site.notes
    Assert-True ($site.paused -and $site.disable_dns) 'monitoring disabled by default'
}

Test 'core recipe: re-running every mode makes no writes' { param($dir)
    New-CoreFixture
    $cfg = New-FakeConfig $dir
    Invoke-StageRun $cfg @('core') 'initial' | Out-Null
    foreach ($mode in 'initial', 'incremental', 'cutover') {
        $r = Invoke-StageRun $cfg @('core') $mode
        Assert-True $r.Success "$mode should succeed"
        Assert-Equal 0 (Get-FakeWrites).Count "$mode must not write"
    }
    Assert-Equal 5 $global:Fake.Assets.Count
    Assert-Equal 2 $global:Fake.Websites.Count
}

Test 'changes in IT Glue update exactly the affected Hudu records' { param($dir)
    New-CoreFixture
    $cfg = New-FakeConfig $dir
    Invoke-StageRun $cfg @('core') 'initial' | Out-Null
    Set-FakeLocation -Id '12' -Attributes @{ city = 'Ogdenville' }
    Set-FakeItgRecord Contacts '32' @{ title = 'CEO' }
    Set-FakeItgRecord Domains '42' @{ notes = 'renewal in May' }
    Invoke-StageRun $cfg @('core') 'incremental' | Out-Null
    $puts = @(Get-FakeCalls PUT)
    Assert-Equal 3 $puts.Count ("got: " + ($puts.Path -join ', '))
    Assert-Equal 'Ogdenville' (Get-FakeAssetField ($global:Fake.Assets | Where-Object name -eq 'Warehouse') 'City')
    Assert-Equal 'CEO' (Get-FakeAssetField ($global:Fake.Assets | Where-Object name -eq 'Hank Scorpio') 'Title')
    Assert-Equal 'renewal in May' ($global:Fake.Websites | Where-Object name -eq 'https://globex.test').notes
}

Test 'lost state: assets re-link via the ITGlue ID field and stay managed' { param($dir)
    New-CoreFixture
    $cfg = New-FakeConfig $dir
    Invoke-StageRun $cfg @('core') 'initial' | Out-Null
    Remove-Item -LiteralPath (Join-Path $dir 'state') -Recurse -Force
    Set-FakeItgRecord Contacts '31' @{ name = 'Wile E. Coyote' }
    Invoke-StageRun $cfg @('core') 'incremental' | Out-Null
    Assert-Equal 0 (Get-FakeCalls POST).Count 'nothing duplicated'
    Assert-True ($global:Fake.Assets | Where-Object name -eq 'Wile E. Coyote') 'renamed contact updated in place'
    Assert-Equal 5 $global:Fake.Assets.Count
}

Test 'an older layout without some fields still syncs the fields it has' { param($dir)
    New-CoreFixture
    $cfg = New-FakeConfig $dir
    Add-FakeLayout -Name 'People' -Labels @('First Name', 'Last Name', 'Title', 'Emails') | Out-Null
    $r = Invoke-StageRun $cfg @('companies', 'contacts') 'initial'
    Assert-True $r.Success 'no 422 from unknown fields'
    $wile = $global:Fake.Assets | Where-Object name -eq 'Wile Coyote'
    Assert-Equal 'Coyote' (Get-FakeAssetField $wile 'Last Name')
    Assert-True (-not (Get-FakeAssetField $wile 'Location')) 'no Location field to write'
}

Test 'pre-existing Hudu assets are matched by name, including the Primary Address alias, and not modified' { param($dir)
    New-CoreFixture
    $cfg = New-FakeConfig $dir
    Invoke-StageRun $cfg @('companies') 'initial' | Out-Null
    $acme = $global:Fake.Companies | Where-Object name -eq 'Acme Corp'
    $layout = Add-FakeLayout -Name 'Locations' -Labels @('Address 1', 'City', 'ITGlue ID')
    $psa = Add-FakeAsset -LayoutId $layout.id -CompanyId $acme.id -Name 'Primary Address' -Fields @{ City = 'from PSA' }
    $r = Invoke-StageRun $cfg @('locations') 'initial'
    Assert-Equal 'matched' ($r.Results | Where-Object itgId -eq '11').action
    Assert-Equal 3 $global:Fake.Assets.Count
    Set-FakeLocation -Id '11' -Attributes @{ city = 'Changed' }
    Invoke-StageRun $cfg @('locations') 'cutover' | Out-Null
    Assert-Equal 'from PSA' (Get-FakeAssetField $psa 'City')
}

Test 'records for an organization that has not synced are flagged and skipped' { param($dir)
    New-CoreFixture
    $cfg = New-FakeConfig $dir
    Invoke-StageRun $cfg @('companies') 'initial' -Company '1' | Out-Null
    $r = Invoke-StageRun $cfg @('contacts', 'websites') 'initial'
    Assert-Equal 2 @($r.Flags | Where-Object type -eq 'parent-not-synced').Count
    Assert-True (-not ($global:Fake.Assets | Where-Object name -eq 'Hank Scorpio')) 'Globex contact not created'
    Assert-True ($global:Fake.Assets | Where-Object name -eq 'Wile Coyote') 'Acme contact created'
}

Test 'dry run on an empty Hudu reports layouts and records it would create, writing nothing' { param($dir)
    New-CoreFixture
    $cfg = New-FakeConfig $dir
    Invoke-StageRun $cfg @('companies') 'initial' | Out-Null
    $r = Invoke-StageRun $cfg @('locations', 'contacts', 'websites') 'initial' -DryRun
    Assert-Equal 0 (Get-FakeWrites).Count
    Assert-Equal 2 @($r.Results | Where-Object action -eq 'would-create-layout').Count
    Assert-Equal 7 @($r.Results | Where-Object action -eq 'would-create').Count
}

Test 'moved and deleted IT Glue records are flagged and left alone' { param($dir)
    New-CoreFixture
    $cfg = New-FakeConfig $dir
    Invoke-StageRun $cfg @('core') 'initial' | Out-Null
    Set-FakeItgRecord Domains '41' @{ 'organization-id' = 2 }
    [void]$global:Fake.Contacts.Remove(($global:Fake.Contacts | Where-Object id -eq '32'))
    $r = Invoke-StageRun $cfg @('core') 'cutover'
    Assert-Equal 0 (Get-FakeWrites).Count
    Assert-Equal 'moved-company' ($r.Flags | Where-Object stage -eq 'websites').type
    Assert-Equal 'deleted-in-itglue' ($r.Flags | Where-Object stage -eq 'contacts').type
}

Test 'contacts before locations: works, and the link appears once locations sync' { param($dir)
    New-CoreFixture
    $cfg = New-FakeConfig $dir
    Invoke-StageRun $cfg @('companies', 'contacts') 'initial' | Out-Null
    $people = $global:Fake.Layouts | Where-Object name -eq 'People'
    Assert-True (-not ($people.fields | Where-Object label -eq 'Location')) 'no Location field without a Locations layout'
    $r = Invoke-StageRun $cfg @('locations', 'contacts') 'incremental'
    Assert-True $r.Success 'later runs succeed'
    Assert-Equal 0 @(Get-FakeCalls PUT '*/assets/*').Count 'contacts unchanged because the layout has no Location field'
}

Test 'existing Hudu website for the same company is matched, not duplicated' { param($dir)
    New-CoreFixture
    $cfg = New-FakeConfig $dir
    Invoke-StageRun $cfg @('companies') 'initial' | Out-Null
    $acme = $global:Fake.Companies | Where-Object name -eq 'Acme Corp'
    $global:Fake.Websites.Add(@{ id = 900; name = 'https://ACME.test/'; company_id = $acme.id; notes = 'monitored'; updated_at = (Get-FakeNowText) })
    $r = Invoke-StageRun $cfg @('websites') 'initial'
    Assert-Equal 'matched' ($r.Results | Where-Object itgId -eq '41').action
    Assert-Equal 2 $global:Fake.Websites.Count
}

Test 'legacy contacts are adopted and baselined without being rewritten' { param($dir)
    New-CoreFixture
    $cfg = New-FakeConfig $dir
    Invoke-StageRun $cfg @('companies', 'locations') 'initial' | Out-Null
    $acme = $global:Fake.Companies | Where-Object name -eq 'Acme Corp'
    $people = Add-FakeLayout -Name 'People' -Labels @('First Name', 'Last Name', 'Title', 'Emails', 'ITGlue ID')
    $old = Add-FakeAsset -LayoutId $people.id -CompanyId $acme.id -Name 'Wile Coyote' -Fields @{ 'First Name' = 'Wile'; 'Emails' = 'legacy format' }
    $logs = Join-Path $dir 'MigrationLogs'
    New-Item -ItemType Directory -Path $logs | Out-Null
    @(@{ Name = 'Wile Coyote'; ITGID = '31'; HuduID = $old.id; Matched = $true; Imported = 'Created-By-Script' }) | ConvertTo-Json -AsArray | Set-Content (Join-Path $logs 'Contacts.json')
    Step-FakeClock 60
    (Get-Item (Join-Path $logs 'Contacts.json')).LastWriteTimeUtc = $global:FakeNow
    Import-SyncLegacyLogs -Config $cfg -Path $logs | Out-Null
    $r = Invoke-StageRun $cfg @('contacts') 'incremental'
    Assert-Equal 'baseline' ($r.Results | Where-Object itgId -eq '31').action
    Assert-Equal 'legacy format' (Get-FakeAssetField $old 'Emails')
    Assert-Equal 1 @(Get-FakeCalls POST '*/assets').Count 'only the unmigrated Globex contact is created'
}
