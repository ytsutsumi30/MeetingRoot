# ============================================================
# Azure resource deployment for Meeting Minutes (Bicep IaC)
# ============================================================
#
# Creates/updates:
#   - Azure Storage Account (Blob + Queue)
#   - Azure AI Speech resource
#   - Azure Function App + Application Insights
#
# Usage:
#   .\deploy-azure.ps1
#   .\deploy-azure.ps1 -WhatIf
#   .\deploy-azure.ps1 -ResourceGroup rg-meeting-minutes-dev -SpeechSku S0
# ============================================================

param(
    [string]$ResourceGroup = "rg-meeting-minutes-dev",
    [string]$Location      = "japaneast",
    [ValidateSet("dev", "stg", "prod")]
    [string]$Environment   = "dev",
    [string]$ProjectName   = "meetmin",
    [ValidateSet("F0", "S0")]
    [string]$SpeechSku     = "S0",
    [switch]$WhatIf,
    [switch]$DeleteExisting,
    [switch]$Yes
)

$ErrorActionPreference = "Stop"

$rootDir = Split-Path $PSScriptRoot -Parent
$bicepDir = Join-Path $PSScriptRoot "bicep"
$mainBicep = Join-Path $bicepDir "main.bicep"
$paramFile = Join-Path $bicepDir "parameters.local.json"
$envPath = Join-Path $rootDir ".env.azure"

function Require-Command {
    param([string]$Name, [string]$InstallHint)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name が見つかりません。$InstallHint"
    }
}

function Get-OutputValue {
    param($Outputs, [string]$Name)
    return $Outputs.$Name.value
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Meeting Minutes Azure deployment (Bicep)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

Require-Command -Name "az" -InstallHint "infra\install-tools.ps1 を実行するか、Azure CLI をインストールしてください。"

$azVersion = az version --output json 2>&1 | ConvertFrom-Json
Write-Host "Azure CLI: $($azVersion.'azure-cli')" -ForegroundColor Green

try {
    $account = az account show --output json 2>&1 | ConvertFrom-Json
    Write-Host "Signed in: $($account.user.name)" -ForegroundColor Green
    Write-Host "Subscription: $($account.name) ($($account.id))" -ForegroundColor Green
} catch {
    throw "az login が必要です。例: az login --tenant <TENANT_ID>"
}

Write-Host ""
Write-Host "Deployment settings" -ForegroundColor Yellow
Write-Host "  Resource Group: $ResourceGroup"
Write-Host "  Location:       $Location"
Write-Host "  Environment:    $Environment"
Write-Host "  Project:        $ProjectName"
Write-Host "  Speech SKU:     $SpeechSku"
Write-Host ""

if (-not $WhatIf -and -not $Yes) {
    $confirm = Read-Host "上記設定でデプロイしますか？ (y/N)"
    if ($confirm -ne "y") {
        Write-Host "中止しました。" -ForegroundColor Yellow
        exit 0
    }
}

if ($DeleteExisting) {
    Write-Host "既存リソースグループ削除を要求しました: $ResourceGroup" -ForegroundColor Yellow
    az group delete --name $ResourceGroup --yes --no-wait
    Write-Host "削除要求を送信しました。完了まで数分かかります。" -ForegroundColor Yellow
    Start-Sleep -Seconds 5
}

Write-Host "Resource Group を作成/更新しています..." -ForegroundColor Cyan
az group create `
    --name $ResourceGroup `
    --location $Location `
    --tags "Project=OccupancyCounter-MeetingMinutes" "Environment=$Environment" `
    --output none

$deploymentName = "deploy-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$commonParams = @(
    "--resource-group", $ResourceGroup,
    "--template-file", $mainBicep,
    "--parameters", "@$paramFile",
    "--parameters", "environment=$Environment", "projectName=$ProjectName", "location=$Location", "speechSku=$SpeechSku"
)

if ($WhatIf) {
    Write-Host "Bicep what-if を実行します..." -ForegroundColor Cyan
    az deployment group what-if @commonParams
    exit $LASTEXITCODE
}

