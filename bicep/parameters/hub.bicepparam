using '../hub/main.bicep'

param location = 'eastus'
param tags = {
  Project: 'SecureBicep'
  Environment: 'hub'
  ManagedBy: 'Bicep'
}
param addressPrefix = '10.0.0.0/16'
param firewallSubnetPrefix = '10.0.0.0/26'
param bastionSubnetPrefix = '10.0.1.0/26'
param sharedSubnetPrefix = '10.0.2.0/24'
param deployFirewall = true
param deployBastion = true
param spokeAddressPrefixes = [
  '10.1.0.0/16'
  '10.2.0.0/16'
]
param logAnalyticsRetentionDays = 30
