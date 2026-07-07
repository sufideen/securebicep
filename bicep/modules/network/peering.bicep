@description('Name of the virtual network that this peering is created on (must exist in the current resource group scope).')
param localVnetName string

@description('Name of the peering resource.')
param peeringName string

@description('Resource ID of the remote virtual network being peered to.')
param remoteVirtualNetworkId string

@description('Allow traffic forwarded by an NVA (e.g. Azure Firewall) in the peered network. Required for hub-spoke designs that route spoke egress through a hub firewall.')
param allowForwardedTraffic bool = false

param allowGatewayTransit bool = false
param useRemoteGateways bool = false

resource localVnet 'Microsoft.Network/virtualNetworks@2023-09-01' existing = {
  name: localVnetName
}

resource peering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  parent: localVnet
  name: peeringName
  properties: {
    remoteVirtualNetwork: {
      id: remoteVirtualNetworkId
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: allowForwardedTraffic
    allowGatewayTransit: allowGatewayTransit
    useRemoteGateways: useRemoteGateways
  }
}
