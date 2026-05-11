# ============================================================
# Phase 0: 現在の環境調査スクリプト
# ============================================================
# Windows 上で Azurite + Azure Functions + Azure Speech を使った
# 議事録機能ローカル開発に必要なツールが揃っているか確認します。
#
# 使い方:
#   powershell -ExecutionPolicy Bypass -File .\check-environment.ps1
# ============================================================

$ErrorActionPreference = "Continue"
$Host.UI.RawUI.WindowTitle = "Meeting Minutes - Environment Check"

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  議事録機能 ローカル開発環境 チェック" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# ─── ヘルパー関数 ───────────────────────────────────────────────────
function Test-Tool {
    param(
        [string]$Name,
        [string]$Command,
        [string]$VersionArg = "--version",
        [string]$WingetId = "",
        [bool]$Required = $true,
        [string]$ExtraNote = ""
    )
    $result = [PSCustomObject]@{
        Name      = $Name
        Command   = $Command
        Installed = $false
        Version   = ""
        Required  = $Required
        WingetId  = $WingetId
        Note      = $ExtraNote
    }
    try {
        $cmdInfo = Get-Command $Command -ErrorAction Stop
        $output  = & $Command $VersionArg 2>&1 | Out-String
        $result.Installed = $true
        $result.Version   = $output.Trim().Split("`n")[0].Trim()
    } catch {
        $result.Installed = $false
    }
    return $result
}

function Show-Result {
    param($R)
    if ($R.Installed) {
        $mark = "✓"; $color = "Green"
    } elseif ($R.Required) {
        $mark = "✗"; $color = "Red"
    } else {
        $mark = "○"; $color = "Yellow"
    }
    $reqLabel = if ($R.Required) { "[必須]" } else { "[任意]" }
    Write-Host ("  {0} {1,-30} {2,-8}" -f $mark, $R.Name, $reqLabel) -ForegroundColor $color -NoNewline
    if ($R.Installed) {
        Write-Host " $($R.Version)" -ForegroundColor Gray
    } else {
        Write-Host " 未インストール" -ForegroundColor DarkRed -NoNewline
        if ($R.WingetId) {
            Write-Host "  → winget install --id $($R.WingetId)" -ForegroundColor DarkGray
        } else {
            Write-Host ""
        }
    }
    if ($R.Note) {
        Write-Host "      $($R.Note)" -ForegroundColor DarkGray
    }
}

# ─── 必要なツール一覧 ──────────────────────────────────────────────
Write-Host "[1] 開発ランタイム" -ForegroundColor Yellow
$results = @()
$results += Test-Tool -Name "Node.js"   -Command "node" -VersionArg "--version" -WingetId "OpenJS.NodeJS.LTS" -ExtraNote "v20以上推奨"
$results += Test-Tool -Name "npm"       -Command "npm"  -VersionArg "--version"
$results += Test-Tool -Name ".NET SDK"  -Command "dotnet" -VersionArg "--version" -WingetId "Microsoft.DotNet.SDK.8" -ExtraNote "Azure Functions が依存"
$results | Where-Object { $_.Name -in @("Node.js","npm",".NET SDK") } | ForEach-Object { Show-Result $_ }
Write-Host ""

Write-Host "[2] Azure 関連ツール" -ForegroundColor Yellow
$azureResults = @()
$azureResults += Test-Tool -Name "Azure CLI"            -Command "az"   -VersionArg "version" -WingetId "Microsoft.AzureCLI" -ExtraNote "az login で認証"
$azureResults += Test-Tool -Name "Functions Core Tools" -Command "func" -VersionArg "--version" -WingetId "Microsoft.Azure.FunctionsCoreTools" -ExtraNote "v4 系を推奨"
$azureResults += Test-Tool -Name "Bicep CLI"            -Command "bicep" -VersionArg "--version" -WingetId "Microsoft.Bicep" -ExtraNote "IaCデプロイ用"
$azureResults += Test-Tool -Name "Azurite"              -Command "azurite" -VersionArg "--version" -ExtraNote "npm install -g azurite"
$azureResults | ForEach-Object { Show-Result $_ }
$results += $azureResults
Write-Host ""

