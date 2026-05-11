# ============================================================
# Phase 2: ローカル開発環境 起動スクリプト
# ============================================================
# 別ウィンドウで Azurite と Azure Functions をそれぞれ起動します。
# 起動後に URL で Webhook 疏通確認できます。
#
# 使い方:
#   .\\start-local-dev.ps1
# ============================================================

param(
    [switch]$NoAzurite,
    [switch]$NoFunctions
)

$ErrorActionPreference = "Stop"
$root           = Split-Path $PSScriptRoot -Parent
$functionsDir   = Join-Path $root "functions"
$localSettings  = Join-Path $functionsDir "local.settings.json"
$exampleSetting = Join-Path $functionsDir "local.settings.json.example"
$azuriteData    = Join-Path $root "azurite-data"

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  ローカル開発環境 起動" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# ─── 残存プロセスのポート解放 ────────────────────────────────────────────
function Stop-PortProcess {
    param([int]$Port, [string]$Label)
    $conn = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($conn) {
        $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
        if ($proc -and $proc.Name -in @("func", "node", "azurite")) {
            Write-Host "  → ポート $Port の残存プロセス ($($proc.Name) PID:$($proc.Id)) を終了" -ForegroundColor DarkGray
            Stop-Process -Id $proc.Id -Force
            Start-Sleep -Milliseconds 500
        }
    }
}

if (-not $NoAzurite) {
    Stop-PortProcess -Port 10000 -Label "Azurite Blob"
    Stop-PortProcess -Port 10001 -Label "Azurite Queue"
    Stop-PortProcess -Port 10002 -Label "Azurite Table"
}
if (-not $NoFunctions) {
    Stop-PortProcess -Port 7071 -Label "Azure Functions"
}

# ─── 事前確認 ───────────────────────────────────────────────────────────
Write-Host "[1/4] 事前確認" -ForegroundColor Yellow
foreach ($cmd in @("azurite", "func", "node")) {
    try {
        Get-Command $cmd -ErrorAction Stop | Out-Null
        Write-Host "  ✓ $cmd" -ForegroundColor Green
    } catch {
        Write-Host "  ✗ $cmd が見つかりません。.\\install-tools.ps1 を実行してください。" -ForegroundColor Red
        exit 1
    }
}
Write-Host ""

