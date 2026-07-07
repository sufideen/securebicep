@description('Name of the private endpoint.')
param name string

param location string

param tags object = {}

@description('Resource ID of the subnet the private endpoint NIC lands in.')
param subnetId string

@description('Resource ID of the PaaS service being privately connected to (e.g. a storage account).')
param privateLinkServiceId string

@description('Sub-resource(s) being targeted, e.g. [\'blob\'] for a storage account.')
param groupIds array

@description('Resource ID of the private DNS zone (typically owned by the hub) used to auto-register the private IP.')
param privateDnsZoneId string

param privateDnsZoneName string

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    subnet: {
      id: subnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${name}-connection'
        properties: {
          privateLinkServiceId: privateLinkServiceId
          groupIds: groupIds
        }
      }
    ]
  }
}

resource dnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: privateDnsZoneName
        properties: {
          privateDnsZoneId: privateDnsZoneId
        }
      }
    ]
  }
}

output id string = privateEndpoint.id
