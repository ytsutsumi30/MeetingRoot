# ============================================================
# Azure Functions デプロイ + App Settings 反映 + 起動確認
# ============================================================
#
# 前提:
#   - deploy-azure.ps1 -DeployFunctions で Function App が作成済み
#   - .env.azure に FUNCTION_APP_NAME が設定済み
#   - func CLI がインストール済み
#
# Usage:
#   .\deploy-functions.ps1                    # デプロイ + 設定 + 確認
#   .\deploy-functions.ps1 -SkipDeploy        # 設定反映のみ
#   .\deploy-functions.ps1 -SkipSettings      # デプロイのみ
#   .\deploy-functions.ps1 -WhatIf            # ドライラン
# ============================================================

param(
    [string]$ResourceGroup = "rg-meeting-minutes-dev",
    [switch]$SkipDeploy,
    [switch]$SkipSettings,
    [switch]$WhatIf,
    [switch]$Yes
)

$ErrorActionPreference = "Stop"

$rootDir      = Split-Path $PSScriptRoot -Parent
$functionsDir = Join-Path $rootDir "functions"
$envAzure     = Join-Path $rootDir ".env.azure"

# ── ヘルパー ────────────────────────────────────────────────

function Require-Command {
    param([string]$Name, [string]$InstallHint)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name not found. $InstallHint"
    }
}

function Parse-EnvFile {
    param([string]$Path)
    $result = @{}
    if (-not (Test-Path $Path)) { return $result }
    Get-Content $Path | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith("#") -and $line -match "^([^=]+)=(.*)$") {
            $result[$Matches[1].Trim()] = $Matches[2].Trim()
        }
    }
    return $result
}

function Write-Step {
    param([string]$Emoji, [string]$Message)
    Write-Host ""
    Write-Host "$Emoji $Message" -ForegroundColor Cyan
    Write-Host ("─" * 60) -ForegroundColor DarkGray
}

# ── 事前チェック ────────────────────────────────────────────

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Azure Functions デプロイ" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

Require-Command -Name "az"   -InstallHint "Azure CLI をインストールしてください"
Require-Command -Name "func" -InstallHint "npm i -g azure-functions-core-tools@4"

# az login 確認
try {
    $account = az account show --output json 2>&1 | ConvertFrom-Json
    Write-Host "  Azure: $($account.user.name)" -ForegroundColor Green
} catch {
    throw "az login が必要です"
}

# .env.azure 読み込み
if (-not (Test-Path $envAzure)) {
    throw ".env.azure が見つかりません。先に deploy-azure.ps1 -DeployFunctions を実行してください。"
}
$env_vars = Parse-EnvFile -Path $envAzure

$functionAppName = $env_vars["FUNCTION_APP_NAME"]
if ([string]::IsNullOrWhiteSpace($functionAppName)) {
    throw ".env.azure の FUNCTION_APP_NAME が空です。deploy-azure.ps1 -DeployFunctions で Function App を作成してください。"
}

Write-Host "  Function App: $functionAppName" -ForegroundColor Green
Write-Host "  Resource Group: $ResourceGroup" -ForegroundColor Green

# 存在確認
$appExists = az functionapp show --name $functionAppName --resource-group $ResourceGroup --query "name" --output tsv 2>$null
if (-not $appExists) {
    throw "Function App '$functionAppName' が見つかりません (RG: $ResourceGroup)"
}
Write-Host "  Status: 存在確認 OK" -ForegroundColor Green

if (-not $WhatIf -and -not $Yes) {
    $confirm = Read-Host "デプロイを実行しますか? (y/N)"
    if ($confirm -ne "y") {
        Write-Host "キャンセルしました。" -ForegroundColor Yellow
        exit 0
    }
}

# ── Step 1: npm install ─────────────────────────────────────

Write-Step "📦" "Step 1: npm install (functions/)"

