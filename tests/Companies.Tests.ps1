function Invoke-CompaniesRun {
    param($Config, [string]$Mode = 'incremental', [string[]]$Company, [switch]$DryRun, [switch]$Reapply)
    Step-FakeClock 5
    $global:Fake.Calls.Clear()
    Invoke-SyncRun -Config $Config -Stage @('companies') -Mode $Mode -Company $Company -DryRun:$DryRun -Reapply:$Reapply
}

function New-StandardOrgs {
    Add-FakeOrg -Id '1' -Name 'Acme Corp' -ShortName 'ACME' -QuickNotes 'gate code 1234'
    Add-FakeOrg -Id '2' -Name 'Globex' -Alert 'VIP'
    Add-FakeOrg -Id '3' -Name 'Initech'
    Add-FakeLocation -Id '11' -OrgId '1' -City 'Springfield'
    Add-FakeLocation -Id '12' -OrgId '1' -Primary $false -City 'Shelbyville'
}

Test 'initial sync creates every company once with address from the primary location' { param($dir)
    New-StandardOrgs
    $cfg = New-FakeConfig $dir
    $r = Invoke-CompaniesRun $cfg 'initial'
    Assert-True $r.Success 'run should succeed'
    Assert-Equal 3 $global:Fake.Companies.Count
    Assert-Equal 3 (Get-FakeCalls POST).Count
    $acme = $global:Fake.Companies | Where-Object name -eq 'Acme Corp'
    Assert-Equal 'Springfield' $acme.city
    Assert-Equal 'ACME' $acme.nickname
    $globex = $global:Fake.Companies | Where-Object name -eq 'Globex'
    Assert-Equal "<div class='callout callout-warning'>VIP</div>" $globex.notes
}

Test 're-running initial, incremental and cutover with no changes writes nothing' { param($dir)
    New-StandardOrgs
    $cfg = New-FakeConfig $dir
    Invoke-CompaniesRun $cfg 'initial' | Out-Null
    foreach ($mode in 'initial', 'incremental', 'cutover') {
        $r = Invoke-CompaniesRun $cfg $mode
        Assert-True $r.Success "$mode run should succeed"
        Assert-Equal 0 (Get-FakeCalls POST).Count "$mode must not create"
        Assert-Equal 0 (Get-FakeCalls PUT).Count "$mode must not update"
    }
    Assert-Equal 3 $global:Fake.Companies.Count
}

Test 'incremental updates only the company whose IT Glue data changed' { param($dir)
    New-StandardOrgs
    $cfg = New-FakeConfig $dir
    Invoke-CompaniesRun $cfg 'initial' | Out-Null
    Step-FakeClock 30
    Set-FakeOrg -Id '3' -Attributes @{ 'quick-notes' = 'new notes' }
    $r = Invoke-CompaniesRun $cfg 'incremental'
    $puts = Get-FakeCalls PUT
    Assert-Equal 1 $puts.Count
    Assert-Equal 'new notes' ($global:Fake.Companies | Where-Object name -eq 'Initech').notes
    Assert-Equal 1 @($r.Results | Where-Object action -eq 'updated').Count
}

Test 'primary location change updates the company address' { param($dir)
    New-StandardOrgs
    $cfg = New-FakeConfig $dir
    Invoke-CompaniesRun $cfg 'initial' | Out-Null
    Set-FakeLocation -Id '11' -Attributes @{ city = 'Capital City' }
    Invoke-CompaniesRun $cfg 'incremental' | Out-Null
    Assert-Equal 1 (Get-FakeCalls PUT).Count
    Assert-Equal 'Capital City' ($global:Fake.Companies | Where-Object name -eq 'Acme Corp').city
}

