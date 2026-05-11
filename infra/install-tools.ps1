# ============================================================
# Phase 1: 不足ツール 自動インストールスクリプト
# ============================================================
# winget を使って Windows 上に必要ツールを一括インストールします。
# Azurite だけは npm 経由（winget パッケージなし）。
#
# 使い方 (管理者PowerShellで実行推奨):
#   powershell -ExecutionPolicy Bypass -File .\install-tools.ps1
#
# 部分インストール:
#   .\install-tools.ps1 -Only Node,FuncTools
# ============================================================

param(
    [string[]]$Only = @(),
    [switch]$SkipAzurite,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$Host.UI.RawUI.WindowTitle = "Meeting Minutes - Install Tools"

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  議事録機能 ローカル開発ツール インストール" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# 管理者権限確認
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "⚠️  管理者権限ではありません。winget が一部失敗する可能性があります。" -ForegroundColor Yellow
    Write-Host "   推奨: 管理者として PowerShell を起動して再実行" -ForegroundColor Yellow
    Write-Host ""
    $continue = Read-Host "それでも続行しますか？ (y/N)"
    if ($continue -ne "y") { exit 1 }
}

# winget 存在確認
try {
    winget --version | Out-Null
} catch {
    Write-Host "❌ winget が見つかりません。" -ForegroundColor Red
    Write-Host "   Microsoft Store で「アプリ インストーラー」をインストールしてください:" -ForegroundColor Yellow
    Write-Host "   https://www.microsoft.com/store/productId/9NBLGGH4NNS1" -ForegroundColor Yellow
    exit 1
}

# パッケージリスト
$packages = @(
    @{ Key="Node";       Id="OpenJS.NodeJS.LTS";                     Name="Node.js LTS";                CheckCmd="node" }
    @{ Key="DotNet";     Id="Microsoft.DotNet.SDK.8";                Name=".NET 8 SDK";                  CheckCmd="dotnet" }
    @{ Key="AzCli";      Id="Microsoft.AzureCLI";                    Name="Azure CLI";                   CheckCmd="az" }
    @{ Key="FuncTools";  Id="Microsoft.Azure.FunctionsCoreTools";    Name="Azure Functions Core Tools";  CheckCmd="func" }
    @{ Key="Bicep";      Id="Microsoft.Bicep";                       Name="Bicep CLI";                   CheckCmd="bicep" }
    @{ Key="Git";        Id="Git.Git";                               Name="Git";                        CheckCmd="git" }
    @{ Key="Cloudflared";Id="Cloudflare.cloudflared";                Name="cloudflared";                 CheckCmd="cloudflared" }
)

# フィルタ
if ($Only.Count -gt 0) {
    $packages = $packages | Where-Object { $_.Key -in $Only }
}

# インストール処理
$installed = @()
$skipped = @()
$failed = @()

foreach ($pkg in $packages) {
    Write-Host "▶ $($pkg.Name)" -ForegroundColor Cyan
    $alreadyInstalled = $false
    if (-not $Force) {
        try { Get-Command $pkg.CheckCmd -ErrorAction Stop | Out-Null; $alreadyInstalled = $true } catch {}
    }
    if ($alreadyInstalled) {
        Write-Host "  ○ 既にインストール済み (スキップ)" -ForegroundColor Gray
        $skipped += $pkg.Name
        Write-Host ""
        continue
    }
    Write-Host "  → winget install --id $($pkg.Id)" -ForegroundColor DarkGray
    try {
        winget install --id $pkg.Id --accept-package-agreements --accept-source-agreements --silent --exact 2>&1 | Out-String | Write-Host
        Write-Host "  ✓ インストール完了" -ForegroundColor Green
        $installed += $pkg.Name
    } catch {
        Write-Host "  ✗ インストール失敗: $_" -ForegroundColor Red
        $failed += $pkg.Name
    }
    Write-Host ""
}

# Azurite (npm 経由)
if (-not $SkipAzurite) {
    Write-Host "▶ Azurite (Azure Storage Emulator)" -ForegroundColor Cyan
    try {
        Get-Command azurite -ErrorAction Stop | Out-Null
        Write-Host "  ○ 既にインストール済み (スキップ)" -ForegroundColor Gray
        $skipped += "Azurite"
    } catch {
        # Node.js があれば npm でインストール
        try {
            Get-Command npm -ErrorAction Stop | Out-Null
            Write-Host "  → npm install -g azurite" -ForegroundColor DarkGray
            npm install -g azurite 2>&1 | Out-String | Write-Host
            Write-Host "  ✓ インストール完了" -ForegroundColor Green
            $installed += "Azurite"
        } catch {
            Write-Host "  ✗ npm が無いため Azurite をインストールできません。" -ForegroundColor Red
            Write-Host "     先に Node.js をインストールして、新しい PowerShell で再実行してください。" -ForegroundColor Yellow
            $failed += "Azurite"
        }
    }
    Write-Host ""
}

# サマリ
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  インストール結果" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "  ✓ インストール: $($installed.Count) 件" -ForegroundColor Green
$installed | ForEach-Object { Write-Host "      - $_" -ForegroundColor Green }
Write-Host ""
Write-Host "  ○ スキップ (既存): $($skipped.Count) 件" -ForegroundColor Gray
$skipped | ForEach-Object { Write-Host "      - $_" -ForegroundColor Gray }
Write-Host ""
if ($failed.Count -gt 0) {
    Write-Host "  ✗ 失敗: $($failed.Count) 件" -ForegroundColor Red
    $failed | ForEach-Object { Write-Host "      - $_" -ForegroundColor Red }
    Write-Host ""
}

Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "重要: 新しい PowerShell ウィンドウを開いて PATH を再読み込みしてください。" -ForegroundColor Yellow
Write-Host "      その後 .\check-environment.ps1 で確認できます。" -ForegroundColor Yellow
Write-Host ""
