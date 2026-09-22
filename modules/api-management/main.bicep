targetScope = 'resourceGroup'

@description('Globally unique name of the Azure API Management service.')
param name string

@description('Azure region for the API Management service.')
param location string = resourceGroup().location

@description('Publisher contact email for the API Management service.')
param publisherEmail string

@description('Publisher display name for the API Management service.')
param publisherName string

@description('Resource ID of the dedicated subnet used for internal VNet injection.')
param subnetResourceId string

@description('Resource ID of the Log Analytics workspace for diagnostics. Leave empty to skip diagnostic settings.')
param logAnalyticsWorkspaceResourceId string = ''

@description('Tags to apply to the API Management service.')
param tags object = {}

resource apiManagement 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: name
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'Developer'
    capacity: 1
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
    publicNetworkAccess: 'Enabled'
    virtualNetworkType: 'Internal'
    virtualNetworkConfiguration: {
      subnetResourceId: subnetResourceId
    }
  }
}

resource apiManagementDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceResourceId)) {
  name: 'send-to-log-analytics'
  scope: apiManagement
  properties: {
    workspaceId: logAnalyticsWorkspaceResourceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

@description('Resource ID of the Azure API Management service.')
output resourceId string = apiManagement.id
