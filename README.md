# RCA Agent Demo Kit - Foundry IQ + Azure Databricks + Copilot Studio

## What this demo shows

An AI agent that turns a critical manufacturing incident into a cited, draft Root Cause Analysis (RCA) in minutes instead of days.

Today, engineers spend hours collecting evidence from many systems: sensor and maintenance data, quality inspections, past RCA reports, SOPs, shift logs, chats and ServiceNow tickets. In this demo, an engineer asks in Teams/Copilot Studio to *"Investigate INC0019874"*. The **RCA Analyst** agent in Microsoft Foundry then:

- reads the incident from **ServiceNow** (through Copilot Studio),
- queries structured plant data through **Azure Databricks Genie** (Unity Catalog governed, one space each for Maintenance and Quality),
- searches unstructured knowledge (past RCAs, SOPs, manuals, lessons learned, shift logs, Teams exports, incident history) through a **Foundry IQ** knowledge base on Azure AI Search,
- works through the standard RCA questions and returns a **DRAFT RCA** with root cause, contributing causes, ruled-out causes, CAPAs, a confidence level and source citations, for human review and approval.

**The scenario:** silver streaks and brittle parts on Eindhoven Line 2, with ~20k parts quarantined. The agent finds evidence planted across the data sources: a resin dryer whose maintenance was deferred, a dew point drifting for days below an alarm threshold left at the OEM default, a wet resin lot from a supplier with a known history, and the same failure mode at another plant last year, whose corrective actions were never rolled out to Eindhoven. The key message: the agent connects structured and unstructured evidence across systems and sites, and exposes **process gaps**, not just the immediate cause.

The kit includes one-click Azure provisioning ([infra/](infra/README.md)), all synthetic data and documents, the agent instructions and a [demo script](06_DEMO_SCRIPT.md).

All data in this kit is **synthetic** (fictitious company "Fabrikam Components", 3 injection-moulding plants: Eindhoven EIN, Brno BRN, Valencia VAL). Data window: 20 Sep - 4 Nov 2026.

## Target architecture

```
 Teams / M365 Copilot                ServiceNow (P1/P2 trigger, incidents, work notes)
          |                                   ^
          v                                   |
 [Copilot Studio "RCA Assistant"] ------------+   front door, orchestration, approvals, SharePoint draft
          | connected agent (passes incident context)
          v
 [Foundry agent "rca-analyst"]  -- reasoning, SOP-RCA-001 questions, drafts RCA
     |                         \
     | knowledge (Foundry IQ)   \ tools (Azure Databricks Genie)
     v                           v
 Azure AI Search KB  <- Blob    Genie "RCA Maintenance"  +  Genie "RCA Quality"
 (RCAs, SOPs, manuals,          (Unity Catalog tables + metric view, existing pattern
  shift logs, Teams export,      at the customer - we extend it, we don't replace it)
  ServiceNow history)
```

## Kit contents
| Folder | What | Goes to |
|---|---|---|
| 01_databricks/data | 8 CSVs (sites, equipment, lots, hourly sensors ~88k rows, batches, inspections, downtime, work orders) | UC Volume -> Delta tables |
| 01_databricks/setup_unity_catalog.sql | Catalog, tables, views, metric view, grants, sanity checks | Databricks SQL editor |
| 01_databricks/genie_spaces_config.md | Two Genie spaces: tables, instructions, sample/trusted SQL | Genie UI |
| 02_foundry_iq_blob/ | 5 RCA reports, 3 SOPs, OEM manual, lessons learned, template, shift log, Teams export, 77 ServiceNow history files | Blob container `rca-knowledge` |
| 03_servicenow/ | incidents (78) + problems as CSV/JSON | ServiceNow PDI import |
| 04_foundry_agent/agent_instructions.md | System prompt for the Foundry agent | Foundry agent |
| 05_copilot_studio/ | Copilot Studio, ServiceNow and proactive-flow notes | Colleague |
| 06_DEMO_SCRIPT.md | Storyline, prompts, expected answers | Rehearsal |

