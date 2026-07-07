@description('Name of the virtual network.')
param name string

param location string

param tags object = {}

@description('CIDR ranges assigned to the virtual network.')
param addressPrefixes array

@description('Subnets to create. Each item: { name, addressPrefix, nsgId?, routeTableId?, serviceEndpoints?, delegations?, privateEndpointNetworkPolicies? }')
param subnets array

@description('Custom DNS servers for the virtual network. Leave empty to use Azure-provided DNS.')
param dnsServers array = []

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: addressPrefixes
    }
    dhcpOptions: empty(dnsServers) ? null : {
      dnsServers: dnsServers
    }
    subnets: [for subnet in subnets: {
      name: subnet.name
      properties: union({
        addressPrefix: subnet.addressPrefix
        privateEndpointNetworkPolicies: contains(subnet, 'privateEndpointNetworkPolicies') ? subnet.privateEndpointNetworkPolicies : 'Enabled'
      }, contains(subnet, 'nsgId') ? { networkSecurityGroup: { id: subnet.nsgId } } : {}, contains(subnet, 'routeTableId') ? { routeTable: { id: subnet.routeTableId } } : {}, contains(subnet, 'serviceEndpoints') ? { serviceEndpoints: subnet.serviceEndpoints } : {}, contains(subnet, 'delegations') ? { delegations: subnet.delegations } : {})
    }]
  }
}

output id string = vnet.id
output name string = vnet.name
output subnets array = [for (subnet, i) in subnets: {
  name: subnet.name
  id: vnet.properties.subnets[i].id
}]
