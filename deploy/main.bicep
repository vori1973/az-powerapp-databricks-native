// Scenario A: Native Databricks Connector — full private network deployment
//
// What this deploys:
//   - PP-VNet (primary region) with one delegated subnet → Enterprise Policy primary
//   - PP-VNet Secondary (paired region) with one delegated subnet → Enterprise Policy secondary
//   - Cross-region VNet peering between the two PP-VNets
//   - Databricks spoke VNet + workspace (VNet-injected, no public IP option)
//   - All 4 private DNS zones: ADB + ADLS DFS/Blob + Key Vault
//   - All private endpoints: ADB (ui_api + browser_auth) + ADLS (dfs + blob) + Key Vault
//   - ADLS Gen2 (HNS, public access disabled)
//   - Databricks Access Connector (MSI for Unity Catalog storage credential)
//   - Key Vault (private, RBAC)
//
// What this does NOT deploy (Scenario A vs enterprise.bicep):
//   - No Logic App — native connector goes directly from Power Apps to Databricks
//   - No Power Automate relay — not needed when connector is DLP-cleared
//
// Post-deploy manual steps (see deploy.ps1 output):
//   1. Confirm DLP: Databricks connector in Business tier in PPAC
//   2. Verify PP environment region: Get-EnvironmentRegion (confirm correct region pair)
//   3. Hub VNet reverse peerings (networking team)
//   4. Enterprise Policy: bind primary + secondary subnets in PPAC
//   5. NCC: configure private endpoint rules for ADLS (CRITICAL)
//   6. Create SQL Warehouse + note connection details
//   7. Unity Catalog: init metastore, catalog, schema, permissions, RLS

@description('Short prefix for all resource names (3-6 lowercase alphanumeric)')
@minLength(3)
@maxLength(6)
param prefix string = 'scena'

@description('Primary Azure region — PP environment primary region (e.g. eastus2)')
param location string = 'eastus2'

@description('Secondary Azure region — the paired region for this PP region. Enterprise Policy validates this pair; for the unitedstates geography the ONLY supported pairs are eastus|westus and centralus|eastus2 — eastus2 does NOT pair with eastus. Run Get-EnvironmentRegion to confirm which pair applies to your environment.')
param secondaryLocation string = 'centralus'

@description('Databricks workspace SKU — premium required for Unity Catalog')
@allowed(['standard', 'premium'])
param databricksSku string = 'premium'

@description('Resource ID of the existing Hub VNet for peering. Omit to auto-create a stub (dev/demo).')
param hubVnetResourceId string = ''

@description('Object ID of the user or SPN deploying — gets Key Vault admin role')
param kvAdminObjectId string

@description('Allow public network access to the Databricks workspace. Enabled for dev/demo (no jumpbox); Disabled for production.')
@allowed(['Enabled', 'Disabled'])
param workspacePublicNetworkAccess string = 'Enabled'

// ── Address spaces ─────────────────────────────────────────────────────────────
@description('Address space for the primary PP-VNet')
param ppVnetPrimaryAddressPrefix string = '10.200.0.0/16'

@description('Delegated subnet in primary PP-VNet for Enterprise Policy (primary)')
param ppSubnetPrimaryPrefix string = '10.200.1.0/24'

@description('Address space for the secondary PP-VNet (paired region — must not overlap primary)')
param ppVnetSecondaryAddressPrefix string = '10.201.0.0/16'

@description('Delegated subnet in secondary PP-VNet for Enterprise Policy (secondary/failover)')
param ppSubnetSecondaryPrefix string = '10.201.1.0/24'

@description('Address space for the Databricks spoke VNet (must not overlap PP-VNets or Hub)')
param adbVnetAddressPrefix string = '10.204.0.0/16'

@description('Databricks host subnet (VNet-injected classic compute)')
param adbHostSubnetPrefix string = '10.204.10.0/24'

