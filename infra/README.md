# Meeting Minutes Azure IaC

`infra/bicep` は議事録生成に必要な Azure リソースを作成します。

## 作成されるリソース

- Azure Storage Account
  - Blob container: 音声公開 / transcript 保存用
  - Queue: `minutes-jobs`
- Azure AI Speech resource
  - Speech-to-text
  - Speaker Recognition
- Azure Function App（任意）
  - Microsoft Graph webhook 受信用
- Application Insights（任意）

## デプロイ

```powershell
cd C:\PRJ2\dev2\infra
.\deploy-azure.ps1 -WhatIf
.\deploy-azure.ps1 -Yes
```

既定では `Azure Storage` と `Azure AI Speech` のみを作成します。
Azure Function App と Application Insights も作成する場合は、サブスクリプションの Dynamic VM quota と `Microsoft.OperationalInsights` provider を確認してから次を実行してください。

```powershell
az provider register --namespace Microsoft.OperationalInsights
.\deploy-azure.ps1 -Yes -DeployFunctions
```

SKUを変える場合:

```powershell
.\deploy-azure.ps1 -SpeechSku F0 -Yes
```

## 出力

デプロイ後、ルートに `C:\PRJ2\dev2\.env.azure` が生成されます。
このファイルには `AZURE_SPEECH_KEY`、`SPEAKER_RECOGNITION_KEY`、`AZURE_STORAGE_CONNECTION_STRING` などの秘密情報が含まれるため、Gitにはコミットしません。

`TestDashboard` で利用するには、`.env.azure` の必要値を `C:\PRJ2\dev2\TestDashboard\.env` にコピーするか、PowerShellで読み込んでから `npm start` してください。

```powershell
cd C:\PRJ2\dev2\TestDashboard

Get-Content ..\.env.azure | ForEach-Object {
  if ($_ -match '^([^#][^=]+)=(.*)$') {
    [Environment]::SetEnvironmentVariable($matches[1].Trim(), $matches[2].Trim(), 'Process')
  }
}

npm start
```

起動ログで以下になれば、Android録音が実Azure Speechで文字起こしされます。

```text
Speech mock: false
Claude mock: false
```

## 手動設定が必要な値

以下はIaCでは作成せず、`.env.azure` へ手動入力します。

- `MS_TENANT_ID`
- `MS_CLIENT_ID`
- `MS_CLIENT_SECRET`
- `MS_USER_UPN`
- `ANTHROPIC_API_KEY`
- `WEBHOOK_CLIENT_STATE`

## Microsoft Graph アプリ登録

`MS_CLIENT_ID`、`MS_CLIENT_SECRET`、`WEBHOOK_CLIENT_STATE` は次のスクリプトで作成・反映できます。

```powershell
cd C:\PRJ2\dev2\infra
.\setup-graph-app.ps1
```

テナント管理者権限がある場合は、Graph API 権限の admin consent までまとめて実行できます。

```powershell
.\setup-graph-app.ps1 -GrantAdminConsent
```

既存 secret を更新する場合:

```powershell
.\setup-graph-app.ps1 -RotateSecret
```

スクリプトは以下を更新します。

- `C:\PRJ2\dev2\.env.azure`
- `C:\PRJ2\dev2\TestDashboard\.env`

付与する Microsoft Graph Application permissions:

- `Files.ReadWrite.All`
- `OnlineMeetings.Read.All`
- `OnlineMeetingTranscript.Read.All`
- `OnlineMeetingRecording.Read.All`
- `User.Read.All`
