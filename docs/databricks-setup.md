# Databricks Setup Guide

Quick reference for the Databricks concepts used in this project.

## Key Concepts

| Term | What it is | Analogy |
|------|-----------|---------|
| **Workspace** | Your Databricks environment (URL: `adb-xxx.azuredatabricks.net`) | Azure subscription |
| **Cluster** | Spark compute for notebooks/jobs | VM scale set |
| **SQL Warehouse** | Purpose-built SQL compute (faster cold start, ODBC/JDBC) | Azure SQL Server |
| **Notebook** | Interactive code editor (Python/SQL/R/Scala) | Jupyter notebook |
| **Delta Table** | Versioned, ACID-compliant table on ADLS Gen2 | SQL table with time travel |
| **Unity Catalog** | Centralized governance across workspaces | Azure Purview (for Databricks) |
| **PAT** | Personal Access Token — bearer token for REST/connector auth | API key |

---

## Workspace Setup

Complete these four steps once before anything else. The rest of this guide assumes the workspace is already running.

### Step 1 — Create the Workspace with VNet Injection

VNet injection deploys cluster VMs into a VNet you own rather than a Databricks-managed one. This is required for private connectivity and is a hard prerequisite for Steps 2–4.

**VNet prerequisites** — two subnets dedicated exclusively to Databricks (no other resources):

| Subnet | Purpose | Min size |
|--------|---------|----------|
| `snet-adb-public` | Driver/worker public NICs | /26 (64 IPs) |
| `snet-adb-private` | Driver/worker private NICs | /26 (64 IPs) |

Both subnets must have `Microsoft.Databricks/workspaces` service delegation.

**Portal**: Create a resource → Azure Databricks → **Networking** tab:
- Deploy in your own VNet: **Yes**
- Virtual network: `adbpa-adb-vnet`
- Public subnet: `snet-adb-public` / Private subnet: `snet-adb-private`
- Pricing tier: **Premium** (required for Unity Catalog and private endpoints)

**Bicep**:
```bicep
resource databricksWorkspace 'Microsoft.Databricks/workspaces@2023-02-01' = {
  name: workspaceName
  location: location
  sku: { name: 'premium' }
  properties: {
    managedResourceGroupId: '${subscription().id}/resourceGroups/${managedRgName}'
    parameters: {
      customVirtualNetworkId:  { value: vnet.id }
      customPublicSubnetName:  { value: 'snet-adb-public' }
      customPrivateSubnetName: { value: 'snet-adb-private' }
      enableNoPublicIp:        { value: true }  // NPIP — see Step 2
    }
  }
}
```

---

### Step 2 — Enable No Public IP (NPIP / Secure Cluster Connectivity)

NPIP removes public IPs from all cluster nodes. Traffic between the Databricks control plane and your compute flows through a secure relay — no inbound ports, no public IPs on VMs.

| | Standard VNet injection | NPIP (recommended) |
|--|--|--|
| Cluster node public IPs | Yes | No |
| Inbound NSG rules needed | Yes (control plane CIDRs) | No |
| Satisfies "no public IPs" policy | No | Yes |

Enable via `enableNoPublicIp: true` in Bicep (shown above) or the **Secure Cluster Connectivity** toggle in the portal Networking tab.

**Required outbound NSG rules** on both `snet-adb-public` and `snet-adb-private`:

| Priority | Destination service tag | Port | Protocol | Purpose |
|----------|------------------------|------|----------|---------|
| 100 | `AzureDatabricks` | 443 | TCP | Control plane API |
| 110 | `Storage` | 443 | TCP | ADLS / DBFS |
| 120 | `Sql` | 3306 | TCP | Hive metastore |
| 130 | `AzureDatabricks` | 5557 | UDP | Secure relay tunnel |

---

### Step 3 — Private Endpoint for the Control Plane

With NPIP the VMs have no public IPs, but the workspace URL (`adb-xxx.azuredatabricks.net`) still resolves to a public IP by default. Private endpoints move all API and UI traffic onto the private network.

Create two endpoints — one for the REST API/UI, one for browser SSO redirects:

```powershell
# UI + REST API
az network private-endpoint create `
  --resource-group <rg> --name "pe-adb-ui-api" `
  --vnet-name "adbpa-pp-vnet" --subnet "snet-private-endpoints" `
  --private-connection-resource-id "<workspace-resource-id>" `
  --group-id "databricks_ui_api" --connection-name "pec-adb-ui-api"

# Browser authentication (SSO redirects)
az network private-endpoint create `
  --resource-group <rg> --name "pe-adb-browser-auth" `
  --vnet-name "adbpa-pp-vnet" --subnet "snet-private-endpoints" `
  --private-connection-resource-id "<workspace-resource-id>" `
  --group-id "browser_authentication" --connection-name "pec-adb-browser-auth"
```

Register A-records in the `privatelink.azuredatabricks.net` private DNS zone:

```powershell
$uiApiIp   = az network private-endpoint show -g <rg> -n pe-adb-ui-api `
               --query 'customDnsConfigs[0].ipAddresses[0]' -o tsv
