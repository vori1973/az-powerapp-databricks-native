<#
.SYNOPSIS
    Deploys Scenario A: Power Apps native Databricks connector with full private networking.

    Resources deployed:
      - PP-VNet Primary  (primary region, delegated subnet for Enterprise Policy)
      - PP-VNet Secondary (paired region, delegated subnet for Enterprise Policy failover)
      - Cross-region VNet peering between the two PP-VNets
      - Databricks spoke VNet + workspace (VNet-injected)
      - All 4 private DNS zones (ADB, ADLS DFS/Blob, Key Vault)
      - Private endpoints (ADB ui_api + browser_auth, ADLS DFS/Blob, Key Vault)
      - ADLS Gen2 (HNS, public access disabled)
      - Databricks Access Connector (MSI for Unity Catalog)
      - Key Vault (private, RBAC)

    NOT deployed (Scenario A vs enterprise pattern):
      - No Logic App — native connector goes directly Power Apps → Databricks
      - No Power Automate relay

.PARAMETER ResourceGroup
    Target resource group (created if it doesn't exist).

.PARAMETER Location
    Primary Azure region. Should match where the Power Platform environment will be.

.PARAMETER SecondaryLocation
    Paired Azure region for the secondary PP-VNet.
    Run Get-EnvironmentRegion (subnet diagnostics module) to confirm the correct pair.
    US default: 'eastus' when primary is 'eastus2'. UK: 'ukwest'. Canada: 'canadaeast'.

.PARAMETER HubVNetId
    Full resource ID of the existing Hub VNet to peer with.
    Omit to auto-create a stub hub (dev/POC — no firewall inspection).

.PARAMETER Prefix
    3-6 lowercase alphanumeric prefix for all resource names.

.PARAMETER PublicAccess
    Enabled (default) — workspace reachable from browser without jumpbox (POC mode).
    Disabled — workspace accessible only via private endpoint (production mode).

.EXAMPLE
    # POC — no Hub VNet (stub created automatically, workspace publicly accessible)
    .\deploy.ps1 -ResourceGroup "rg-powerapp-databricks-poc" -Location "eastus2"

.EXAMPLE
    # With customer Hub VNet
    $hub = "/subscriptions/xxx/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/hub-vnet"
    .\deploy.ps1 -ResourceGroup "rg-powerapp-databricks" -Location "eastus2" -HubVNetId $hub
#>
param(
    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [string]$Location = "eastus2",

    [string]$SecondaryLocation = "eastus",

    [string]$HubVNetId = "",

    [string]$StubHubAddressPrefix = "10.100.0.0/16",

    [string]$Prefix = "scena",

    [ValidateSet("Enabled", "Disabled")]
    [string]$PublicAccess = "Enabled"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "`n=== Scenario A: Native Connector Deployment ===" -ForegroundColor Cyan
Write-Host "    Resource Group     : $ResourceGroup"
Write-Host "    Primary Location   : $Location"
Write-Host "    Secondary Location : $SecondaryLocation"
Write-Host "    Hub VNet           : $(if ($HubVNetId) { $HubVNetId } else { '(stub will be created)' })"
Write-Host "    Workspace Access   : $PublicAccess"

# ── Prerequisites ──────────────────────────────────────────────────────────────
Write-Host "`n[1/8] Checking prerequisites..." -ForegroundColor Yellow

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    $azWbin = 'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin'
    if (Test-Path $azWbin) {
        $env:PATH += ";$azWbin"
    } else {
        Write-Error "Azure CLI not found. Install from https://aka.ms/installazurecli"
    }
}

$cliVer = (az version -o json 2>$null | ConvertFrom-Json).'azure-cli'
if (-not $cliVer) { Write-Error "Azure CLI not found or not working. Run: az login" }
Write-Host "    Azure CLI $cliVer"

$account = az account show -o json | ConvertFrom-Json
Write-Host "    Subscription : $($account.name) ($($account.id))"
Write-Host "    Tenant       : $($account.tenantId)"

# ── DLP gate check ─────────────────────────────────────────────────────────────
Write-Host "`n[2/8] DLP gate check..." -ForegroundColor Yellow
Write-Host @"

  IMPORTANT — Scenario A requires the Databricks connector to be in the Business
  tier of the Power Platform DLP policy BEFORE Power Apps can use it.

  To check or update the DLP policy:
    Power Platform Admin Center (admin.powerplatform.microsoft.com)
    → Policies → Data policies → [your policy]
    → Connectors → find 'Databricks' → move to Business tier

  This deployment can proceed regardless of DLP status. But the Power Apps
  connector will not work until DLP is resolved.

"@ -ForegroundColor DarkYellow

# ── Confirm PP environment region pair ────────────────────────────────────────
Write-Host "[3/8] Verifying region pair..." -ForegroundColor Yellow
Write-Host @"

  The secondary PP-VNet will be deployed in: $SecondaryLocation
  This MUST match the paired Azure region for your Power Platform environment.

  To confirm the correct region:
    Install-Module Microsoft.PowerPlatform.EnterprisePolicies -Force
    Import-Module Microsoft.PowerPlatform.EnterprisePolicies
    Get-EnvironmentRegion -EnvironmentId '<your-environment-id>'

  Power Platform region pairs (reference):
    United States : eastus  ↔ westus
    UK            : uksouth ↔ ukwest
    Canada        : canadacentral ↔ canadaeast
    Europe        : westeurope ↔ northeurope
    Australia     : australiaeast ↔ australiasoutheast

  If the secondary location is wrong, re-run with -SecondaryLocation <correct-region>.

"@ -ForegroundColor DarkYellow

$confirm = Read-Host "  Press Enter to continue or Ctrl+C to abort and fix -SecondaryLocation"

# ── Object ID ──────────────────────────────────────────────────────────────────
Write-Host "`n[4/8] Resolving deployer object ID..." -ForegroundColor Yellow
$objectId = az ad signed-in-user show --query id -o tsv 2>$null
if (-not $objectId) { Write-Error "Could not get Object ID. Run: az login" }
Write-Host "    Object ID: $objectId"

# ── Hub VNet ───────────────────────────────────────────────────────────────────
if (-not $HubVNetId) {
    Write-Host "`n[5/8] No Hub VNet supplied — creating stub hub for POC..." -ForegroundColor Yellow
    $stubHubRg   = "$ResourceGroup-hub"
    $stubHubName = "hub-vnet-stub"

    az group create --name $stubHubRg --location $Location --output none
    az network vnet create -g $stubHubRg -n $stubHubName `
        --address-prefix $StubHubAddressPrefix `
        --subnet-name hub-subnet `
        --subnet-prefixes ($StubHubAddressPrefix -replace '0/16','1.0/24') `
        --location $Location --output none

    $HubVNetId = az network vnet show -g $stubHubRg -n $stubHubName --query id -o tsv
    Write-Host "    Stub hub: $stubHubRg/$stubHubName"
    Write-Host "    Hub ID  : $HubVNetId"
    Write-Host "    NOTE: stub hub has no firewall. For production, provide -HubVNetId." -ForegroundColor DarkYellow
} else {
    Write-Host "`n[5/8] Validating Hub VNet..." -ForegroundColor Yellow
    $hubExists = az network vnet show --ids $HubVNetId --query id -o tsv 2>$null
    if (-not $hubExists) { Write-Error "Hub VNet not found: $HubVNetId" }
    Write-Host "    Hub VNet validated."
}

# ── Address space conflict check ───────────────────────────────────────────────
Write-Host "`n[6/8] Checking address space conflicts..." -ForegroundColor Yellow
$hubPrefixes = az network vnet show --ids $HubVNetId --query addressSpace.addressPrefixes -o json | ConvertFrom-Json
Write-Host "    Hub address spaces: $($hubPrefixes -join ', ')"
Write-Warning "    Ensure 10.200.0.0/16 and 10.201.0.0/16 do NOT overlap with Hub or Spoke VNets."
$confirm = Read-Host "    Press Enter to continue or Ctrl+C to abort"

# ── Resource group ─────────────────────────────────────────────────────────────
Write-Host "`n[7/8] Creating resource group '$ResourceGroup'..." -ForegroundColor Yellow
az group create --name $ResourceGroup --location $Location --output none
Write-Host "    Resource group ready."

# ── Deploy ─────────────────────────────────────────────────────────────────────
$deploymentName = "deploy-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Write-Host "`n[8/8] Deploying '$deploymentName'..." -ForegroundColor Yellow
Write-Host "    Estimated time: ~15-20 minutes (Databricks workspace provisioning)"
Write-Host "    Two PP-VNets will be created: $Location (primary) + $SecondaryLocation (secondary)"

$scriptDir = $PSScriptRoot
$outputs = az deployment group create `
    --name $deploymentName `
    --resource-group $ResourceGroup `
    --template-file "$scriptDir\main.bicep" `
    --parameters "$scriptDir\parameters.json" `
    --parameters `
        prefix=$Prefix `
        location=$Location `
        secondaryLocation=$SecondaryLocation `
        hubVnetResourceId=$HubVNetId `
        kvAdminObjectId=$objectId `
        workspacePublicNetworkAccess=$PublicAccess `
    --query properties.outputs `
    -o json | ConvertFrom-Json

if ($LASTEXITCODE -ne 0) {
    Write-Error "Deployment failed. Check portal: https://portal.azure.com/#resource/subscriptions/$($account.id)/resourceGroups/$ResourceGroup"
}

# ── Collect outputs ────────────────────────────────────────────────────────────
$adbUrl          = $outputs.databricksWorkspaceUrl.value
$adbWsId         = $outputs.databricksWorkspaceId.value
$adbNumId        = $outputs.databricksWorkspaceNumId.value
$ppPrimaryId     = $outputs.ppVnetPrimaryId.value
$ppPrimaryName   = $outputs.ppVnetPrimaryName.value
$ppSecondaryId   = $outputs.ppVnetSecondaryId.value
$ppSecondaryName = $outputs.ppVnetSecondaryName.value
$storage         = $outputs.storageAccountName.value
$storageEndpoint = $outputs.storageAccountDfsEndpoint.value
$kvName          = $outputs.keyVaultName.value
$kvUri           = $outputs.keyVaultUri.value
$acId            = $outputs.accessConnectorId.value
$acPrincipalId   = $outputs.accessConnectorPrincipalId.value
$ucStorageRoot   = $outputs.ucStorageRoot.value

Write-Host "`n=== DEPLOYMENT OUTPUTS ===" -ForegroundColor Cyan
Write-Host "Databricks Workspace URL     : $adbUrl"
Write-Host "Databricks Workspace (ARM)   : $adbWsId"
Write-Host "PP-VNet Primary              : $ppPrimaryName ($Location)"
Write-Host "PP-VNet Secondary            : $ppSecondaryName ($SecondaryLocation)"
Write-Host "Storage Account              : $storage"
Write-Host "Key Vault                    : $kvName"
Write-Host "Access Connector ID          : $acId"
Write-Host "UC Storage Root              : $ucStorageRoot"

Write-Host "`n=== MANUAL STEPS REQUIRED ===" -ForegroundColor Yellow
Write-Host "(ARM cannot automate these — complete them in order)" -ForegroundColor DarkGray

Write-Host @"

──────────────────────────────────────────────────────────────
STEP 1 — CONFIRM DLP POLICY [BLOCKER — do this first]
──────────────────────────────────────────────────────────────
The Databricks connector must be in the Business tier before Power Apps can use it.

  admin.powerplatform.microsoft.com
  → Policies → Data policies → [your env policy]
  → Connectors → Databricks → Move to Business data group

No networking work unblocks this — it must be done in PPAC by the CloudX team.

──────────────────────────────────────────────────────────────
STEP 2 — VERIFY ENVIRONMENT REGION PAIR [required before Step 3]
──────────────────────────────────────────────────────────────
Confirm the secondary VNet is in the correct paired region for your PP environment:

  Install-Module Microsoft.PowerPlatform.EnterprisePolicies -Force
  Import-Module Microsoft.PowerPlatform.EnterprisePolicies
  Get-EnvironmentRegion -EnvironmentId '<your-pp-environment-id>'

  Expected result for US environments: eastus + westus (or eastus2 + centralus — varies)
  Current deployment: $Location (primary) + $SecondaryLocation (secondary)

  If the secondary is wrong: redeploy with -SecondaryLocation <correct-region>

──────────────────────────────────────────────────────────────
STEP 3 — HUB VNET REVERSE PEERINGS [networking team]
──────────────────────────────────────────────────────────────
Ask the networking team to add on the Hub VNet:
  a. Hub → PP-VNet-Primary   ($ppPrimaryId)
  b. Hub → ADB Spoke VNet    ($(az network vnet show -g $ResourceGroup --query id -o tsv 2>$null))
Both: allowForwardedTraffic=true, allowVirtualNetworkAccess=true

Also needed (PP-VNet-Secondary → Hub, run from secondary sub if different):
  az network vnet peering create \
    --resource-group $ResourceGroup \
    --vnet-name $ppSecondaryName \
    --name peer-pp-secondary-to-hub \
    --remote-vnet $HubVNetId \
    --allow-vnet-access true --allow-forwarded-traffic true

  And the reverse (Hub → PP-VNet-Secondary) from the Hub VNet side.

──────────────────────────────────────────────────────────────
STEP 4 — POWER PLATFORM ENTERPRISE POLICY [PPAC]
──────────────────────────────────────────────────────────────
  admin.powerplatform.microsoft.com → Policies → Enterprise Policies → New Policy
  Type: Network
  Select your Managed Environment
  Primary VNet  : $ppPrimaryName    Subnet: snet-pp-primary
  Secondary VNet: $ppSecondaryName  Subnet: snet-pp-secondary
  Save and wait ~5-10 minutes for Status: Succeeded

  Validate:
    Get-SubnetInjectionStatus -EnvironmentId '<your-environment-id>'

──────────────────────────────────────────────────────────────
STEP 5 — NCC CONFIGURATION [CRITICAL — serverless queries fail without this]
──────────────────────────────────────────────────────────────
The Serverless SQL Warehouse runs in Databricks-managed infrastructure outside
your VNet. Without NCC, it cannot reach the private ADLS storage account.

Prerequisite: You must be a Databricks Account Admin.
  → accounts.azuredatabricks.net → User Management → toggle Account Admin ON

  # Configure account-level CLI profile (one-time)
  databricks auth login --host https://accounts.azuredatabricks.net --profile ACCOUNT-<account-id>

  # 1. Create NCC in the same region as the workspace
  databricks account network-connectivity create-network-connectivity-configuration ``
    "ncc-${Prefix}" "$Location" ``
    --profile ACCOUNT-<account-id> --output json
  # → note: network_connectivity_config_id from output

  # 2. Add private endpoint rule for ADLS DFS sub-resource
  `$storageId = az storage account show -n $storage -g $ResourceGroup --query id -o tsv
  databricks account network-connectivity create-private-endpoint-rule <ncc-id> ``
    --json "{``"resource_id``": ``"`$storageId``", ``"group_id``": ``"dfs``"}" ``
    --profile ACCOUNT-<account-id> --output json
  # → connection_state will be PENDING

  # 3. Approve the pending private endpoint in Azure Portal:
  #    Storage account '$storage' → Networking → Private endpoint connections
  #    → Approve the connection from prod-$Location-snp-* subscription
  # OR via CLI:
  `$peConnId = az storage account show -n $storage -g $ResourceGroup ``
    --query "privateEndpointConnections[?privateLinkServiceConnectionState.status=='Pending'].id" -o tsv
  az storage account private-endpoint-connection approve --id `$peConnId ``
    --description "Approved for Databricks NCC Serverless"

  # 4. Assign NCC to workspace
  databricks account workspaces update $adbNumId ``
    --json "{``"network_connectivity_config_id``": ``"<ncc-id>``"}" ``
    --profile ACCOUNT-<account-id> --output json

  # 5. Verify rule is ESTABLISHED (may take 2-3 minutes after approval)
  databricks account network-connectivity get-private-endpoint-rule ``
    <ncc-id> <rule-id> --profile ACCOUNT-<account-id> --output json

  Full steps: docs/networking.md → NCC Configuration

──────────────────────────────────────────────────────────────
STEP 6 — CREATE SERVERLESS SQL WAREHOUSE
──────────────────────────────────────────────────────────────
  # Configure workspace-level CLI profile (one-time)
  databricks auth login --host $adbUrl --profile ${Prefix}-workspace

  # Create Serverless Pro warehouse
  databricks warehouses create ``
    --json '{
      "name": "${Prefix}-sql-wh-pro",
      "cluster_size": "Small",
      "warehouse_type": "PRO",
      "enable_serverless_compute": true,
      "auto_stop_mins": 10,
      "max_num_clusters": 1
    }' ``
    --profile ${Prefix}-workspace --output json

  Note the connection details from output:
    Server hostname : $($adbUrl -replace 'https://')
    HTTP path       : /sql/1.0/warehouses/<id>

