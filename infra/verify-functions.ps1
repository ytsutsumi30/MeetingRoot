# ============================================================
# Functions デプロイ後の検証スクリプト
# ============================================================
#
# deploy-functions.ps1 実行後にこのスクリプトで全機能を検証。
#
# Usage:
#   .\verify-functions.ps1
#   .\verify-functions.ps1 -FunctionAppName meetmin-fn-dev-xxx
# ============================================================

param(
    [string]$FunctionAppName,
    [string]$ResourceGroup = "rg-meeting-minutes-dev"
)

$ErrorActionPreference = "Stop"

$rootDir  = Split-Path $PSScriptRoot -Parent
$envAzure = Join-Path $rootDir ".env.azure"

# .env.azure 読み込み
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

if (-not $FunctionAppName) {
    $env_vars = Parse-EnvFile -Path $envAzure
    $FunctionAppName = $env_vars["FUNCTION_APP_NAME"]
}

if ([string]::IsNullOrWhiteSpace($FunctionAppName)) {
    throw "FunctionAppName が指定されていません。-FunctionAppName を指定するか .env.azure を確認してください。"
}

$pass = 0; $fail = 0; $warn = 0

function Test-Check {
    param([string]$Name, [scriptblock]$Check)
    try {
        $result = & $Check
        if ($result) {
            Write-Host "  [PASS] $Name" -ForegroundColor Green
            $script:pass++
        } else {
            Write-Host "  [FAIL] $Name" -ForegroundColor Red
            $script:fail++
        }
    } catch {
        Write-Host "  [FAIL] $Name : $($_.Exception.Message)" -ForegroundColor Red
        $script:fail++
    }
}

