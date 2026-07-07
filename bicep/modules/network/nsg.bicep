@description('Name of the network security group.')
param name string

@description('Azure region for the NSG.')
param location string

@description('Resource tags.')
param tags object = {}

@description('Security rules to attach. Each item follows the standard Microsoft.Network/networkSecurityGroups/securityRules schema.')
param securityRules array = []

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    securityRules: securityRules
  }
}

output id string = nsg.id
output name string = nsg.name
