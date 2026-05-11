# ============================================================
# Azurite debug.log ローテーションスクリプト
# ============================================================
# 使い方:
#   .\rotate-azurite-log.ps1
#   .\rotate-azurite-log.ps1 -MaxSizeMB 5 -KeepDays 14
#
# 動作:
#   1. debug.log が MaxSizeMB を超えていたらローテーション実施
#      → debug.log.YYYYMMDD_HHmmss にリネームして空の debug.log を作成
#   2. KeepDays 以上古いアーカイブファイルを削除
# ============================================================

param(
    [string] $LogDir    = "$PSScriptRoot\..\azurite-data",
    [int]    $MaxSizeMB = 10,
    [int]    $KeepDays  = 7
)

$ErrorActionPreference = "Stop"
$logPath = Join-Path $LogDir "debug.log"

# ログファイルが存在しない場合は何もしない
if (-not (Test-Path $logPath)) {
    Write-Host "[rotate-azurite-log] debug.log not found, skip." -ForegroundColor Yellow
    exit 0
}

$sizeMB = (Get-Item $logPath).Length / 1MB
Write-Host "[rotate-azurite-log] debug.log size: $([math]::Round($sizeMB, 2)) MB (threshold: ${MaxSizeMB} MB)"

if ($sizeMB -ge $MaxSizeMB) {
    $stamp   = Get-Date -Format "yyyyMMdd_HHmmss"
    $archive = Join-Path $LogDir "debug.log.$stamp"
    Move-Item -Path $logPath -Destination $archive
    New-Item  -Path $logPath -ItemType File | Out-Null
    Write-Host "[rotate-azurite-log] Rotated → $archive" -ForegroundColor Green
} else {
    Write-Host "[rotate-azurite-log] No rotation needed." -ForegroundColor Cyan
}

# 古いアーカイブを削除
$cutoff = (Get-Date).AddDays(-$KeepDays)
Get-ChildItem -Path $LogDir -Filter "debug.log.*" | Where-Object {
    $_.LastWriteTime -lt $cutoff
} | ForEach-Object {
    Remove-Item $_.FullName -Force
    Write-Host "[rotate-azurite-log] Deleted old archive: $($_.Name)" -ForegroundColor DarkYellow
}

Write-Host "[rotate-azurite-log] Done." -ForegroundColor Green

