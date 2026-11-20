# Step 0 infrastructure deployment

Uses **Azure CLI + Bicep + PowerShell 7**. No Python, pip, uv environment, Databricks CLI, or azd is needed.

## What it provisions

Defaults are in [deployment.config.json](deployment.config.json). The subscription is selected at launch; the default region is **France Central**.

| Resource | Configuration |
|---|---|
| Resource group | `rg-rca-demo` |
| Microsoft Foundry account and project | `AIServices`, S0; project `rca-project`; system-assigned managed identities |
| Agent model deployment | `rca-agent`: `gpt-5.4`, version `2026-03-05`, capacity 10 |
| KB query-planning model deployment | `rca-query-planner`: `gpt-5.4-mini`, version `2026-03-17`, capacity 10 |
| Embedding model deployment | `rca-embedding`: `text-embedding-3-large`, version `1`, capacity 1 |
| Azure AI Search | Basic, one replica and partition, paid standard semantic ranker, system-assigned managed identity |
| Blob Storage | StorageV2, Standard LRS, Hot tier, private `rca-knowledge` container, HTTPS/TLS 1.2, seven-day blob soft delete |
| Azure Databricks | Premium workspace, secure cluster connectivity; a separate Databricks-managed resource group is also created |
| Unity Catalog | Verifies automatic metastore assignment; optionally assigns an existing regional metastore with `-MetastoreId` |
| SQL warehouse | `RCA Demo Serverless`, PRO/serverless, 2X-Small, one cluster maximum, five-minute auto-stop |
| Access | Managed-identity RBAC below; signed-in operator receives scoped access for subsequent setup |

Azure resource names include a deterministic subscription/resource-group suffix. Rerunning with the same subscription, resource group and prefix targets the same resources and reuses the named warehouse. Keep those values stable. Model capacity is in **Azure SKU units**, not a universal TPM count; allocation and current availability are checked against the live regional catalog and subscription quota. Existing matching model allocations are credited on reruns.

### Managed-identity permissions

- Foundry project identity: Storage Blob Data Reader on Storage; Search Index Data Reader and Search Service Contributor on Search; Cognitive Services OpenAI User on the Foundry account.
- Search identity: Storage Blob Data Reader on Storage and Cognitive Services OpenAI User on Foundry, for subsequent identity-based ingestion/vectorization.
- Deploying user/service principal: Azure AI User on the project, Storage Blob Data Contributor on Storage, Search Service Contributor and Search Index Data Contributor on Search.
- No account keys, passwords, PATs, or client secrets are generated or saved. Bearer tokens are used only in memory.

## Before running

