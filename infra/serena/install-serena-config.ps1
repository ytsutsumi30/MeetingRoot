# ============================================================
# Serena MCP - Claude Desktop 設定自動マージスクリプト
# ============================================================
#
# 既存の claude_desktop_config.json に serena エントリを安全に追加します。
#   - 既存ファイルあり: バックアップ → mcpServers.serena を追加 (他は保持)
#   - 既存ファイル無し: 新規作成
#
# 使い方:
#   powershell -ExecutionPolicy Bypass -File .\install-serena-config.ps1
#
# オプション:
#   -ProjectPath "C:/別のパス"    既定: C:/PRJ2/dev2
#   -DryRun                       書き込まずに差分プレビュー
# ============================================================

param(
    [string]$ProjectPath = "C:/PRJ2/dev2",
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$configPath  = Join-Path $env:APPDATA "Claude\claude_desktop_config.json"
$configDir   = Split-Path $configPath -Parent

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Serena MCP - Claude Desktop 設定マージ" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

Write-Host "設定ファイル: $configPath" -ForegroundColor Gray
Write-Host "プロジェクト: $ProjectPath" -ForegroundColor Gray
if ($DryRun) { Write-Host "モード: DryRun (書き込みなし)" -ForegroundColor Yellow }
Write-Host ""

# ─── 1. uvx 存在確認 ─────────────────────────────────────────
Write-Host "[1/5] uvx の存在確認..." -ForegroundColor Yellow
try {
    $uvxPath = (Get-Command uvx -ErrorAction Stop).Source
    Write-Host "  ✓ uvx 検出: $uvxPath" -ForegroundColor Green
} catch {
    Write-Host "  ✗ uvx が見つかりません。まず uv をインストールしてください:" -ForegroundColor Red
    Write-Host "      winget install --id astral-sh.uv" -ForegroundColor Yellow
    Write-Host "    インストール後、PowerShell を開き直して再実行" -ForegroundColor Yellow
    if (-not $Force) { exit 1 }
}
Write-Host ""

# ─── 2. プロジェクトディレクトリ確認 ──────────────────────
Write-Host "[2/5] プロジェクトディレクトリ確認..." -ForegroundColor Yellow
$projectWindowsPath = $ProjectPath -replace "/", "\"
if (Test-Path $projectWindowsPath) {
    Write-Host "  ✓ 存在: $projectWindowsPath" -ForegroundColor Green
} else {
    Write-Host "  ⚠ パス '$projectWindowsPath' が存在しません (継続)" -ForegroundColor Yellow
}
Write-Host ""

# ─── 3. Claude 設定ディレクトリ確保 ───────────────────────
Write-Host "[3/5] Claude 設定ディレクトリを確認..." -ForegroundColor Yellow
if (-not (Test-Path $configDir)) {
    if (-not $DryRun) { New-Item -Path $configDir -ItemType Directory | Out-Null }
    Write-Host "  ✓ 新規作成: $configDir" -ForegroundColor Green
} else {
    Write-Host "  ○ 既存: $configDir" -ForegroundColor Gray
}
Write-Host ""

# ─── 4. 既存設定を読み込み & serena エントリをマージ ──────
Write-Host "[4/5] 設定をマージ..." -ForegroundColor Yellow

$serenaEntry = [ordered]@{
    command = "uvx"
    args    = @(
        "--from",
        "git+https://github.com/oraios/serena",
        "serena-mcp-server",
        "--context",
        "ide-assistant",
        "--project",
        $ProjectPath
    )
}

if (Test-Path $configPath) {
    # バックアップ
    $backupPath = "$configPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    if (-not $DryRun) { Copy-Item $configPath $backupPath }
    Write-Host "  ✓ バックアップ: $backupPath" -ForegroundColor Green

    try {
        $existing = Get-Content $configPath -Raw | ConvertFrom-Json
    } catch {
        Write-Host "  ✗ 既存 JSON が壊れています: $_" -ForegroundColor Red
        Write-Host "    手動で修正するか、別名にリネームして再実行してください。" -ForegroundColor Yellow
        exit 1
    }

    # mcpServers が無い場合は作成
    if (-not $existing.PSObject.Properties['mcpServers']) {
        $existing | Add-Member -MemberType NoteProperty -Name mcpServers -Value ([PSCustomObject]@{})
    }

    # 既に serena がある場合の処理
    if ($existing.mcpServers.PSObject.Properties['serena']) {
        Write-Host "  ⚠ 既に serena エントリが存在します" -ForegroundColor Yellow
        if (-not $Force) {
            Write-Host "  → 上書きする場合は -Force を付けて再実行" -ForegroundColor Yellow
            exit 0
        }
        Write-Host "  → -Force 指定のため上書きします" -ForegroundColor Yellow
        $existing.mcpServers.serena = [PSCustomObject]$serenaEntry
    } else {
        # PSCustomObject に Add-Member で serena を追加
        $existing.mcpServers | Add-Member -MemberType NoteProperty -Name serena -Value ([PSCustomObject]$serenaEntry)
    }

    $merged = $existing
} else {
    Write-Host "  ○ 既存ファイル無し → 新規作成" -ForegroundColor Gray
    $merged = [PSCustomObject]@{
        mcpServers = [PSCustomObject]@{
            serena = [PSCustomObject]$serenaEntry
        }
    }
}

# JSON に変換
$jsonText = $merged | ConvertTo-Json -Depth 10

# ─── 5. 書込 ─────────────────────────────────────────
Write-Host ""
Write-Host "[5/5] 書込" -ForegroundColor Yellow
Write-Host ""
Write-Host "─── 出力内容 ─────────────────────────────────────" -ForegroundColor DarkGray
Write-Host $jsonText -ForegroundColor White
Write-Host "──────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""

if ($DryRun) {
    Write-Host "  → DryRun のため書き込みません。実行するには -DryRun を外してください。" -ForegroundColor Yellow
} else {
    # UTF-8 (BOMなし) で書き込み
    [System.IO.File]::WriteAllText($configPath, $jsonText, [System.Text.UTF8Encoding]::new($false))
    Write-Host "  ✓ 書込完了: $configPath" -ForegroundColor Green
}

# ─── 完了表示 ────────────────────────────────────────
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  完了" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""
Write-Host "  次のステップ:" -ForegroundColor Cyan
Write-Host "    1. Claude Desktop を タスクトレイ → 右クリック → Quit で完全終了" -ForegroundColor White
Write-Host "    2. Claude Desktop を再起動" -ForegroundColor White
Write-Host "    3. 新規チャットで「現在接続中のMCPサーバーを一覧表示」と入力" -ForegroundColor White
Write-Host "    4. 'serena' が表示されればOK" -ForegroundColor White
Write-Host ""
Write-Host "  動作テスト:" -ForegroundColor Cyan
Write-Host "    Serena の find_symbol で MeetingRecorder クラスを探して" -ForegroundColor Gray
Write-Host ""