Test 'initial mode never updates already-synced companies' { param($dir)
    New-StandardOrgs
    $cfg = New-FakeConfig $dir
    Invoke-CompaniesRun $cfg 'initial' | Out-Null
    Set-FakeOrg -Id '1' -Attributes @{ 'short-name' = 'ACME2' }
    Invoke-CompaniesRun $cfg 'initial' | Out-Null
    Assert-Equal 0 (Get-FakeCalls PUT).Count
    Invoke-CompaniesRun $cfg 'cutover' | Out-Null
    Assert-Equal 1 (Get-FakeCalls PUT).Count
}

Test 'duplicate IT Glue names get stable suffixes and are flagged' { param($dir)
    Add-FakeOrg -Id '20' -Name 'Contoso'
    Add-FakeOrg -Id '7' -Name 'Contoso'
    $cfg = New-FakeConfig $dir
    $r = Invoke-CompaniesRun $cfg 'initial'
    Assert-Equal 'Contoso,Contoso-1' ((@($global:Fake.Companies.name) | Sort-Object) -join ',')
    $map = Open-SyncMap -Config $cfg -Entity companies
    Assert-Equal 'Contoso' $map.Records['7'].huduName 'lowest IT Glue ID keeps the plain name'
    Assert-Equal 1 @($r.Flags | Where-Object type -eq 'duplicate-name').Count
    Add-FakeOrg -Id '3' -Name 'Contoso'
    Invoke-CompaniesRun $cfg 'incremental' | Out-Null
    Assert-Equal 0 (Get-FakeCalls PUT).Count 'existing names must not shift when a new duplicate appears'
    Assert-Equal 'Contoso-2' ($global:Fake.Companies | Select-Object -Last 1).name
}

Test 'pre-existing Hudu company with the same name is matched, not duplicated or modified' { param($dir)
    New-StandardOrgs
    $existing = Add-FakeHuduCompany -Name 'globex' -Fields @{ notes = 'from PSA' }
    $cfg = New-FakeConfig $dir
    $r = Invoke-CompaniesRun $cfg 'initial'
    Assert-Equal 3 $global:Fake.Companies.Count
    Assert-Equal 'matched' ($r.Results | Where-Object itgId -eq '2').action
    Set-FakeOrg -Id '2' -Attributes @{ alert = 'changed' }
    Invoke-CompaniesRun $cfg 'cutover' | Out-Null
    Assert-Equal 0 (Get-FakeCalls PUT).Count
    Assert-Equal 'from PSA' (Get-FakeHuduCompany $existing.id).notes
}

Test 'UpdatePreExisting lets the sync manage name-matched companies' { param($dir)
    New-StandardOrgs
    Add-FakeHuduCompany -Name 'Globex' -Fields @{ notes = 'from PSA' } | Out-Null
    $cfg = New-FakeConfig $dir -Companies @{ UpdatePreExisting = $true }
    Invoke-CompaniesRun $cfg 'incremental' | Out-Null
    Assert-Equal "<div class='callout callout-warning'>VIP</div>" ($global:Fake.Companies | Where-Object name -eq 'Globex').notes
}

Test 'company deleted in IT Glue is flagged and left alone in Hudu' { param($dir)
    New-StandardOrgs
    $cfg = New-FakeConfig $dir
    Invoke-CompaniesRun $cfg 'initial' | Out-Null
    Remove-FakeOrg '3'
    $r = Invoke-CompaniesRun $cfg 'cutover'
    Assert-Equal 3 $global:Fake.Companies.Count
    Assert-Equal 0 @(Get-FakeCalls PUT).Count
    Assert-Equal 'deleted-in-itglue' ($r.Flags | Select-Object -First 1).type
    $store = Get-SyncFlags $cfg
    Assert-Equal 1 $store.Count
    Add-FakeOrg -Id '3' -Name 'Initech'
    Invoke-CompaniesRun $cfg 'incremental' | Out-Null
    Assert-Equal 0 (Get-SyncFlags $cfg).Count 'flag clears once the organization is back'
}

