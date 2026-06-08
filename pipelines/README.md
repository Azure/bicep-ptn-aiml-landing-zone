# Pipelines

This folder is organized by CI/CD platform to keep each workflow isolated.

## Documentation

For end-to-end setup and usage instructions (service connections, variable groups, environments, and running the CI/CD pipelines), see the official guide:

- [Deploy with Azure DevOps](https://azure.github.io/AI-Landing-Zones/bicep/deploy-with-azure-devops/) — Azure AI Landing Zones documentation.

Always refer to the documentation above as the source of truth; the files in this folder are the assets it references.

## Current structure

- `azuredevops/` — Azure DevOps CI/CD pipelines, templates, and setup docs.
- `../tools/` — shared utility scripts used across CI/CD platforms:
  - `azure_region_capacity_checker.ps1` — rank Azure regions by service support, VM SKU, vCPU, AI Search and Cognitive quota.
  - `check-resource-providers.ps1` — optional pre-deploy check that the resource providers required by `main.bicep` are registered in the target subscription.

## Planned expansion

- Add future GitHub Actions assets under a separate top-level folder (for example, `github-actions/`).