function Test-Warn {
    param([string]$Name, [string]$Message)
    Write-Host "  [WARN] $Name : $Message" -ForegroundColor Yellow
    $script:warn++
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Functions デプロイ検証" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Function App: $FunctionAppName"
Write-Host "  Resource Group: $ResourceGroup"
Write-Host ""

# ── 1. Function App 存在確認 ────────────────────────────────

Write-Host "📋 1. Azure リソース確認" -ForegroundColor Cyan

Test-Check "Function App 存在" {
    $name = az functionapp show --name $FunctionAppName --resource-group $ResourceGroup --query "name" --output tsv 2>$null
    return $name -eq $FunctionAppName
}

$hostName = az functionapp show --name $FunctionAppName --resource-group $ResourceGroup --query "defaultHostName" --output tsv 2>$null
$baseUrl = "https://$hostName"
Write-Host "  URL: $baseUrl" -ForegroundColor Gray

Test-Check "Function App 稼働中" {
    $state = az functionapp show --name $FunctionAppName --resource-group $ResourceGroup --query "state" --output tsv
    return $state -eq "Running"
}

# ── 2. Functions 一覧確認 ──────────────────────────────────

Write-Host ""
Write-Host "📋 2. デプロイ済み Functions 確認" -ForegroundColor Cyan

$functions = az functionapp function list --name $FunctionAppName --resource-group $ResourceGroup --output json 2>$null | ConvertFrom-Json

Test-Check "notifications Function 存在" {
    return ($functions | Where-Object { $_.name -match "notifications" }).Count -gt 0
}

Test-Check "healthz Function 存在" {
    return ($functions | Where-Object { $_.name -match "healthz" }).Count -gt 0
}

Write-Host "  デプロイ済み: $($functions.Count) Functions" -ForegroundColor Gray

# ── 3. ヘルスチェック ──────────────────────────────────────

Write-Host ""
Write-Host "📋 3. ヘルスチェック (GET /api/healthz)" -ForegroundColor Cyan

Test-Check "healthz エンドポイント応答" {
    $r = Invoke-RestMethod -Uri "$baseUrl/api/healthz" -Method GET -TimeoutSec 60
    Write-Host "    ok=$($r.ok) configured=$($r.configured) node=$($r.node)" -ForegroundColor Gray
    if ($r.missing) {
        Write-Host "    missing: $($r.missing -join ', ')" -ForegroundColor Yellow
    }
    return $true  # 200 or 503 でも応答があればOK
}

# 環境変数の設定状況
try {
    $health = Invoke-RestMethod -Uri "$baseUrl/api/healthz" -Method GET -TimeoutSec 30
    Test-Check "環境変数すべて設定済み" {
        return $health.ok -eq $true
    }
    if ($health.missing) {
        foreach ($m in $health.missing) {
            Test-Warn "App Setting 未設定" $m
        }
    }
} catch {
    Test-Warn "healthz 詳細取得" "Cold start の可能性。60秒後に再試行してください。"
}

# ── 4. Webhook 検証エンドポイント ───────────────────────────

Write-Host ""
Write-Host "📋 4. Webhook 検証テスト (GET /api/notifications?validationToken=...)" -ForegroundColor Cyan

$validationToken = "verify-$(Get-Date -Format 'yyyyMMddHHmmss')"

Test-Check "validationToken 応答" {
    $r = Invoke-WebRequest -Uri "$baseUrl/api/notifications?validationToken=$validationToken" -Method GET -TimeoutSec 60
    return $r.StatusCode -eq 200 -and $r.Content.Contains($validationToken)
}

# ── 5. POST 通知テスト ─────────────────────────────────────

Write-Host ""
Write-Host "📋 5. POST通知テスト (空通知)" -ForegroundColor Cyan

Test-Check "空通知 → 202 応答" {
    $r = Invoke-WebRequest -Uri "$baseUrl/api/notifications" -Method POST `
        -ContentType "application/json" -Body '{"value":[]}' -TimeoutSec 60
    $body = $r.Content | ConvertFrom-Json
    return $r.StatusCode -eq 202 -and $body.ok -eq $true -and $body.processed -eq 0
}

# ── 6. App Settings 確認 ──────────────────────────────────

Write-Host ""
Write-Host "📋 6. App Settings 確認" -ForegroundColor Cyan

$appSettings = az functionapp config appsettings list --name $FunctionAppName --resource-group $ResourceGroup --output json | ConvertFrom-Json
$settingsDict = @{}
$appSettings | ForEach-Object { $settingsDict[$_.name] = $_.value }

$requiredSettings = @(
    "AZURE_STORAGE_CONNECTION_STRING",
    "AZURE_QUEUE_NAME",
    "AZURE_BLOB_CONTAINER",
    "WEBHOOK_CLIENT_STATE"
)

$graphSettings = @(
    "MS_TENANT_ID",
    "MS_CLIENT_ID",
    "MS_CLIENT_SECRET"
)

foreach ($key in $requiredSettings) {
    Test-Check "App Setting: $key" {
        return -not [string]::IsNullOrWhiteSpace($settingsDict[$key])
    }
}

foreach ($key in $graphSettings) {
    if ([string]::IsNullOrWhiteSpace($settingsDict[$key])) {
        Test-Warn "App Setting: $key" "未設定 (admin consent 後に設定)"
    } else {
        Test-Check "App Setting: $key" { return $true }
    }
}

# ── 7. Queue 接続確認 ──────────────────────────────────────

Write-Host ""
Write-Host "📋 7. Storage Queue 確認" -ForegroundColor Cyan

$storageConn = $settingsDict["AZURE_STORAGE_CONNECTION_STRING"]
$queueName   = $settingsDict["AZURE_QUEUE_NAME"]

if ($storageConn -and $queueName -and $storageConn -ne "UseDevelopmentStorage=true") {
    Test-Check "Queue '$queueName' 存在" {
        $exists = az storage queue exists --name $queueName --connection-string $storageConn --output tsv 2>$null
        return $exists -eq "True"
    }
} else {
    Test-Warn "Queue確認" "Storage接続文字列が未設定またはローカル設定"
}

# ── 結果サマリ ──────────────────────────────────────────────

Write-Host ""
Write-Host "============================================================" -ForegroundColor $(if ($fail -eq 0) {"Green"} else {"Red"})
Write-Host "  検証結果: PASS=$pass  FAIL=$fail  WARN=$warn" -ForegroundColor $(if ($fail -eq 0) {"Green"} else {"Red"})
Write-Host "============================================================" -ForegroundColor $(if ($fail -eq 0) {"Green"} else {"Red"})

if ($fail -gt 0) {
    Write-Host ""
    Write-Host "修正後に再実行してください:" -ForegroundColor Yellow
    Write-Host "  .\infra\verify-functions.ps1" -ForegroundColor Gray
}

if ($warn -gt 0) {
    Write-Host ""
    Write-Host "WARN 項目は admin consent 後に再確認:" -ForegroundColor Yellow
    Write-Host "  .\infra\deploy-functions.ps1 -SkipDeploy" -ForegroundColor Gray
}

exit $fail
