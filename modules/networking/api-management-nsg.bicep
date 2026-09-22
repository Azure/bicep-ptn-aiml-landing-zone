targetScope = 'resourceGroup'

@description('Name of the network security group for the API Management subnet.')
param name string

@description('Azure region for the network security group.')
param location string = resourceGroup().location

@minLength(1)
@description('Hub firewall source CIDRs allowed to reach the internal API Management gateway on TCP 443.')
param ingressSourceAddressPrefixes array

@description('Tags to apply to the network security group.')
param tags object = {}

resource apiManagementNsg 'Microsoft.Network/networkSecurityGroups@2024-07-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowApiManagementControlPlane'
        properties: {
          access: 'Allow'
          description: 'Allow Azure API Management control-plane access.'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '3443'
          direction: 'Inbound'
          priority: 100
          protocol: 'Tcp'
          sourceAddressPrefix: 'ApiManagement'
          sourcePortRange: '*'
        }
      }
      {
        name: 'AllowAzureLoadBalancerHealthProbe'
        properties: {
          access: 'Allow'
          description: 'Allow Azure Load Balancer health probes for API Management.'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '6390'
          direction: 'Inbound'
          priority: 110
          protocol: 'Tcp'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
        }
      }
      {
        name: 'AllowHttpsFromHubFirewall'
        properties: {
          access: 'Allow'
          description: 'Allow API gateway ingress after hub firewall DNAT.'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '443'
          direction: 'Inbound'
          priority: 120
          protocol: 'Tcp'
          sourceAddressPrefixes: ingressSourceAddressPrefixes
          sourcePortRange: '*'
        }
      }
      {
        name: 'DenyAllInbound'
        properties: {
          access: 'Deny'
          description: 'Deny ingress that did not traverse the approved hub firewall path.'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          direction: 'Inbound'
          priority: 4096
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
        }
      }
    ]
  }
}

@description('Resource ID of the API Management subnet network security group.')
output resourceId string = apiManagementNsg.id