if ($WhatIf) {
    Write-Host "  [WhatIf] npm install --omit=dev を実行します" -ForegroundColor Yellow
} else {
    Push-Location $functionsDir
    try {
        npm install --omit=dev 2>&1 | Select-Object -Last 5
        if ($LASTEXITCODE -ne 0) { throw "npm install failed" }
        Write-Host "  npm install OK" -ForegroundColor Green
    } finally {
        Pop-Location
    }
}

# ── Step 2: Functions デプロイ ───────────────────────────────

if (-not $SkipDeploy) {
    Write-Step "🚀" "Step 2: func azure functionapp publish $functionAppName"

    if ($WhatIf) {
        Write-Host "  [WhatIf] func azure functionapp publish $functionAppName" -ForegroundColor Yellow
    } else {
        Push-Location $functionsDir
        try {
            func azure functionapp publish $functionAppName --javascript 2>&1
            if ($LASTEXITCODE -ne 0) { throw "func publish failed" }
            Write-Host "  デプロイ OK" -ForegroundColor Green
        } finally {
            Pop-Location
        }
    }
} else {
    Write-Step "⏭️" "Step 2: デプロイ スキップ (-SkipDeploy)"
}

# ── Step 3: App Settings 反映 ───────────────────────────────

if (-not $SkipSettings) {
    Write-Step "⚙️" "Step 3: App Settings 反映"

    # Functions に必要な環境変数をマッピング
    $settingsToApply = @{
        "AZURE_STORAGE_CONNECTION_STRING"   = $env_vars["AZURE_STORAGE_CONNECTION_STRING"]
        "AZURE_QUEUE_NAME"                  = $env_vars["AZURE_QUEUE_NAME"]
        "AZURE_BLOB_CONTAINER"              = $env_vars["AZURE_BLOB_CONTAINER"]
        "SUBSCRIPTION_TABLE_NAME"           = $(if ([string]::IsNullOrWhiteSpace($env_vars["SUBSCRIPTION_TABLE_NAME"])) { "subscriptions" } else { $env_vars["SUBSCRIPTION_TABLE_NAME"] })
        "STORAGE_MODE"                      = $(if ([string]::IsNullOrWhiteSpace($env_vars["STORAGE_MODE"])) { "table" } else { $env_vars["STORAGE_MODE"] })
        "SUBSCRIPTION_RENEW_BEFORE_MINUTES" = $(if ([string]::IsNullOrWhiteSpace($env_vars["SUBSCRIPTION_RENEW_BEFORE_MINUTES"])) { "720" } else { $env_vars["SUBSCRIPTION_RENEW_BEFORE_MINUTES"] })
        "LIFECYCLE_REAUTHORIZE_SKIP_GRAPH"  = $(if ([string]::IsNullOrWhiteSpace($env_vars["LIFECYCLE_REAUTHORIZE_SKIP_GRAPH"])) { "false" } else { $env_vars["LIFECYCLE_REAUTHORIZE_SKIP_GRAPH"] })
        "MS_TENANT_ID"                      = $env_vars["MS_TENANT_ID"]
        "MS_CLIENT_ID"                      = $env_vars["MS_CLIENT_ID"]
        "MS_CLIENT_SECRET"                  = $env_vars["MS_CLIENT_SECRET"]
        "WEBHOOK_CLIENT_STATE"              = $env_vars["WEBHOOK_CLIENT_STATE"]
        "WEBHOOK_NOTIFICATION_URL"          = $env_vars["WEBHOOK_NOTIFICATION_URL"]
        "WEBHOOK_LIFECYCLE_URL"             = $env_vars["WEBHOOK_LIFECYCLE_URL"]
        "MS_USER_UPN"                       = $env_vars["MS_USER_UPN"]
        "GRAPH_SUBSCRIPTION_LIFETIME_MIN"   = $(if ([string]::IsNullOrWhiteSpace($env_vars["GRAPH_SUBSCRIPTION_LIFETIME_MIN"])) { "4200" } else { $env_vars["GRAPH_SUBSCRIPTION_LIFETIME_MIN"] })
        "SUBSCRIPTION_USER_ID"              = $env_vars["SUBSCRIPTION_USER_ID"]
    }

    # 空の値を検出して警告
    $missingKeys = @()
    foreach ($kv in $settingsToApply.GetEnumerator()) {
        if ([string]::IsNullOrWhiteSpace($kv.Value)) {
            $missingKeys += $kv.Key
        }
    }

    if ($missingKeys.Count -gt 0) {
        Write-Host "  [WARNING] 以下のキーが .env.azure で未設定です:" -ForegroundColor Yellow
        $missingKeys | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }
        Write-Host "  設定済みのキーのみ反映します。" -ForegroundColor Yellow
    }

    # 設定済みキーのみフィルタ
    $validSettings = $settingsToApply.GetEnumerator() | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Value) }

    if ($validSettings.Count -eq 0) {
        Write-Host "  反映する設定がありません。" -ForegroundColor Yellow
    } else {
        # az functionapp config appsettings set は複数設定を一括で渡せる
        $settingsArgs = ($validSettings | ForEach-Object { "$($_.Key)=$($_.Value)" })

        if ($WhatIf) {
            Write-Host "  [WhatIf] 以下の設定を反映します:" -ForegroundColor Yellow
            $settingsArgs | ForEach-Object {
                $key = $_.Split("=")[0]
                $val = $_.Substring($key.Length + 1)
                $masked = if ($val.Length -gt 8) { $val.Substring(0,4) + "****" } else { "****" }
                Write-Host "    $key = $masked"
            }
        } else {
            Write-Host "  設定数: $($validSettings.Count)" -ForegroundColor Green
            az functionapp config appsettings set `
                --name $functionAppName `
                --resource-group $ResourceGroup `
                --settings @settingsArgs `
                --output none 2>&1

            if ($LASTEXITCODE -ne 0) {
                Write-Host "  [WARNING] App Settings 反映でエラーが発生しました。" -ForegroundColor Yellow
                Write-Host "  個別に反映を試みます..." -ForegroundColor Yellow
                foreach ($setting in $settingsArgs) {
                    az functionapp config appsettings set `
                        --name $functionAppName `
                        --resource-group $ResourceGroup `
                        --settings $setting `
                        --output none 2>&1
                }
            }
            Write-Host "  App Settings 反映 OK" -ForegroundColor Green
        }
    }
} else {
    Write-Step "⏭️" "Step 3: App Settings スキップ (-SkipSettings)"
}

