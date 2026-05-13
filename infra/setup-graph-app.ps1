# ============================================================
# Microsoft Graph App Registration setup for Meeting Minutes
# ============================================================
#
# Creates or reuses an Entra ID app registration, adds Microsoft Graph
# application permissions, creates a client secret when needed, generates
# WEBHOOK_CLIENT_STATE, and updates:
#   - C:\PRJ2\dev2\.env.azure
#   - C:\PRJ2\dev2\TestDashboard\.env
#
# Usage:
#   .\setup-graph-app.ps1
#   .\setup-graph-app.ps1 -AppName meeting-minutes-dev -GrantAdminConsent
#   .\setup-graph-app.ps1 -RotateSecret -RotateClientState
# ============================================================

param(
    [string]$AppName = "meeting-minutes-dev",
    [string]$UserUpn = "",
    [int]$SecretYears = 1,
    [switch]$GrantAdminConsent,
    [switch]$RotateSecret,
    [switch]$RotateClientState
)

$ErrorActionPreference = "Stop"

$rootDir = Split-Path $PSScriptRoot -Parent
$envAzurePath = Join-Path $rootDir ".env.azure"
$dashboardEnvPath = Join-Path $rootDir "TestDashboard\.env"
$graphAppId = "00000003-0000-0000-c000-000000000000"

$requiredGraphAppRoles = @(
    "Files.ReadWrite.All",
    "OnlineMeetings.Read.All",
    "OnlineMeetingTranscript.Read.All",
    "OnlineMeetingRecording.Read.All",
    "User.Read.All"
)

function Require-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name not found. Install Azure CLI first."
    }
}

function Read-EnvMap {
    param([string]$Path)
    $map = [ordered]@{}
    if (-not (Test-Path $Path)) { return $map }
    Get-Content $Path | ForEach-Object {
        if ($_ -match '^\s*#' -or $_ -notmatch '=') { return }
        $parts = $_ -split '=', 2
        $key = $parts[0].Trim()
        if ($key) { $map[$key] = $parts[1] }
    }
    return $map
}

function Set-EnvValues {
    param(
        [string]$Path,
        [hashtable]$Values
    )

    if (-not (Test-Path $Path)) {
        New-Item -ItemType File -Path $Path -Force | Out-Null
    }

    $existingLines = Get-Content $Path
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $output = New-Object 'System.Collections.Generic.List[string]'

    foreach ($line in $existingLines) {
        if ($line -match '^\s*#' -or $line -notmatch '=') {
            $output.Add($line)
            continue
        }

        $parts = $line -split '=', 2
        $key = $parts[0].Trim()
        if ($Values.ContainsKey($key)) {
            $output.Add("$key=$($Values[$key])")
            [void]$seen.Add($key)
        } else {
            $output.Add($line)
        }
    }

    foreach ($key in $Values.Keys) {
        if (-not $seen.Contains($key)) {
            $output.Add("$key=$($Values[$key])")
        }
    }

    $output | Set-Content -Path $Path -Encoding UTF8
}

