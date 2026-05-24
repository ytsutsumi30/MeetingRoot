# ============================================================
# ローカル開発環境 一括起動スクリプト
# ============================================================
# 実行:
#   C:\PRJ2\dev2> .\start-dev.ps1
#
# 処理順:
#   1. Azurite debug.log をローテーション
#   2. Azurite (Storage エミュレーター) をバックグラウンドで起動
#      ※ AZURE_STORAGE_CONNECTION_STRING が実 Azure の場合はスキップ
#   3. Azure Functions (func start :7071) をバックグラウンドで起動
#   4. TestDashboard (Express サーバー) をフォアグラウンドで起動
#
# 前提:
#   - azurite が npm install -g azurite でグローバルインストール済み
#   - Azure Functions Core Tools (func) がインストール済み
#   - node / npm が PATH に存在すること
# ============================================================

$ErrorActionPreference = "Stop"
$Root      = $PSScriptRoot
$AzureDir  = Join-Path $Root "azurite-data"
$Dashboard = Join-Path $Root "TestDashboard"
$Functions = Join-Path $Root "functions"
$DashPort  = 3000
$FuncPort  = 7071

Write-Host "=== ローカル開発環境 起動 ===" -ForegroundColor Cyan

# ─── ヘルパー: ポートが使用中かどうかを確認 ─────────────────────────
function Test-PortInUse([int]$Port) {
    $conn = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue
    return ($null -ne $conn)
}

# ─── ヘルパー: .env から接続文字列が実 Azure かどうかを判定 ──────────
function Test-RealAzureStorage {
    $envFile = Join-Path $Dashboard ".env"
    if (-not (Test-Path $envFile)) { return $false }
    $line = Get-Content $envFile | Where-Object { $_ -match '^\s*AZURE_STORAGE_CONNECTION_STRING\s*=' } | Select-Object -First 1
    if (-not $line) { return $false }
    $val = ($line -split '=', 2)[1].Trim()
    # Azurite の接続文字列には UseDevelopmentStorage か devstoreaccount1 が含まれる
    return ($val -notmatch 'UseDevelopmentStorage|devstoreaccount1')
}

# ─── 1. Azurite ログローテーション ───────────────────────────────
Write-Host "`n[1/4] Azurite debug.log ローテーション" -ForegroundColor Yellow
& "$Root\scripts\rotate-azurite-log.ps1" -LogDir $AzureDir -MaxSizeMB 10 -KeepDays 7

# ─── 2. Azurite バックグラウンド起動 ─────────────────────────────
Write-Host "`n[2/4] Azurite 起動 (バックグラウンド)" -ForegroundColor Yellow

if (Test-RealAzureStorage) {
    Write-Host "  実 Azure Storage を使用中のため Azurite はスキップ" -ForegroundColor DarkGray
} else {
    $azuriteProc = Get-Process -Name "node" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*azurite*" } |
        Select-Object -First 1

    if ($azuriteProc) {
        Write-Host "  Azurite は既に起動中 (PID $($azuriteProc.Id))" -ForegroundColor Cyan
    } else {
        $logPath = Join-Path $AzureDir "debug.log"
        Start-Process -FilePath "azurite" `
            -ArgumentList "--location `"$AzureDir`" --debug `"$logPath`" --silent" `
            -WindowStyle Hidden
        Write-Host "  Azurite 起動済み → データ: $AzureDir" -ForegroundColor Green
        Start-Sleep -Seconds 2
    }
}

# ─── 3. Azure Functions バックグラウンド起動 ──────────────────────
Write-Host "`n[3/4] Azure Functions 起動 (バックグラウンド, port $FuncPort)" -ForegroundColor Yellow

if (Test-PortInUse $FuncPort) {
    Write-Host "  Azure Functions は既に起動中 (port $FuncPort)" -ForegroundColor Cyan
} elseif (-not (Test-Path $Functions)) {
    Write-Host "  functions/ ディレクトリが見つかりません。スキップ" -ForegroundColor DarkGray
} elseif (-not (Get-Command "func" -ErrorAction SilentlyContinue)) {
    Write-Host "  Azure Functions Core Tools (func) が見つかりません。スキップ" -ForegroundColor DarkGray
    Write-Host "  インストール: npm install -g azure-functions-core-tools@4" -ForegroundColor DarkGray
} else {
    $funcOutLog = Join-Path $Root "functions-out.log"
    $funcErrLog = Join-Path $Root "functions-err.log"
    Start-Process -FilePath "func" `
        -ArgumentList "start" `
        -WorkingDirectory $Functions `
        -RedirectStandardOutput $funcOutLog `
        -RedirectStandardError  $funcErrLog `
        -WindowStyle Hidden
    Write-Host "  Azure Functions 起動中..." -ForegroundColor Green
    # 起動完了を最大15秒待つ
    $waited = 0
    while ($waited -lt 15 -and -not (Test-PortInUse $FuncPort)) {
        Start-Sleep -Seconds 1
        $waited++
    }
    if (Test-PortInUse $FuncPort) {
        Write-Host "  Azure Functions 起動完了 → http://localhost:$FuncPort" -ForegroundColor Green
    } else {
        Write-Host "  Azure Functions の起動確認がタイムアウトしました。ログ: $funcErrLog" -ForegroundColor Yellow
    }
}

# ─── 4. TestDashboard 起動 ────────────────────────────────────────
Write-Host "`n[4/4] TestDashboard 起動" -ForegroundColor Yellow

if (Test-PortInUse $DashPort) {
    Write-Host "  ポート $DashPort は既に使用中です。" -ForegroundColor Red
    Write-Host "  既存プロセスを停止してから再実行してください:" -ForegroundColor Red
    $existing = Get-NetTCPConnection -LocalPort $DashPort -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($existing) {
        Write-Host "    Stop-Process -Id $($existing.OwningProcess) -Force" -ForegroundColor Red
    }
    exit 1
}

# .env があれば読み込む
$envFile = Join-Path $Dashboard ".env"
if (Test-Path $envFile) {
    Write-Host "  .env 読み込み中..." -ForegroundColor Cyan
    Get-Content $envFile | ForEach-Object {
        if ($_ -match '^\s*([^#=][^=]*)=(.*)$') {
            [Environment]::SetEnvironmentVariable($matches[1].Trim(), $matches[2].Trim(), 'Process')
        }
    }
}

Set-Location $Dashboard
Write-Host "  npm start → http://localhost:$DashPort" -ForegroundColor Green
npm start