@description('Databricks container subnet')
param adbContainerSubnetPrefix string = '10.204.11.0/24'

@description('Subnet for private endpoints within the ADB spoke VNet')
param peSubnetPrefix string = '10.204.12.0/24'

@description('Tags applied to all resources')
param tags object = {
  project: 'powerapps-databricks'
  pattern: 'scenario-a'
  environment: 'poc'
}

// ── Derived names ──────────────────────────────────────────────────────────────
var suffix               = uniqueString(resourceGroup().id)
var ppVnetPrimaryName    = '${prefix}-pp-vnet-primary'
var ppVnetSecondaryName  = '${prefix}-pp-vnet-secondary'
var adbVnetName          = '${prefix}-adb-vnet'
var workspaceName        = '${prefix}-adb-${suffix}'
var managedRgName        = '${prefix}-adb-managed-${suffix}'
var kvName               = '${prefix}-kv-${take(suffix, 8)}'
var storageAccountName   = '${prefix}st${take(suffix, 8)}'
var adbNsgName           = '${prefix}-adb-nsg'

// ── NSG for Databricks subnets (required for VNet injection + no-public-IP) ───
resource adbNsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: adbNsgName
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowAzureDatabricksOutbound'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'AzureDatabricks'
        }
      }
      {
        name: 'AllowStorageOutbound'
        properties: {
          priority: 110
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'Storage'
        }
      }
      {
        name: 'AllowSqlOutbound'
        properties: {
          priority: 120
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '3306'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'Sql'
        }
      }
      {
        name: 'AllowAzureMonitorOutbound'
        properties: {
          priority: 130
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'AzureMonitor'
        }
      }
      {
        // Required by Databricks Network Intent Policy (NoAzureDatabricksRules mode)
        // Workers stream telemetry to EventHub on port 9093
        name: 'AllowEventHubOutbound'
        properties: {
          priority: 140
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '9093'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'EventHub'
        }
      }
    ]
  }
}

// ── Databricks Spoke VNet ──────────────────────────────────────────────────────
resource adbVnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: adbVnetName
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [adbVnetAddressPrefix] }
    subnets: [
      {
        name: 'adb-host'
        properties: {
          addressPrefix: adbHostSubnetPrefix
          networkSecurityGroup: { id: adbNsg.id }
          delegations: [
            {
              name: 'databricks-delegation'
              properties: { serviceName: 'Microsoft.Databricks/workspaces' }
            }
          ]
        }
      }
      {
        name: 'adb-container'
        properties: {
          addressPrefix: adbContainerSubnetPrefix
          networkSecurityGroup: { id: adbNsg.id }
          delegations: [
            {
              name: 'databricks-delegation'
              properties: { serviceName: 'Microsoft.Databricks/workspaces' }
            }
          ]
        }
      }
      {
        name: 'private-endpoints'
        properties: {
          addressPrefix: peSubnetPrefix
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

// ── PP-VNet Primary (delegated subnet for Enterprise Policy — primary region) ──
resource ppVnetPrimary 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: ppVnetPrimaryName
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [ppVnetPrimaryAddressPrefix] }
    subnets: [
      {
        name: 'snet-pp-primary'
        properties: {
          addressPrefix: ppSubnetPrimaryPrefix
          delegations: [
            {
              name: 'powerplatform-delegation'
              properties: { serviceName: 'Microsoft.PowerPlatform/enterprisePolicies' }
            }
          ]
        }
      }
    ]
  }
}

