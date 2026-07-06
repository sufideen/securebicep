// Spoke network: a single reusable template deployed once per environment (dev, prod, ...).
// Each spoke is isolated from every other spoke - there is no spoke-to-spoke peering -
// so the hub, and its firewall, is the only path between them. That is the whole point
// of hub-and-spoke from a zero-trust perspective: no implicit trust between workloads.

@description('Environment name, e.g. dev or prod. Used for resource naming and tagging.')
param environmentName string

param location string

param tags object = {}

@description('Address space for this spoke virtual network.')
param addressPrefix string

param appSubnetPrefix string
param dataSubnetPrefix string

@allowed([
  'Standard_LRS'
  'Standard_ZRS'
  'Standard_GRS'
  'Standard_RAGRS'
])
@description('Storage redundancy for this environment. Defaults to geo-redundant for every environment; only loosen this deliberately (e.g. Standard_LRS for a throwaway Dev sandbox) if you\'ve accepted the reduced durability.')
param storageSku string = 'Standard_GRS'

@description('Resource group that owns the hub network (vnet, firewall, private DNS zone).')
param hubResourceGroupName string

@description('Name of the hub virtual network.')
param hubVnetName string = 'vnet-hub'

@description('Subscription that owns the hub resource group. Defaults to this deployment\'s subscription, which covers the common single-subscription hub-spoke layout.')
param hubSubscriptionId string = subscription().subscriptionId

@description('Private IP of the hub Azure Firewall. Leave empty if the hub was deployed with deployFirewall=false - spokes then fall back to default system routing instead of forced egress inspection.')
param hubFirewallPrivateIp string = ''

@description('Name of the private DNS zone owned by the hub, e.g. privatelink.blob.core.windows.net.')
param hubPrivateDnsZoneName string = 'privatelink.blob.core.windows.net'

@description('Resource ID of the hub\'s Log Analytics workspace, for centralized diagnostics. Leave empty to skip diagnostic settings.')
param logAnalyticsWorkspaceId string = ''

var vnetName = 'vnet-${environmentName}'
var routeToFirewall = !empty(hubFirewallPrivateIp)
var hubVnetResourceId = resourceId(hubSubscriptionId, hubResourceGroupName, 'Microsoft.Network/virtualNetworks', hubVnetName)

// Application subnet: only accepts HTTPS from inside the vnet, only talks to the data
// subnet on the way out. Everything else is an explicit, auditable deny.
module appNsg '../modules/network/nsg.bicep' = {
  name: 'deploy-nsg-app-${environmentName}'
  params: {
    name: 'nsg-app-${environmentName}'
    location: location
    tags: tags
    securityRules: [
      {
        name: 'AllowHttpsFromVnet'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'DenyAllInbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'AllowHttpsToDataSubnet'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: dataSubnetPrefix
          destinationPortRange: '443'
        }
      }
      {
        name: 'DenyAllOutbound'
        properties: {
          priority: 4096
          direction: 'Outbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// Data subnet: only accepts traffic from the app subnet. This is where the private
// endpoint for storage lives, so nothing here is ever reachable from the internet.
module dataNsg '../modules/network/nsg.bicep' = {
  name: 'deploy-nsg-data-${environmentName}'
  params: {
    name: 'nsg-data-${environmentName}'
    location: location
    tags: tags
    securityRules: [
      {
        name: 'AllowHttpsFromAppSubnet'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: appSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'DenyAllInbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'DenyAllOutbound'
        properties: {
          priority: 4096
          direction: 'Outbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// Force every outbound packet through the hub firewall for inspection - the
// "layered security" backstop behind the NSGs above.
module routeTable '../modules/network/routeTable.bicep' = if (routeToFirewall) {
  name: 'deploy-rt-${environmentName}'
  params: {
    name: 'rt-${environmentName}'
    location: location
    tags: tags
    routes: [
      {
        name: 'DefaultToFirewall'
        addressPrefix: '0.0.0.0/0'
        nextHopType: 'VirtualAppliance'
        nextHopIpAddress: hubFirewallPrivateIp
      }
    ]
  }
}

module vnet '../modules/network/vnet.bicep' = {
  name: 'deploy-vnet-${environmentName}'
  params: {
    name: vnetName
    location: location
    tags: tags
    addressPrefixes: [addressPrefix]
    subnets: [
      union({
        name: 'snet-app'
        addressPrefix: appSubnetPrefix
        nsgId: appNsg.outputs.id
      }, routeToFirewall ? { routeTableId: routeTable.outputs.id } : {})
      union({
        name: 'snet-data'
        addressPrefix: dataSubnetPrefix
        nsgId: dataNsg.outputs.id
        privateEndpointNetworkPolicies: 'Disabled'
      }, routeToFirewall ? { routeTableId: routeTable.outputs.id } : {})
    ]
  }
}

module peerToHub '../modules/network/peering.bicep' = {
  name: 'deploy-peer-${environmentName}-to-hub'
  params: {
    localVnetName: vnet.outputs.name
    peeringName: 'peer-${environmentName}-to-hub'
    remoteVirtualNetworkId: hubVnetResourceId
    allowForwardedTraffic: true
  }
}

module peerFromHub '../modules/network/peering.bicep' = {
  name: 'deploy-peer-hub-to-${environmentName}'
  scope: resourceGroup(hubSubscriptionId, hubResourceGroupName)
  params: {
    localVnetName: hubVnetName
    peeringName: 'peer-hub-to-${environmentName}'
    remoteVirtualNetworkId: vnet.outputs.id
    allowForwardedTraffic: true
  }
}

module dnsZoneLink '../modules/network/privateDnsZoneLink.bicep' = {
  name: 'deploy-dns-link-${environmentName}'
  scope: resourceGroup(hubSubscriptionId, hubResourceGroupName)
  params: {
    zoneName: hubPrivateDnsZoneName
    vnetId: vnet.outputs.id
    linkName: 'link-${environmentName}'
  }
}

module storage '../modules/storage/storageAccount.bicep' = {
  name: 'deploy-storage-${environmentName}'
  params: {
    name: 'st${environmentName}${uniqueString(resourceGroup().id)}'
    location: location
    tags: tags
    sku: storageSku
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
  }
}

// The only path to the storage account: a private endpoint inside the data subnet,
// resolved through the hub's centralized private DNS zone. No public network access.
module storagePrivateEndpoint '../modules/network/privateEndpoint.bicep' = {
  name: 'deploy-pe-storage-${environmentName}'
  params: {
    name: 'pep-st-${environmentName}'
    location: location
    tags: tags
    subnetId: filter(vnet.outputs.subnets, s => s.name == 'snet-data')[0].id
    privateLinkServiceId: storage.outputs.id
    groupIds: ['blob']
    privateDnsZoneId: resourceId(hubSubscriptionId, hubResourceGroupName, 'Microsoft.Network/privateDnsZones', hubPrivateDnsZoneName)
    privateDnsZoneName: hubPrivateDnsZoneName
  }
}

output vnetId string = vnet.outputs.id
output vnetName string = vnet.outputs.name
output storageAccountName string = storage.outputs.name