──────────────────────────────────────────────────────────────
STEP 7 — UNITY CATALOG INITIALIZATION
──────────────────────────────────────────────────────────────
Access Connector ID : $acId
Access Connector MSI: $acPrincipalId
UC Storage Root     : $ucStorageRoot

  # 1. Grant Storage Blob Data Contributor to Access Connector MSI
  az role assignment create ``
    --assignee "$acPrincipalId" ``
    --role "Storage Blob Data Contributor" ``
    --scope "$(az storage account show -n $storage -g $ResourceGroup --query id -o tsv 2>$null)"

  # 2. Check if account-level metastore already exists for the region
  databricks account metastores list --profile ACCOUNT-<account-id> --output json
  # If none: create one
  databricks account metastores create "$Location-metastore" ``
    --region $Location --profile ACCOUNT-<account-id> --output json

  # 3. Assign metastore to workspace (if not already assigned)
  databricks account metastore-assignments create ``
    --json "{``"metastore_id``": ``"<metastore-id>``", ``"default_catalog_name``": ``"${Prefix}_poc``"}" ``
    $adbNumId --profile ACCOUNT-<account-id>

  # 4. Create storage credential using Access Connector
  #    Note: storage account is deployed with bypass: AzureServices which allows the
  #    Databricks UC control plane to validate credentials without opening public access.
  databricks storage-credentials create ``
    --json "{
      ``"name``": ``"${Prefix}-ac-uc-credential``",
      ``"azure_managed_identity``": {
        ``"access_connector_id``": ``"$acId``"
      },
      ``"comment``": ``"Access Connector MSI for UC storage on $storage``"
    }" ``
    --profile ${Prefix}-workspace --output json

  # Validate credential (all 6 checks must PASS before proceeding)
  `$valBody = "{``"storage_credential_name``":``"${Prefix}-ac-uc-credential``",``"url``":``"abfss://delta@${storage}.dfs.core.windows.net/``",``"readonly``":false}"
  databricks api post /api/2.1/unity-catalog/validate-storage-credentials ``
    --profile ${Prefix}-workspace --json `$valBody

  # 5. Create external location with live validation
  databricks external-locations create ``
    "${Prefix}-uc-root" ``
    "abfss://unity-catalog@${storage}.dfs.core.windows.net/" ``
    "${Prefix}-ac-uc-credential" ``
    --comment "Root external location for UC on $storage" ``
    --profile ${Prefix}-workspace --output json


  # 6. Create catalog backed by the external location
  databricks catalogs create "${Prefix}_poc" ``
    --storage-root "${ucStorageRoot}${Prefix}_poc" ``
    --comment "Scenario A POC catalog" ``
    --profile ${Prefix}-workspace --output json

  # 7. Create schema
  databricks schemas create "customers" "${Prefix}_poc" ``
    --comment "Customer data with RLS by SESSION_USER()" ``
    --profile ${Prefix}-workspace --output json

  Full steps: docs/implementation-guide.md → Unity Catalog Setup