Test 'company deleted in Hudu is flagged, not re-created' { param($dir)
    New-StandardOrgs
    $cfg = New-FakeConfig $dir
    Invoke-CompaniesRun $cfg 'initial' | Out-Null
    [void]$global:Fake.Companies.Remove(($global:Fake.Companies | Where-Object name -eq 'Initech'))
    $r = Invoke-CompaniesRun $cfg 'cutover'
    Assert-Equal 0 (Get-FakeCalls POST).Count
    Assert-Equal 'missing-in-hudu' ($r.Flags | Select-Object -First 1).type
}

Test 'edits on both sides: itglue-wins applies and flags, hudu-wins keeps Hudu and flags' { param($dir)
    New-StandardOrgs
    $cfg = New-FakeConfig $dir
    Invoke-CompaniesRun $cfg 'initial' | Out-Null
    Step-FakeClock 10
    $c = $global:Fake.Companies | Where-Object name -eq 'Initech'
    $c.notes = 'edited in hudu'; $c.updated_at = Get-FakeNowText
    Set-FakeOrg -Id '3' -Attributes @{ 'quick-notes' = 'edited in itglue' }
    $r = Invoke-CompaniesRun $cfg 'incremental'
    Assert-Equal 'edited in itglue' $c.notes
    Assert-Equal 'hudu-modified' ($r.Flags | Select-Object -First 1).type

    Step-FakeClock 10
    $c.notes = 'edited in hudu again'; $c.updated_at = Get-FakeNowText
    Set-FakeOrg -Id '3' -Attributes @{ 'quick-notes' = 'edited in itglue again' }
    $cfg.ConflictPolicy = 'hudu-wins'
    $r = Invoke-CompaniesRun $cfg 'incremental'
    Assert-Equal 'edited in hudu again' $c.notes
    Assert-Equal 0 (Get-FakeCalls PUT).Count
}

Test 'lost state: re-run matches existing companies by name instead of duplicating' { param($dir)
    New-StandardOrgs
    $cfg = New-FakeConfig $dir
    Invoke-CompaniesRun $cfg 'initial' | Out-Null
    Remove-Item -LiteralPath (Join-Path $dir 'state') -Recurse -Force
    Invoke-CompaniesRun $cfg 'incremental' | Out-Null
    Assert-Equal 0 (Get-FakeCalls POST).Count
    Assert-Equal 3 $global:Fake.Companies.Count
}

Test 'lost state with back-references: companies re-link as managed and keep syncing' { param($dir)
    New-StandardOrgs
    $cfg = New-FakeConfig $dir -Companies @{ WriteBackReference = $true }
    Invoke-CompaniesRun $cfg 'initial' | Out-Null
    Assert-Equal 'ITG:1' ($global:Fake.Companies | Where-Object name -eq 'Acme Corp').id_number
    Remove-Item -LiteralPath (Join-Path $dir 'state') -Recurse -Force
    Set-FakeOrg -Id '1' -Attributes @{ name = 'Acme Corporation' }
    Invoke-CompaniesRun $cfg 'incremental' | Out-Null
    Assert-Equal 0 (Get-FakeCalls POST).Count
    Assert-True ($global:Fake.Companies | Where-Object name -eq 'Acme Corporation') 'renamed company re-linked by back-reference and updated'
}

Test 'rename in IT Glue renames the Hudu company in place' { param($dir)
    New-StandardOrgs
    $cfg = New-FakeConfig $dir
    Invoke-CompaniesRun $cfg 'initial' | Out-Null
    Set-FakeOrg -Id '2' -Attributes @{ name = 'Globex International' }
    Invoke-CompaniesRun $cfg 'incremental' | Out-Null
    Assert-Equal 0 (Get-FakeCalls POST).Count
    Assert-Equal 3 $global:Fake.Companies.Count
    Assert-True ($global:Fake.Companies | Where-Object name -eq 'Globex International') 'renamed'
}

