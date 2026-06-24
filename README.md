# Power Apps → Azure Databricks: Native Connector

**Scenario**: Power Apps canvas app reading from and writing to Azure Databricks via the native Databricks connector — fully private, Entra ID authenticated, Unity Catalog row-level security.

**Assumption**: The Databricks connector has been moved to the Business tier in the organisation's DLP policy. If that gate is still open, this pattern cannot be used — see the authentication section for the Service Principal workaround.

---

## What This Repo Contains

```
deploy/
  main.bicep          Full private network deployment (Bicep)
  parameters.json     Default parameter values (edit prefix, locations, address spaces)
  deploy.ps1          Deployment script — deploys Bicep + prints 9-step post-deploy guide

docs/
  implementation-guide.md   Complete setup guide: SP auth, Unity Catalog, RLS, Power Apps formulas
  networking.md             Post-deploy manual steps: NCC, hub peerings, DNS zones, Enterprise Policy
  architecture-brief.md     One-page architecture brief (current design gaps + proposed additions)
  databricks-setup.md       Databricks concepts reference (workspace, SQL Warehouse, Unity Catalog)
```

---

## What Gets Deployed

`deploy/main.bicep` deploys a complete private-networking foundation for the native connector path:

| Resource | Purpose |
|----------|---------|
| PP-VNet Primary + delegated subnet | Enterprise Policy primary region — injects connector into your VNet |
| PP-VNet Secondary + delegated subnet | Enterprise Policy secondary region — failover |
| Cross-region VNet peering (primary ↔ secondary) | Failover path between the two PP-VNets |
| Databricks spoke VNet + workspace (VNet-injected) | Workspace with no public IP option |
| Private endpoints — Databricks (ui_api + browser_auth) | Private workspace access |
| Private endpoints — ADLS (dfs + blob) | Private storage access |
| Private endpoint — Key Vault | Private secrets access |
| Private DNS zones — all 4 services | DNS resolution to private IPs |
| ADLS Gen2 (HNS, public access disabled) | Delta Lake storage |
| Databricks Access Connector (MSI) | Managed identity for Unity Catalog storage credential |
| Key Vault (private, RBAC) | Secrets store (available for future use) |

**Not deployed** (intentional): no Logic App, no Power Automate relay — the native connector goes directly `Power Apps → Databricks`.

---

## Quick Start

### Prerequisites

- Azure CLI logged in (`az login`)
- Databricks CLI installed (`pip install databricks-cli` or `brew install databricks`)
- Contributor or Owner on the target subscription

### Deploy

```powershell
# POC — stub hub VNet created automatically, workspace publicly accessible
.\deploy\deploy.ps1 -ResourceGroup "rg-powerapp-databricks-poc" -Location "eastus2"
```

```powershell
# With your existing Hub VNet
$hub = "/subscriptions/<sub>/resourceGroups/<hub-rg>/providers/Microsoft.Network/virtualNetworks/<hub-vnet>"
.\deploy\deploy.ps1 `
  -ResourceGroup "rg-powerapp-databricks" `
  -Location "eastus2" `
  -SecondaryLocation "eastus" `
  -HubVNetId $hub
```

