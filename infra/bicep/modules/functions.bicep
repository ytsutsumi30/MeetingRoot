// ============================================================
// Azure Function App (Consumption Plan / Node.js 20)
// ============================================================
@description('Function App 名')
param appName string

@description('リージョン')
param location string

@description('共有ストレージ接続文字列')
@secure()
param storageConnString string

@description('Node.js バージョン')
param nodeVersion string = '~20'

@description('共通タグ')
param tags object = {}

// Application Insights (任意・推奨)
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${appName}-insights'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// Consumption Plan (Linux) - 共有プランを参照 (新規作成はクォータ制約により不可)
resource hostingPlan 'Microsoft.Web/serverfarms@2022-09-01' existing = {
  name: 'JapanEastLinuxDynamicPlan'
}

// Function App
resource functionApp 'Microsoft.Web/sites@2022-09-01' = {
  name: appName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: hostingPlan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'Node|22'
      use32BitWorkerProcess: false
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      cors: {
        allowedOrigins: [
          'https://ytsutsumi30.github.io'
          'https://portal.azure.com'
        ]
      }
      appSettings: [
        { name: 'AzureWebJobsStorage',                   value: storageConnString }
        { name: 'FUNCTIONS_EXTENSION_VERSION',           value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME',              value: 'node' }
        { name: 'APPINSIGHTS_INSTRUMENTATIONKEY',        value: appInsights.properties.InstrumentationKey }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
        { name: 'AZURE_STORAGE_CONNECTION_STRING',       value: storageConnString }
        { name: 'AZURE_QUEUE_NAME',                      value: 'minutes-jobs' }
        { name: 'AZURE_BLOB_CONTAINER',                  value: 'transcripts' }
        // 以下はデプロイ後に手動で設定 (KeyVault推奨)
        // { name: 'MS_TENANT_ID',          value: '...' }
        // { name: 'MS_CLIENT_ID',          value: '...' }
        // { name: 'MS_CLIENT_SECRET',      value: '...' }
        // { name: 'WEBHOOK_CLIENT_STATE',  value: '...' }
      ]
    }
  }
}

// ─── Outputs ─────────────────────────────────────────
output functionAppId string      = functionApp.id
output functionAppName string    = functionApp.name
output defaultHostName string    = functionApp.properties.defaultHostName
output principalId string        = functionApp.identity.principalId
output appInsightsName string    = appInsights.name
output webhookUrlSample string   = 'https://${functionApp.properties.defaultHostName}/api/notifications'