Write-Host "[3] 補助ツール" -ForegroundColor Yellow
$auxResults = @()
$auxResults += Test-Tool -Name "Git"          -Command "git"  -VersionArg "--version" -WingetId "Git.Git"
$auxResults += Test-Tool -Name "cloudflared"  -Command "cloudflared" -VersionArg "--version" -WingetId "Cloudflare.cloudflared" -ExtraNote "ローカル開発で外部公開する場合"
$auxResults += Test-Tool -Name "VS Code"      -Command "code" -VersionArg "--version" -WingetId "Microsoft.VisualStudioCode" -Required $false
$auxResults | ForEach-Object { Show-Result $_ }
$results += $auxResults
Write-Host ""

# ─── ポート使用状況確認 ────────────────────────────────────────────
Write-Host "[4] ポート使用状況 (ローカル開発で使用予定)" -ForegroundColor Yellow
$ports = @(
    @{ Port = 3000;  Name = "TestDashboard (既存)" },
    @{ Port = 7071;  Name = "Azure Functions" },
    @{ Port = 10000; Name = "Azurite Blob" },
    @{ Port = 10001; Name = "Azurite Queue" },
    @{ Port = 10002; Name = "Azurite Table" }
)
foreach ($p in $ports) {
    $netstat = netstat -ano | Select-String ":$($p.Port)\s.*LISTENING"
    if ($netstat) {
        $procId = ($netstat -split '\s+')[-1]
        Write-Host ("  ⚠️  Port {0,-5} {1,-25} 使用中 (PID: {2})" -f $p.Port, $p.Name, $procId) -ForegroundColor Yellow
    } else {
        Write-Host ("  ✓  Port {0,-5} {1,-25} 空き" -f $p.Port, $p.Name) -ForegroundColor Green
    }
}
Write-Host ""

# ─── PowerShell ExecutionPolicy ────────────────────────────────────
Write-Host "[5] PowerShell ExecutionPolicy" -ForegroundColor Yellow
$ep = Get-ExecutionPolicy
if ($ep -in @("RemoteSigned","Unrestricted","Bypass")) {
    Write-Host "  ✓ 現在: $ep (スクリプト実行可)" -ForegroundColor Green
} else {
    Write-Host "  ✗ 現在: $ep (スクリプト実行不可)" -ForegroundColor Red
    Write-Host "    対処: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned" -ForegroundColor DarkGray
}
Write-Host ""

# ─── winget 確認 ────────────────────────────────────────────────────
Write-Host "[6] winget (パッケージマネージャ)" -ForegroundColor Yellow
try {
    $wingetVersion = winget --version 2>&1 | Out-String
    Write-Host "  ✓ winget $($wingetVersion.Trim())" -ForegroundColor Green
} catch {
    Write-Host "  ✗ winget が見つかりません" -ForegroundColor Red
    Write-Host "    対処: Microsoft Store で「アプリ インストーラー」を更新" -ForegroundColor DarkGray
}
Write-Host ""

# ─── サマリ ────────────────────────────────────────────────────────
$missing = $results | Where-Object { -not $_.Installed -and $_.Required }
$missingOpt = $results | Where-Object { -not $_.Installed -and -not $_.Required }

Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  結果サマリ" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
$installed = ($results | Where-Object { $_.Installed }).Count
$total     = $results.Count
Write-Host ""
Write-Host "  インストール済: $installed / $total ツール" -ForegroundColor Cyan
Write-Host ""

if ($missing.Count -eq 0) {
    Write-Host "  ✓ すべての必須ツールがインストール済みです！" -ForegroundColor Green
    Write-Host "  → 次のステップ: .\start-local-dev.ps1 で開発環境を起動できます" -ForegroundColor Green
} else {
    Write-Host "  ⚠ 不足している必須ツール ($($missing.Count) 件):" -ForegroundColor Yellow
    foreach ($m in $missing) {
        Write-Host "      - $($m.Name)" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "  → 次のステップ: 管理者PowerShellで .\install-tools.ps1 を実行" -ForegroundColor Yellow
}

if ($missingOpt.Count -gt 0) {
    Write-Host ""
    Write-Host "  ○ 任意 (未インストールでもOK):" -ForegroundColor Gray
    foreach ($m in $missingOpt) {
        Write-Host "      - $($m.Name)" -ForegroundColor Gray
    }
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# 結果を JSON で出力 (CI/IaCから読める)
$jsonPath = Join-Path $PSScriptRoot "check-result.json"
$results | ConvertTo-Json -Depth 3 | Out-File -FilePath $jsonPath -Encoding UTF8
Write-Host "詳細結果: $jsonPath" -ForegroundColor DarkGray
