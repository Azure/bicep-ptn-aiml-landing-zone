# Azure AI Landing Zone

## Overview

The Azure AI Landing Zone is an enterprise-scale, production-ready reference architecture designed to deploy secure and resilient AI applications and agents on Azure. This repository contains the Bicep implementation, the Terraform implementations are available in separate repositories.   

![Architecture Diagram](media/Architecture%20Diagram.png)

## How to Deploy

Choose your preferred deployment method based on project requirements and environment constraints.

### Prerequisites

**Required Permissions:**

- Azure subscription with **Contributor** and **User Access Admin** roles
- Agreement to Responsible AI terms for Azure AI Services

**Required Tools:**

- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)
- [Azure Developer CLI](https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/install-azd)
- [Git](https://git-scm.com/downloads)

> Azure CLI is included as a prerequisite for future pre/post provisioning hooks that may depend on it.

### Basic Deployment

Quick setup for demos without network isolation.

**Initialize the project**

```
azd init -t azure/bicep-ptn-aiml-landing-zone
```

**Sign in to Azure**

```
az login
azd auth login
```

> Add `--tenant` for `az` or `--tenant-id` for `azd` if you want a specific tenant.

**Provision Infrastructure**

```
azd provision
```
> **Optional:** You can change parameter values in `main.parameters.json` or set them using `azd env set` before running `azd provision`. The latter applies only to parameters that support environment variable substitution.

### Zero Trust Deployment

For deployments that **require network isolation**.

**Before Provisioning**

Enable network isolation in your environment:

```
azd env set NETWORK_ISOLATION true
```

> **Optional:** Update other parameters in `main.parameters.json` or via `azd env set` before provisioning.

Make sure you're signed in with your Azure user account:

```
az login
azd auth login
```

> Add `--tenant` for `az` or `--tenant-id` for `azd` if you want a specific tenant.

**Provision Infrastructure**

```
azd provision
```

**Using the Jumpbox VM**

1. **Reset the VM password** in the Azure Portal (required on first access if not set in deployment parameters):

   - Go to your VM resource → **Support + troubleshooting** → **Reset password** → Set new credentials
   - Default username is `testvmuser`

2. **Connect via Azure Bastion**

#### Building and pushing images with network isolation

When `networkIsolation=true`, the Container Registry is deployed as **Premium** with `publicNetworkAccess=Disabled` and is only reachable via its private endpoint. `az acr build` against the shared Microsoft-managed builder will fail. This landing zone therefore provisions an **ACR Tasks agent pool** attached to the `devops-build-agents-subnet` so image builds run inside the VNet and push to the registry over its private endpoint. No Docker client is required (and the jumpbox has no Docker installed by design — see issue #14).

Build and push from the jumpbox (or any client that can reach ARM):

```powershell
$acr  = (azd env get-values | Select-String '^AZURE_CONTAINER_REGISTRY_ENDPOINT').Line.Split('=')[1].Trim('"').Split('.')[0]
$pool = (azd env get-values | Select-String '^ACR_TASK_AGENT_POOL').Line.Split('=')[1].Trim('"')

az acr build `
  -r $acr `
  --agent-pool $pool `
  -t myapp:latest `
  -f Dockerfile `
  .
```

Pause billing between builds (default tier `S1` is billed per hour whether idle or not):

```powershell
az acr agentpool update -r <acr> -n <pool> --count 0
```

Resume before the next build:

```powershell
az acr agentpool update -r <acr> -n <pool> --count 1
```

The agent pool can be disabled entirely with `deployAcrTaskAgentPool=false` if builds are handled by a central CI/CD runner that already reaches the registry's private endpoint.

#### Firewall egress allow-list (network isolation)

When `networkIsolation=true`, egress from the jumpbox and workload subnets is forced through the default Azure Firewall. The landing zone codifies the FQDNs required by the default `install.ps1` bootstrap and by the ACR Tasks agent pool. The set is split by purpose so you can audit or trim it:

| Rule | Source subnet | FQDN group | Used by |
| --- | --- | --- | --- |
| `AllowMicrosoftContainerRegistry` | `*` | `mcr.microsoft.com`, `*.data.mcr.microsoft.com` | ACA/agents/ACR Tasks pulling Microsoft base images |
| `AllowEntraIdAuth` | `*` | `login.microsoftonline.com`, `login.windows.net`, `management.azure.com`, `graph.microsoft.com`, `*.applicationinsights.azure.com` | Entra ID auth, ARM control plane, App Insights telemetry |
| `AllowGitHub` | `*` | `github.com`, `*.github.com`, `raw.githubusercontent.com`, `codeload.github.com`, `objects.githubusercontent.com`, `*.githubusercontent.com` | Repo clones, release downloads |
| `AllowJumpboxBootstrap` | `jumpboxSubnetPrefix` | Chocolatey, NuGet, VS Installer, `download.microsoft.com`, `aka.ms`, `go.microsoft.com`, `*.core.windows.net`, `*.azureedge.net` | `choco install`, Python/VS Code/PowerShell Core MSIs |
| `AllowJumpboxDevRuntimes` | `jumpboxSubnetPrefix` | `*.python.org`, `*.pypi.org`, `*.pythonhosted.org`, `*.npmjs.org` | `pip install`, `npm install` |
| `AllowJumpboxEditors` | `jumpboxSubnetPrefix` | `update.code.visualstudio.com`, `*.vo.msecnd.net`, `*.vscode-cdn.net` | VS Code updates |
| `AllowAcrTasks` | `devopsBuildAgentsSubnetPrefix` | `*.azurecr.io`, `*.data.azurecr.io` | ACR Tasks agent pool talking to its registry |

Set `extendFirewallForJumpboxBootstrap=false` to skip the three jumpbox-scoped rules when egress is managed centrally by another policy.

### Permissions

The following role assignments are provisioned by the template based on the **default configuration** in `main.parameters.json`. This includes the default set of container apps, their associated roles, and the services they interact with. If you customize the parameters before provisioning — such as adding or removing container apps or changing role mappings — the actual assignments will vary accordingly.

#### Microsoft Foundry and AI Search Assignments

| Resource | Role | Assignee | Description |
| --- | --- | --- | --- |
| Microsoft Foundry Account | Cognitive Services User | Search Service | Allow Search Service to access vectorizers |
| GenAI App Search Service | Search Index Data Reader | Microsoft Foundry Project | Read index data |
| GenAI App Search Service | Search Service Contributor | Microsoft Foundry Project | Create AI Search connection |
| GenAI App Storage Account | Storage Blob Data Reader | Microsoft Foundry Project | Read blob data |
| GenAI App Storage Account | Storage Blob Data Reader | Search Service | Read blob data for indexing |

#### Container App Role Assignments

Current default configuration provisions a single Hello World container app (`orchestrator`), so only the assignments below are expected by default.

| Resource | Role | Assignee | Description |
| --- | --- | --- | --- |
| GenAI App Configuration Store | App Configuration Data Reader | ContainerApp: orchestrator | Read configuration data |
| GenAI App Container Registry | AcrPull | ContainerApp: orchestrator | Pull container images |
| GenAI App Key Vault | Key Vault Secrets User | ContainerApp: orchestrator | Read secrets |
| GenAI App Search Service | Search Index Data Reader | ContainerApp: orchestrator | Read index data |
| GenAI App Storage Account | Storage Blob Data Reader | ContainerApp: orchestrator | Read blob data |
| GenAI App Cosmos DB | Cosmos DB Built-in Data Contributor | ContainerApp: orchestrator | Read/write Cosmos DB data |
| Microsoft Foundry Account | Cognitive Services User | ContainerApp: orchestrator | Access Cognitive Services |
| Microsoft Foundry Account | Cognitive Services OpenAI User | ContainerApp: orchestrator | Use OpenAI APIs |

#### Executor Role Assignments

| Resource | Role | Assignee | Description |
| --- | --- | --- | --- |
| GenAI App Configuration Store | App Configuration Data Owner | Executor | Full control over configuration settings |
| GenAI App Container Registry | AcrPush | Executor | Push container images |
| GenAI App Container Registry | AcrPull | Executor | Pull container images |
| GenAI App Key Vault | Key Vault Contributor | Executor | Manage Key Vault settings |
| GenAI App Key Vault | Key Vault Secrets Officer | Executor | Create Key Vault secrets |
| GenAI App Search Service | Search Service Contributor | Executor | Create/update search service elements |
| GenAI App Search Service | Search Index Data Contributor | Executor | Read/write search index data |
| GenAI App Search Service | Search Index Data Reader | Executor | Read index data |
| GenAI App Storage Account | Storage Blob Data Contributor | Executor | Read/write blob data |
| GenAI App Cosmos DB | Cosmos DB Built-in Data Contributor | Executor | Read/write Cosmos DB data |
| Microsoft Foundry Account | Cognitive Services OpenAI User | Executor | Use OpenAI APIs |
| Microsoft Foundry Account | Cognitive Services User | Executor | Access Cognitive Services |

#### Jumpbox VM Role Assignments

| Resource | Role | Assignee | Description |
| --- | --- | --- | --- |
| GenAI App Container Apps | Container Apps Contributor | Jumpbox VM | Full control over Container Apps |
| Azure Managed Identity | Managed Identity Operator | Jumpbox VM | Assign and manage user-assigned identities |
| GenAI App Container Registry | Container Registry Repository Writer | Jumpbox VM | Write to ACR repositories |
| GenAI App Container Registry | Container Registry Tasks Contributor | Jumpbox VM | Manage ACR tasks |
| GenAI App Container Registry | Container Registry Data Access Configuration Administrator | Jumpbox VM | Manage ACR data access configuration |
| GenAI App Container Registry | AcrPush | Jumpbox VM | Push container images |
| GenAI App Configuration Store | App Configuration Data Owner | Jumpbox VM | Full control over configuration settings |
| GenAI App Key Vault | Key Vault Contributor | Jumpbox VM | Manage Key Vault settings |
| GenAI App Key Vault | Key Vault Secrets Officer | Jumpbox VM | Create Key Vault secrets |
| GenAI App Search Service | Search Service Contributor | Jumpbox VM | Create/update search service elements |
| GenAI App Search Service | Search Index Data Contributor | Jumpbox VM | Read/write search index data |
| GenAI App Storage Account | Storage Blob Data Contributor | Jumpbox VM | Read/write blob data |
| GenAI App Cosmos DB | Cosmos DB Built-in Data Contributor | Jumpbox VM | Read/write Cosmos DB data |
| Microsoft Foundry Account | Cognitive Services Contributor | Jumpbox VM | Manage Cognitive Services resources |
| Microsoft Foundry Account | Cognitive Services OpenAI User | Jumpbox VM | Use OpenAI APIs |
