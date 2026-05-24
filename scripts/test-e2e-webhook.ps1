# ============================================================
# Teams webhook → Azure Queue 疎通テスト
# ============================================================
# 事前準備:
#   1. Azure Functions を起動しておく
#      > cd functions; func start
#
# 実行例:
#   > .\scripts\test-e2e-webhook.ps1
#   > .\scripts\test-e2e-webhook.ps1 -FunctionsUrl "http://localhost:7071" -WaitSec 3
# ============================================================
param(
    [string]$FunctionsUrl = "http://localhost:7071",
    [int]   $WaitSec      = 3,
    [switch]$SkipQueueCheck
)

$ErrorActionPreference = "SilentlyContinue"
$pass = 0; $fail = 0; $warn = 0

function Write-Result {
    param($label, $status, $detail = "")
    $color = switch ($status) {
        "PASS" { "Green" }; "FAIL" { "Red" }; "WARN" { "Yellow" }; default { "White" }
    }
    $msg = if ($detail) { "[$status] $label -- $detail" } else { "[$status] $label" }
    Write-Host $msg -ForegroundColor $color
    if ($status -eq "PASS") { $script:pass++ }
    elseif ($status -eq "FAIL") { $script:fail++ }
    else { $script:warn++ }
}

# ─── local.settings.json から設定を読み込む ──────────────────────
$settingsPath = Join-Path $PSScriptRoot "..\functions\local.settings.json"
$settings = @{}
if (Test-Path $settingsPath) {
    $json = Get-Content $settingsPath -Raw | ConvertFrom-Json
    foreach ($key in $json.Values.PSObject.Properties.Name) {
        $settings[$key] = $json.Values.$key
    }
}

$ClientState    = $settings["WEBHOOK_CLIENT_STATE"] ?? $env:WEBHOOK_CLIENT_STATE ?? ""
$ConnStr        = $settings["AZURE_STORAGE_CONNECTION_STRING"] ?? $env:AZURE_STORAGE_CONNECTION_STRING ?? ""
$QueueName      = $settings["AZURE_QUEUE_NAME"] ?? "minutes-jobs"

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Teams Webhook → Azure Queue 疎通テスト" -ForegroundColor Cyan
Write-Host " Functions: $FunctionsUrl" -ForegroundColor Cyan
Write-Host " Queue:     $QueueName" -ForegroundColor Cyan
Write-Host "============================================================"
Write-Host ""

# ─── 前提チェック ────────────────────────────────────────────────
Write-Host "--- [0] 前提チェック ---"

if (-not $ClientState) {
    Write-Result "WEBHOOK_CLIENT_STATE" "FAIL" "未設定 (functions/local.settings.json を確認)"
    exit 1
}
Write-Result "WEBHOOK_CLIENT_STATE" "PASS" "設定済み"

if (-not $ConnStr) {
    Write-Result "AZURE_STORAGE_CONNECTION_STRING" "WARN" "未設定 - キューチェックはスキップ"
    $SkipQueueCheck = $true
} else {
    Write-Result "AZURE_STORAGE_CONNECTION_STRING" "PASS" "設定済み"
}

# Functions が起動しているか確認
try {
    $hc = Invoke-WebRequest -Uri "$FunctionsUrl/api/healthz" -UseBasicParsing -ErrorAction Stop -TimeoutSec 5
    Write-Result "Functions healthz" "PASS" "HTTP $($hc.StatusCode)"
} catch {
    $code = 0; try { $code = $_.Exception.Response.StatusCode.value__ } catch {}
    if ($code -eq 404) {
        # /api/healthz が無くても Functions は動いているかもしれない
        Write-Result "Functions healthz" "WARN" "404 (healthz 未登録?) - 続行します"
    } else {
        Write-Result "Functions healthz" "FAIL" "接続できません ($FunctionsUrl) - func start を実行してください"
        exit 1
    }
}

# ─── テストケース 1: 引用符形式 (quoted-paren) ──────────────────
Write-Host ""
Write-Host "--- [1] Quoted-paren 形式: onlineMeetings('id')/transcripts('id') ---"

$meetingId1    = "MSo1Mjk4MjM5OS05NzUxLTQ2ZGMtOWNiZC0wMDAwMDAwMDAwMDI"
$transcriptId1 = "MSoxMjM0NTY3ODktYWJjZC0xMjM0LWFiY2QtMTIzNDU2Nzg5YWJj"
$resource1     = "users/00000000-0000-0000-0000-000000000001/onlineMeetings('$meetingId1')/transcripts('$transcriptId1')"

