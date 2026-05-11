# 議事録機能 ローカル開発環境セットアップ手順

**目的**: Windows 上で **Azurite + Azure Functions Core Tools + Azure Speech** を使った
議事録機能の最小ローカル開発環境を構築する。IaC (Bicep) で再現可能。

**作成日**: 2026-05-10
**対象OS**: Windows 10 / 11 (PowerShell 5.1+)

---

## 完成イメージ

```
┌─────────────────────────────────────────────────────────────┐
│ ローカルPC                                                    │
│                                                             │
│   ┌─────────────┐   ┌──────────────┐   ┌─────────────────┐ │
│   │  Azurite     │   │ Azure        │   │ Express          │ │
│   │ (Storage)    │←─→│ Functions    │←─→│ TestDashboard    │ │
│   │  :10000-2    │   │  :7071        │   │  :3000           │ │
│   └─────────────┘   └──────────────┘   └─────────────────┘ │
│         ↑                  ↑                                │
│         │                  │ HTTP                           │
│   curl テスト         実際は Microsoft Graph                  │
│                                                             │
└─────────────────────────────────────────────────────────────┘
                           ↕ クラウド
┌─────────────────────────────────────────────────────────────┐
│ Azure (本番デプロイ後)                                          │
│   - Storage Account (Blob + Queue)                          │
│   - Speech Service (S0)                                     │
│   - Function App (Consumption Plan)                         │
└─────────────────────────────────────────────────────────────┘
```

---

## ファイル構成（IaC込み）

```
C:\PRJ2\dev2\
├── infra\                                ← IaC + 自動化スクリプト
│   ├── check-environment.ps1              [Phase 0] 環境調査
│   ├── install-tools.ps1                  [Phase 1] 不足ツールインストール
│   ├── start-local-dev.ps1                [Phase 2] Azurite + Functions 起動
│   ├── deploy-azure.ps1                   [Phase 3] Bicep デプロイ
│   └── bicep\
│       ├── main.bicep                     ルートテンプレ
│       ├── parameters.local.json          dev環境パラメータ
│       └── modules\
│           ├── storage.bicep              Storage Account
│           ├── speech.bicep               Speech Service
│           └── functions.bicep            Function App
│
├── functions\                             ← Azure Functions プロジェクト
│   ├── package.json
│   ├── host.json
│   ├── local.settings.json.example        環境変数テンプレ
│   ├── .gitignore
│   └── notifications\                     HTTP Trigger Webhook
│       ├── function.json
│       └── index.js
│
└── MeetingMinutes_LocalDev_Setup.md       ← このファイル
```

---

## Phase 0: 現在の環境調査

まず、PCに何がインストールされているかを自動チェックします。

```powershell
cd C:\PRJ2\dev2\infra
powershell -ExecutionPolicy Bypass -File .\check-environment.ps1
```

### チェック項目

- [ ] Node.js (v20以上)
- [ ] npm
- [ ] .NET 8 SDK
- [ ] Azure CLI
- [ ] Azure Functions Core Tools v4
- [ ] Bicep CLI
- [ ] Azurite (npm package)
- [ ] Git
- [ ] cloudflared (任意)
- [ ] VS Code (任意)
- [ ] PowerShell ExecutionPolicy が `RemoteSigned` 以上
- [ ] winget が利用可能
- [ ] ポート 3000/7071/10000-10002 が空き

実行結果は色付きで表示され、`infra\check-result.json` にも保存されます。
**不足している必須ツールがあれば Phase 1 へ進む** こと。

---

## Phase 1: 不足ツールの一括インストール

**管理者権限のPowerShell** を起動して実行:

```powershell
cd C:\PRJ2\dev2\infra
powershell -ExecutionPolicy Bypass -File .\install-tools.ps1
```

このスクリプトが行うこと:

1. winget で以下を一括インストール（既存のものはスキップ）
   - Node.js LTS
   - .NET 8 SDK
   - Azure CLI
   - Azure Functions Core Tools v4
   - Bicep CLI
   - Git
   - cloudflared
2. npm で Azurite をグローバルインストール

### オプション

```powershell
# 特定ツールのみ
.\install-tools.ps1 -Only Node,FuncTools

# Azurite はスキップ
.\install-tools.ps1 -SkipAzurite

# 既にあっても強制再インストール
.\install-tools.ps1 -Force
```

### インストール後

新しい PowerShell ウィンドウを開いて PATH を再読み込みしてから、再度 `check-environment.ps1` で全ツールが緑になることを確認。

### チェックリスト

