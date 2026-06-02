# Maintenance & Troubleshooting

How to sync upstream updates and troubleshoot common pipeline issues.

---

## Syncing Upstream Updates

This repo is forked from [Azure/bicep-ptn-aiml-landing-zone](https://github.com/Azure/bicep-ptn-aiml-landing-zone). The upstream repo is configured as a git remote named `upstream`, and your pipeline files/customizations live on top of upstream commits.

### Git Remote Setup

```
origin    https://<org>@dev.azure.com/<org>/<project>/_git/<repo>      (fetch/push)
upstream  https://github.com/Azure/bicep-ptn-aiml-landing-zone.git      (fetch/push)
```

Recommended safety guard (optional): disable pushes to the GitHub upstream remote to prevent accidental push attempts.

### Pull Latest Changes from Upstream

When the AI Landing Zone repo publishes updates, use this sequence from `main`:

```bash
# 0. Confirm branch and remotes
git status -sb
git branch --show-current
git remote -v

# 1. Fetch latest from GitHub upstream remote
git fetch upstream --prune

# 2. Try fast-forward first (cleanest path)
git pull --ff-only upstream main

# 3. If fast-forward fails with "Diverging branches can't be fast-forwarded"
#    merge upstream explicitly:
git merge upstream/main

# 4. Optional: review recent history after merge
git log --oneline --decorate --graph --max-count=20 --all

# 5. Resolve any conflicts (if any)
#    Conflicts are most likely in main.parameters.json if you customized it.
#    Keep your pipeline files — upstream doesn't have them.

# 6. Push merged main to Azure DevOps
git push origin main

# 7. Verify sync state
git status -sb
```

Expected verification: `## main...origin/main` with no additional local change markers.

### Pin to a Specific Upstream Release

If you prefer to update to a specific version rather than the latest `main`:

```bash
# Fetch all tags
git fetch upstream --tags

# List available releases
git tag -l 'v*'

# Merge a specific release
git merge v1.0.3

# Push to Azure DevOps
git push origin main
```

### What to Expect During a Merge

| Upstream Change | Impact on Your Files |
|-----------------|---------------------|
| `main.bicep` updated | Auto-merges unless you modified the same lines |
| `main.parameters.json` updated | May conflict if you edited parameter defaults |
| New `modules/` added | Auto-merges cleanly (your Azure DevOps pipeline files are in `pipelines/azuredevops/`) |
| `azure.yaml` updated | Auto-merges cleanly |
| Your `pipelines/azuredevops/` files | Never touched by upstream — no conflicts |
| Your `.github/` files | Never touched by upstream — no conflicts |
| Your `bicepconfig.json` | Never touched by upstream — no conflicts |

> **Tip**: After merging upstream changes, run the CI pipeline to validate that the updated Bicep templates still compile and pass lint.

---

## Troubleshooting

### Pipeline Errors

| Error | Cause | Fix |
|-------|-------|-----|
| `No hosted parallelism has been purchased or granted` | The free grant for Microsoft-hosted parallel jobs is not enabled for your organization. New Azure DevOps organizations do not receive this grant by default. Even if you have purchased parallel jobs via Billing, the free grant must also be approved separately. | Submit the [free parallelism grant request form](https://aka.ms/azpipelines-parallelism-request). Processing takes several business days. See [Configure and pay for parallel jobs](https://learn.microsoft.com/en-us/azure/devops/pipelines/licensing/concurrent-jobs?view=azure-devops) for details. While waiting, you can use a self-hosted agent (see Prerequisites). |
| `No agent found in pool Azure Pipelines` | Same root cause as above — no Microsoft-hosted parallel jobs available | Same fix: submit the [free grant request](https://aka.ms/azpipelines-parallelism-request) or use a self-hosted agent. |
| `Environment 'dev' could not be found` | Environment not created before pipeline run | Create the environment in Pipelines → Environments (see [Setup Guide](setup-guide.md#step-4-create-azure-devops-environments)) |
| `This pipeline needs permission to access a resource` | Service connection or variable group not authorized | Select View → Permit, or authorize manually in Project Settings (see [Pipeline Usage](pipeline-usage.md#step-9-authorize-pipeline-permissions)) |
| `Bicep build failed` | Syntax error in `.bicep` files | Check the build log for the specific error. Run `az bicep build --file main.bicep` locally to debug |
| `The deployment 'ailz-dev-xxx' failed with error` | Azure resource creation failed | Check the deployment error in the Azure Portal → Resource Group → Deployments |
| `429 Too Many Requests` / `AuthorizationFailed` | Service principal lacks required roles | Verify RBAC assignments (see [Setup Guide](setup-guide.md#step-3-assign-azure-rbac-roles-to-the-service-principal)) |
| `Responsible AI terms have not been accepted` | Responsible AI terms not accepted in target subscription | Follow [Step 1](setup-guide.md#step-1-accept-responsible-ai-terms) to accept terms manually |
| `The template is not valid` | Parameter mismatch between `main.bicep` and `main.parameters.json` | This should not occur when using `azd provision` as it filters parameters automatically. If using raw `az` CLI, run `azd provision --preview` locally instead |
| `UnmatchedPrincipalType` | `principalType` defaults to `User` but pipeline deploys as `ServicePrincipal` | Ensure `principalType` is in `main.parameters.json` with `${AZURE_PRINCIPAL_TYPE}` substitution and the deploy template sets `AZURE_PRINCIPAL_TYPE=ServicePrincipal` |
| `Select an Azure Subscription to use` | `azd` can't auto-detect subscription in non-interactive pipeline | Ensure `azd env set AZURE_SUBSCRIPTION_ID` is called before `azd provision` |
| `NameUnavailable` / soft-deleted resource | After deleting a resource group, Azure App Configuration and Key Vault remain soft-deleted for 7 days, blocking name reuse | Purge the soft-deleted resources before redeploying (see [Redeploying After Resource Group Deletion](#redeploying-after-resource-group-deletion) below) |

### Redeploying After Resource Group Deletion

When you delete a resource group and try to redeploy with the same resource names, some Azure services block name reuse because they have **soft-delete** enabled by default. You must purge these soft-deleted resources first:

```bash
# ── Find and purge soft-deleted App Configuration stores ──────────────
az appconfig list-deleted --subscription <subscription-id> --query "[].name" -o tsv
az appconfig purge --name <app-config-name> --location <location>

# ── Find and purge soft-deleted Key Vaults ────────────────────────────
az keyvault list-deleted --subscription <subscription-id> --query "[].name" -o tsv
az keyvault purge --name <key-vault-name>

# ── Find and purge soft-deleted Cognitive Services (AI Foundry) ───────
az cognitiveservices account list-deleted --subscription <subscription-id> --query "[].name" -o tsv
az cognitiveservices account purge --name <account-name> --resource-group <rg-name> --location <location>
```

> **Tip**: If you're unsure which resources are soft-deleted, run the `list-deleted` commands above to find them. Purge all of them before re-running the CD pipeline.

### Useful Local Debugging Commands

```bash
# Compile Bicep locally
az bicep build --file main.bicep --stdout > /dev/null

# Lint Bicep locally
az bicep lint --file main.bicep

# Validate with azd (handles parameter filtering automatically)
azd provision --preview

# Full provisioning
azd provision
```

### Checking Pipeline Runs

- Go to **Pipelines** → select the pipeline → select the latest run.
- On the run summary, select a failed stage/job to see step-level logs.
- Use **Download logs** from the **⋮** menu for full diagnostics.

---

> **Previous:** [Pipeline Usage Guide (Steps 7–10)](pipeline-usage.md)
>
> **Back to:** [CI/CD Pipelines Overview](../README.md)
