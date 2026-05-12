# Meeting Minutes Azure IaC

`infra/bicep` は議事録生成に必要な Azure リソースを作成します。

## 作成されるリソース

- Azure Storage Account
  - Blob container: 音声公開 / transcript 保存用
  - Queue: `minutes-jobs`
- Azure AI Speech resource
  - Speech-to-text
  - Speaker Recognition
- Azure Function App
  - Microsoft Graph webhook 受信用
- Application Insights

## デプロイ

```powershell
cd C:\PRJ2\dev2\infra
.\deploy-azure.ps1 -WhatIf
.\deploy-azure.ps1 -Yes
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
