# Networking Guide

Manual steps that ARM/Bicep cannot automate. Complete these after running `deploy/deploy.ps1`.

---

## 1. NCC Configuration (CRITICAL — Gap 1 Fix)

**Why**: Serverless SQL Warehouse runs in Databricks-managed compute, not your VNet. It needs explicit private endpoint rules (via Network Connectivity Configuration) to reach private ADLS storage. Without this, all serverless queries fail at the storage read step.

**What NCC does**: tells the Databricks control plane to provision private endpoints from the serverless data plane network into your ADLS account.

### Step-by-step

```bash
# Prerequisites: Databricks CLI configured with your workspace URL + PAT
pip install databricks-cli
databricks configure --host https://<workspace-url> --token <PAT>
```

```bash
# 1. Get your Account ID (Databricks Accounts console — accounts.azuredatabricks.net)
# 2. Get your Workspace ID (from Databricks workspace URL: adb-<workspace-id>.azuredatabricks.net)

# 3. Create a Network Connectivity Configuration
databricks account network-connectivity-configs create \
  --name "ncc-powerapps-prod" \
  --region eastus2

# 4. Note the NCC ID from the output: "network_connectivity_config_id": "ncc-xxx"

# 5. Add private endpoint rule for ADLS DFS
databricks account network-connectivity-configs create-private-endpoint-rule \
  --network-connectivity-config-id ncc-xxx \
  --resource-id "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<storage>" \
  --group-id dfs

# 6. Add private endpoint rule for ADLS Blob
databricks account network-connectivity-configs create-private-endpoint-rule \
  --network-connectivity-config-id ncc-xxx \
  --resource-id "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<storage>" \
  --group-id blob

# 7. Associate NCC with workspace
databricks account workspace-network-config update \
  --workspace-id <workspace-id> \
  --network-connectivity-config-id ncc-xxx
```

> **Important**: After adding private endpoint rules, Databricks creates the actual private endpoints asynchronously. You must **approve** them in the Azure portal:
> Azure Portal → your storage account → Networking → Private endpoint connections → Approve pending connections

### Verify NCC is working

```sql
-- Run in Databricks SQL Editor on the Serverless SQL Warehouse
SELECT * FROM samples.nyctaxi.trips LIMIT 5;
-- If this returns data: NCC is working
-- If you get "Error: storage endpoint not reachable": NCC not yet approved
```

---

## 2. Hub VNet Reverse Peerings and Cross-Region PP-VNet Peering

