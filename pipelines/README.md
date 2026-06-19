# Pipelines

This folder is organized by CI/CD platform to keep each workflow isolated.

## Documentation

For end-to-end setup and usage instructions (service connections, variable groups, environments, and running the CI/CD pipelines), see the official guide:

- [Deploy with Azure DevOps](https://azure.github.io/AI-Landing-Zones/bicep/deploy-with-azure-devops/) — Azure AI Landing Zones documentation.

Always refer to the documentation above as the source of truth; the files in this folder are the assets it references.

## Current structure

- `azuredevops/` — Azure DevOps CI/CD pipelines, templates, and setup docs.

Pre-deploy validation is provided by the repo-root preflight script,
[`../scripts/Invoke-PreflightChecks.ps1`](../scripts/Invoke-PreflightChecks.ps1).
It folds in checks that previously lived in standalone `tools/` scripts:

- Regional capacity readiness — service/region support, VM SKU and vCPU quota, AI Search and Cognitive Services quota headroom.
- Resource-provider registration — verifies the resource providers required by the deployment are registered in the target subscription.

## Planned expansion

- Add future GitHub Actions assets under a separate top-level folder (for example, `github-actions/`).
