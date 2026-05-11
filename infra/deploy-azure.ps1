# ============================================================
# Phase 3: Azure 繝ｪ繧ｽ繝ｼ繧ｹ繝・・繝ｭ繧､ (Bicep IaC)
# ============================================================
#
# 蜑肴署:
#   - az CLI 縺ｨ Bicep CLI 縺後う繝ｳ繧ｹ繝医・繝ｫ貂医∩
#   - az login 縺ｧ繧ｵ繧､繝ｳ繧､繝ｳ貂医∩
#   - 繧ｵ繝悶せ繧ｯ繝ｪ繝励す繝ｧ繝ｳ驕ｸ謚樊ｸ医∩ (az account set)
#
# 菴ｿ縺・婿:
#   .\deploy-azure.ps1                          # dev迺ｰ蠅・#   .\deploy-azure.ps1 -Environment stg
#   .\deploy-azure.ps1 -ResourceGroup rg-mtg
# ============================================================

param(
    [string]$ResourceGroup = "rg-meeting-minutes-dev",
    [string]$Location      = "japaneast",
    [string]$Environment   = "dev",
    [string]$ProjectName   = "meetmin",
    [switch]$WhatIf,
    [switch]$DeleteExisting
)

$ErrorActionPreference = "Stop"
$bicepDir = Join-Path $PSScriptRoot "bicep"
$mainBicep = Join-Path $bicepDir "main.bicep"
$paramFile = Join-Path $bicepDir "parameters.local.json"

Write-Host ""
Write-Host "笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊・ -ForegroundColor Cyan
Write-Host "  Azure 繝ｪ繧ｽ繝ｼ繧ｹ繝・・繝ｭ繧､ (Bicep)" -ForegroundColor Cyan
Write-Host "笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊・ -ForegroundColor Cyan
Write-Host ""

# az CLI 遒ｺ隱・try {
    $azVersion = az version --output json 2>&1 | ConvertFrom-Json
    Write-Host "  笨・Azure CLI: $($azVersion.'azure-cli')" -ForegroundColor Green
} catch {
    Write-Host "  笨・Azure CLI 縺瑚ｦ九▽縺九ｊ縺ｾ縺帙ｓ縲・\install-tools.ps1 繧貞ｮ溯｡後＠縺ｦ縺上□縺輔＞縲・ -ForegroundColor Red
    exit 1
}