Enterprise Policy requires a delegated subnet in **each of the two Azure regions** in the Power Platform region pair (see [§4](#4-power-platform-enterprise-policy)). These are separate VNets (one per region). For failover to work — if Power Platform fails over to the secondary region, the secondary VNet's traffic still needs to reach the Databricks spoke — the two PP-VNets must also **peer with each other**, not only with the hub.

Required peerings:
- Hub → PP-VNet-Primary (and reverse)
- Hub → PP-VNet-Secondary (and reverse)
- Hub → ADB Spoke VNet (and reverse)
- PP-VNet-Primary ↔ PP-VNet-Secondary (cross-region peer — both directions)

The Bicep creates peerings from PP-VNet→Hub and ADB-VNet→Hub, but VNet peering requires **both sides**. The networking team must add these on the Hub side:

```bash
# Ask networking team to run these on the Hub VNet subscription:
HUB_RG="<hub-resource-group>"
HUB_VNET="<hub-vnet-name>"

# Peering: Hub → PP-VNet
az network vnet peering create \
  --resource-group $HUB_RG \
  --vnet-name $HUB_VNET \
  --name "peer-hub-to-ppvnet" \
  --remote-vnet "<PP-VNet resource ID from deployment output>" \
  --allow-vnet-access true \
  --allow-forwarded-traffic true

# Peering: Hub → ADB Spoke VNet
az network vnet peering create \
  --resource-group $HUB_RG \
  --vnet-name $HUB_VNET \
  --name "peer-hub-to-adbvnet" \
  --remote-vnet "<ADB-VNet resource ID from deployment output>" \
  --allow-vnet-access true \
  --allow-forwarded-traffic true
```

```bash
# Cross-region peering: PP-VNet-Primary → PP-VNet-Secondary
# Run on the subscription that owns PP-VNet-Primary
az network vnet peering create \
  --resource-group <primary-rg> \
  --vnet-name <pp-vnet-primary> \
  --name "peer-ppvnet-primary-to-secondary" \
  --remote-vnet "<PP-VNet-Secondary resource ID>" \
  --allow-vnet-access true \
  --allow-forwarded-traffic true

# Cross-region peering: PP-VNet-Secondary → PP-VNet-Primary (reverse)
az network vnet peering create \
  --resource-group <secondary-rg> \
  --vnet-name <pp-vnet-secondary> \
  --name "peer-ppvnet-secondary-to-primary" \
  --remote-vnet "<PP-VNet-Primary resource ID>" \
  --allow-vnet-access true \
  --allow-forwarded-traffic true
```

> Cross-region VNet peering incurs bandwidth charges. In practice this traffic is only the failover path — Power Platform secondary region traffic is low-volume until a regional outage occurs.

**If Hub has a Firewall**: add UDR (User Defined Route) on PP-VNet and ADB-VNet subnets routing `0.0.0.0/0` → Firewall private IP. Then add Firewall rules to allow:
- PP-VNet → Databricks private endpoint IP: TCP 443
- Databricks control plane → Databricks private endpoint: TCP 443, 8443-8451

---

## 3. DNS Zone Linking to Hub VNet

The Bicep links the 4 private DNS zones to PP-VNet and ADB-VNet. You also need them linked to the Hub VNet so DNS resolution works for all traffic transiting the hub:

```bash
# Run for each zone: azuredatabricks.net, dfs.core.windows.net, blob.core.windows.net, vaultcore.azure.net
for ZONE in "privatelink.azuredatabricks.net" "privatelink.dfs.core.windows.net" "privatelink.blob.core.windows.net" "privatelink.vaultcore.azure.net"; do
  az network private-dns link vnet create \
    --resource-group "<deployment-rg>" \
    --zone-name "$ZONE" \
    --name "link-hub-$(echo $ZONE | tr '.' '-')" \
    --virtual-network "<Hub VNet resource ID>" \
    --registration-enabled false
done
```

> If the customer already has these DNS zones in the Hub VNet resource group, **do not create new zones** — link the existing ones to the PP-VNet and ADB-VNet instead.

---

## 4. Power Platform Enterprise Policy

This binds the deployed PP-VNet subnets to the Power Platform Managed Environment.

> **Reference**: https://learn.microsoft.com/en-us/power-platform/admin/vnet-support-setup-configure

---

### Step 0 — Register the resource provider (one-time per subscription)

```powershell
Register-AzResourceProvider -ProviderNamespace 'Microsoft.PowerPlatform'

# Wait until RegistrationState = Registered (takes ~1-2 min)
Get-AzResourceProvider -ProviderNamespace 'Microsoft.PowerPlatform' |
    Select-Object RegistrationState
```

> **Access required**: Contributor or Owner on the Azure subscription. In enterprise environments this is typically owned by the CloudX team — raise a request if you don't have access.

---

### Option A: PowerShell module (recommended for automation / scripted deployments)

```powershell
# Step 1 — Install the Enterprise Policies module
Install-Module Microsoft.PowerPlatform.EnterprisePolicies -Force
Import-Module Microsoft.PowerPlatform.EnterprisePolicies

# Step 2 — The PP-VNet and delegated subnets are already created by main.bicep.
# If you need to create them separately (without Bicep):
New-VnetForSubnetDelegation `
  -SubscriptionId "<subscription-id>" `
  -VirtualNetworkName "adbpa-pp-vnet" `
  -SubnetName "snet-pp-primary" `
  -ResourceGroupName "<deployment-rg>" `
  -AddressPrefix "10.200.0.0/16" `
  -SubnetPrefix "10.200.1.0/24" `
  -Region "eastus2"

# Step 3 — Create the Enterprise Policy resource
# (Microsoft.PowerPlatform/enterprisePolicies in your subscription)
# The module's New-EnterprisePolicy cmdlet creates this — run:
#   Get-Command -Module Microsoft.PowerPlatform.EnterprisePolicies
# for the full command list after installing the module.

# Step 4 — Link the policy to your Power Platform environment
Enable-SubnetInjection `
  -EnvironmentId "<power-platform-environment-id>" `
  -PolicyArmId "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.PowerPlatform/enterprisePolicies/<policyName>"
```

> Get your environment ID from Power Platform Admin Center: **Environments** → select environment → copy the ID from the URL (format: `00000000-0000-0000-0000-000000000000`).

---

### Option B: Admin Center UI

1. Go to [Power Platform Admin Center](https://admin.powerplatform.microsoft.com)
2. **Policies** → **Enterprise Policies** → **New Policy**
3. **Policy type**: `Network`
4. Select your **Managed Environment**
5. **Subscription**: select your Azure subscription
6. **Virtual Network**: select `adbpa-pp-vnet` (from deployment output)
7. **Primary subnet**: `snet-pp-primary`
8. **Secondary subnet**: `snet-pp-secondary`
9. Save and wait for policy to apply (~5-10 minutes)

---

### Validate

```powershell
# Via PowerShell module
Get-SubnetInjectionStatus -EnvironmentId "<environment-id>"
```

**Admin Center**: Manage → Environments → select environment → **History** → verify **Status: Succeeded**

### Operational constraints (do not skip)

- **Cannot change subnet CIDR after delegation**: if you need to resize, remove the delegation, resize, then re-enable. Plan subnet sizing before enabling.
- **Cannot change VNet DNS after delegation**: same process — remove, change DNS, re-enable.
- **Subnet sizing**: production environments use 25–30 IPs; dev/sandbox 6–10. If multiple environments share one Enterprise Policy, size accordingly: `(N × IPs per env) + 5 reserved`.
- **Secondary subnet region**: the primary and secondary subnets must be in the **two different Azure regions** of the Power Platform region pair — not the same region. Run `Get-EnvironmentRegion` to confirm the correct pair before creating subnets.
- **Internet-bound calls**: after delegation, public internet calls from connectors still work by default. Attach an [Azure NAT gateway](https://learn.microsoft.com/en-us/azure/nat-gateway/nat-overview) to the delegated subnet so outbound public traffic is logged, controlled, and exits from a known IP range. Without it, public egress uses random Azure fabric IPs.

---

## 5. DLP Policy Resolution

The Databricks connector must be in the **Business** tier of the organisation's DLP policy before Power Apps can connect to Databricks. This is a gate that must be resolved regardless of networking status.

Work with the CloudX/Security team to move the connector:

1. Power Platform Admin Center → **Policies** → **Data policies**
2. Find the policy that governs the target environment
3. Under **Connectors** → find `Databricks` → move to **Business** tier
4. Save policy

> There is no automation or CLI path for this step — it must be done in PPAC by someone with DLP admin rights. The connector will silently fail to connect (not a networking error) until this is done.

---

## 6. Verifying the Full Private Chain

Use this checklist after all manual steps are complete:

```powershell
# From a VM or jumpbox inside the PP-VNet or Hub VNet:

# 1. Databricks DNS resolves to private IP
Resolve-DnsName "adb-xxx.azuredatabricks.net"
# Expect: IP in your private endpoint subnet (e.g. 10.200.12.x)

# 2. ADLS DNS resolves to private IP
Resolve-DnsName "<storage>.dfs.core.windows.net"
# Expect: IP in your private endpoint subnet

# 3. Key Vault DNS resolves to private IP
Resolve-DnsName "<kv-name>.vault.azure.net"
# Expect: IP in your private endpoint subnet

# 4. Connectivity to Databricks (port 443)
Test-NetConnection "adb-xxx.azuredatabricks.net" -Port 443
# Expect: TcpTestSucceeded : True

# 5. End-to-end connector test (from Power Apps)
# Add a Label to a Canvas App, set Text to:
#   Text(Databricks.ExecuteQuery("SELECT current_user(), SESSION_USER()", {timeout: 30}))
# Run the app — should return the signed-in user's UPN (delegated auth)
# or the SP client ID (service principal auth)
```
