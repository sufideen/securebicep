@description('Name of an existing private DNS zone, owned by the hub, to link a spoke virtual network to. Centralizing private DNS in the hub keeps name resolution consistent across every spoke.')
param zoneName string

@description('Resource ID of the spoke virtual network to link.')
param vnetId string

param linkName string

param registrationEnabled bool = false

resource zone 'Microsoft.Network/privateDnsZones@2024-06-01' existing = {
  name: zoneName
}

resource link 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: zone
  name: linkName
  location: 'global'
  properties: {
    registrationEnabled: registrationEnabled
    virtualNetwork: {
      id: vnetId
    }
  }
}