## Step 0 - Prerequisites (one resource group, same region)

**Automated Azure provisioning (no Python required):** double-click [deploy.cmd](deploy.cmd), or run:

```powershell
pwsh -NoProfile -File .\infra\deploy.ps1 -SubscriptionId "<subscription-id>"
```

See [deployment instructions and resource inventory](infra/README.md) for prerequisites, configuration, quota checks, validation-only mode, permissions, costs, and troubleshooting. The script deploys the Foundry account/project and three models, Search, Blob Storage, Databricks Premium, managed identities/RBAC, and a serverless SQL warehouse. It verifies Unity Catalog (or assigns an existing metastore when supplied). Defaults: France Central, `gpt-5.4`, `gpt-5.4-mini`, `text-embedding-3-large`, and Global Standard. Databricks also creates its own managed resource group.

**Excluded:** Copilot Studio; ServiceNow PDI signup (external to Azure); the data import, knowledge base, Genie/OAuth and agent configuration in Steps 1-4. Automatic Unity Catalog assignment and serverless availability depend on the Databricks account; a missing metastore requires account-admin setup rather than an Azure template alone. Outputs are saved to `infra\deployment.outputs.json`; completion requires a successful serverless SQL smoke test.

- **Region (verified against Microsoft Learn, Nov 2026): France Central for everything.** Agent Service + MCP tool + Azure AI Search tool: yes; AI Search agentic retrieval + semantic ranker + AI enrichment: yes and NOT flagged high-demand; Databricks serverless: yes. Alternatives with the same full coverage: UK South, Switzerland North. AVOID creating AI Search in Sweden Central, West Europe, Germany West Central or North Europe - flagged high-demand, new search services can be blocked (Foundry itself may still go there; Search can sit in another region).
- Microsoft Foundry resource + project (new Foundry portal) in France Central.
- Model deployments (Global Standard or Data Zone Standard EU; confirm quota in Foundry > Operate > Quota): agent model that supports the MCP tool in Agent Service - gpt-4.1 or gpt-5.4 (gpt-5-mini does NOT support MCP in Agent Service); KB query-planning model gpt-4.1-mini or gpt-5.4-mini; text-embedding-3-large.
- Azure AI Search (Basic or higher; semantic ranker enabled).
- Storage account (StorageV2) with container `rca-knowledge`.
- Azure Databricks workspace, Premium, Unity Catalog enabled, serverless SQL warehouse.
- Copilot Studio environment (same Entra tenant), ServiceNow developer instance (developer.servicenow.com).
- Identities: Foundry project managed identity -> `Storage Blob Data Reader` on the storage account; Search service managed identity -> `Storage Blob Data Reader`; Foundry project MI -> `Search Index Data Reader` + `Search Service Contributor` on Search (or follow the wizard prompts).

## Step 1 - Databricks (approx. 30 min)
1. In Databricks Catalog Explorer, create catalog `rca_demo_data` with managed storage before running SQL. Select your workspace's registered external location (`<your-external-location>`, for example `<prefix><suffix>_dbw`) and sub/path `rca-demo-data`. Creating managed storage requires the appropriate external-location privileges. A metastore assignment alone does not guarantee a storage root. Then run the first block of [setup_unity_catalog.sql](01_databricks/setup_unity_catalog.sql) on **RCA Demo Serverless** (catalog check, schemas, volume). Do not recreate or delete the existing configured catalog.
2. Upload all files in `01_databricks/data` to `/Volumes/rca_demo_data/raw/landing/`.
3. Run the rest of the script; the optional metric view is commented out and not required. Check the two sanity queries at the end (EIN L2 defect rate ~1% -> ~19%; dryer dew point -42 C -> -16 C).
4. Create the two Genie spaces per `genie_spaces_config.md`, add instructions and sample questions, test them in the Genie UI first. Note the space IDs.
5. Grant the identity Foundry will use: USE CATALOG/SCHEMA + SELECT, CAN USE on the warehouse, CAN RUN on both spaces.

