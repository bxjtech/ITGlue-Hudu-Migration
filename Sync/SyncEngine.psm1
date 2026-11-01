$core = 'Util', 'Http', 'Clients', 'Config', 'State', 'Stages', 'Engine', 'Records', 'Assets', 'Report', 'Legacy'
foreach ($c in $core) { . (Join-Path $PSScriptRoot "Core/$c.ps1") }

. (Join-Path $PSScriptRoot 'Stages/Catalog.ps1')
foreach ($f in (Get-ChildItem -Path (Join-Path $PSScriptRoot 'Stages') -Filter '*.ps1' | Where-Object Name -ne 'Catalog.ps1' | Sort-Object Name)) {
    . $f.FullName
}

function Set-SyncClock { param([scriptblock]$Clock) $script:SyncClock = $Clock }
function Set-SyncSleep { param([Parameter(Mandatory)][scriptblock]$Sleep) $script:SyncSleep = $Sleep }
function Set-SyncLogOptions {
    param([switch]$Quiet, [switch]$Verbose, [string]$Path)
    $script:SyncQuiet = [bool]$Quiet
    $script:SyncVerbose = [bool]$Verbose
    if ($PSBoundParameters.ContainsKey('Path')) { $script:SyncLogPath = $Path }
}

Export-ModuleMember -Function *
