# ============================================================
# Microsoft Graph Subscription 作成 (Teams Transcript Webhook)
# ============================================================
#
# 前提:
#   - Function App がデプロイ済み (deploy-functions.ps1)
#   - Azure AD App に OnlineMeetingTranscript.Read.All 権限 (admin consent 済み)
#   - .env.azure に MS_TENANT_ID, MS_CLIENT_ID, MS_CLIENT_SECRET 設定済み
#
# Usage:
#   .\create-graph-subscription.ps1
#   .\create-graph-subscription.ps1 -UserId meetingbot@contoso.com
#   .\create-graph-subscription.ps1 -WhatIf
#   .\create-graph-subscription.ps1 -ListOnly
# ============================================================

param(
    [string]$UserId,
    [switch]$ListOnly,
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

$rootDir  = Split-Path $PSScriptRoot -Parent
$envAzure = Join-Path $rootDir ".env.azure"

# ── .env.azure 読み込み ─────────────────────────────────────

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

$env_vars = Parse-EnvFile -Path $envAzure

$tenantId    = $env_vars["MS_TENANT_ID"]
$clientId    = $env_vars["MS_CLIENT_ID"]
$clientSecret = $env_vars["MS_CLIENT_SECRET"]
$webhookUrl  = $env_vars["WEBHOOK_NOTIFICATION_URL"]
$lifecycleUrl = $env_vars["WEBHOOK_LIFECYCLE_URL"]
$clientState = $env_vars["WEBHOOK_CLIENT_STATE"]

if ([string]::IsNullOrWhiteSpace($lifecycleUrl)) {
    $lifecycleUrl = $webhookUrl
}

# ユーザー Object ID (GUID) を優先使用: resource フォーマットに必要
$userObjectId = $env_vars["SUBSCRIPTION_USER_ID"]
if ([string]::IsNullOrWhiteSpace($userObjectId)) { $userObjectId = $env_vars["MS_USER_ID"] }
if (-not $UserId) { $UserId = $env_vars["MS_USER_UPN"] }

# バリデーション
$missing = @()
if ([string]::IsNullOrWhiteSpace($tenantId))    { $missing += "MS_TENANT_ID" }
if ([string]::IsNullOrWhiteSpace($clientId))     { $missing += "MS_CLIENT_ID" }
if ([string]::IsNullOrWhiteSpace($clientSecret)) { $missing += "MS_CLIENT_SECRET" }
if ([string]::IsNullOrWhiteSpace($webhookUrl))   { $missing += "WEBHOOK_NOTIFICATION_URL" }
if ([string]::IsNullOrWhiteSpace($clientState))  { $missing += "WEBHOOK_CLIENT_STATE" }
if ([string]::IsNullOrWhiteSpace($UserId))       { $missing += "MS_USER_UPN / -UserId" }

if ($missing.Count -gt 0) {
    Write-Host "必要な設定が不足しています:" -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    throw ".env.azure を確認してください。"
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Microsoft Graph Subscription 管理" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Tenant:       $tenantId"
Write-Host "  Client:       $clientId"
Write-Host "  User (Org):   $UserId"
Write-Host "  Webhook:      $webhookUrl"
Write-Host "  Lifecycle:    $lifecycleUrl"

# ── Token 取得 ──────────────────────────────────────────────

Write-Host ""
Write-Host "🔑 Token取得中..." -ForegroundColor Cyan

$tokenBody = @{
    client_id     = $clientId
    client_secret = $clientSecret
    scope         = "https://graph.microsoft.com/.default"
    grant_type    = "client_credentials"
}

try {
    $tokenResponse = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" `
        -Method POST -Body $tokenBody -ContentType "application/x-www-form-urlencoded"
    $token = $tokenResponse.access_token
    Write-Host "  ✅ Token取得 OK (expires_in: $($tokenResponse.expires_in)s)" -ForegroundColor Green
} catch {
    Write-Host "  ❌ Token取得失敗: $($_.Exception.Message)" -ForegroundColor Red
    throw "Azure AD App の client_id/secret を確認してください。"
}

$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type"  = "application/json"
}

# ── 既存 Subscription 一覧 ─────────────────────────────────

Write-Host ""
Write-Host "📋 既存 Subscription 一覧..." -ForegroundColor Cyan

try {
    $subs = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/subscriptions" `
        -Method GET -Headers $headers
    $existingSubs = $subs.value

    if ($existingSubs.Count -eq 0) {
        Write-Host "  (なし)" -ForegroundColor Gray
    } else {
        foreach ($s in $existingSubs) {
            $remaining = ([datetime]$s.expirationDateTime - [datetime]::UtcNow).TotalHours
            $status = if ($remaining -gt 0) { "active (残り $([math]::Round($remaining,1))h)" } else { "EXPIRED" }
            Write-Host "  ID:         $($s.id)" -ForegroundColor $(if ($remaining -gt 0) {"Green"} else {"Red"})
            Write-Host "  Resource:   $($s.resource)"
            Write-Host "  Webhook:    $($s.notificationUrl)"
            Write-Host "  Expiration: $($s.expirationDateTime) [$status]"
            Write-Host ""
        }
    }
} catch {
    Write-Host "  ⚠️ Subscription一覧取得失敗: $($_.Exception.Message)" -ForegroundColor Yellow
    if ($_.Exception.Message -match "403|Forbidden") {
        Write-Host "  → Admin consent が未付与の可能性があります。" -ForegroundColor Yellow
    }
}

if ($ListOnly) {
    Write-Host "(-ListOnly モード: 一覧のみ表示)" -ForegroundColor Gray
    exit 0
}

# ── Subscription 作成 ───────────────────────────────────────

Write-Host ""
Write-Host "🆕 新規 Subscription 作成..." -ForegroundColor Cyan

# 有効期限: 70時間 (上限4230分 ≈ 70.5h)
$expiration = [datetime]::UtcNow.AddMinutes(4200).ToString("o")

# users/{objectId}/onlineMeetings/getAllTranscripts 形式を使用
# (communications/onlineMeetings/getAllTranscripts(meetingOrganizerUserId='UPN') 形式は Webhook 検証エラーになる)
$resolvedId = if (-not [string]::IsNullOrWhiteSpace($userObjectId)) { $userObjectId } else { $UserId }
$resource = "users/$resolvedId/onlineMeetings/getAllTranscripts"

$subBody = @{
    changeType              = "created"
    notificationUrl         = $webhookUrl
    lifecycleNotificationUrl= $lifecycleUrl
    resource                = $resource
    expirationDateTime      = $expiration
    clientState             = $clientState
} | ConvertTo-Json -Depth 5

Write-Host "  Resource: $resource"
Write-Host "  Expiration: $expiration"

if ($WhatIf) {
    Write-Host ""
    Write-Host "[WhatIf] 以下の Subscription を作成します:" -ForegroundColor Yellow
    Write-Host $subBody
    Write-Host ""
    Write-Host "実行するには -WhatIf を外してください。" -ForegroundColor Yellow
    exit 0
}

try {
    $created = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/subscriptions" `
        -Method POST -Headers $headers -Body $subBody

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "  ✅ Subscription 作成成功" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "  Subscription ID: $($created.id)"
    Write-Host "  Expiration:      $($created.expirationDateTime)"
    Write-Host "  Notification:    $($created.notificationUrl)"
    if ($created.lifecycleNotificationUrl) {
        Write-Host "  Lifecycle:       $($created.lifecycleNotificationUrl)"
    }
    Write-Host ""
    Write-Host "次のステップ:" -ForegroundColor Yellow
    Write-Host "  1. Teams 会議を開催して Live Transcript を有効化"
    Write-Host "  2. 会議終了後に Azure Functions のログで通知を確認:"
    Write-Host "     func azure functionapp logstream $($env_vars['FUNCTION_APP_NAME'])"
    Write-Host "  3. lifecycle 通知が来た場合は subscriptions-renew で復旧可能か確認"
    Write-Host "  4. TestDashboard の /api/jobs で Teams ジョブが生成されることを確認"
    Write-Host ""
    Write-Host "⚠️ Subscription は $([math]::Round(4200/60, 1))h で期限切れします。" -ForegroundColor Yellow
    Write-Host "  定期更新のために Timer Trigger の追加を推奨します。" -ForegroundColor Yellow

} catch {
    $errorBody = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
    Write-Host ""
    Write-Host "❌ Subscription 作成失敗" -ForegroundColor Red

    if ($errorBody.error.code -eq "ExtensionError") {
        Write-Host "  Webhook検証に失敗しました。" -ForegroundColor Red
        Write-Host "  → Function App が正常に起動しているか確認してください:" -ForegroundColor Yellow
        Write-Host "    curl.exe -s `"${webhookUrl}?validationToken=test`"" -ForegroundColor Gray
    } elseif ($errorBody.error.code -eq "Authorization_RequestDenied") {
        Write-Host "  権限不足です。" -ForegroundColor Red
        Write-Host "  → Azure AD App に以下の権限が admin consent 済みか確認:" -ForegroundColor Yellow
        Write-Host "    - OnlineMeetings.Read.All (Application)" -ForegroundColor Yellow
        Write-Host "    - OnlineMeetingTranscript.Read.All (Application)" -ForegroundColor Yellow
    } elseif ($errorBody.error.code -eq "InvalidRequest" -and $errorBody.error.message -match "Subscription validation") {
        Write-Host "  Webhook URL の検証が失敗しました。" -ForegroundColor Red
        Write-Host "  → Function App の /api/notifications が validationToken を返せるか確認:" -ForegroundColor Yellow
        Write-Host "    curl.exe -s `"${webhookUrl}?validationToken=test`"" -ForegroundColor Gray
    } else {
        Write-Host "  Error: $($errorBody.error.code) - $($errorBody.error.message)" -ForegroundColor Red
    }

    Write-Host ""
    Write-Host "デバッグ用 curl コマンド:" -ForegroundColor Gray
    Write-Host "  curl.exe -X POST 'https://graph.microsoft.com/v1.0/subscriptions' \" -ForegroundColor Gray
    Write-Host "    -H 'Authorization: Bearer <TOKEN>' \" -ForegroundColor Gray
    Write-Host "    -H 'Content-Type: application/json' \" -ForegroundColor Gray
    Write-Host "    -d '$subBody'" -ForegroundColor Gray

    throw "Subscription 作成失敗"
}
