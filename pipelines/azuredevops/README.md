# Azure AI Landing Zone – CI/CD Pipelines

CI/CD pipelines for deploying the Azure AI Landing Zone Bicep infrastructure via Azure DevOps.
Uses Azure Developer CLI (`azd`) for provisioning, matching the upstream repo's recommended deployment flow.

---

## Quick Start

1. Complete the [Azure Setup Guide](docs/setup-guide.md) (Steps 1–6)
2. Follow the [Pipeline Usage Guide](docs/pipeline-usage.md) (Steps 7–10)
3. See [Maintenance & Troubleshooting](docs/maintenance.md) for ongoing operations

---

## Pipeline Files

| File | Purpose |
|------|---------|
| `ci-pipeline.yml` | CI – Bicep compile, lint, and publish artifact on every PR and push to `main` |
| `cd-pipeline.yml` | CD – Manual, sequential deployment: DEV → TEST → PROD (with approval gates configured on Environments) |
| `templates/variables.yml` | Shared variables (per-env service connection, location, environment name, retry count) |
| `templates/validate-bicep.yml` | Reusable job: Bicep build + lint + publish artifact |
| `templates/deploy-bicep.yml` | Reusable deployment job using `azd provision` with built-in retry loop |
| `templates/preview-bicep.yml` | (Unused, retained for future) Reusable job for `azd provision --preview` |
| `../../tools/azure_region_capacity_checker.ps1` | Shared local helper to rank Azure regions by service support, VM SKU, vCPU, AI Search and Cognitive quota |
| `../../tools/check-resource-providers.ps1` | Optional shared helper to verify (and optionally register) the Azure resource providers required by `main.bicep` |

---

## Prerequisites

- Azure DevOps organization with a project containing a Git repository
- One Azure subscription per environment (DEV/TEST/PROD can share or differ); deploying identity needs **Owner**, or **Contributor** + **User Access Administrator** + **Cognitive Services Contributor**
- **Project Administrator** or **Build Administrator** role in Azure DevOps
- Parallel job grant ([request here](https://aka.ms/azpipelines-parallelism-request)) or self-hosted agent
- Azure CLI and Azure Developer CLI (`azd`) installed locally

### Optional — Region Capacity Check

AI Landing Zone deploys resources such as Virtual Machines, Cosmos DB, AI Services, and Container Apps that are subject to **regional quota and availability constraints**. Deploying to a region with insufficient capacity can cause provisioning failures.

Before starting your deployment, verify that the target region is configured in [templates/variables.yml](templates/variables.yml) (`location` variable). To help you choose the right region, run the capacity checker script included in this repository:

```powershell
az login
./tools/azure_region_capacity_checker.ps1
```

The script checks VM SKU availability, compute vCPU quota headroom, Cosmos DB availability zone support, Azure AI Search SKU quota/capability, and AI service registration across candidate regions, then ranks them by overall readiness.

> **Tip:** The script accepts optional parameters such as `-VmSku`, `-Regions`, `-Top`, and `-OutputFormat`.
> Run `Get-Help ./tools/azure_region_capacity_checker.ps1 -Detailed` for the full parameter list.

After reviewing the output, update the `location` variable in [templates/variables.yml](templates/variables.yml) (or run `azd env set AZURE_LOCATION <region>` for `azd`-based deployments) before provisioning.

---

## Documentation

| Guide | Contents |
|-------|----------|
| [Azure Setup Guide](docs/setup-guide.md) | Service connections (per env), RBAC roles, environments, approval gates, variable groups, pipeline variables |
| [Pipeline Usage Guide](docs/pipeline-usage.md) | Register pipelines, authorize permissions, run & verify, architecture diagram, customization |
| [Maintenance & Troubleshooting](docs/maintenance.md) | Syncing upstream updates, troubleshooting errors, local debugging |

---

## Pipeline Architecture

:::mermaid
graph LR
    PR[PR / push main] --> CI[CI: build + lint] -.manual.-> Build[CD: build]
    Build --> Dev[DEV] -->|approve| Test[TEST] -->|approve| Prod[PROD]
    Dev -.retry.-> Dev
    Test -.retry.-> Test
    Prod -.retry.-> Prod
:::

- Each env stage runs only when its `deploy<Env>` boolean is set to `true` at queue time (all default to `false`).
- Stages are chained: `Test.dependsOn = Dev`, `Prod.dependsOn = Test`. A failed env skips all later envs.
- `azd provision` retries on transient Azure failures; controlled by `deployRetryCount` in `templates/variables.yml` (default `2`, set to `0` to disable).
- Approvals are configured on Azure DevOps **Environments** (outside YAML), not in the pipeline file.

---

> **Next:** Start with the [Azure Setup Guide](docs/setup-guide.md) to configure your Azure and Azure DevOps environment.