# ─── local.settings.json 自動生成 ────────────────────────────────
Write-Host "[2/4] local.settings.json 確認" -ForegroundColor Yellow
if (-not (Test-Path $localSettings)) {
    if (Test-Path $exampleSetting) {
        Copy-Item $exampleSetting $localSettings
        Write-Host "  ✓ local.settings.json.example からコピーしました" -ForegroundColor Green
    } else {
        Write-Host "  ✗ local.settings.json と .example の両方が存在しません" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "  ○ 既存ファイルあり (上書きしません)" -ForegroundColor Gray
}
Write-Host ""

# ─── Azurite 起動 ──────────────────────────────────────────────────────────
if (-not $NoAzurite) {
    Write-Host "[3/4] Azurite 起動 (別ウィンドウ)" -ForegroundColor Yellow
    if (-not (Test-Path $azuriteData)) { New-Item -ItemType Directory $azuriteData | Out-Null }

    $azCmd = "Set-Location '$azuriteData'; Write-Host '[ Azurite ]' -Fore Cyan; azurite --silent --location . --debug ./debug.log --skipApiVersionCheck"
    $azuriteProc = Start-Process powershell -ArgumentList @("-NoExit", "-Command", $azCmd) -PassThru -WindowStyle Normal

    Write-Host "  ✓ Azurite 起動 (PID: $($azuriteProc.Id))" -ForegroundColor Green
    Write-Host "    Blob:  http://127.0.0.1:10000" -ForegroundColor Gray
    Write-Host "    Queue: http://127.0.0.1:10001" -ForegroundColor Gray
    Write-Host "    Table: http://127.0.0.1:10002" -ForegroundColor Gray

    # 起動待ち
    Start-Sleep -Seconds 3
    $maxWait = 10
    $isReady = $false
    for ($i = 0; $i -lt $maxWait; $i++) {
        try {
            Invoke-WebRequest "http://127.0.0.1:10000/devstoreaccount1?comp=list" -UseBasicParsing -TimeoutSec 2 | Out-Null
            $isReady = $true; break
        } catch {
            # 401/403 (AuthorizationFailure) はAzurite起動済みの証拠
            if ($_.Exception.Response -ne $null) { $isReady = $true; break }
            Start-Sleep -Seconds 1
        }
    }
    if ($isReady) {
        Write-Host "  ✓ Azurite 疏通確認 OK" -ForegroundColor Green
    } else {
        Write-Host "  ⚠ Azurite 疏通確認できず。別ウィンドウのログ確認" -ForegroundColor Yellow
    }

    # キュー作成 (存在しない場合のみ)
    try {
        az storage queue create --name minutes-jobs --connection-string "UseDevelopmentStorage=true" --output none 2>$null
        Write-Host "  ✓ Storage Queue 'minutes-jobs' 確認/作成済み" -ForegroundColor Green
    } catch {
        Write-Host "  ⚠ Queue 作成をスキップ (az CLI 未インストール?)" -ForegroundColor Yellow
    }
    Write-Host ""
}

# ─── npm install ───────────────────────────────────────────────────
$nodeModules = Join-Path $functionsDir "node_modules"
if (-not (Test-Path $nodeModules)) {
    Write-Host "  ▶ 初回: npm install を実行" -ForegroundColor DarkGray
    Push-Location $functionsDir
    npm install --silent
    Pop-Location
}

# ─── Functions 起動 ──────────────────────────────────────────────────────────
if (-not $NoFunctions) {
    Write-Host "[4/4] Azure Functions 起動 (別ウィンドウ)" -ForegroundColor Yellow

    $fnCmd = "Set-Location '$functionsDir'; Write-Host '[ Azure Functions ]' -Fore Cyan; func start --port 7071"
    $funcProc = Start-Process powershell -ArgumentList @("-NoExit", "-Command", $fnCmd) -PassThru -WindowStyle Normal

    Write-Host "  ✓ Functions 起動 (PID: $($funcProc.Id))" -ForegroundColor Green
    Write-Host "    URL: http://localhost:7071/api/notifications" -ForegroundColor Gray

    # 起動待ち
    Start-Sleep -Seconds 6
    $maxWait = 15
    $isReady = $false
    for ($i = 0; $i -lt $maxWait; $i++) {
        try {
            $r = Invoke-WebRequest "http://localhost:7071/api/notifications?validationToken=test123" -UseBasicParsing -TimeoutSec 2
            if ($r.Content -eq "test123") { $isReady = $true; break }
        } catch { Start-Sleep -Seconds 1 }
    }
    if ($isReady) {
        Write-Host "  ✓ Webhook 検証エンドポイント 疏通確認 OK" -ForegroundColor Green
    } else {
        Write-Host "  ⚠ Functions の起動を確認できません。別ウィンドウのログ確認" -ForegroundColor Yellow
    }
    Write-Host ""
}

# ─── 起動完了 表示 ─────────────────────────────────────────────────────────
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  起動完了" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""
Write-Host "  動作確認用コマンド" -ForegroundColor Cyan
Write-Host ""
Write-Host "  # 1. Webhook 検証エンドポイント" -ForegroundColor White
Write-Host '  curl.exe "http://localhost:7071/api/notifications?validationToken=test123"' -ForegroundColor Gray
Write-Host ""
Write-Host "  # 2. 通知受信テスト (模擬 Microsoft Graph 通知)" -ForegroundColor White
Write-Host "  curl.exe -X POST http://localhost:7071/api/notifications" -ForegroundColor Gray
Write-Host '    -H "Content-Type: application/json"' -ForegroundColor Gray
Write-Host "    -d '{`"value`":[{`"changeType`":`"created`",`"clientState`":`"validation-string`",`"resource`":`"communications/onlineMeetings/AAMk.../transcripts/MSMm...`"}]}'" -ForegroundColor Gray
Write-Host ""
Write-Host "  # 3. Azurite Queue を確認" -ForegroundColor White
Write-Host '  az storage message peek --queue-name minutes-jobs --connection-string "UseDevelopmentStorage=true"' -ForegroundColor Gray
Write-Host ""
Write-Host "  停止方法:" -ForegroundColor Yellow
Write-Host "    各ウィンドウで Ctrl+C、またはこのウィンドウを閉じる" -ForegroundColor White
Write-Host ""