Test 'dry run writes nothing to Hudu or local state' { param($dir)
    New-StandardOrgs
    $cfg = New-FakeConfig $dir
    $r = Invoke-CompaniesRun $cfg 'initial' -DryRun
    Assert-Equal 0 $global:Fake.Companies.Count
    Assert-Equal 3 @($r.Results | Where-Object action -eq 'would-create').Count
    Assert-True (-not (Test-Path (Join-Path $dir 'state/map-companies.json'))) 'no map written'
    Assert-Equal 0 (Get-SyncStageState $cfg).Count
}

Test 'scoped run syncs only the chosen companies and does not advance the watermark' { param($dir)
    New-StandardOrgs
    $cfg = New-FakeConfig $dir
    $r = Invoke-CompaniesRun $cfg 'initial' -Company '2', 'Initech'
    Assert-Equal 'Globex,Initech' ((@($global:Fake.Companies.name) | Sort-Object) -join ',')
    $st = (Get-SyncStageState $cfg).companies
    Assert-True $st.lastSuccessAt 'scoped success still satisfies dependencies'
    Assert-True (-not $st.watermark) 'scoped run must not move the watermark'
    Assert-Equal 0 @($r.Flags | Where-Object type -eq 'deleted-in-itglue').Count
    Assert-Throws { Invoke-CompaniesRun $cfg 'initial' -Company 'Nobody' } -Like '*no IT Glue organization*'
}

Test 'crash mid-run: mappings already written survive and the re-run creates only the rest' { param($dir)
    1..5 | ForEach-Object { Add-FakeOrg -Id "$_" -Name "Company $_" }
    $cfg = New-FakeConfig $dir
    $global:Fake.PostLimit = 2
    $r = Invoke-CompaniesRun $cfg 'initial'
    Assert-True (-not $r.Success) 'run reports errors'
    Assert-Equal 2 $global:Fake.Companies.Count
    Assert-Equal 5 @(Get-FakeCalls POST).Count 'each failed POST is attempted once, never retried'
    $global:Fake.PostLimit = $null
    Invoke-CompaniesRun $cfg 'initial' | Out-Null
    Assert-Equal 5 $global:Fake.Companies.Count
    Assert-Equal 3 @(Get-FakeCalls POST).Count
}

Test 'journal replays mappings that were never compacted into the snapshot' { param($dir)
    $cfg = New-FakeConfig $dir
    $m = Open-SyncMap -Config $cfg -Entity companies
    Set-SyncMapRecord -Map $m -ItgId '9' -Record @{ huduId = '900'; managed = $true }
    $reopened = Open-SyncMap -Config $cfg -Entity companies
    Assert-Equal '900' $reopened.Records['9'].huduId
    Save-SyncMap $reopened
    Assert-True (-not (Test-Path $m.JournalPath)) 'journal compacted'
    Assert-Equal '900' (Open-SyncMap -Config $cfg -Entity companies).Records['9'].huduId
}

Test 'rate limiting (429) on reads is retried transparently' { param($dir)
    New-StandardOrgs
    $cfg = New-FakeConfig $dir
    $global:Fake.FailNext = @(@{ Method = 'GET'; Path = '/organizations'; Status = 429 }, @{ Method = 'GET'; Path = '/api/v1/companies'; Status = 503 })
    $r = Invoke-CompaniesRun $cfg 'initial'
    Assert-True $r.Success 'run should succeed after retries'
    Assert-Equal 3 $global:Fake.Companies.Count
}

Test 'merged organization types map to one Hudu company without creating anything' { param($dir)
    New-StandardOrgs
    Add-FakeOrg -Id '50' -Name 'Dell' -Type 'Vendor'
    Add-FakeOrg -Id '51' -Name 'HP' -Type 'Vendor'
    $vendors = Add-FakeHuduCompany -Name 'Vendors'
    $cfg = New-FakeConfig $dir -Companies @{ MergeOrgTypes = @('Vendor'); MergeTargetHuduCompany = $vendors.id }
    Invoke-CompaniesRun $cfg 'initial' | Out-Null
    Assert-Equal 4 $global:Fake.Companies.Count 'three customers plus the existing Vendors company'
    $map = Open-SyncMap -Config $cfg -Entity companies
    Assert-Equal ([string]$vendors.id) $map.Records['50'].huduId
    Assert-Equal ([string]$vendors.id) $map.Records['51'].huduId
}