- [ ] `node --version` で v20 以上
- [ ] `npm --version` 表示
- [ ] `dotnet --version` 表示
- [ ] `az --version` 表示
- [ ] `func --version` で v4 系表示
- [ ] `bicep --version` 表示
- [ ] `azurite --version` 表示

---

## Phase 2: ローカル開発環境の起動と動作確認

### Step 1. ローカル起動（自動）

```powershell
cd C:\PRJ2\dev2\infra
powershell -ExecutionPolicy Bypass -File .\start-local-dev.ps1
```

スクリプトが自動的に行うこと:

1. 必要ツールの存在確認
2. `functions\local.settings.json` が無ければ `.example` からコピー
3. `azurite-data\` フォルダ作成
4. **別ウィンドウで Azurite 起動** (port 10000/10001/10002)
5. **別ウィンドウで Azure Functions 起動** (port 7071)
6. 各サービスの疎通確認

### Step 2. 動作確認（curl テスト）

#### Webhook 検証エンドポイント
```powershell
curl.exe "http://localhost:7071/api/notifications?validationToken=test123"
```
→ レスポンスが `test123` (そのまま返却) になれば OK

#### 通知受信テスト（擬似 Microsoft Graph 通知）
```powershell
curl.exe -X POST http://localhost:7071/api/notifications `
  -H "Content-Type: application/json" `
  -d '{"value":[{"changeType":"created","clientState":"long-random-string-for-validation","resource":"communications/onlineMeetings(\"AAMk...\")/transcripts(\"MSMm...\")"}]}'
```
→ レスポンス `{"ok":true,"processed":1}`

#### Azurite Queue を確認
```powershell
az storage message peek `
  --queue-name minutes-jobs `
  --connection-string "UseDevelopmentStorage=true"
```
→ メッセージ（meetingId/transcriptId 含む JSON）が表示されれば、Functions → Queue の連携 OK

### Step 3. ブラウザ確認

Azurite Blob を簡易確認:
```
http://127.0.0.1:10000/devstoreaccount1?comp=list
```
→ XML で空のコンテナリストが表示されれば OK

### チェックリスト

- [ ] Azurite ウィンドウが「listening on 10000/10001/10002」を表示
- [ ] Functions ウィンドウが「Functions: notifications: ...」を表示
- [ ] `curl ?validationToken=test123` で `test123` が返る
- [ ] 通知 POST が `{"ok":true}` を返す
- [ ] Azurite Queue にメッセージが入る

---

## Phase 3: Azure リソース デプロイ (Bicep IaC)

ローカル開発が動いたら、Azure 上に同等リソースをプロビジョニングします。
Bicep で **再現可能・宣言的** に管理します。

### 前提

- [ ] Azure サブスクリプションあり
- [ ] `az login` でサインイン済み
  ```powershell
  az login --tenant <YOUR_TENANT_ID>
  az account set --subscription <SUBSCRIPTION_ID>
  ```

### Step 1. デプロイ前プレビュー (what-if)

実際に作る前に差分を確認:

```powershell
cd C:\PRJ2\dev2\infra
.\deploy-azure.ps1 -WhatIf
```

### Step 2. 本デプロイ

```powershell
.\deploy-azure.ps1
```

スクリプトが行うこと:

1. Azure CLI でサインイン状態確認
2. Resource Group `rg-meeting-minutes-dev` を作成（既存ならスキップ）
3. Bicep テンプレを `az deployment group create` で適用
4. デプロイ outputs を取得し表示
5. Speech Key と Storage Connection String を取得
6. `C:\PRJ2\dev2\.env.azure` を自動生成

### 作成されるリソース

| リソース | 名前パターン | SKU |
|---|---|---|
| Resource Group | `rg-meeting-minutes-dev` | - |
| Storage Account | `meetminst<dev環境ID>` | Standard_LRS |
| Blob Container | `transcripts` | - |
| Queue | `minutes-jobs` | - |
| Speech Service | `meetmin-speech-dev-<id>` | S0 |
| Function App | `meetmin-fn-dev-<id>` | Consumption (Y1) |
| Application Insights | `meetmin-fn-dev-<id>-insights` | Web |

### Step 3. Functions コードをAzureへデプロイ

```powershell
cd C:\PRJ2\dev2\functions
func azure functionapp publish meetmin-fn-dev-<id>
```

### Step 4. Webhook URL 確認

```powershell
$webhookUrl = "https://meetmin-fn-dev-<id>.azurewebsites.net/api/notifications"
curl.exe "$webhookUrl?validationToken=test"
```
→ `test` が返ればクラウド側もOK

### チェックリスト

