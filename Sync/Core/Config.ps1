function Get-SyncDefaultDataDir {
    if ($env:SYNC_DATA_DIR) { return $env:SYNC_DATA_DIR }
    if (Test-Path -LiteralPath '/data' -PathType Container) { return '/data' }
    return (Join-Path (Split-Path -Parent $PSScriptRoot | Split-Path -Parent) 'data')
}

function Get-SyncConfig {
    param([string]$Path)

    $config = [ordered]@{
        HuduBaseUrl               = ''
        HuduApiKey                = ''
        ITGlueApiUrl              = 'https://api.itglue.com'
        ITGlueApiKey              = ''
        ITGlueExportPath          = ''
        DataDir                   = Get-SyncDefaultDataDir
        ConflictPolicy            = 'itglue-wins'
        LockStaleHours            = 12
        UpdatePreExisting         = $false
        IncludeITGlueIdField      = $true
        Companies                 = [ordered]@{
            WriteBackReference     = $false
            MergeOrgTypes          = @()
            MergeTargetHuduCompany = $null
            Parents                = [ordered]@{}
        }
        Layouts                   = [ordered]@{
            Locations              = 'Locations'
            Contacts               = 'People'
            Color                  = '#6136ff'
            IconColor              = '#ffffff'
            PrimaryLocationAliases = @('Primary Address')
            MissingFields          = 'stop'
        }
        Websites                  = [ordered]@{
            DisableMonitoring = $true
        }
    }

    $resolved = $Path
    if (-not $resolved -and $env:SYNC_CONFIG) { $resolved = $env:SYNC_CONFIG }
    if (-not $resolved) { $resolved = Join-Path $config.DataDir 'sync.config.json' }
    $config.ConfigPath = $resolved

    if ($resolved -and (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        $fromFile = Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json -AsHashtable
        foreach ($k in @($fromFile.Keys)) {
            if ($config[$k] -is [System.Collections.IDictionary] -and $fromFile[$k] -is [System.Collections.IDictionary]) {
                foreach ($sub in @($fromFile[$k].Keys)) { $config[$k][$sub] = $fromFile[$k][$sub] }
            } else {
                $config[$k] = $fromFile[$k]
            }
        }
    } elseif ($Path) {
        throw "Config file not found: $Path"
    }

    $envMap = @{
        HUDU_BASE_URL      = 'HuduBaseUrl'
        HUDU_API_KEY       = 'HuduApiKey'
        ITGLUE_API_URL     = 'ITGlueApiUrl'
        ITGLUE_API_KEY     = 'ITGlueApiKey'
        ITGLUE_EXPORT_PATH = 'ITGlueExportPath'
        SYNC_DATA_DIR      = 'DataDir'
    }
    foreach ($name in $envMap.Keys) {
        $val = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($val)) { $config[$envMap[$name]] = $val.Trim() }
    }

    foreach ($k in 'HuduBaseUrl', 'ITGlueApiUrl') {
        $config[$k] = ([string]$config[$k]).Trim().TrimEnd('/')
    }
    if ($config.Layouts.MissingFields -notin @('stop', 'add', 'ignore')) {
        throw "Layouts.MissingFields must be 'stop', 'add' or 'ignore' (got '$($config.Layouts.MissingFields)')."
    }
    if ($config.ConflictPolicy -notin @('itglue-wins', 'hudu-wins')) {
        throw "ConflictPolicy must be 'itglue-wins' or 'hudu-wins' (got '$($config.ConflictPolicy)')."
    }
    return $config
}

function Assert-SyncConfigForApi {
    param([Parameter(Mandatory)]$Config)
    $missing = @()
    if (-not $Config.HuduBaseUrl) { $missing += 'HUDU_BASE_URL' }
    if (-not $Config.HuduApiKey) { $missing += 'HUDU_API_KEY' }
    if (-not $Config.ITGlueApiUrl) { $missing += 'ITGLUE_API_URL' }
    if (-not $Config.ITGlueApiKey) { $missing += 'ITGLUE_API_KEY' }
    if ($missing.Count) {
        throw "Missing required settings: $($missing -join ', '). Set them as environment variables (see .env.example) or in sync.config.json."
    }
    if ($Config.HuduBaseUrl -notmatch '^https?://') { throw "HUDU_BASE_URL must start with https:// (got '$($Config.HuduBaseUrl)')." }
}