// ── PP-VNet Secondary (delegated subnet for Enterprise Policy — paired region) ─
// This VNet lives in secondaryLocation (the paired Azure region for the PP environment).
// Enterprise Policy references primary subnet from ppVnetPrimary and secondary subnet
// from this VNet — both are linked to the same Power Platform Managed Environment.
resource ppVnetSecondary 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: ppVnetSecondaryName
  location: secondaryLocation   // MUST be the paired region — confirm with Get-EnvironmentRegion
  tags: union(tags, { region: 'secondary' })
  properties: {
    addressSpace: { addressPrefixes: [ppVnetSecondaryAddressPrefix] }
    subnets: [
      {
        name: 'snet-pp-secondary'
        properties: {
          addressPrefix: ppSubnetSecondaryPrefix
          delegations: [
            {
              name: 'powerplatform-delegation'
              properties: { serviceName: 'Microsoft.PowerPlatform/enterprisePolicies' }
            }
          ]
        }
      }
    ]
  }
}

// ── Cross-region VNet peering: PP-Primary ↔ PP-Secondary ─────────────────────
// Required so that if Power Platform fails over to the secondary region, traffic
// from the secondary subnet can still reach the Databricks spoke in the primary region.
resource ppPrimaryToSecondaryPeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  name: 'peer-pp-primary-to-secondary'
  parent: ppVnetPrimary
  properties: {
    remoteVirtualNetwork: { id: ppVnetSecondary.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

resource ppSecondaryToPrimaryPeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  name: 'peer-pp-secondary-to-primary'
  parent: ppVnetSecondary
  properties: {
    remoteVirtualNetwork: { id: ppVnetPrimary.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

// ── PP-VNet Primary → Hub peering (only when Hub VNet ID is provided) ─────────
resource ppPrimaryToHubPeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = if (!empty(hubVnetResourceId)) {
  name: 'peer-pp-primary-to-hub'
  parent: ppVnetPrimary
  properties: {
    remoteVirtualNetwork: { id: hubVnetResourceId }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

// ── PP-VNet Secondary → Hub peering ───────────────────────────────────────────
resource ppSecondaryToHubPeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = if (!empty(hubVnetResourceId)) {
  name: 'peer-pp-secondary-to-hub'
  parent: ppVnetSecondary
  properties: {
    remoteVirtualNetwork: { id: hubVnetResourceId }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

// ── ADB Spoke VNet → Hub peering ──────────────────────────────────────────────
resource adbToHubPeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = if (!empty(hubVnetResourceId)) {
  name: 'peer-adbvnet-to-hub'
  parent: adbVnet
  properties: {
    remoteVirtualNetwork: { id: hubVnetResourceId }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

// NOTE: Hub reverse peerings (Hub → PP-Primary, Hub → ADB, Hub → PP-Secondary)
// are created by deploy.ps1 via az CLI after this Bicep completes.
// Bicep cannot create child resources on a cross-RG parent inline (BCP165) —
// it would require a separate module. The deploy script handles this automatically
// when you have access to the hub resource group; in enterprise environments where
// the hub is in a different subscription, the networking team must add them.

// ── Private DNS Zones (all 4 required — Gap 3 fix) ───────────────────────────
var storageSuffix = environment().suffixes.storage
var dnsZones = [
  'privatelink.azuredatabricks.net'
  'privatelink.dfs.${storageSuffix}'
  'privatelink.blob.${storageSuffix}'
  'privatelink.vaultcore.azure.net'
]

resource privateDnsZones 'Microsoft.Network/privateDnsZones@2020-06-01' = [for zone in dnsZones: {
  name: zone
  location: 'global'
  tags: tags
}]

// Link DNS zones to PP-VNet Primary
resource ppPrimaryDnsLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for (zone, i) in dnsZones: {
  name: 'link-pp-primary-${replace(zone, '.', '-')}'
  parent: privateDnsZones[i]
  location: 'global'
  properties: {
    virtualNetwork: { id: ppVnetPrimary.id }
    registrationEnabled: false
  }
}]

// Link DNS zones to PP-VNet Secondary (so failover traffic resolves private IPs too)
resource ppSecondaryDnsLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for (zone, i) in dnsZones: {
  name: 'link-pp-secondary-${replace(zone, '.', '-')}'
  parent: privateDnsZones[i]
  location: 'global'
  properties: {
    virtualNetwork: { id: ppVnetSecondary.id }
    registrationEnabled: false
  }
}]

// Link DNS zones to ADB Spoke VNet
resource adbVnetDnsLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for (zone, i) in dnsZones: {
  name: 'link-adbvnet-${replace(zone, '.', '-')}'
  parent: privateDnsZones[i]
  location: 'global'
  properties: {
    virtualNetwork: { id: adbVnet.id }
    registrationEnabled: false
  }
}]

// ── ADLS Gen2 (Delta Lake backend — public access disabled) ───────────────────
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    isHnsEnabled: true
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices' // Databricks UC control plane needs this for storage credential validation
    }
  }
}

resource deltaContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  name: '${storageAccountName}/default/delta'
  dependsOn: [storageAccount]
}

resource unityCatalogContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  name: '${storageAccountName}/default/unity-catalog'
  dependsOn: [storageAccount]
}

// ── Databricks Access Connector (MSI for Unity Catalog storage credential) ────
resource accessConnector 'Microsoft.Databricks/accessConnectors@2023-05-01' = {
  name: '${prefix}-ac-uc'
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {}
}

// Storage Blob Data Contributor — Unity Catalog reads/writes managed table data
resource accessConnectorStorageRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, accessConnector.id, 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
    principalId: accessConnector.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ── Key Vault (private, RBAC) — stores any secrets outside Databricks auth path
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: kvName
  location: location
  tags: tags
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: tenant().tenantId
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enableRbacAuthorization: true
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'None'
    }
  }
}