# 繧ｵ繧､繝ｳ繧､繝ｳ遒ｺ隱・try {
    $account = az account show --output json 2>&1 | ConvertFrom-Json
    Write-Host "  笨・繧ｵ繧､繝ｳ繧､繝ｳ荳ｭ: $($account.user.name)" -ForegroundColor Green
    Write-Host "  笨・繧ｵ繝悶せ繧ｯ繝ｪ繝励す繝ｧ繝ｳ: $($account.name) ($($account.id))" -ForegroundColor Green
} catch {
    Write-Host "  笨・az login 縺悟ｿ・ｦ√〒縺吶・ -ForegroundColor Red
    Write-Host "    az login --tenant <TENANT_ID>" -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "繝・・繝ｭ繧､險ｭ螳・" -ForegroundColor Yellow
Write-Host "  Resource Group: $ResourceGroup"
Write-Host "  Location:       $Location"
Write-Host "  Environment:    $Environment"
Write-Host "  Project:        $ProjectName"
Write-Host ""

# 遒ｺ隱・if (-not $WhatIf) {
    $confirm = Read-Host "荳願ｨ倥〒繝・・繝ｭ繧､縺励∪縺吶°・・(y/N)"
    if ($confirm -ne "y") { Write-Host "荳ｭ豁｢縺励∪縺励◆縲・ -ForegroundColor Yellow; exit 0 }
}

# 譌｢蟄伜炎髯､繧ｪ繝励す繝ｧ繝ｳ
if ($DeleteExisting) {
    Write-Host "笆ｶ 譌｢蟄倥Μ繧ｽ繝ｼ繧ｹ繧ｰ繝ｫ繝ｼ繝励ｒ蜑企勁..." -ForegroundColor Yellow
    az group delete --name $ResourceGroup --yes --no-wait
    Write-Host "  蜑企勁繝ｪ繧ｯ繧ｨ繧ｹ繝磯∽ｿ｡縲ょｮ御ｺ・∪縺ｧ謨ｰ蛻・°縺九ｊ縺ｾ縺吶・ -ForegroundColor Yellow
    Start-Sleep -Seconds 5
}

# 繝ｪ繧ｽ繝ｼ繧ｹ繧ｰ繝ｫ繝ｼ繝嶺ｽ懈・ (idempotent)
Write-Host "笆ｶ 繝ｪ繧ｽ繝ｼ繧ｹ繧ｰ繝ｫ繝ｼ繝礼｢ｺ隱・菴懈・: $ResourceGroup" -ForegroundColor Cyan
az group create --name $ResourceGroup --location $Location --tags "Project=OccupancyCounter-MeetingMinutes" "Environment=$Environment" --output none
Write-Host "  笨・OK" -ForegroundColor Green
Write-Host ""

# Bicep 繝・・繝ｭ繧､
Write-Host "笆ｶ Bicep 繝・Φ繝励Ξ繝ｼ繝医ｒ繝・・繝ｭ繧､..." -ForegroundColor Cyan
$deploymentName = "deploy-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

if ($WhatIf) {
    Write-Host "  竊・what-if 繝励Ξ繝薙Η繝ｼ螳溯｡・ -ForegroundColor Yellow
    az deployment group what-if `
        --resource-group $ResourceGroup `
        --template-file $mainBicep `
        --parameters "@$paramFile" `
        --parameters "environment=$Environment" "projectName=$ProjectName" "location=$Location"
    Write-Host ""
    Write-Host "  what-if 螳御ｺ・ょｮ滄圀縺ｫ繝・・繝ｭ繧､縺吶ｋ縺ｫ縺ｯ -WhatIf 繧貞､悶＠縺ｦ蜀榊ｮ溯｡後＠縺ｦ縺上□縺輔＞縲・ -ForegroundColor Yellow
    exit 0
}

az deployment group create `
    --name $deploymentName `
    --resource-group $ResourceGroup `
    --template-file $mainBicep `
    --parameters "@$paramFile" `
    --parameters "environment=$Environment" "projectName=$ProjectName" "location=$Location" `
    --output json | Out-Null

if ($LASTEXITCODE -ne 0) {
    Write-Host "  笨・繝・・繝ｭ繧､螟ｱ謨・ -ForegroundColor Red
    exit 1
}

# Outputs蜿門ｾ・Write-Host "  笨・繝・・繝ｭ繧､謌仙粥" -ForegroundColor Green
Write-Host ""
Write-Host "笆ｶ Outputs蜿門ｾ・.." -ForegroundColor Cyan
$outputs = az deployment group show `
    --name $deploymentName `
    --resource-group $ResourceGroup `
    --query properties.outputs `
    --output json | ConvertFrom-Json

Write-Host ""
Write-Host "笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊・ -ForegroundColor Green
Write-Host "  繝・・繝ｭ繧､螳御ｺ・- 蜿門ｾ玲ュ蝣ｱ" -ForegroundColor Green
Write-Host "笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊・ -ForegroundColor Green
Write-Host ""
Write-Host "  Storage Account:      $($outputs.storageAccountName.value)" -ForegroundColor White
Write-Host "  Blob Container:       $($outputs.blobContainerName.value)" -ForegroundColor White
Write-Host "  Queue:                $($outputs.queueName.value)" -ForegroundColor White
Write-Host "  Speech endpoint:      $($outputs.speechEndpoint.value)" -ForegroundColor White
Write-Host "  Speech resource:      $($outputs.speechResourceName.value)" -ForegroundColor White
Write-Host "  Function App:         $($outputs.functionAppName.value)" -ForegroundColor White
Write-Host "  Function Hostname:    https://$($outputs.functionAppHostName.value)" -ForegroundColor White
Write-Host ""

# Speech Key 蜿門ｾ・(output 縺ｫ縺ｯ蜷ｫ繧√※縺・↑縺・・縺ｧ蛻･騾・
Write-Host "笆ｶ Speech Service 縺ｮ API Key 蜿門ｾ・.." -ForegroundColor Cyan
$speechKey = az cognitiveservices account keys list `
    --resource-group $ResourceGroup `
    --name $outputs.speechResourceName.value `
    --query "key1" --output tsv
Write-Host "  笨・Speech Key 蜿門ｾ・(迺ｰ蠅・､画焚縺ｫ險ｭ螳壹＠縺ｦ縺上□縺輔＞)" -ForegroundColor Green

Write-Host ""
Write-Host "笆ｶ Storage 謗･邯壽枚蟄怜・蜿門ｾ・.." -ForegroundColor Cyan
$storageKey = az storage account keys list `
    --resource-group $ResourceGroup `
    --account-name $outputs.storageAccountName.value `
    --query "[0].value" --output tsv
$storageConn = "DefaultEndpointsProtocol=https;AccountName=$($outputs.storageAccountName.value);AccountKey=$storageKey;EndpointSuffix=core.windows.net"

# .env.azure 蜃ｺ蜉・Write-Host ""
Write-Host "笆ｶ .env.azure 繧堤函謌・.." -ForegroundColor Cyan
$envPath = Join-Path (Split-Path $PSScriptRoot -Parent) ".env.azure"
$envContent = @"
# 閾ｪ蜍慕函謌・- $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
# 縺薙・繝輔ぃ繧､繝ｫ縺ｯ git commit 縺励↑縺・％縺ｨ

# === Azure Speech ===
AZURE_SPEECH_KEY=$speechKey
AZURE_SPEECH_REGION=$Location
AZURE_SPEECH_ENDPOINT=$($outputs.speechEndpoint.value)

# === Azure Storage ===
AZURE_STORAGE_CONNECTION_STRING=$storageConn
AZURE_QUEUE_NAME=$($outputs.queueName.value)
AZURE_BLOB_CONTAINER=$($outputs.blobContainerName.value)

# === Azure Functions ===
FUNCTION_APP_NAME=$($outputs.functionAppName.value)
WEBHOOK_NOTIFICATION_URL=https://$($outputs.functionAppHostName.value)/api/notifications

# === Microsoft Graph (隕！T邂｡逅・・ｾ晞ｼ) ===
MS_TENANT_ID=
MS_CLIENT_ID=
MS_CLIENT_SECRET=
MS_USER_UPN=
MS_DRIVE_PATH=/Apps/MeetingMinutes

# === Anthropic Claude ===
ANTHROPIC_API_KEY=
CLAUDE_MODEL=claude-sonnet-4-6

# === Webhook security ===
WEBHOOK_CLIENT_STATE=
"@
$envContent | Out-File -FilePath $envPath -Encoding UTF8
Write-Host "  笨・$envPath" -ForegroundColor Green

Write-Host ""
Write-Host "笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊・ -ForegroundColor Green
Write-Host "  谺｡縺ｮ繧ｹ繝・ャ繝・ -ForegroundColor Green
Write-Host "笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊絶武笊・ -ForegroundColor Green
Write-Host ""
Write-Host "  1. .env.azure 縺ｫ Microsoft Graph 縺ｨ Anthropic 縺ｮ蛟､繧定ｿｽ險・ -ForegroundColor White
Write-Host "  2. Functions 繧ｳ繝ｼ繝峨ｒ繝・・繝ｭ繧､:" -ForegroundColor White
Write-Host "       cd functions" -ForegroundColor Gray
Write-Host "       func azure functionapp publish $($outputs.functionAppName.value)" -ForegroundColor Gray
Write-Host "  3. Microsoft Graph subscription 逋ｻ骭ｲ (蛻･繧ｹ繧ｯ繝ｪ繝励ヨ)" -ForegroundColor White
Write-Host ""
