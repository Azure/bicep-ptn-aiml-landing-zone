# Azure Setup Guide

Step-by-step Azure and Azure DevOps configuration required before running the CI/CD pipelines.

> **Documentation sources verified**: This guide is based on the official
> Microsoft Learn documentation as of March 2026.
> - [Manage service connections](https://learn.microsoft.com/en-us/azure/devops/pipelines/library/service-endpoints?view=azure-devops&tabs=yaml)
> - [Connect to Azure with ARM service connection](https://learn.microsoft.com/en-us/azure/devops/pipelines/library/connect-to-azure?view=azure-devops)
> - [Create and target environments](https://learn.microsoft.com/en-us/azure/devops/pipelines/process/environments?view=azure-devops)
> - [Define approvals and checks](https://learn.microsoft.com/en-us/azure/devops/pipelines/process/approvals?view=azure-devops&tabs=check-pass)
> - [Manage variable groups](https://learn.microsoft.com/en-us/azure/devops/pipelines/library/variable-groups?view=azure-devops&tabs=yaml)

---

## Step 1: Create the ARM Service Connections (one per environment)

The pipelines target up to three environments — DEV, TEST, PROD — each with its own ARM service connection. The connections may point to the same subscription or to different subscriptions.

### 1.1 Create the Connections

Repeat the steps below **once per environment** you plan to deploy to (you can create only DEV first and add the others later).

Choose **one** option per connection based on your organization's policies:

#### Option A: App Registration with Workload Identity Federation (Recommended)

Use this option if your organization allows creating app registrations.

1. In your Azure DevOps project, go to **Project settings** (gear icon, bottom-left).
2. In the left menu under **Pipelines**, select **Service connections**.
3. Select **Create/New service connection**.
4. Select **Azure Resource Manager**, then select **Next**.
5. Select **App registration (automatic)** with credential type **Workload identity federation**.
6. Configure the connection:
   - **Scope level**: `Subscription`
   - **Subscription**: Select the target Azure subscription for this environment
   - **Resource group**: Leave empty (subscription-level access needed)
   - **Service connection name**: e.g. `azure-ailz-dev`, `azure-ailz-test`, `azure-ailz-prod`
   - **Description**: `AI Landing Zone Bicep deployment — <env>`
7. **Do NOT** check "Grant access permission to all pipelines" — you will authorize each pipeline individually (more secure).
8. Select **Save**.

#### Option B: Managed Identity

Use this option if your organization restricts app registrations (e.g., via Azure AD policy).

1. Ensure you have an existing **user-assigned managed identity** in the target Azure subscription.
2. In your Azure DevOps project, go to **Project settings** → **Service connections**.
3. Select **New service connection** → **Azure Resource Manager** → **Next**.
4. Select **Managed identity**.
5. Configure the connection:
   - **Subscription**: Select your target Azure subscription for this environment
   - **Resource group**: The resource group containing your managed identity
   - **Managed identity**: Select the existing user-assigned managed identity
   - **Service connection name**: e.g. `azure-ailz-dev`, `azure-ailz-test`, `azure-ailz-prod`
6. Select **Save**.

> **Reference**: [Create a service connection for a managed identity](https://learn.microsoft.com/en-us/azure/devops/pipelines/library/connect-to-azure?view=azure-devops#create-a-service-connection-for-an-existing-user-assigned-managed-identity)

> **Note**: Whatever you name the connections, you will record those names later in `pipelines/azuredevops/templates/variables.yml` under `azureServiceConnectionDev`, `azureServiceConnectionTest`, and `azureServiceConnectionProd` (Step 6).

### 1.2 Verify the Connection

1. Go to **Project settings** → **Service connections** → select each connection.
2. On the **Overview** tab, confirm the connection type shows **Azure Resource Manager** with the credential type you chose.

---

## Step 2: Assign Azure RBAC Roles to the Service Principal(s)

Each service principal that backs your service connections needs specific Azure roles. The AI Landing Zone template creates resources **and** assigns RBAC roles to managed identities, which requires elevated permissions.

> Repeat the steps below **once per service connection** you created in Step 1, against the corresponding subscription.

### Required Roles

| Role | Scope | Why |
|------|-------|-----|
| **Contributor** | Subscription | Create and update all Azure resources |
| **User Access Administrator** | Subscription | Assign RBAC roles to managed identities created by the template |
| **Cognitive Services Contributor** | Subscription | Deploy AI Foundry accounts and OpenAI model deployments |

### Find Your Service Principal's Application ID

1. In Azure DevOps, go to **Project settings** → **Service connections**.
2. Select the service connection you want to grant roles to (e.g., `azure-ailz-dev`).
3. Select **Manage App registration** (link at the top of the Overview tab) — this opens the Azure Portal.
4. On the **App registration** overview page, copy the **Application (client) ID** (a GUID like `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`).
5. Also note the **Subscription ID** that connection targets — visible on the service connection details page or in **Subscriptions** in the Azure Portal.

### Assign Roles via Azure Cloud Shell


1. Go to the **Azure Portal** → select the **Cloud Shell** icon (terminal icon `>_` in the top navigation bar).
2. If prompted with "Welcome to Azure Cloud Shell", select **Bash**.
3. If this is your first time using Cloud Shell, a **"Getting started"** dialog will appear:
   - Select **No storage account required**.
   - Choose your **Subscription** from the dropdown.
   - Select **Apply** and wait for the terminal to initialize.
  
   ![console](/pipelines/azuredevops/docs/media/cloudshell.png)
4. Run the following commands in Cloud Shell (replace the two placeholder values):

```bash
# ── Replace these with your actual values ─────────────────────────────
SP_APP_ID="<paste-your-application-client-id-here>"
SUBSCRIPTION_ID="<paste-your-subscription-id-here>"
# ──────────────────────────────────────────────────────────────────────

# Set the active subscription
az account set --subscription $SUBSCRIPTION_ID

# Get the service principal object ID from the application ID
SP_OBJECT_ID=$(az ad sp show --id $SP_APP_ID --query id -o tsv)
echo "Service Principal Object ID: $SP_OBJECT_ID"

# Assign Contributor
az role assignment create \
  --assignee-object-id $SP_OBJECT_ID \
  --assignee-principal-type ServicePrincipal \
  --role "Contributor" \
  --scope "/subscriptions/$SUBSCRIPTION_ID"

# Assign User Access Administrator
az role assignment create \
  --assignee-object-id $SP_OBJECT_ID \
  --assignee-principal-type ServicePrincipal \
  --role "User Access Administrator" \
  --scope "/subscriptions/$SUBSCRIPTION_ID"

# Assign Cognitive Services Contributor
az role assignment create \
  --assignee-object-id $SP_OBJECT_ID \
  --assignee-principal-type ServicePrincipal \
  --role "Cognitive Services Contributor" \
  --scope "/subscriptions/$SUBSCRIPTION_ID"
```

5. Verify the assignments were created successfully:

```bash
az role assignment list \
  --assignee $SP_OBJECT_ID \
  --subscription $SUBSCRIPTION_ID \
  --query "[].{Role:roleDefinitionName, Scope:scope}" \
  --output table
```

You should see output similar to:

![RBAC verification output](/pipelines/azuredevops/docs/media/createdassignments.png)

### Alternative: Assign Roles via Azure Portal UI

If you prefer the portal UI instead of CLI:

1. Go to **Subscriptions** → select your subscription → **Access control (IAM)**.
2. Select **+ Add** → **Add role assignment**.
3. On the **Role** tab, search for `Contributor` and select it → **Next**.
4. On the **Members** tab, select **User, group, or service principal** → **+ Select members**.
5. Search for the app registration name (shown in your service connection) → select it → **Select**.
6. Select **Review + assign** → **Review + assign**.
7. Repeat for `User Access Administrator` and `Cognitive Services Contributor`.

> **Security note**: If your organization requires narrower scoping, create one resource group per environment and assign roles at that scope. You'll need to pre-create the resource groups in that case.

---

## Step 3: Create Azure DevOps Environments

Azure DevOps Environments provide deployment history, traceability, and approval gates. The CD pipeline targets three environments: `dev`, `test`, and `prod`.

> **Important**: You must create the environments **before** running the CD pipeline. If an environment doesn't exist and the pipeline is triggered by a push (not the web editor), the pipeline will fail with: *"Environment could not be found."*

### Create Each Environment

Repeat the following for environments named: `dev`, `test`, `prod`.

1. In your Azure DevOps project, go to **Pipelines** → **Environments** in the left menu.
2. Select **Create environment** (or **+ New environment** if environments already exist).
3. Fill in:
   - **Name**: `dev` (then `test`, then `prod`)
   - **Description**: `AI Landing Zone - DEV environment` (adjust per environment)
   - **Resource**: Select **None** (we are not adding Kubernetes or VM resources)
4. Select **Create**.

After creating all three, you should see:

| Environment | Description |
|-------------|-------------|
| `dev` | Development — manual opt-in via the `deployDev` parameter; no approval by default |
| `test` | Test/QA — manual opt-in via `deployTest`; recommended to add an approval check |
| `prod` | Production — manual opt-in via `deployProd`; recommended to add an approval check |

---

## Step 4: Add Approval Checks to Environments (Optional but Recommended)

Approval checks ensure that deployments to `test` and `prod` require manual sign-off before proceeding. The pipeline does not enforce them in YAML — you configure them on the Environment resource.

### Add Approvals to the `test` Environment

1. In **Pipelines** → **Environments**, select the **test** environment.
2. Select the **Approvals and checks** tab (or click the three dots menu → **Approvals and checks**).
3. Select the **+** button to add a new check.
4. Select **Approvals**, then select **Next**.
5. Configure:
   - **Approvers**: Add one or more users or groups who can approve deployments to Test.
   - **Instructions to approvers**: `Please review the previous DEV run and confirm deployment to TEST.`
   - **Allow approvers to approve their own runs**: Uncheck for production-grade security (optional for test).
   - **Timeout**: `72 hours` (the stage will be marked as skipped if not approved within this time).
6. Select **Create**.

### Add Approvals to the `prod` Environment

Repeat the same steps for the `prod` environment with stricter settings:

1. Select the **prod** environment → **Approvals and checks** tab → **+**.
2. Select **Approvals** → **Next**.
3. Configure:
   - **Approvers**: Add senior engineers or a release management group.
   - **Instructions**: `PRODUCTION deployment. Verify TEST environment is healthy before approving.`
   - **Allow approvers to approve their own runs**: **Uncheck** (recommended for production).
   - **Timeout**: `72 hours`.
4. Select **Create**.

### (Optional) Add Branch Control to `prod`

To ensure only the `main` branch can deploy to production:

1. On the `prod` environment → **Approvals and checks** tab → **Add new**.
2. Select **Branch control**.
3. Set **Allowed branches**: `refs/heads/main`.
4. Check **Verify branch protection** if your repo has branch policies.
5. Select **Create**.

---

## Step 5: Create the Variable Group

The CD pipeline expects a variable group named `ailz-secrets` that stores the VM admin password and any other secrets.

### Create the Variable Group

1. In your Azure DevOps project, go to **Pipelines** → **Library** in the left menu.
2. Select **+ Variable group**.
3. Fill in:
   - **Variable group name**: `ailz-secrets`
   - **Description**: `Secrets for AI Landing Zone deployments`
4. Under **Variables**, select **+ Add** and create:

   | Name | Value | Secret? |
   |------|-------|---------|
   | `secretOrRandomPassword` | `<your-secure-password>` | Yes — click the lock icon 🔒 |

   > **Password requirements**: The VM admin password must meet Azure complexity requirements — at least 12 characters, with uppercase, lowercase, numbers, and special characters.

5. Select **Save**.

> **Note**: You will authorize specific pipelines to use this variable group later, after the pipelines are created.

---

## Step 6: Update Pipeline Variables

Before creating pipelines, update the shared variables to match your Azure environment.

### Edit `pipelines/azuredevops/templates/variables.yml`

Open the file and update these values:

```yaml
variables:
  # ── Azure connection (one per env) ─────────────────────────────────
  azureServiceConnectionDev:  'azure-ailz-dev'    # Must match Step 1
  azureServiceConnectionTest: 'azure-ailz-test'
  azureServiceConnectionProd: 'azure-ailz-prod'

  # ── Azure region (shared across envs) ──────────────────────────────
  location: 'eastus2'                              # Your preferred Azure region

  # ── AZD environment name (suffixed with -dev/-test/-prod per stage) ──
  environmentName: 'ailz'

  # ── Deployment mode ────────────────────────────────────────────────
  deploymentMode: 'zeroTrust'                      # 'basic' for public networking

  # ── Deploy retries ─────────────────────────────────────────────────
  deployRetryCount: 2                              # 0 disables retries
```

> **Note**: Resource group names and parameter file paths are not pipeline variables — the Azure Developer CLI (`azd`) handles resource group creation and parameter resolution automatically based on `azure.yaml` and `main.parameters.json`. The CD pipeline derives each env's resource group as `rg-<environmentName>-<env>` (e.g., `rg-ailz-dev`).

### Per-Environment Overrides

If an env needs extra `azd` env variables, set them per stage in `pipelines/azuredevops/cd-pipeline.yml` via the `additionalEnvVars` template parameter:

```yaml
- template: templates/deploy-bicep.yml
  parameters:
    azureServiceConnection: $(azureServiceConnectionDev)
    location: $(location)
    environmentName: dev
    azdEnvironmentName: $(environmentName)-dev
    additionalEnvVars: 'USE_UAI=true USE_CAPP_API_KEY=false'
```

---

> **Next:** Continue to the [Pipeline Usage Guide (Steps 7–10)](pipeline-usage.md) to register, authorize, and run the pipelines.
>
> **Previous:** [CI/CD Pipelines Overview](../README.md)