resource kvAdminRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, kvAdminObjectId, 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')
    principalId: kvAdminObjectId
    principalType: 'User'
  }
}

// ── Databricks Workspace (VNet-injected, no public IP on nodes) ───────────────
resource databricksWorkspace 'Microsoft.Databricks/workspaces@2023-02-01' = {
  name: workspaceName
  location: location
  tags: tags
  sku: { name: databricksSku }
  properties: {
    managedResourceGroupId: subscriptionResourceId('Microsoft.Resources/resourceGroups', managedRgName)
    parameters: {
      customVirtualNetworkId: { value: adbVnet.id }
      customPublicSubnetName: { value: 'adb-host' }
      customPrivateSubnetName: { value: 'adb-container' }
      enableNoPublicIp: { value: true }
    }
    publicNetworkAccess: workspacePublicNetworkAccess
    requiredNsgRules: 'NoAzureDatabricksRules'
  }
}

// ── Private Endpoint: Databricks ui_api (workspace + REST API access) ─────────
resource peAdbUiApi 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name: '${prefix}-pe-adb-uiapi'
  location: location
  tags: tags
  properties: {
    subnet: { id: '${adbVnet.id}/subnets/private-endpoints' }
    privateLinkServiceConnections: [
      {
        name: 'adb-uiapi-connection'
        properties: {
          privateLinkServiceId: databricksWorkspace.id
          groupIds: ['databricks_ui_api']
        }
      }
    ]
  }
}

resource peAdbUiApiDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = {
  name: 'adb-uiapi-dns-group'
  parent: peAdbUiApi
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-azuredatabricks-net'
        properties: { privateDnsZoneId: privateDnsZones[0].id }
      }
    ]
  }
}

// ── Private Endpoint: Databricks browser_authentication (Entra ID OAuth redirect)
// Required for the native connector's delegated OAuth flow — the connector's
// OAuth redirect goes through this endpoint when using Entra ID auth.
// dependsOn peAdbUiApi: Databricks workspace only allows one PE update at a time;
// deploying both in parallel causes ConcurrentUpdateError.
resource peAdbBrowserAuth 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  dependsOn: [peAdbUiApiDnsGroup]
  name: '${prefix}-pe-adb-browser'
  location: location
  tags: tags
  properties: {
    subnet: { id: '${adbVnet.id}/subnets/private-endpoints' }
    privateLinkServiceConnections: [
      {
        name: 'adb-browser-connection'
        properties: {
          privateLinkServiceId: databricksWorkspace.id
          groupIds: ['browser_authentication']
        }
      }
    ]
  }
}