1. Install [PowerShell 7](https://aka.ms/powershell-release) and [Azure CLI](https://aka.ms/installazurecliwindows).
2. Sign in with `az login`. The launcher also opens login if no cached subscriptions exist. For a different tenant, use `az login --tenant <tenant-id>`.
3. Use a subscription where you can create resource groups, register resource providers, create the resources, and assign roles: normally subscription **Owner**, or **Contributor plus User Access Administrator / Role Based Access Control Administrator**. Organization policies can impose additional restrictions.
4. Ensure Databricks is available for the subscription, serverless SQL is permitted in the account/region, and your deploying identity has Databricks workspace-admin/SQL-create access. Azure resource permissions alone do not guarantee Databricks data-plane permissions. New workspaces normally receive Unity Catalog automatically. If that is disabled in your account, a Databricks account admin must first create a regional metastore and supply its ID.
5. Review the configuration. The defaults use `GlobalStandard`, which does **not** guarantee EU-only model processing. Set `modelSku` to `DataZoneStandard` if EU data-zone processing is required and all three models support it with available quota. No automatic model, SKU, or region substitution is performed.

These are **billable demo resources**. Search incurs standing charges even when idle, semantic ranking can incur usage charges, and serverless SQL is billed while running. The warehouse starts for its smoke test and then auto-stops after inactivity. This is not a production-hardened network topology: endpoints are public but authenticated; blob anonymous access and Storage/Search/Foundry key authentication are disabled.

## Deploy

### Double-click

Double-click [deploy.cmd](../deploy.cmd) in the project root. Select the subscription, review the target and model table, then type `DEPLOY`. Leave the window open until the script completes.

### One CLI command

From the project root:

```powershell
pwsh -NoProfile -File .\infra\deploy.ps1 -SubscriptionId "<subscription-id>"
```

The script compiles Bicep, checks model versions/SKUs and quota, registers providers, creates the resource group, runs ARM validation, deploys resources and RBAC, checks Unity Catalog, creates/reconciles the serverless warehouse, waits for it to be RUNNING, and executes `SELECT 1`. It reports completion only after that query succeeds.

The console shows timestamped stages `[1/8]` through `[8/8]`, CLI operation start/completion timings, and warehouse/SQL status. During ARM deployment it polls approximately every 15 seconds (plus API response time), prints resource-state changes and an elapsed-time heartbeat, and displays Azure error details if deployment fails. Provider registration and ARM validation show start/completion messages but can take several minutes between them. Command arguments, tokens and credentials are not logged. Closing the terminal stops monitoring but does not cancel an ARM deployment already submitted to Azure.

For unattended use after reviewing the configuration, append `-Yes`. All subscription-specific CLI calls specify the selected subscription; the script does not change your global Azure CLI default subscription.

### Preflight without provisioning

```powershell
pwsh -NoProfile -File .\infra\deploy.ps1 -SubscriptionId "<subscription-id>" -ValidateOnly
```

This checks configuration, local Bicep compilation, live model/SKU availability and quota. It does not create resources, register providers or run a chargeable SQL warehouse. It requires Azure login and does not prove that ARM policies, deployment permissions, actual service capacity or Databricks configuration will permit deployment.

### Custom configuration / existing metastore

Edit the supplied configuration or pass your own JSON file with `-ConfigFile`. Region changes should be checked against the availability of **all** services, Foundry IQ features and Databricks serverless, not just model availability.

If automatic Unity Catalog assignment is unavailable:

```powershell
pwsh -NoProfile -File .\infra\deploy.ps1 `
  -SubscriptionId "<subscription-id>" `
  -MetastoreId "<existing-france-central-metastore-id>"
```

Assigning a metastore requires Databricks **account admin** permissions. The script never creates, replaces or deletes an account-level metastore and refuses to replace an existing different assignment. Metastores are shared regional governance resources, not ordinary Azure resources.

## Outputs and remaining setup

After ARM succeeds, `infra\deployment.outputs.json` contains the resource names, endpoints, subscription and resource group. On full success it also contains `warehouseId`, `metastoreId`, and `status: "Step 0 complete"`. Treat this file as environment metadata; it is ignored by Git.

If initialization fails, Azure resources remain deployed and the script exits nonzero. Read the error/output status, resolve the permission, quota, metastore or serverless issue, and rerun. No automatic rollback or destructive cleanup is attempted. If ARM itself fails, inspect deployment `rca-demo-infra` in the resource group's **Deployments** blade; outputs might not yet be available.

Foundry model deployments run serially, and project creation waits for all models, because concurrent project/model writes can produce `RequestConflict` on the parent account. If a separate deployment or portal operation holds that lock, let it finish before rerunning. Run only one deployment of this kit at a time; do not delete successfully provisioned resources to recover from this conflict.

This implements **Step 0**, not the complete demo:

- **Copilot Studio is excluded**, as requested.
- **ServiceNow developer instances cannot be provisioned with Azure CLI/ARM.** Request a PDI manually at <https://developer.servicenow.com/>; its signup, account/license and activation are external prerequisites.
- Continue [setup guide Steps 1-4](../README.md): upload/import CSVs and create Unity Catalog tables, configure Genie spaces, upload the document library, create the Foundry IQ knowledge base/indexer and its identity-based connections, configure OAuth/consent for Genie, and create the RCA agent. These are not deployed by this Step 0 script.
- The Foundry project uses the service's basic agent setup. This does not create a Standard Agent Setup capability host, Cosmos DB, private endpoints, or hosted-agent container infrastructure.
- The script validates ARM provisioning plus Databricks UC/SQL readiness. It does not test model inference, Search ingestion, KB retrieval, or the end-to-end RCA workflow; those require the later setup steps.

Use the model **deployment names** `rca-agent`, `rca-query-planner`, and `rca-embedding` when selecting deployments in Foundry. Allow a few minutes for new role assignments to propagate before configuring connections.

## Validation for maintainers

```powershell
az bicep build --file .\infra\main.bicep --stdout > $null
pwsh -NoProfile -File .\infra\tests\deployment.tests.ps1
```

The tests compile Bicep to verify Foundry resource ordering and mock the remaining CLI/Databricks operations. They require Azure CLI/Bicep but do not create Azure resources.

## Removing the demo

Use a dedicated resource group. When finished, review its contents and delete that group in the Azure portal. Databricks also creates a managed resource group and service-managed resources, whose removal is handled by Databricks; confirm removal and billing afterwards. Do not delete a shared Unity Catalog metastore or shared storage belonging to another workspace.

## References

- [Foundry account/project ARM schema](https://learn.microsoft.com/azure/templates/microsoft.cognitiveservices/2025-06-01/accounts/projects)
- [Model quota](https://learn.microsoft.com/azure/ai-foundry/openai/how-to/quota)
- [Unity Catalog workspace enablement](https://learn.microsoft.com/azure/databricks/data-governance/unity-catalog/enable-workspaces)
- [Databricks SQL warehouse API](https://docs.databricks.com/api/azure/workspace/warehouses/create)