$browserIp = az network private-endpoint show -g <rg> -n pe-adb-browser-auth `
               --query 'customDnsConfigs[0].ipAddresses[0]' -o tsv

az network private-dns record-set a add-record `
  --resource-group <rg> --zone-name "privatelink.azuredatabricks.net" `
  --record-set-name "adb-<workspace-id>" --ipv4-address $uiApiIp

az network private-dns record-set a add-record `
  --resource-group <rg> --zone-name "privatelink.azuredatabricks.net" `
  --record-set-name "adb-<workspace-id>-auth" --ipv4-address $browserIp
```

Finally, disable public access on the workspace:

> Azure Portal → workspace → **Networking** → **Public network access** → **Disabled**

---

### Step 4 — Enable Unity Catalog

Unity Catalog is configured at the **Databricks account level** (`accounts.azuredatabricks.net`), not the workspace level. You need Databricks Account Admin to complete this.

#### 4a — Create an Access Connector (MSI for metastore storage)

Unity Catalog stores managed tables in an ADLS Gen2 container. A Databricks Access Connector provides the MSI that reads/writes that container.

```powershell
az databricks access-connector create `
  --resource-group <rg> --name "ac-unity-catalog" `
  --location eastus2 --identity-type SystemAssigned

$acPrincipalId = az databricks access-connector show `
  -g <rg> -n ac-unity-catalog --query identity.principalId -o tsv

az role assignment create `
  --assignee $acPrincipalId `
  --role "Storage Blob Data Contributor" `
  --scope "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<storage>/blobServices/default/containers/unity-catalog"
```

#### 4b — Create the metastore (one per region)

```bash
# Databricks CLI — account scope
databricks account metastores create \
  --name "uc-eastus2" \
  --storage-root "abfss://unity-catalog@<storage>.dfs.core.windows.net/" \
  --region eastus2
# Note the metastore_id in the output
```

Or: Accounts console → **Catalog** → **Create metastore**

#### 4c — Assign the metastore to your workspace

```bash
databricks account metastore-assignments create \
  --workspace-id <workspace-id> \
  --metastore-id <metastore-id>
```

#### 4d — Register the storage credential

```bash
databricks storage-credentials create \
  --name "sc-unity-catalog-adls" \
  --azure-managed-identity \
    access-connector-id="/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Databricks/accessConnectors/ac-unity-catalog"
```

#### 4e — Grant initial admin permissions

```sql
-- Run in Databricks SQL Editor after metastore assignment
GRANT CREATE CATALOG ON METASTORE TO `<admin-group-or-user>`;
```

> For granting table-level permissions to the Logic App MSI after workspace setup, see [`enterprise-networking.md → §6`](enterprise-networking.md).

---

## SQL Warehouse vs. All-Purpose Cluster

| | SQL Warehouse | All-Purpose Cluster |
|--|--------------|---------------------|
| Best for | BI, reporting, Power Apps queries | Interactive notebooks, development |
| Cold start | ~20-45 seconds (serverless: ~5s) | 3-5 minutes |
| Cost | Per DBU, auto-stop | Per DBU + VM cost |
| ODBC/JDBC | Yes | Yes (but not default) |
| Use in this project | Patterns 1 & 2 (SQL queries) | Running notebooks (Pattern 2 jobs) |

**Warehouse type comparison**:

| Type | Cold start | Runs in | NCC needed for private ADLS | Account Admin needed |
|------|-----------|---------|----------------------------|---------------------|
| **Serverless** | ~5s | Databricks-managed compute (outside VNet) | Yes | Yes (for NCC setup) |
| **Pro** | ~20-45s | Customer VNet | No | No |
| **Classic** | ~20-45s | Customer VNet | No | No |

**Demo (this project)**: Uses a **Pro** warehouse — runs inside the ADB spoke VNet, no NCC required, no Account Admin dependency. Works immediately after deployment.

**Customer production**: Switch to **Serverless** for ~5s cold start and zero compute management overhead. Requires NCC configuration (Account Admin) only if data is in private ADLS. If using Databricks-managed storage (auto-provisioned metastore Default Storage), Serverless works without NCC.

---

## Setting up a SQL Warehouse

1. Databricks UI → **Compute** → **SQL Warehouses** → **Create a SQL Warehouse**
2. Settings:
   - **Name**: `powerapps-demo`
   - **Cluster size**: `Small` (4 DBUs/hour — good balance for demos)
   - **Auto-stop**: `10 minutes` (keep warm during demo, saves cost otherwise)
   - **Type**: **Pro** (for this demo — see table above; switch to Serverless for production)
3. **Connection details** tab → copy:
   - **Server hostname**: `adb-12345678901234.56.azuredatabricks.net`
   - **HTTP path**: `/sql/1.0/warehouses/abcdef0123456789`

---

## Authentication

### Recommended: Entra ID (Managed Identity or interactive)

