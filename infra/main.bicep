targetScope = 'subscription'

@description('Short name of the environment this deployment targets, e.g. dev, test, prod.')
param environmentName string

@description('Azure region for the resource group and its resources.')
param location string = deployment().location

var resourceGroupName = 'rg-securebicep-${environmentName}'

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: {
    environment: environmentName
    managedBy: 'azure-pipelines'
  }
}

module storage 'modules/storage-account.bicep' = {
  name: 'storage-${environmentName}'
  scope: rg
  params: {
    environmentName: environmentName
    location: location
  }
}

output resourceGroupName string = rg.name
output storageAccountName string = storage.outputs.storageAccountName
