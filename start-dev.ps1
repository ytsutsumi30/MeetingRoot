# ============================================================
# ローカル開発環境 一括起動スクリプト
# ============================================================
# 実行:
#   C:\PRJ2\dev2> .\start-dev.ps1
#
# 処理順:
#   1. Azurite debug.log をローテーション
#   2. Azurite (Storage エミュレーター) をバックグラウンドで起動
#   3. TestDashboard (Express サーバー) を起動
#
# 前提:
#   - azurite が npm install -g azurite でグローバルインストール済み
#   - node / npm が PATH に存在すること
# ============================================================

$ErrorActionPreference = "Stop"
$Root      = $PSScriptRoot
$AzureDir  = Join-Path $Root "azurite-data"
$Dashboard = Join-Path $Root "TestDashboard"

Write-Host "=== ローカル開発環境 起動 ===" -ForegroundColor Cyan

# ─── 1. Azurite ログローテーション ───────────────────────────────
Write-Host "`n[1/3] Azurite debug.log ローテーション" -ForegroundColor Yellow
& "$Root\scripts\rotate-azurite-log.ps1" -LogDir $AzureDir -MaxSizeMB 10 -KeepDays 7

# ─── 2. Azurite バックグラウンド起動 ─────────────────────────────
Write-Host "`n[2/3] Azurite 起動 (バックグラウンド)" -ForegroundColor Yellow

# 既に起動中か確認
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

# ─── 3. TestDashboard 起動 ────────────────────────────────────────
Write-Host "`n[3/3] TestDashboard 起動" -ForegroundColor Yellow

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
Write-Host "  npm start → http://localhost:$(${env:PORT} ?? '3000')" -ForegroundColor Green
npm start