> **`-SecondaryLocation`**: defaults to `eastus` (US pair). Run `Get-EnvironmentRegion` from the [PP subnet diagnostics module](https://learn.microsoft.com/en-us/troubleshoot/power-platform/administration/virtual-network#use-the-diagnostics-powershell-module) to confirm the correct paired region for your specific environment before deploying.

The script (~15–20 minutes) prints a 9-step post-deploy guide with exact commands populated from the deployment outputs.

### After deployment (summary)

The deploy script prints these steps in full. This is the sequence:

| Step | What | Who |
|------|------|-----|
| 1 | Confirm Databricks connector is in Business DLP tier in PPAC | Security / CloudX |
| 2 | Verify PP environment region pair | You |
| 3 | Hub VNet reverse peerings | Networking team |
| 4 | Power Platform Enterprise Policy — bind subnets to Managed Environment | PPAC admin |
| 5 | NCC — create + approve private endpoint rules for ADLS | Databricks admin |
| 6 | Create Serverless SQL Warehouse | You |
| 7 | Unity Catalog init — metastore, storage credential, external location, catalog, schema | You |
| 8 | Unity Catalog permissions + row-level security (SQL) | Data Platform team |
| 9 | Connect Power Apps — Phase 1 (PAT smoke test) → Phase 2 (Entra ID delegated) | You |

Full step-by-step: [`docs/implementation-guide.md`](docs/implementation-guide.md)

---

## Authentication Model

The native connector supports two auth modes:

| | OAuth (delegated) | Service Principal |
|---|---|---|
| Identity Databricks sees | Signed-in user's Entra ID UPN | SP client ID |
| `SESSION_USER()` / RLS | ✅ Per-user — works natively | ❌ Returns SP identity — RLS breaks |
| Each user needs Databricks account | **Yes** | No |
| Credential storage | None — user's own session | Client secret (stored in connection) |

**Recommendation**: OAuth delegated for production — no stored credentials, per-user RLS works automatically. Service Principal is documented for environments where provisioning individual Databricks accounts is not feasible; it requires moving per-user filtering into Power Apps formulas (`User().Email`).

Full SP setup, RLS bypass, and Power Apps formula patterns: [`docs/implementation-guide.md → Service Principal`](docs/implementation-guide.md#setting-up-a-service-principal-connection)

---

## Networking Architecture

```
Power Apps (user: alice@company.com)
    │  OAuth 2.0 delegated token
    ▼
Databricks Connector (Enterprise Policy — subnet injection)
    │  routes through customer VNet
    ▼
PP-VNet Primary (snet-pp-primary /24)
    │  VNet Peering
    ▼
Hub VNet (Azure Firewall + 4 private DNS zones)
    │  Private Link
    ▼
Databricks Workspace (Private Endpoint)
    │
    ├─ Serverless SQL Warehouse
    │      │  NCC private endpoint
    │      ▼
    │   ADLS Gen2 / Delta Lake (public access disabled)
    │
    └─ Unity Catalog (SESSION_USER() RLS)
           │  Access Connector MSI
           ▼
        ADLS Gen2 (Storage Blob Data Contributor)
```

Three layers required for end-to-end private connectivity:

```
Layer 1 — Enterprise Policy (VNet Injection)     routes connector traffic through your VNet
Layer 2 — Private Endpoints + Private DNS        resolves services to private IPs
Layer 3 — NCC (Databricks serverless)            gives the Serverless SQL Warehouse a private
                                                  path to ADLS — without this, all queries fail
```

Detailed post-deploy networking steps: [`docs/networking.md`](docs/networking.md)

---

## Key Constraints

| Constraint | Detail |
|-----------|--------|
| DLP gate | Databricks connector must be in Business tier — nothing works until confirmed in PPAC |
| NCC is critical | Serverless SQL Warehouse cannot reach private ADLS without it — queries silently return no data |
| Region pair | Secondary PP-VNet must be in the exact paired region for your PP environment — not just any secondary region |
| Databricks accounts | OAuth delegated auth requires every Power Apps user to have a provisioned Databricks account |
| Subnet delegation lock | Cannot change subnet CIDR or VNet DNS after delegation without removing and re-enabling Enterprise Policy |

---

## POC Phases

**Phase 1 — connector smoke test** (no private networking needed)
- Connector + PAT auth → verify DLP is cleared, read/write works, RLS returns expected rows

**Phase 2 — full private path**
- Enterprise Policy → Hub peerings → DNS zones → NCC → switch to Entra ID delegated auth → verify per-user RLS

Full POC checklist with exact commands: [`docs/implementation-guide.md → POC Checklist`](docs/implementation-guide.md#poc-checklist--scenario-a)
