@description('Name of the Azure Firewall.')
param name string

param location string

param tags object = {}

@description('Resource ID of the AzureFirewallSubnet.')
param subnetId string

@allowed([
  'Standard'
  'Premium'
])
param skuTier string = 'Standard'

@description('Spoke address prefixes allowed to reach the internet over HTTPS. Tighten this to specific FQDNs/application rules for production use - this starter rule is intentionally broad so the reference architecture deploys cleanly.')
param spokeAddressPrefixes array = []

resource publicIp 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: 'pip-${name}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource firewall 'Microsoft.Network/azureFirewalls@2023-09-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: skuTier
    }
    threatIntelMode: 'Deny'
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: subnetId
          }
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
    networkRuleCollections: [
      {
        name: 'AllowSpokeEgress'
        properties: {
          priority: 100
          action: {
            type: 'Allow'
          }
          rules: [
            {
              name: 'AllowHttpsOutbound'
              protocols: ['TCP']
              sourceAddresses: spokeAddressPrefixes
              destinationAddresses: ['*']
              destinationPorts: ['443']
            }
          ]
        }
      }
    ]
  }
}

output id string = firewall.id
output privateIp string = firewall.properties.ipConfigurations[0].properties.privateIPAddress