function New-RandomState {
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return [Convert]::ToBase64String($bytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")
}

function Get-JsonOrNull {
    param([scriptblock]$Command)
    $raw = & $Command
    if ([string]::IsNullOrWhiteSpace($raw) -or $raw -eq "null") { return $null }
    return $raw | ConvertFrom-Json
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Meeting Minutes Graph App Registration setup" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

Require-Command -Name "az"

$account = az account show --output json | ConvertFrom-Json
$tenantId = $account.tenantId
Write-Host "Signed in: $($account.user.name)" -ForegroundColor Green
Write-Host "Tenant:    $tenantId" -ForegroundColor Green
Write-Host "App name:  $AppName" -ForegroundColor Green

$envAzure = Read-EnvMap $envAzurePath
$dashboardEnv = Read-EnvMap $dashboardEnvPath

if ([string]::IsNullOrWhiteSpace($UserUpn)) {
    $UserUpn = [string]$envAzure["MS_USER_UPN"]
}
if ([string]::IsNullOrWhiteSpace($UserUpn)) {
    try {
        $UserUpn = az ad signed-in-user show --query userPrincipalName -o tsv
    } catch {
        $UserUpn = $account.user.name
    }
}

Write-Host ""
Write-Host "Creating/reusing app registration..." -ForegroundColor Cyan
$app = Get-JsonOrNull { az ad app list --display-name $AppName --query "[0]" --output json }
if ($null -eq $app) {
    $app = az ad app create `
        --display-name $AppName `
        --sign-in-audience AzureADMyOrg `
        --output json | ConvertFrom-Json
    Write-Host "Created app registration." -ForegroundColor Green
} else {
    Write-Host "Reusing existing app registration." -ForegroundColor Green
}

$clientId = $app.appId
Write-Host "MS_CLIENT_ID: $clientId"

Write-Host "Creating/reusing service principal..." -ForegroundColor Cyan
$sp = Get-JsonOrNull { az ad sp list --filter "appId eq '$clientId'" --query "[0]" --output json }
if ($null -eq $sp) {
    az ad sp create --id $clientId --output none
    Write-Host "Created service principal." -ForegroundColor Green
} else {
    Write-Host "Service principal already exists." -ForegroundColor Green
}

Write-Host "Adding Microsoft Graph application permissions..." -ForegroundColor Cyan
$graphSp = az ad sp show --id $graphAppId --output json | ConvertFrom-Json
foreach ($permission in $requiredGraphAppRoles) {
    $role = $graphSp.appRoles | Where-Object {
        $_.value -eq $permission -and $_.allowedMemberTypes -contains "Application"
    } | Select-Object -First 1
    if ($null -eq $role) {
        throw "Microsoft Graph app role not found: $permission"
    }

    az ad app permission add `
        --id $clientId `
        --api $graphAppId `
        --api-permissions "$($role.id)=Role" `
        --only-show-errors | Out-Null
    Write-Host "  added/requested: $permission"
}

if ($GrantAdminConsent) {
    Write-Host "Granting admin consent..." -ForegroundColor Cyan
    try {
        az ad app permission admin-consent --id $clientId --only-show-errors | Out-Null
        Write-Host "Admin consent granted." -ForegroundColor Green
    } catch {
        Write-Warning "Admin consent failed. Use Entra portal: App registrations > $AppName > API permissions > Grant admin consent."
    }
} else {
    Write-Host "Admin consent not granted by this script. Run with -GrantAdminConsent if your account is tenant admin." -ForegroundColor Yellow
}

$currentSecret = [string]$envAzure["MS_CLIENT_SECRET"]
$clientSecret = $currentSecret
if ($RotateSecret -or [string]::IsNullOrWhiteSpace($clientSecret)) {
    Write-Host "Creating client secret..." -ForegroundColor Cyan
    $clientSecret = az ad app credential reset `
        --id $clientId `
        --display-name "meeting-minutes-secret" `
        --years $SecretYears `
        --query password `
        --output tsv
    Write-Host "Created MS_CLIENT_SECRET. Value is written to env files and not printed." -ForegroundColor Green
} else {
    Write-Host "Existing MS_CLIENT_SECRET in .env.azure is preserved. Use -RotateSecret to create a new one." -ForegroundColor Yellow
}

$currentClientState = [string]$envAzure["WEBHOOK_CLIENT_STATE"]
$clientState = $currentClientState
if ($RotateClientState -or [string]::IsNullOrWhiteSpace($clientState)) {
    $clientState = New-RandomState
    Write-Host "Generated WEBHOOK_CLIENT_STATE." -ForegroundColor Green
} else {
    Write-Host "Existing WEBHOOK_CLIENT_STATE in .env.azure is preserved. Use -RotateClientState to regenerate." -ForegroundColor Yellow
}

$values = @{
    "GRAPH_MOCK" = "false"
    "MS_TENANT_ID" = $tenantId
    "MS_CLIENT_ID" = $clientId
    "MS_CLIENT_SECRET" = $clientSecret
    "MS_USER_UPN" = $UserUpn
    "WEBHOOK_CLIENT_STATE" = $clientState
}

Write-Host "Updating env files..." -ForegroundColor Cyan
Set-EnvValues -Path $envAzurePath -Values $values
Set-EnvValues -Path $dashboardEnvPath -Values $values

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  Graph app setup completed" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ".env.azure:        $envAzurePath"
Write-Host "TestDashboard.env: $dashboardEnvPath"
Write-Host "MS_TENANT_ID:      set"
Write-Host "MS_CLIENT_ID:      set"
Write-Host "MS_CLIENT_SECRET:  set"
Write-Host "MS_USER_UPN:       $UserUpn"
Write-Host "WEBHOOK_CLIENT_STATE: set"
Write-Host ""
Write-Host "Next steps" -ForegroundColor Yellow
Write-Host "  1. If admin consent was not granted, grant it in Entra portal."
Write-Host "  2. Restart TestDashboard so it reloads TestDashboard\.env."
Write-Host "  3. Expected startup: Graph mock false, Speech mock false, Claude mock false."