# ── Step 4: 起動確認 ────────────────────────────────────────

Write-Step "🏥" "Step 4: 起動確認 (ヘルスチェック)"

$functionHostName = az functionapp show `
    --name $functionAppName `
    --resource-group $ResourceGroup `
    --query "defaultHostName" `
    --output tsv

$notificationUrl = "https://$functionHostName/api/notifications"

if ($WhatIf) {
    Write-Host "  [WhatIf] Webhook URL: $notificationUrl" -ForegroundColor Yellow
    Write-Host "  [WhatIf] GET $notificationUrl?validationToken=deploy-test" -ForegroundColor Yellow
} else {
    Write-Host "  Webhook URL: $notificationUrl"

    # validation token テスト (Webhook検証エンドポイントの動作確認)
    Write-Host "  Webhook検証テスト..." -ForegroundColor Gray
    try {
        $testUrl = "${notificationUrl}?validationToken=deploy-test-$(Get-Date -Format 'yyyyMMddHHmmss')"
        $response = Invoke-WebRequest -Uri $testUrl -Method GET -TimeoutSec 30 -ErrorAction Stop
        if ($response.StatusCode -eq 200 -and $response.Content -match "deploy-test") {
            Write-Host "  ✅ Webhook検証エンドポイント OK (200, validation token returned)" -ForegroundColor Green
        } else {
            Write-Host "  ⚠️ レスポンス: HTTP $($response.StatusCode)" -ForegroundColor Yellow
        }
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        if ($statusCode) {
            Write-Host "  ⚠️ HTTP $statusCode - 起動中の可能性があります (Consumption Plan の cold start)" -ForegroundColor Yellow
        } else {
            Write-Host "  ⚠️ 接続エラー: $($_.Exception.Message)" -ForegroundColor Yellow
        }
        Write-Host "  数分後に再度確認してください:" -ForegroundColor Yellow
        Write-Host "    curl.exe -s `"$testUrl`"" -ForegroundColor Gray
    }

    # POST テスト (空ボディ → clientState なしで拒否されることを確認)
    Write-Host "  POST通知テスト..." -ForegroundColor Gray
    try {
        $postResponse = Invoke-WebRequest -Uri $notificationUrl -Method POST `
            -ContentType "application/json" `
            -Body '{"value":[]}' `
            -TimeoutSec 30 -ErrorAction Stop
        if ($postResponse.StatusCode -eq 202) {
            Write-Host "  ✅ POST通知エンドポイント OK (202, processed: 0)" -ForegroundColor Green
        }
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        Write-Host "  POST結果: HTTP $statusCode (通常動作範囲内)" -ForegroundColor Yellow
    }
}

