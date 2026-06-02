# Pipelines

This folder is organized by CI/CD platform to keep each workflow isolated.

## Current structure

- `azuredevops/` — Azure DevOps CI/CD pipelines, templates, and setup docs.
- `../tools/` — shared utility scripts used across CI/CD platforms:
  - `azure_region_capacity_checker.ps1` — rank Azure regions by service support, VM SKU, vCPU, AI Search and Cognitive quota.
  - `check-resource-providers.ps1` — optional pre-deploy check that the resource providers required by `main.bicep` are registered in the target subscription.

## Planned expansion

- Add future GitHub Actions assets under a separate top-level folder (for example, `github-actions/`).
