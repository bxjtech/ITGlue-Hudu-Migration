#Requires -Version 7.2
# Dependency-free test runner: pwsh tests/run-tests.ps1 [-Filter <substring>]
param([string]$Filter)
$ErrorActionPreference = 'Stop'

$script:TestResults = [System.Collections.Generic.List[object]]::new()

function Test {
    param([Parameter(Mandatory, Position = 0)][string]$Name, [Parameter(Mandatory, Position = 1)][scriptblock]$Body)
    if ($Filter -and $Name -notlike "*$Filter*") { return }
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("sync-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $dir | Out-Null
    try {
        Reset-FakeApis
        & $Body $dir
        $script:TestResults.Add([pscustomobject]@{ Name = $Name; Passed = $true; Error = $null })
        Write-Host "  PASS  $Name" -ForegroundColor Green
    } catch {
        $script:TestResults.Add([pscustomobject]@{ Name = $Name; Passed = $false; Error = $_ })
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        Write-Host "        $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "        $(($_.ScriptStackTrace -split "`n" | Select-Object -First 2) -join ' | ')" -ForegroundColor DarkGray
    } finally {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Because = '')
    if ("$Expected" -ne "$Actual") { throw "Expected '$Expected' but got '$Actual'. $Because" }
}

function Assert-True {
    param($Condition, [string]$Because = 'condition was false')
    if (-not $Condition) { throw "Assertion failed: $Because" }
}

function Assert-Throws {
    param([scriptblock]$Body, [string]$Like = '*')
    try { & $Body } catch {
        if ($_.Exception.Message -notlike $Like) { throw "Threw '$($_.Exception.Message)', expected like '$Like'." }
        return
    }
    throw "Expected an exception like '$Like'."
}

Import-Module (Join-Path $PSScriptRoot '../Sync/SyncEngine.psm1') -Force
. (Join-Path $PSScriptRoot 'FakeApis.ps1')
Set-SyncTransport $global:FakeTransport
Set-SyncClock { $global:FakeNow }
Set-SyncSleep { param($s) }
Set-SyncLogOptions -Quiet

foreach ($file in (Get-ChildItem -Path $PSScriptRoot -Filter '*.Tests.ps1' | Sort-Object Name)) {
    Write-Host $file.Name
    . $file.FullName
}

$failed = @($script:TestResults | Where-Object { -not $_.Passed })
Write-Host ''
Write-Host "$($script:TestResults.Count - $failed.Count) passed, $($failed.Count) failed"
exit ([int]($failed.Count -gt 0))