Databricks supports Entra ID (Azure AD) OAuth tokens natively. The Databricks resource ID in Entra ID is fixed across all tenants: `2ff814a6-3304-4ab8-85cb-cd0e6f879c1d`.

**In Azure (Logic App, Function App, any service with Managed Identity):**

The service's MSI requests a token for the Databricks resource — no secret is created or stored anywhere. This is what `enterprise.bicep` deploys.

```python
# Python — works in any Azure service with a Managed Identity
from azure.identity import ManagedIdentityCredential

DATABRICKS_RESOURCE_ID = "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d"

credential = ManagedIdentityCredential()
token = credential.get_token(f"{DATABRICKS_RESOURCE_ID}/.default").token
# Use as: Authorization: Bearer <token>
```

**For local development / CLI testing:**

Use the Azure CLI login — the token comes from your own Entra ID identity, not a PAT.

```powershell
# Login once
az login

# Get a Databricks token (your Entra ID identity)
$token = az account get-access-token `
  --resource "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d" `
  --query accessToken -o tsv

# Test against the workspace
$workspaceUrl = "https://adb-xxx.azuredatabricks.net"
Invoke-RestMethod -Uri "$workspaceUrl/api/2.0/sql/warehouses" `
  -Headers @{ Authorization = "Bearer $token" } `
  -Method GET | ConvertTo-Json -Depth 5
```

> **Prerequisite**: your Entra ID user (or the MSI) must be registered in the Databricks workspace as a service principal or user, and granted Unity Catalog permissions. See [`enterprise-networking.md → Identity`](enterprise-networking.md) for setup steps.

---

### Reference only: Personal Access Token (PAT)

PATs are required for **Pattern 1 (direct connector)** — the native Power Platform Databricks connector does not support Entra ID tokens. For all other patterns (Logic App, Azure Functions), use Managed Identity above.

> PATs are long-lived shared secrets tied to a user account. They do not satisfy the "no shared credentials" enterprise requirement and should not be used in production for this customer.

```
Databricks UI → top-right avatar → Settings → Developer → Access tokens → Generate new token
  Comment: power-apps-connector
  Lifetime: 90 days
```

If a PAT must be stored, use Key Vault:
```powershell
az keyvault secret set --vault-name <kv-name> --name databricks-pat --value "dapi..."
```

---

## Sample Data Available Out-of-the-Box

All Databricks workspaces include the `samples` catalog — no setup required:

```sql
SHOW TABLES IN samples.nyctaxi;
-- trips, yellow_taxi_features

SHOW TABLES IN samples.tpch;
-- customer, lineitem, nation, orders, part, partsupp, region, supplier

SELECT * FROM samples.nyctaxi.trips LIMIT 5;
```

---

## Databricks REST API Quick Reference

All patterns use the Databricks REST API. Base URL: `https://<workspace-url>`

| Operation | Method | Endpoint |
|-----------|--------|----------|
| Execute SQL statement | POST | `/api/2.0/sql/statements` |
| Get statement result | GET | `/api/2.0/sql/statements/{id}` |
| Submit job run | POST | `/api/2.0/jobs/runs/submit` |
| Get job run status | GET | `/api/2.0/jobs/runs/get?run_id={id}` |
| List SQL Warehouses | GET | `/api/2.0/sql/warehouses` |
| List clusters | GET | `/api/2.0/clusters/list` |

**Authentication header**: `Authorization: Bearer <Entra ID token>`

Get a token using the Azure CLI (your own Entra ID identity — no PAT needed):
```powershell
$token = az account get-access-token `
  --resource "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d" `
  --query accessToken -o tsv
```

### List your SQL Warehouses

```powershell
$workspaceUrl = "https://adb-xxx.azuredatabricks.net"

Invoke-RestMethod -Uri "$workspaceUrl/api/2.0/sql/warehouses" `
  -Headers @{ Authorization = "Bearer $token" } `
  -Method GET | ConvertTo-Json -Depth 5
```

### Execute a SQL statement

```powershell
$body = @{
    statement    = "SELECT * FROM samples.nyctaxi.trips LIMIT 5"
    warehouse_id = "<your-warehouse-id>"
    wait_timeout = "50s"
} | ConvertTo-Json

Invoke-RestMethod -Uri "$workspaceUrl/api/2.0/sql/statements" `
  -Headers @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" } `
  -Method POST -Body $body | ConvertTo-Json -Depth 10
```

---

## Cost Estimates (rough)

| Resource | Estimated monthly cost |
|----------|----------------------|
| Databricks Standard workspace | Free (pay for compute only) |
| 2X-Small SQL Warehouse, 8h/day, 20 days | ~$40-80/month |
| Logic App (consumption) ~1000 runs | ~$0.50/month |
| Key Vault (standard) | ~$5/month |
| Storage (100 GB ADLS Gen2) | ~$2/month |
| **Total (dev/demo)** | **~$50-90/month** |

Stop the SQL Warehouse when not in use. The Bicep template sets auto-stop, but the warehouse still incurs cost while running.
