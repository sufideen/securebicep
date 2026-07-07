// Hub network: the shared, tightly-controlled core of the hub-and-spoke topology.
// Every spoke's egress traffic is designed to transit the hub firewall, and every
// spoke resolves private DNS through the zone owned here - so this is where the
// "layered security" story starts.

@description('Azure region for hub resources.')
param location string

param tags object = {}

@description('Address space for the hub virtual network.')
param addressPrefix string = '10.0.0.0/16'

param firewallSubnetPrefix string = '10.0.0.0/26'
param bastionSubnetPrefix string = '10.0.1.0/26'
param sharedSubnetPrefix string = '10.0.2.0/24'

@description('Deploy Azure Firewall to inspect and control all spoke egress traffic. Keep this true for a genuine zero-trust posture; set false only for a quick, low-cost smoke test.')
param deployFirewall bool = true

@description('Deploy Azure Bastion so operators never need a public IP or open RDP/SSH to reach a VM.')
param deployBastion bool = true

@description('Address prefixes of every spoke network. Used to scope the firewall egress rule to known ranges only, instead of 0.0.0.0/0.')
param spokeAddressPrefixes array = []

param logAnalyticsRetentionDays int = 30

var vnetName = 'vnet-hub'
var privateDnsZoneName = 'privatelink.blob.core.windows.net'

// Centralized logging: every spoke's diagnostic settings point back to this workspace.
module logAnalytics '../modules/monitoring/logAnalytics.bicep' = {
  name: 'deploy-hub-law'
  params: {
    name: 'log-hub-${uniqueString(resourceGroup().id)}'
    location: location
    tags: tags
    retentionInDays: logAnalyticsRetentionDays
  }
}

// Microsoft requires (and recommends) a dedicated NSG on AzureBastionSubnet with this
// exact rule set - see https://learn.microsoft.com/azure/bastion/bastion-nsg
module bastionNsg '../modules/network/nsg.bicep' = if (deployBastion) {
  name: 'deploy-nsg-bastion'
  params: {
    name: 'nsg-bastion'
    location: location
    tags: tags
    securityRules: [
      {
        name: 'AllowHttpsInbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowGatewayManagerInbound'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'GatewayManager'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowAzureLoadBalancerInbound'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowBastionHostCommunication'
        properties: {
          priority: 130
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: ['8080', '5701']
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
        name: 'AllowSshRdpOutbound'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: ['22', '3389']
        }
      }
      {
        name: 'AllowAzureCloudOutbound'
        properties: {
          priority: 110
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureCloud'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowBastionCommunicationOutbound'
        properties: {
          priority: 120
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: ['8080', '5701']
        }
      }
      {
        name: 'AllowGetSessionInformation'
        properties: {
          priority: 130
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '80'
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

// Shared-services subnet: deny-by-default, only intra-vnet traffic allowed.
module sharedNsg '../modules/network/nsg.bicep' = {
  name: 'deploy-nsg-shared'
  params: {
    name: 'nsg-shared'
    location: location
    tags: tags
    securityRules: [
      {
        name: 'AllowVirtualNetworkInbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '*'
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
    ]
  }
}

module vnet '../modules/network/vnet.bicep' = {
  name: 'deploy-hub-vnet'
  params: {
    name: vnetName
    location: location
    tags: tags
    addressPrefixes: [addressPrefix]
    // NB: Microsoft advises against attaching an NSG directly to AzureFirewallSubnet -
    // the firewall itself is the security boundary for that subnet.
    subnets: concat([
      {
        name: 'AzureFirewallSubnet'
        addressPrefix: firewallSubnetPrefix
      }
      {
        name: 'snet-shared'
        addressPrefix: sharedSubnetPrefix
        nsgId: sharedNsg.outputs.id
      }
    ], deployBastion ? [
      {
        name: 'AzureBastionSubnet'
        addressPrefix: bastionSubnetPrefix
        nsgId: bastionNsg.outputs.id
      }
    ] : [])
  }
}

module firewall '../modules/network/firewall.bicep' = if (deployFirewall) {
  name: 'deploy-hub-firewall'
  params: {
    name: 'afw-hub'
    location: location
    tags: tags
    subnetId: filter(vnet.outputs.subnets, s => s.name == 'AzureFirewallSubnet')[0].id
    spokeAddressPrefixes: spokeAddressPrefixes
  }
}

module bastion '../modules/network/bastion.bicep' = if (deployBastion) {
  name: 'deploy-hub-bastion'
  params: {
    name: 'bas-hub'
    location: location
    tags: tags
    subnetId: filter(vnet.outputs.subnets, s => s.name == 'AzureBastionSubnet')[0].id
  }
}

// Centralized private DNS: every spoke links to this zone instead of owning its own,
// so blob-storage name resolution is consistent no matter which spoke you're in.
module privateDnsZone '../modules/network/privateDnsZone.bicep' = {
  name: 'deploy-private-dns-zone'
  params: {
    zoneName: privateDnsZoneName
    tags: tags
    vnetId: vnet.outputs.id
    vnetLinkName: 'link-hub'
  }
}

output vnetId string = vnet.outputs.id
output vnetName string = vnet.outputs.name
output firewallPrivateIp string = deployFirewall ? firewall.outputs.privateIp : ''
output privateDnsZoneName string = privateDnsZone.outputs.name
output logAnalyticsWorkspaceId string = logAnalytics.outputs.id