──────────────────────────────────────────────────────────────
STEP 8 — UNITY CATALOG PERMISSIONS + ROW-LEVEL SECURITY
──────────────────────────────────────────────────────────────
In Databricks SQL Editor (as workspace admin):

  -- Create catalog, schema, sample table
  CREATE CATALOG IF NOT EXISTS hr;
  CREATE SCHEMA IF NOT EXISTS hr.employees_data;

  CREATE TABLE IF NOT EXISTS hr.employees_data.employees (
    emp_id       STRING,
    full_name    STRING,
    email        STRING,
    email_domain STRING,
    department   STRING,
    contractor   BOOLEAN
  );

  -- Grant access to the Entra ID group that contains Power Apps users
  -- Replace 'powerapps-users@company.com' with the actual Entra group
  GRANT USE CATALOG  ON CATALOG hr TO ``powerapps-users@company.com``;
  GRANT USE SCHEMA   ON SCHEMA hr.employees_data TO ``powerapps-users@company.com``;
  GRANT SELECT       ON TABLE hr.employees_data.employees TO ``powerapps-users@company.com``;

  -- Row-level security using SESSION_USER() — works natively with delegated OAuth
  -- (no SQL parameter needed — the connector passes the user's actual UPN)
  CREATE FUNCTION IF NOT EXISTS hr.employees_data.user_domain_filter(domain STRING)
  RETURN LOWER(SESSION_USER()) LIKE LOWER(CONCAT('%@', domain));

  ALTER TABLE hr.employees_data.employees
  SET ROW FILTER hr.employees_data.user_domain_filter ON (email_domain);

  -- Verify RLS works (should return rows for YOUR domain only):
  SELECT current_user(), SESSION_USER();
  SELECT * FROM hr.employees_data.employees LIMIT 5;

──────────────────────────────────────────────────────────────
STEP 9 — CONNECT POWER APPS (Phase 1: PAT | Phase 2: Entra ID)
──────────────────────────────────────────────────────────────
Phase 1 — PAT (fastest for smoke test, RLS will NOT filter per-user):
  make.powerapps.com → Data → Add data → Databricks
  Server hostname: <from Step 6>
  HTTP path: <from Step 6>
  Token: <PAT from Databricks User Settings>

Phase 2 — Entra ID delegated (production, enables current_user() RLS):
  Edit the connector connection → Authentication type: Azure Active Directory
  Users sign in with their own work account — no shared credential stored

  Canvas App formula to load data:
    Databricks.ExecuteQuery(
        "SELECT emp_id, full_name, department FROM hr.employees_data.employees LIMIT 100",
        \{timeout: 30\}
    ).value

"@

Write-Host "`nPortal: https://portal.azure.com/#resource/subscriptions/$($account.id)/resourceGroups/$ResourceGroup" -ForegroundColor Cyan
Write-Host "Databricks: $adbUrl" -ForegroundColor Cyan
Write-Host "`nDocs: docs/implementation-guide.md" -ForegroundColor DarkGray