$body1 = @{
    value = @(
        @{
            clientState    = $ClientState
            changeType     = "created"
            resource       = $resource1
            subscriptionId = "test-sub-001"
        }
    )
} | ConvertTo-Json -Depth 5

try {
    $r1 = Invoke-WebRequest -Uri "$FunctionsUrl/api/notifications" `
        -Method POST -Body $body1 `
        -ContentType "application/json" `
        -UseBasicParsing -ErrorAction Stop -TimeoutSec 15
    $j1 = $r1.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($r1.StatusCode -eq 202 -and $j1.processed -eq 1) {
        Write-Result "TC-1 quoted-paren 受信" "PASS" "HTTP 202, processed=1"
    } elseif ($r1.StatusCode -eq 202 -and $j1.processed -eq 0) {
        Write-Result "TC-1 quoted-paren 受信" "FAIL" "HTTP 202 だが processed=0 (パターン未マッチ)"
    } else {
        Write-Result "TC-1 quoted-paren 受信" "FAIL" "HTTP $($r1.StatusCode): $($r1.Content)"
    }
} catch {
    Write-Result "TC-1 quoted-paren 受信" "FAIL" $_.ToString()
}

# ─── テストケース 2: スラッシュ形式 (slash) ─────────────────────
Write-Host ""
Write-Host "--- [2] Slash 形式: onlineMeetings/{id}/transcripts/{id} ---"

$meetingId2    = "MSo1Mjk4MjM5OS05NzUxLTQ2ZGMtOWNiZC0wMDAwMDAwMDAwMDM"
$transcriptId2 = "MSoxMjM0NTY3ODktYWJjZC0xMjM0LWFiY2QtMTIzNDU2Nzg5YWJk"
$resource2     = "users/00000000-0000-0000-0000-000000000001/onlineMeetings/$meetingId2/transcripts/$transcriptId2"

$body2 = @{
    value = @(
        @{
            clientState    = $ClientState
            changeType     = "created"
            resource       = $resource2
            subscriptionId = "test-sub-002"
        }
    )
} | ConvertTo-Json -Depth 5

try {
    $r2 = Invoke-WebRequest -Uri "$FunctionsUrl/api/notifications" `
        -Method POST -Body $body2 `
        -ContentType "application/json" `
        -UseBasicParsing -ErrorAction Stop -TimeoutSec 15
    $j2 = $r2.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($r2.StatusCode -eq 202 -and $j2.processed -eq 1) {
        Write-Result "TC-2 slash 受信" "PASS" "HTTP 202, processed=1"
    } elseif ($r2.StatusCode -eq 202 -and $j2.processed -eq 0) {
        Write-Result "TC-2 slash 受信" "FAIL" "HTTP 202 だが processed=0 (パターン未マッチ)"
    } else {
        Write-Result "TC-2 slash 受信" "FAIL" "HTTP $($r2.StatusCode): $($r2.Content)"
    }
} catch {
    Write-Result "TC-2 slash 受信" "FAIL" $_.ToString()
}

# ─── テストケース 3: URL エンコード済み ID ───────────────────────
Write-Host ""
Write-Host "--- [3] URL-encoded ID (Base64 = 含む) ---"

$meetingId3    = [Uri]::EscapeDataString("MSo=meeting+test/abc")
$transcriptId3 = [Uri]::EscapeDataString("MSo=transcript+test/def")
$resource3     = "users/00000000-0000-0000-0000-000000000001/onlineMeetings('$meetingId3')/transcripts('$transcriptId3')"

$body3 = @{
    value = @(
        @{
            clientState    = $ClientState
            changeType     = "created"
            resource       = $resource3
            subscriptionId = "test-sub-003"
        }
    )
} | ConvertTo-Json -Depth 5

