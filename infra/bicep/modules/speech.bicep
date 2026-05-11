// ============================================================
// Azure Speech Service
// ============================================================
@description('Speech Service 名')
param name string

@description('リージョン (Conversation Transcription は japaneast 推奨)')
param location string

@description('SKU (F0=無料5h/月, S0=従量課金)')
@allowed(['F0', 'S0'])
param sku string = 'S0'

@description('共通タグ')
param tags object = {}

resource speech 'Microsoft.CognitiveServices/accounts@2023-05-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: sku
  }
  kind: 'SpeechServices'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    customSubDomainName: name
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
    }
  }
}

// ─── Outputs ─────────────────────────────────────────
output resourceId string   = speech.id
output resourceName string = speech.name
output endpoint string     = speech.properties.endpoint
output region string       = location
// API key は output で出さない (デプロイ後 az で取得)
//   az cognitiveservices account keys list -n <name> -g <rg>
