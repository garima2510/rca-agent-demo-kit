targetScope = 'resourceGroup'

@minLength(3)
@maxLength(11)
param prefix string = 'rcademo'

param location string = resourceGroup().location
param operatorPrincipalId string

@allowed([
  'User'
  'ServicePrincipal'
])
param operatorPrincipalType string = 'User'

@allowed([
  'GlobalStandard'
  'DataZoneStandard'
])
param modelSku string = 'GlobalStandard'

type modelDeployment = {
  name: string
  model: string
  version: string
  capacity: int
}

param models modelDeployment[]

var suffix = uniqueString(subscription().subscriptionId, resourceGroup().id)
var resourceName = '${prefix}-${suffix}'
var tags = {
  application: 'rca-demo-kit'
  environment: 'demo'
}
var blobReader = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1')
var blobContributor = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
var searchReader = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '1407120a-92aa-4202-b7e9-c0e197c71c8f')
var searchContributor = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7ca78c08-252a-4471-8644-bb5ff32d4ba0')
var searchDataContributor = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '8ebe5a00-799e-43f5-93ac-243d3dce84a7')
var openAiUser = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')
var aiUser = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '53ca6127-db72-4b80-b1b0-d745d6d5456d')

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: '${prefix}${suffix}'
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Enabled'
    supportsHttpsTrafficOnly: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource knowledgeContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'rca-knowledge'
  properties: {
    publicAccess: 'None'
  }
}

resource search 'Microsoft.Search/searchServices@2025-05-01' = {
  name: '${resourceName}-search'
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'basic'
  }
  properties: {
    replicaCount: 1
    partitionCount: 1
    semanticSearch: 'standard'
    disableLocalAuth: true
    publicNetworkAccess: 'enabled'
    hostingMode: 'Default'
  }
}

resource foundry 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: '${resourceName}-ai'
  location: location
  tags: tags
  kind: 'AIServices'
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'S0'
  }
  properties: {
    allowProjectManagement: true
    customSubDomainName: '${resourceName}-ai'
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
  }
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  parent: foundry
  // Project and model writes share the Foundry account's operation lock.
  dependsOn: [
    deployments
  ]
  name: 'rca-project'
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: 'RCA Demo Project'
    description: 'Manufacturing RCA demo: Foundry IQ and Databricks Genie.'
  }
}

@batchSize(1)
resource deployments 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = [for model in models: {
  parent: foundry
  name: model.name
  sku: {
    name: modelSku
    capacity: model.capacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: model.model
      version: model.version
    }
    versionUpgradeOption: 'NoAutoUpgrade'
  }
}]

resource databricks 'Microsoft.Databricks/workspaces@2024-05-01' = {
  name: '${resourceName}-dbw'
  location: location
  tags: tags
  sku: {
    name: 'premium'
  }
  properties: {
    managedResourceGroupId: subscriptionResourceId('Microsoft.Resources/resourceGroups', '${resourceGroup().name}-databricks-managed')
    publicNetworkAccess: 'Enabled'
    requiredNsgRules: 'AllRules'
    parameters: {
      enableNoPublicIp: {
        value: true
      }
    }
  }
}

resource projectBlobReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, project.id, blobReader)
  scope: storage
  properties: {
    roleDefinitionId: blobReader
    principalId: project.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource searchBlobReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, search.id, blobReader)
  scope: storage
  properties: {
    roleDefinitionId: blobReader
    principalId: search.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource projectSearchReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, project.id, searchReader)
  scope: search
  properties: {
    roleDefinitionId: searchReader
    principalId: project.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource projectSearchContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, project.id, searchContributor)
  scope: search
  properties: {
    roleDefinitionId: searchContributor
    principalId: project.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource inferenceUsers 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for identityResourceId in [
  project.id
  search.id
]: {
  name: guid(foundry.id, identityResourceId, openAiUser)
  scope: foundry
  properties: {
    roleDefinitionId: openAiUser
    principalId: identityResourceId == project.id ? project.identity.principalId : search.identity.principalId
    principalType: 'ServicePrincipal'
  }
}]

resource operatorProjectUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(project.id, operatorPrincipalId, aiUser)
  scope: project
  properties: {
    roleDefinitionId: aiUser
    principalId: operatorPrincipalId
    principalType: operatorPrincipalType
  }
}

resource operatorBlobContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, operatorPrincipalId, blobContributor)
  scope: storage
  properties: {
    roleDefinitionId: blobContributor
    principalId: operatorPrincipalId
    principalType: operatorPrincipalType
  }
}

resource operatorSearchContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, operatorPrincipalId, searchContributor)
  scope: search
  properties: {
    roleDefinitionId: searchContributor
    principalId: operatorPrincipalId
    principalType: operatorPrincipalType
  }
}

resource operatorSearchDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, operatorPrincipalId, searchDataContributor)
  scope: search
  properties: {
    roleDefinitionId: searchDataContributor
    principalId: operatorPrincipalId
    principalType: operatorPrincipalType
  }
}

output foundryAccountName string = foundry.name
output foundryProjectId string = project.id
output foundryProjectEndpoint string = 'https://${foundry.properties.customSubDomainName}.services.ai.azure.com/api/projects/${project.name}'
output searchServiceName string = search.name
output searchEndpoint string = 'https://${search.name}.search.windows.net'
output storageAccountName string = storage.name
output knowledgeContainerName string = knowledgeContainer.name
output databricksWorkspaceId string = databricks.id
output databricksWorkspaceNumber string = databricks.properties.workspaceId
output databricksWorkspaceUrl string = 'https://${databricks.properties.workspaceUrl}'
output modelDeployments array = [for model in models: model.name]