try {
    $r3 = Invoke-WebRequest -Uri "$FunctionsUrl/api/notifications" `
        -Method POST -Body $body3 `
        -ContentType "application/json" `
        -UseBasicParsing -ErrorAction Stop -TimeoutSec 15
    $j3 = $r3.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($r3.StatusCode -eq 202 -and $j3.processed -eq 1) {
        Write-Result "TC-3 URL-encoded 受信" "PASS" "HTTP 202, processed=1"
    } elseif ($r3.StatusCode -eq 202 -and $j3.processed -eq 0) {
        Write-Result "TC-3 URL-encoded 受信" "FAIL" "HTTP 202 だが processed=0 (パターン未マッチ)"
    } else {
        Write-Result "TC-3 URL-encoded 受信" "FAIL" "HTTP $($r3.StatusCode): $($r3.Content)"
    }
} catch {
    Write-Result "TC-3 URL-encoded 受信" "FAIL" $_.ToString()
}

# ─── テストケース 4: clientState 不正 → スキップされること ─────
Write-Host ""
Write-Host "--- [4] 不正 clientState → processed=0 になること ---"

$body4 = @{
    value = @(
        @{
            clientState    = "INVALID_STATE"
            changeType     = "created"
            resource       = $resource2
            subscriptionId = "test-sub-004"
        }
    )
} | ConvertTo-Json -Depth 5

try {
    $r4 = Invoke-WebRequest -Uri "$FunctionsUrl/api/notifications" `
        -Method POST -Body $body4 `
        -ContentType "application/json" `
        -UseBasicParsing -ErrorAction Stop -TimeoutSec 15
    $j4 = $r4.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($r4.StatusCode -eq 202 -and $j4.processed -eq 0) {
        Write-Result "TC-4 不正 clientState 拒否" "PASS" "HTTP 202, processed=0"
    } else {
        Write-Result "TC-4 不正 clientState 拒否" "FAIL" "HTTP $($r4.StatusCode), processed=$($j4.processed)"
    }
} catch {
    Write-Result "TC-4 不正 clientState 拒否" "FAIL" $_.ToString()
}

# ─── キューチェック (Azure Storage Queue / Node.js) ────────────
if (-not $SkipQueueCheck) {
    Write-Host ""
    Write-Host "--- [5] Azure Storage Queue 確認 ($QueueName) ---"
    Write-Host "  $WaitSec 秒待機中..." -ForegroundColor DarkGray
    Start-Sleep -Seconds $WaitSec

    $nodeScript = @"
const { QueueServiceClient } = require('@azure/storage-queue');
const connStr   = process.argv[2];
const queueName = process.argv[3];
(async () => {
  try {
    const svc    = QueueServiceClient.fromConnectionString(connStr);
    const client = svc.getQueueClient(queueName);
    const r      = await client.peekMessages({ numberOfMessages: 5 });
    const msgs   = r.peekedMessageItems || [];
    process.stdout.write(JSON.stringify({ count: msgs.length, items: msgs.map(m => {
      try { return JSON.parse(Buffer.from(m.messageText,'base64').toString('utf8')); } catch { return { raw: m.messageText }; }
    })}));
  } catch(e) { process.stdout.write(JSON.stringify({ error: e.message })); }
})();
"@
    $nodeExe = Get-Command node -ErrorAction SilentlyContinue
    $functionsDir = Join-Path $PSScriptRoot "..\functions"
    # functions ディレクトリに一時スクリプトを書き出す (node_modules 解決のため)
    $tmpJs = Join-Path $functionsDir "_e2e_queue_check.tmp.js"
    Set-Content -Path $tmpJs -Value $nodeScript -Encoding utf8

    if ($nodeExe -and (Test-Path (Join-Path $functionsDir "node_modules\@azure\storage-queue"))) {
        $prevPwd = $PWD
        Set-Location $functionsDir
        $output = & node $tmpJs $ConnStr $QueueName 2>&1
        Set-Location $prevPwd
        Remove-Item $tmpJs -ErrorAction SilentlyContinue
        try {
            $parsed = $output | ConvertFrom-Json -ErrorAction Stop
            if ($parsed.error) {
                Write-Result "TC-5 Queue メッセージ確認" "WARN" "Node エラー: $($parsed.error)"
            } elseif ($parsed.count -gt 0) {
                Write-Result "TC-5 Queue メッセージ確認" "PASS" "$($parsed.count) 件確認"
                foreach ($item in $parsed.items) {
                    Write-Host "    meetingId=$($item.meetingId) | transcriptId=$($item.transcriptId)" -ForegroundColor DarkGray
                }
            } else {
                Write-Result "TC-5 Queue メッセージ確認" "WARN" "キューが空 (直前のメッセージが消費された可能性あり)"
            }
        } catch {
            Write-Result "TC-5 Queue メッセージ確認" "WARN" "出力パース失敗: $output"
        }
    } else {
        Remove-Item $tmpJs -ErrorAction SilentlyContinue
        Write-Result "TC-5 Queue メッセージ確認" "WARN" "node または @azure/storage-queue が見つかりません"
    }
}

# ─── 結果サマリー ─────────────────────────────────────────────────
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Test Results" -ForegroundColor Cyan
Write-Host "============================================================"
Write-Host "  PASS: $pass" -ForegroundColor Green
Write-Host "  WARN: $warn" -ForegroundColor Yellow
$fc = if ($fail -gt 0) { "Red" } else { "Green" }
Write-Host "  FAIL: $fail" -ForegroundColor $fc
Write-Host ""
if ($fail -gt 0) { exit 1 } else { exit 0 }