# ── Step 5: .env.azure 更新 ─────────────────────────────────

Write-Step "📝" "Step 5: .env.azure 更新"

$currentWebhookUrl = $env_vars["WEBHOOK_NOTIFICATION_URL"]
if ([string]::IsNullOrWhiteSpace($currentWebhookUrl) -or $currentWebhookUrl -ne $notificationUrl) {
    if ($WhatIf) {
        Write-Host "  [WhatIf] WEBHOOK_NOTIFICATION_URL=$notificationUrl を .env.azure に反映" -ForegroundColor Yellow
    } else {
        $envContent = Get-Content $envAzure -Raw

        if ($envContent -match "WEBHOOK_NOTIFICATION_URL=") {
            $envContent = $envContent -replace "WEBHOOK_NOTIFICATION_URL=.*", "WEBHOOK_NOTIFICATION_URL=$notificationUrl"
        } else {
            $envContent += "`nWEBHOOK_NOTIFICATION_URL=$notificationUrl`n"
        }

        $envContent | Out-File -FilePath $envAzure -Encoding UTF8 -NoNewline
        Write-Host "  WEBHOOK_NOTIFICATION_URL=$notificationUrl" -ForegroundColor Green
    }
} else {
    Write-Host "  WEBHOOK_NOTIFICATION_URL は既に最新です" -ForegroundColor Green
}

# ── 完了サマリ ──────────────────────────────────────────────

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  Functions デプロイ完了" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  Function App:  $functionAppName"
Write-Host "  Webhook URL:   $notificationUrl"
Write-Host ""
Write-Host "次のステップ:" -ForegroundColor Yellow
Write-Host "  1. Admin Consent 取得後に Graph Subscription を作成:"
Write-Host "     .\create-graph-subscription.ps1"
Write-Host "  2. lifecycle 復旧確認 (E-1):"
Write-Host "     - subscriptions-bootstrap (初回作成)"
Write-Host "     - subscriptions-renew (期限更新/再作成)"
Write-Host "  3. TestDashboard の WEBHOOK_NOTIFICATION_URL を更新:"
Write-Host "     WEBHOOK_NOTIFICATION_URL=$notificationUrl"
Write-Host ""
if ($missingKeys.Count -gt 0) {
    Write-Host "⚠️ 未設定の App Settings があります:" -ForegroundColor Yellow
    $missingKeys | ForEach-Object { Write-Host "   - $_" -ForegroundColor Yellow }
    Write-Host "  .env.azure を更新後、再度 .\deploy-functions.ps1 -SkipDeploy を実行してください" -ForegroundColor Yellow
}