Test 'legacy MigrationLogs import adopts earlier migration without duplicates' { param($dir)
    New-StandardOrgs
    $acme = Add-FakeHuduCompany -Name 'Acme Corp' -Fields @{ notes = 'rewritten links' }
    $globex = Add-FakeHuduCompany -Name 'Globex'
    $logs = Join-Path $dir 'MigrationLogs'
    New-Item -ItemType Directory -Path $logs | Out-Null
    @(
        @{ CompanyName = 'Acme Corp'; ITGID = '1'; HuduID = $acme.id; Matched = $true; Imported = 'Created-By-Script'; ITGCompanyObject = @{ attributes = @{ name = 'Acme Corp' } } }
        @{ CompanyName = 'Globex'; ITGID = '2'; HuduID = $globex.id; Matched = $true; Imported = 'Pre-Existing'; ITGCompanyObject = @{ attributes = @{ name = 'Globex' } } }
        @{ CompanyName = 'Initech'; ITGID = '3'; HuduID = ''; Matched = $false; Imported = '' }
    ) | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $logs 'Companies.json')
    Step-FakeClock 60
    (Get-Item (Join-Path $logs 'Companies.json')).LastWriteTimeUtc = $global:FakeNow
    $cfg = New-FakeConfig $dir
    $rows = Import-SyncLegacyLogs -Config $cfg -Path $logs
    Assert-Equal 2 ($rows | Where-Object Entity -eq 'companies').Imported

    $r = Invoke-CompaniesRun $cfg 'incremental'
    Assert-Equal 1 (Get-FakeCalls POST).Count 'only the never-migrated company is created'
    Assert-Equal 0 (Get-FakeCalls PUT).Count 'unchanged legacy company is baselined, not overwritten'
    Assert-Equal 'baseline' ($r.Results | Where-Object itgId -eq '1').action
    Assert-Equal 'rewritten links' (Get-FakeHuduCompany $acme.id).notes

    Set-FakeOrg -Id '1' -Attributes @{ 'quick-notes' = 'changed after migration' }
    Invoke-CompaniesRun $cfg 'incremental' | Out-Null
    Assert-Equal 1 (Get-FakeCalls PUT).Count
    Assert-Equal 3 $global:Fake.Companies.Count
}

Test 'lock blocks a concurrent run; stale locks are cleared' { param($dir)
    $cfg = New-FakeConfig $dir
    $lock = Enter-SyncLock -Config $cfg
    Assert-Throws { Enter-SyncLock -Config $cfg } -Like '*Another sync is running*'
    Step-FakeClock (13 * 60)
    $again = Enter-SyncLock -Config $cfg
    Exit-SyncLock $again
    Assert-True (-not (Test-Path $lock)) 'lock released'
}

Test 'pagination walks every page on both APIs' { param($dir)
    1..7 | ForEach-Object { Add-FakeOrg -Id "$_" -Name "Org $_" }
    1..5 | ForEach-Object { Add-FakeHuduCompany -Name "Co $_" | Out-Null }
    $cfg = New-FakeConfig $dir
    Assert-Equal 7 @(Get-ITGlueCollection -Config $cfg -Path '/organizations' -PageSize 3).Count
    Assert-Equal 5 @(Get-HuduCollection -Config $cfg -Path '/api/v1/companies' -Property companies -PageSize 2).Count
}

Test 'reports are written as JSON and Markdown' { param($dir)
    New-StandardOrgs
    $cfg = New-FakeConfig $dir
    $r = Invoke-CompaniesRun $cfg 'initial'
    Assert-True (Test-Path $r.ReportPath) 'markdown report'
    $json = Get-Content $r.JsonPath -Raw | ConvertFrom-Json
    Assert-Equal 'initial' $json.mode
    Assert-Equal 3 $json.stages[0].counts.created
}