Write-Host "Bicep デプロイを実行します..." -ForegroundColor Cyan
az deployment group create `
    --name $deploymentName `
    @commonParams `
    --output json | Out-Null

if ($LASTEXITCODE -ne 0) {
    throw "Bicep デプロイに失敗しました。"
}

Write-Host "Deployment outputs を取得しています..." -ForegroundColor Cyan
$outputs = az deployment group show `
    --name $deploymentName `
    --resource-group $ResourceGroup `
    --query properties.outputs `
    --output json | ConvertFrom-Json

$storageAccountName = Get-OutputValue $outputs "storageAccountName"
$speechResourceName = Get-OutputValue $outputs "speechResourceName"
$speechEndpoint = Get-OutputValue $outputs "speechEndpoint"
$speechRegion = Get-OutputValue $outputs "speechRegion"
$functionAppName = Get-OutputValue $outputs "functionAppName"
$functionHostName = Get-OutputValue $outputs "functionAppHostName"
$queueName = Get-OutputValue $outputs "queueName"
$blobContainerName = Get-OutputValue $outputs "blobContainerName"

Write-Host "Speech API Key を取得しています..." -ForegroundColor Cyan
$speechKey = az cognitiveservices account keys list `
    --resource-group $ResourceGroup `
    --name $speechResourceName `
    --query "key1" `
    --output tsv

Write-Host "Storage connection string を取得しています..." -ForegroundColor Cyan
$storageKey = az storage account keys list `
    --resource-group $ResourceGroup `
    --account-name $storageAccountName `
    --query "[0].value" `
    --output tsv
$storageConn = "DefaultEndpointsProtocol=https;AccountName=$storageAccountName;AccountKey=$storageKey;EndpointSuffix=core.windows.net"

Write-Host ".env.azure を生成しています..." -ForegroundColor Cyan
$envContent = @"
# Auto-generated by infra/deploy-azure.ps1 at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
# Do not commit this file. It contains secrets.

# === Azure Speech / Speech-to-text ===
AZURE_SPEECH_MOCK=false
AZURE_SPEECH_KEY=$speechKey
AZURE_SPEECH_REGION=$speechRegion
AZURE_SPEECH_ENDPOINT=$speechEndpoint

# === Azure Speaker Recognition ===
# Speaker Recognition uses the same Azure AI Speech resource/key.
SPEAKER_RECOGNITION_MOCK=false
SPEAKER_RECOGNITION_ENDPOINT=$speechEndpoint
SPEAKER_RECOGNITION_KEY=$speechKey
SPEAKER_AUDIO_IDENTIFICATION_ENABLED=true
SPEAKER_IDENTIFICATION_MIN_SCORE=0.65
SPEAKER_IDENTIFICATION_MIN_SEGMENT_SEC=4
SPEAKER_IDENTIFICATION_IGNORE_MIN_LENGTH=false
SPEAKER_KEEP_TEAM_RECORDINGS=false
FFMPEG_BIN=ffmpeg

# === Azure Storage ===
AZURE_STORAGE_CONNECTION_STRING=$storageConn
AZURE_BLOB_CONTAINER=$blobContainerName
QUEUE_NAME=$queueName
AZURE_QUEUE_NAME=$queueName
QUEUE_CONSUMER_MOCK=false

# Blob mode lets Azure Speech fetch uploaded audio without depending on Cloudflare Tunnel.
PUBLISH_MODE=blob
PUBLIC_BASE_URL=

# === Azure Functions ===
FUNCTION_APP_NAME=$functionAppName
WEBHOOK_NOTIFICATION_URL=https://$functionHostName/api/notifications

# === Microsoft Graph (fill manually from App Registration) ===
GRAPH_MOCK=false
MS_TENANT_ID=
MS_CLIENT_ID=
MS_CLIENT_SECRET=
MS_USER_UPN=
MS_DRIVE_PATH=/Apps/MeetingMinutes

# === Anthropic Claude (fill manually) ===
ANTHROPIC_API_KEY=
CLAUDE_MODEL=claude-sonnet-4-5
CLAUDE_MOCK=false

# === Webhook security (fill manually) ===
WEBHOOK_CLIENT_STATE=
"@
$envContent | Out-File -FilePath $envPath -Encoding UTF8

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  Deployment completed" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host "Storage Account:   $storageAccountName"
Write-Host "Blob Container:    $blobContainerName"
Write-Host "Queue:             $queueName"
Write-Host "Speech Resource:   $speechResourceName"
Write-Host "Speech Endpoint:   $speechEndpoint"
Write-Host "Function App:      $functionAppName"
Write-Host "Function URL:      https://$functionHostName"
Write-Host ".env output:       $envPath"
Write-Host ""
Write-Host "Next steps" -ForegroundColor Yellow
Write-Host "  1. .env.azure の MS_* / ANTHROPIC_API_KEY / WEBHOOK_CLIENT_STATE を埋める"
Write-Host "  2. TestDashboard で .env.azure を読み込む、または必要値を TestDashboard\.env にコピー"
Write-Host "  3. functions を publish: cd functions; func azure functionapp publish $functionAppName"
Write-Host "  4. Microsoft Graph subscription を WEBHOOK_NOTIFICATION_URL に作成"
