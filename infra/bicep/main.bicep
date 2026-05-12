// ============================================================
// Azure リソース IaC - メイン
// ============================================================
//   - Azure Storage Account (Blob + Queue)
//   - Azure Speech Service (S0)
//   - Azure Function App (Consumption Plan)
//
// デプロイ:
//   az deployment group create \
//     --resource-group rg-meeting-minutes \
//     --template-file main.bicep \
//     --parameters @parameters.local.json
// ============================================================

@description('リソース配置リージョン')
param location string = 'japaneast'

@description('プロジェクト識別子 (リソース名のprefix)')
@minLength(3)
@maxLength(12)
param projectName string = 'meetmin'

@description('環境タグ (dev/stg/prod)')
@allowed(['dev', 'stg', 'prod'])
param environment string = 'dev'

@description('Speech Service SKU')
@allowed(['F0', 'S0'])
param speechSku string = 'S0'

// 一意な suffix (ストレージアカウント名は全世界で一意 + 24文字)
var uniqueSuffix = uniqueString(resourceGroup().id, projectName)
var nameSuffix   = '${environment}-${uniqueSuffix}'

var commonTags = {
  Project:     'OccupancyCounter-MeetingMinutes'
  Environment: environment
  ManagedBy:   'Bicep'
}

// ─── Storage Account ─────────────────────────────────────────
module storage 'modules/storage.bicep' = {
  name: 'storage-deployment'
  params: {
    name:     toLower('${projectName}st${replace(nameSuffix, '-', '')}')
    location: location
    tags:     commonTags
  }
}

// ─── Speech Service ──────────────────────────────────────────
module speech 'modules/speech.bicep' = {
  name: 'speech-deployment'
  params: {
    name:     '${projectName}-speech-${nameSuffix}'
    location: location
    sku:      speechSku
    tags:     commonTags
  }
}

// ─── Function App ────────────────────────────────────────────
module functions 'modules/functions.bicep' = {
  name: 'functions-deployment'
  params: {
    appName:           '${projectName}-fn-${nameSuffix}'
    location:          location
    storageConnString: storage.outputs.connectionString
    tags:              commonTags
  }
}

// ─── Outputs (デプロイ後の参照に使用) ───────────────────────
output storageAccountName string = storage.outputs.storageAccountName
output speechEndpoint string     = speech.outputs.endpoint
output speechResourceName string = speech.outputs.resourceName
output speechRegion string       = speech.outputs.region
output functionAppName string    = functions.outputs.functionAppName
output functionAppHostName string = functions.outputs.defaultHostName
output queueName string          = storage.outputs.queueName
output blobContainerName string  = storage.outputs.containerName
