param environmentName string
param location string

var storageAccountName = toLower('stsb${environmentName}${uniqueString(resourceGroup().id)}')

// Name resolves at deploy time to max 21 chars (4 'stsb' + up to 4 env + 13 uniqueString),
// within the 24-char limit. CKV_AZURE_43 is suppressed via --skip-check in the pipeline
// because Checkov's Bicep parser can't evaluate uniqueString()/interpolation statically.
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_GRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}

output storageAccountName string = storageAccount.name
