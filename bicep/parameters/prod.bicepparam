using '../spoke/main.bicep'

param environmentName = 'prod'
param location = 'uksouth'
param tags = {
  Project: 'SecureBicep'
  Environment: 'prod'
  ManagedBy: 'Bicep'
}
param addressPrefix = '10.2.0.0/16'
param appSubnetPrefix = '10.2.0.0/24'
param dataSubnetPrefix = '10.2.1.0/24'
param storageSku = 'Standard_GRS'
param hubResourceGroupName = 'rg-securebicep-hub'
param hubVnetName = 'vnet-hub'
param hubPrivateDnsZoneName = 'privatelink.blob.core.windows.net'

// hubFirewallPrivateIp and logAnalyticsWorkspaceId can only be known once the hub
// stage has actually deployed. The pipeline reads them from the hub deployment's
// outputs and overrides these defaults at deploy time - see azure-pipelines.yml.
param hubFirewallPrivateIp = ''
param logAnalyticsWorkspaceId = ''