resource peAdbBrowserAuthDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = {
  name: 'adb-browser-dns-group'
  parent: peAdbBrowserAuth
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-azuredatabricks-net'
        properties: { privateDnsZoneId: privateDnsZones[0].id }
      }
    ]
  }
}

// ── Private Endpoint: ADLS Gen2 DFS ───────────────────────────────────────────
resource peAdlsDfs 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name: '${prefix}-pe-adls-dfs'
  location: location
  tags: tags
  properties: {
    subnet: { id: '${adbVnet.id}/subnets/private-endpoints' }
    privateLinkServiceConnections: [
      {
        name: 'adls-dfs-connection'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: ['dfs']
        }
      }
    ]
  }
}

resource peAdlsDfsDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = {
  name: 'adls-dfs-dns-group'
  parent: peAdlsDfs
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-dfs-core-windows-net'
        properties: { privateDnsZoneId: privateDnsZones[1].id }
      }
    ]
  }
}

// ── Private Endpoint: ADLS Blob ───────────────────────────────────────────────
resource peAdlsBlob 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name: '${prefix}-pe-adls-blob'
  location: location
  tags: tags
  properties: {
    subnet: { id: '${adbVnet.id}/subnets/private-endpoints' }
    privateLinkServiceConnections: [
      {
        name: 'adls-blob-connection'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: ['blob']
        }
      }
    ]
  }
}

resource peAdlsBlobDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = {
  name: 'adls-blob-dns-group'
  parent: peAdlsBlob
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-blob-core-windows-net'
        properties: { privateDnsZoneId: privateDnsZones[2].id }
      }
    ]
  }
}

// ── Private Endpoint: Key Vault ───────────────────────────────────────────────
resource peKv 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name: '${prefix}-pe-kv'
  location: location
  tags: tags
  properties: {
    subnet: { id: '${adbVnet.id}/subnets/private-endpoints' }
    privateLinkServiceConnections: [
      {
        name: 'kv-connection'
        properties: {
          privateLinkServiceId: keyVault.id
          groupIds: ['vault']
        }
      }
    ]
  }
}

resource peKvDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = {
  name: 'kv-dns-group'
  parent: peKv
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-vaultcore-azure-net'
        properties: { privateDnsZoneId: privateDnsZones[3].id }
      }
    ]
  }
}

// ── Outputs ────────────────────────────────────────────────────────────────────
output databricksWorkspaceUrl    string = 'https://${databricksWorkspace.properties.workspaceUrl}'
output databricksWorkspaceId     string = databricksWorkspace.id
output databricksWorkspaceNumId  string = databricksWorkspace.properties.workspaceId
output ppVnetPrimaryId           string = ppVnetPrimary.id
output ppVnetPrimaryName         string = ppVnetPrimary.name
output ppSubnetPrimaryId         string = '${ppVnetPrimary.id}/subnets/snet-pp-primary'
output ppVnetSecondaryId         string = ppVnetSecondary.id
output ppVnetSecondaryName       string = ppVnetSecondary.name
output ppSubnetSecondaryId       string = '${ppVnetSecondary.id}/subnets/snet-pp-secondary'
output adbVnetId                 string = adbVnet.id
output adbVnetName               string = adbVnet.name
output storageAccountName        string = storageAccount.name
output storageAccountDfsEndpoint string = storageAccount.properties.primaryEndpoints.dfs
output keyVaultName              string = keyVault.name
output keyVaultUri               string = keyVault.properties.vaultUri
output accessConnectorId         string = accessConnector.id
output accessConnectorPrincipalId string = accessConnector.identity.principalId
output ucStorageRoot             string = replace(storageAccount.properties.primaryEndpoints.dfs, 'https://', 'abfss://unity-catalog@')

