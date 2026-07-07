@description('Name of the Log Analytics workspace.')
param name string

param location string

param tags object = {}

@description('Retention period in days. Use a longer window in production for security investigations.')
param retentionInDays int = 30

param sku string = 'PerGB2018'

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    sku: {
      name: sku
    }
    retentionInDays: retentionInDays
  }
}

output id string = workspace.id
output name string = workspace.name
