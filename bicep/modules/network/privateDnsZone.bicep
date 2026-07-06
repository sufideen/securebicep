@description('Name of the private DNS zone, e.g. privatelink.blob.core.windows.net.')
param zoneName string

param tags object = {}

@description('Resource ID of the virtual network to link (typically the hub).')
param vnetId string

param vnetLinkName string

param registrationEnabled bool = false

resource zone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: zoneName
  location: 'global'
  tags: tags
}

resource link 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: zone
  name: vnetLinkName
  location: 'global'
  properties: {
    registrationEnabled: registrationEnabled
    virtualNetwork: {
      id: vnetId
    }
  }
}

output id string = zone.id
output name string = zone.name
