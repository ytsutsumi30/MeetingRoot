// ============================================================
// Storage Account (Blob + Queue)
// ============================================================
@description('Storage Account 名 (3-24文字, 小文字英数のみ)')
@minLength(3)
@maxLength(24)
param name string

@description('リージョン')
param location string

@description('共通タグ')
param tags object = {}

@description('Blob Container 名 (議事録 transcript 保存用)')
param containerName string = 'transcripts'

@description('Queue 名 (Express への job 通知)')
param queueName string = 'minutes-jobs'

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    accessTier: 'Hot'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    deleteRetentionPolicy: { enabled: true, days: 7 }
  }
}

resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: containerName
  properties: {
    publicAccess: 'None'
  }
}

resource queueService 'Microsoft.Storage/storageAccounts/queueServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource queue 'Microsoft.Storage/storageAccounts/queueServices/queues@2023-05-01' = {
  parent: queueService
  name: queueName
}

// ─── Table Storage (Subscription Lifecycle 状態管理) ─────────────
@description('Graph Subscription 状態管理用 Table 名')
param subscriptionTableName string = 'subscriptions'

resource tableService 'Microsoft.Storage/storageAccounts/tableServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource subscriptionsTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01' = {
  parent: tableService
  name: subscriptionTableName
}

// ─── Outputs ─────────────────────────────────────────
output storageAccountId string        = storage.id
output storageAccountName string      = storage.name
output containerName string           = container.name
output queueName string               = queue.name
output subscriptionTableName string   = subscriptionsTable.name

// 接続文字列 (Functions/Express 両方で使用)
@secure()
output connectionString string = 'DefaultEndpointsProtocol=https;AccountName=${storage.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storage.listKeys().keys[0].value}'