- [ ] `az login` でサインイン
- [ ] `.\deploy-azure.ps1 -WhatIf` で差分確認
- [ ] `.\deploy-azure.ps1` でデプロイ完了
- [ ] `.env.azure` が自動生成された
- [ ] Functions コード publish 完了
- [ ] Webhook URL に curl で test 値が返る
- [ ] Azure Portal で Storage / Speech / Function App が表示される

---

## Phase 4: 統合動作確認 (E2E)

### ローカル

- [ ] `start-local-dev.ps1` 実行
- [ ] Azurite起動を確認
- [ ] Functions起動を確認
- [ ] curl での疎通確認 (validation + notification)
- [ ] Azurite Queue にメッセージが入っている

### Azure クラウド

- [ ] Bicep デプロイ完了
- [ ] Functions コード公開
- [ ] cloudflared 不要で直接 https URL でアクセス可能
- [ ] Application Insights にトレースが流れている

### Microsoft Graph 連携

- [ ] Azure AD App Registration（管理者依頼経由）完了
- [ ] `OnlineMeetingTranscript.Read.All` 権限付与
- [ ] `.env.azure` に MS_TENANT_ID / CLIENT_ID / CLIENT_SECRET 設定
- [ ] Functions App Settings に同値を反映
- [ ] Microsoft Graph subscription を作成（PowerShell or Postman）
- [ ] テスト用 Teams 会議で transcript が Webhook 経由で届く

---

## トラブルシューティング

### `azurite : 用語と認識されない`

```powershell
npm install -g azurite
# PowerShell を一度閉じて開き直す
```

### `func : 用語と認識されない`

```powershell
winget install --id Microsoft.Azure.FunctionsCoreTools
# PowerShell を一度閉じて開き直す
```

### `Bicep CLI not found`

```powershell
az bicep install
# または winget install --id Microsoft.Bicep
```

### Azurite が起動しない (`EADDRINUSE :::10000`)

別アプリが使用中:
```powershell
netstat -ano | findstr :10000
taskkill /PID <PID> /F
```

または Azurite を別ポートで起動:
```powershell
azurite --blobPort 11000 --queuePort 11001 --tablePort 11002
```

### Functions 起動時 `JobHost stopped`

`local.settings.json` の `AzureWebJobsStorage` が不正:
- ローカルなら `UseDevelopmentStorage=true` (Azurite 起動済み)
- Azure接続なら正しい接続文字列

### Bicep デプロイ `RoleAssignmentUpdateNotPermitted`

サブスクリプションへのコントリビューター権限が必要。
管理者に **Owner** または **Contributor** ロール付与を依頼。

### `MissingSubscriptionRegistration` エラー

リソースプロバイダ未登録:
```powershell
az provider register --namespace Microsoft.CognitiveServices
az provider register --namespace Microsoft.Web
az provider register --namespace Microsoft.Storage
az provider register --namespace Microsoft.Insights
```

### Azure Functions が node version エラー

```powershell
# Function App 設定でNode 20を強制
az functionapp config appsettings set `
  --name meetmin-fn-dev-<id> `
  --resource-group rg-meeting-minutes-dev `
  --settings "WEBSITE_NODE_DEFAULT_VERSION=~20"
```

---

## クリーンアップ

### ローカル環境

```powershell
# 各ウィンドウで Ctrl+C
# Azurite データ削除
Remove-Item -Recurse C:\PRJ2\dev2\azurite-data
```

### Azure リソース全削除

```powershell
az group delete --name rg-meeting-minutes-dev --yes --no-wait
```

または:

```powershell
.\deploy-azure.ps1 -DeleteExisting
```

---

## 関連ドキュメント

- [`MeetingMinutes_PLAN.md`](./MeetingMinutes_PLAN.md) - 機能設計と全体計画
- [`README.md`](./README.md) - プロジェクト全体ナビ
- [`TestDashboard/README.md`](./TestDashboard/README.md) - 既存サーバー仕様
- [`OccupancyCounter/README.md`](./OccupancyCounter/README.md) - Android 仕様

---

## 想定環境投資

| 項目 | 単位 | 概算 |
|---|---|---|
| Azure サブスク (Pay-As-You-Go) | 初期 | $0 (使用分のみ) |
| Bicep デプロイ後の月額 | dev環境1回稼働 | $5前後 |
| 開発期間中の月額（試用） | 月20会議 × 1時間 | $25前後 |
| 学習コスト | 開発者1名・初学 | 1〜2日 (本ドキュメント込み) |

---

**最終更新**: 2026-05-10
**スクリプト動作確認**: Windows 11 + PowerShell 5.1
