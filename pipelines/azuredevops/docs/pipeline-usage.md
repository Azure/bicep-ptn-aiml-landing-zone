# Pipeline Usage Guide

How to register, authorize, run, and customize the CI/CD pipelines.

---

## Step 7: Create the CI Pipeline

1. In your Azure DevOps project, go to **Pipelines** in the left menu.
2. Select **New pipeline** (or **Create pipeline** if this is the first pipeline).
3. On the **"Where is your code?"** screen, select **Azure DevOps/Azure Repos Git**.
4. Select the **ailz** repository.
5. On the **"Configure your pipeline"** screen, select **Existing Azure Pipelines YAML file**.
6. In the dialog:
   - **Branch**: `main`
   - **Path**: select `pipelines/azuredevops/ci-pipeline.yml` from the dropdown.
7. Select **Continue**.
8. Review the YAML — do **not** change it. Select **Save** (use the dropdown arrow next to "Run" → **Save** if you want to save without running yet).
9. **(Recommended)** Rename the pipeline:
   - Go to the pipeline you just created.
   - Select the **⋮** (More actions) menu → **Rename/move**.
   - Rename to: `AI Landing Zone - CI`.

---

## Step 8: Create the CD Pipeline

1. Go to **Pipelines** → **New pipeline**.
2. Select **Azure Repos Git** → select the **ailz** repository.
3. Select **Existing Azure Pipelines YAML file**.
4. In the dialog:
   - **Branch**: `main`
   - **Path**: select `pipelines/azuredevops/cd-pipeline.yml`.
5. Select **Continue**.
6. Review the YAML. Select **Save** (not Run — you should authorize permissions first).
7. Rename the pipeline to: `AI Landing Zone - CD`.

---

## Step 9: Authorize Pipeline Permissions

Now that both pipelines exist, authorize them to use the service connections and variable group.

### Authorize the Service Connections

Repeat the following for each service connection you created in Step 1 (e.g., `azure-ailz-dev`, `azure-ailz-test`, `azure-ailz-prod`):

1. Go to **Project settings** → **Service connections**.
2. Select the connection.
3. Select the **⋮** (More actions) → **Security**.
4. Under **Pipeline permissions**, select **+**.
5. Add the `AI Landing Zone - CD` pipeline. (CI doesn't need any service connection.)

**Alternative**: When you first run the CD pipeline, Azure DevOps shows:
> *"This pipeline needs permission to access a resource before this run can continue."*

Select **View** → **Permit** → **Permit** to authorize on-demand.

### Authorize the Variable Group

1. Go to **Pipelines** → **Library**.
2. Select the `ailz-secrets` variable group.
3. Select the **Pipeline permissions** tab.
4. Select **+** and add the `AI Landing Zone - CD` pipeline.

> **Security recommendation**: Do not use "Open access" if the variable group contains secrets. Instead, authorize each pipeline individually.

---

## Step 10: Run and Verify

### Test the CI Pipeline

1. Go to **Pipelines**, select `AI Landing Zone - CI`.
2. Select **Run pipeline**.
3. Confirm the branch is `main` and select **Run**.
4. Monitor the pipeline run — the **Validate** stage runs three steps:
   - Install Bicep CLI
   - `az bicep build` (compile to ARM)
   - `az bicep lint`
   - Publish `bicep-templates` artifact

### Test the CD Pipeline

1. Go to **Pipelines**, select `AI Landing Zone - CD`.
2. Select **Run pipeline**.
3. Set parameters at queue time (all default to `false`):
   - **Deploy to DEV**: checked
   - **Deploy to TEST**: optional (only the envs you opt-in run)
   - **Deploy to PROD**: optional
4. Select **Run**.
5. The **Build** stage downloads the latest CI artifact.
6. Each selected env stage runs in order:
   - **DEV** runs first (no approval by default).
   - **TEST** runs only after DEV succeeds; pauses for approval if you configured one on the `test` Environment.
   - **PROD** runs only after TEST succeeds; pauses for approval if configured on `prod`.
7. If `azd provision` hits a transient Azure failure, the task automatically retries up to `deployRetryCount` more times before marking the stage failed (default `2` retries, see `templates/variables.yml`).

> **First run**: The initial deployment may take 20–40 minutes depending on the resources enabled in `main.parameters.json`.

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

> Each env stage runs only when its `deploy<Env>` parameter is `true` at queue time (all default to `false`). Stages are chained via `dependsOn`, so a failed env skips all later envs. `azd provision` retries on transient failures (`deployRetryCount`, default `2`).

---

## Customization Reference

### Feature Flags

The `main.parameters.json` file controls which Azure resources are deployed. Key flags:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `deployAiFoundry` | `true` | Deploy Azure AI Foundry account and project |
| `deployCosmosDb` | `true` | Deploy Cosmos DB account |
| `deployContainerApps` | `true` | Deploy Container Apps |
| `deploySearchService` | `true` | Deploy Azure AI Search |
| `deployVM` | `true` | Deploy jumpbox VM (for network-isolated mode) |
| `networkIsolation` | `false` (env var) | Enable Zero Trust networking |

### Per-Environment Overrides

You can pass additional azd environment variables per environment via the `additionalEnvVars` field in the CD pipeline. Example:

```yaml
additionalEnvVars: 'NETWORK_ISOLATION=true USE_UAI=true USE_CAPP_API_KEY=false'
```

> Note: `NETWORK_ISOLATION` is already set automatically by the deploy template based on `deploymentMode` in `templates/variables.yml`. Override it via `additionalEnvVars` only if you want a per-stage difference.

### Using Separate Subscriptions per Environment

This is the **default model**. Each env has its own service connection variable in `templates/variables.yml`:

```yaml
azureServiceConnectionDev:  'azure-ailz-dev'
azureServiceConnectionTest: 'azure-ailz-test'
azureServiceConnectionProd: 'azure-ailz-prod'
```

If two envs share a subscription, simply point the corresponding variables at the same connection. The connection itself determines which subscription each stage targets — you do not need to set `AZURE_SUBSCRIPTION_ID` manually.

### Disabling the azd retry mechanism

`templates/variables.yml` defines `deployRetryCount: 2` (i.e., 1 initial attempt + up to 2 retries). To disable retries entirely, set it to `0`. The deploy template logs `Retry count: N (max attempts: N+1)` at the start, then `Retry: 1`, `Retry: 2`, etc. on each subsequent attempt.

---

> **Next:** See [Maintenance & Troubleshooting](maintenance.md) for syncing upstream updates and resolving common issues.
>
> **Previous:** [Azure Setup Guide (Steps 1–6)](setup-guide.md)
