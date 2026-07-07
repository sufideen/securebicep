@description('Name of the route table.')
param name string

param location string

param tags object = {}

@description('Disable propagation of on-prem/ExpressRoute BGP routes. Keep true so the firewall route always wins - a core zero-trust control.')
param disableBgpRoutePropagation bool = true

@description('Routes to add. Each item: { name, addressPrefix, nextHopType, nextHopIpAddress? }')
param routes array = []

resource routeTable 'Microsoft.Network/routeTables@2023-09-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: disableBgpRoutePropagation
    routes: [for route in routes: {
      name: route.name
      properties: union({
        addressPrefix: route.addressPrefix
        nextHopType: route.nextHopType
      }, contains(route, 'nextHopIpAddress') ? { nextHopIpAddress: route.nextHopIpAddress } : {})
    }]
  }
}

output id string = routeTable.id
