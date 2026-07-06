// Full-stack orchestrator: creates the hub resource group and one resource group per
// spoke environment, then composes hub/main.bicep and spoke/main.bicep into each.
// Deploy this when you want the whole topology in one shot (e.g. a fresh subscription
// or a local what-if). The pipeline deploys hub/main.bicep and spoke/main.bicep
// independently per stage instead, so a dev change never touches prod in the same run.

targetScope = 'subscription'

@description('Azure region for every resource in the topology.')
param location string = 'eastus'

param tags object = {
  Project: 'SecureBicep'
  ManagedBy: 'Bicep'
}

param hubAddressPrefix string = '10.0.0.0/16'
param hubFirewallSubnetPrefix string = '10.0.0.0/26'
param hubBastionSubnetPrefix string = '10.0.1.0/26'
param hubSharedSubnetPrefix string = '10.0.2.0/24'
param deployFirewall bool = true
param deployBastion bool = true

@description('One item per environment to stand up as a spoke. Add more entries (e.g. staging) without touching any module.')
param spokeEnvironments array = [
  {
    name: 'dev'
    addressPrefix: '10.1.0.0/16'
    appSubnetPrefix: '10.1.0.0/24'
    dataSubnetPrefix: '10.1.1.0/24'
    storageSku: 'Standard_GRS'
  }
  {
    name: 'prod'
    addressPrefix: '10.2.0.0/16'
    appSubnetPrefix: '10.2.0.0/24'
    dataSubnetPrefix: '10.2.1.0/24'
    storageSku: 'Standard_GRS'
  }
]

var hubResourceGroupName = 'rg-securebicep-hub'

resource hubRg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: hubResourceGroupName
  location: location
  tags: union(tags, { Environment: 'hub' })
}

resource spokeRgs 'Microsoft.Resources/resourceGroups@2024-03-01' = [for env in spokeEnvironments: {
  name: 'rg-securebicep-${env.name}'
  location: location
  tags: union(tags, { Environment: env.name })
}]

module hub 'hub/main.bicep' = {
  name: 'deploy-hub'
  scope: hubRg
  params: {
    location: location
    tags: union(tags, { Environment: 'hub' })
    addressPrefix: hubAddressPrefix
    firewallSubnetPrefix: hubFirewallSubnetPrefix
    bastionSubnetPrefix: hubBastionSubnetPrefix
    sharedSubnetPrefix: hubSharedSubnetPrefix
    deployFirewall: deployFirewall
    deployBastion: deployBastion
    spokeAddressPrefixes: [for env in spokeEnvironments: env.addressPrefix]
  }
}

module spokes 'spoke/main.bicep' = [for (env, i) in spokeEnvironments: {
  name: 'deploy-spoke-${env.name}'
  scope: spokeRgs[i]
  params: {
    environmentName: env.name
    location: location
    tags: union(tags, { Environment: env.name })
    addressPrefix: env.addressPrefix
    appSubnetPrefix: env.appSubnetPrefix
    dataSubnetPrefix: env.dataSubnetPrefix
    storageSku: env.storageSku
    hubResourceGroupName: hubResourceGroupName
    hubVnetName: hub.outputs.vnetName
    hubFirewallPrivateIp: hub.outputs.firewallPrivateIp
    hubPrivateDnsZoneName: hub.outputs.privateDnsZoneName
    logAnalyticsWorkspaceId: hub.outputs.logAnalyticsWorkspaceId
  }
}]