## Step 2 - Blob + Foundry IQ knowledge base (approx. 30 min)
1. Upload the content of `02_foundry_iq_blob/` to container `rca-knowledge` keeping the folders (rca-reports, procedures, manuals, lessons-learned, templates, communications, servicenow-history).
2. Foundry portal > your project > Knowledge (Foundry IQ) > connect the Azure AI Search resource.
3. Create knowledge base `rca-kb`; add knowledge source **Azure Blob Storage** -> container `rca-knowledge`; select the embedding model and the query-planning model. This creates index + indexer + vectorization for you.
4. Wait for ingestion; test in the KB playground: "What was the root cause of RCA-2025-014?" and "Which sites have implemented the -30 C dew point alarm?"
5. (Phase-2 story) add a SharePoint knowledge source for the customer's real RCA library - same KB, no agent change.

## Step 3 - Databricks as a tool in Foundry
Recommended: **Azure Databricks Genie as a tool** (not as knowledge). Structured data needs SQL generation and Unity Catalog governance - Genie already does this, and it reuses the customer's existing investment.
- Prerequisites (Public Preview): enable the **Managed MCP Servers** preview in the Databricks workspace; register a **custom OAuth application** in the Databricks account (client id/secret, token/auth/refresh URLs).
- Foundry > Tools > search **Azure Databricks Genie** > Connect: Remote MCP Server endpoint = the Genie space's MCP endpoint (`https://<workspace-url>/api/2.0/mcp/genie/<space_id>`), authentication = OAuth identity passthrough (set automatically). One connection per space (Maintenance, Quality).
- Then 'Use in an agent' > send a message > Open consent > sign in to Databricks > Approve.
- Identity passthrough means Unity Catalog permissions apply per user - good governance story; give your demo users USE CATALOG on `rca_demo_data` and USE SCHEMA/SELECT on the relevant schemas.
- Note: Genie Spaces are now called Genie Agents in Databricks docs. Genie API rate limits apply (an earlier doc version stated ~5 questions/min) - keep demo questions focused.
- Write clear tool descriptions (copy from agent_instructions.md) - the model routes on them.

## Step 4 - Foundry agent (approx. 20 min)
1. Foundry > Agents > New agent `rca-analyst`, model = your chat model.
2. Instructions: paste `04_foundry_agent/agent_instructions.md`.
3. Knowledge: add Foundry IQ knowledge base `rca-kb`.
4. Tools: Genie Maintenance, Genie Quality. Optional: Code Interpreter (to chart dew point vs defect rate).
5. Test in the playground with the prompts in `06_DEMO_SCRIPT.md`. Tune Genie instructions first if SQL answers are wrong.
6. Publish/enable the agent and note project endpoint + agent id for Copilot Studio.

## Step 5 - Copilot Studio + ServiceNow (colleague)
See `05_copilot_studio/copilot_studio_and_servicenow_notes.md`: connected Foundry agent, ServiceNow actions, P1/P2 trigger, SharePoint draft, approval, write-back.

## Step 6 - Feedback loop (show it, even if simulated)
Approved RCA -> saved to `rca-knowledge/rca-reports/approved/` (or SharePoint library) -> indexer re-runs -> next incident finds it. Thumbs up/down + comments via Copilot Studio analytics; operator fixes via ServiceNow close notes (already part of the history export).

## Known risks to test early
- Latency: Copilot Studio -> Foundry -> Genie can take 30-90 s for a full RCA draft. Use the proactive/async flow for the full draft and keep interactive questions focused.
- Preview features and region availability (Foundry IQ, Genie tool, connected Foundry agents) - verify in the target tenant before the customer session.
- Identity chain end to end (Copilot Studio user -> Foundry -> Databricks).
