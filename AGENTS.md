## Solution Overview

This repository is an **AI Landing Zone implemented in Bicep** for Azure.
It provides a reusable, production-oriented infrastructure baseline for AI workloads built on Microsoft Foundry and related Azure services.

Primary goals:
- Standardize secure, repeatable provisioning with `azd` + Bicep.
- Offer modular deployment with feature flags and strong parameterization.
- Support both quick-start and hardened network-isolated topologies.
- Act as a reusable infra core for other accelerators and agent-based solutions.

Repository:
- https://github.com/azure/bicep-ptn-aiml-landing-zone

---

## What To Understand First

This is an IaC-first repository. Most work happens in:
- `main.bicep`: orchestrates all resources, modules, conditions, identities, role assignments.
- `main.parameters.json`: deployment topology, feature flags, model list, app list, networking options.
- `modules/`: reusable custom Bicep modules for networking, security role assignment, AI Foundry connections, app config population.
- `constants/constants.bicep`: role IDs and naming abbreviations.
- `azure.yaml`: azd project definition (`infra.path: .`, `infra.module: main`).
- `manifest.json`: release metadata + optional component repos + jumpbox install script source.
- `install.ps1`: jumpbox bootstrap logic for isolated environments.

If behavior changes, update Bicep and parameters consistently.

---

## IaC Architecture and Design Patterns

### 1) Single entrypoint orchestration
- `main.bicep` is the deployment orchestrator.
- It composes AVM modules and custom modules using feature-flag conditions (`if (...)`).

### 2) Feature-flag driven composition
Common toggles:
- `deployAiFoundry`
- `deployAppConfig`
- `deployKeyVault`
- `deploySearchService`
- `deployStorageAccount`
- `deployCosmosDb`
- `deployContainerEnv`
- `deployContainerApps`
- `networkIsolation`
- `useExistingVNet`

Preserve this conditional model when adding resources.

### 3) Strong parameterization + substitution model
- `main.parameters.json` supports env var substitution (`"${ENV_NAME}"`) for `azd` workflows.
- In Bicep, values that can come empty should have safe fallback handling.
- Avoid hardcoding tenant/subscription/resource names in templates.

### 4) Modular networking for Zero Trust
- Supports public and isolated modes.
- Isolated mode includes VNet/subnets, private DNS zones, private endpoints, and controlled dependencies.
- PE creation is serialized in places to avoid parallel conflicts.

### 5) Identity and RBAC by design
- Supports system-assigned MI and optional UAI (`useUAI`).
- Role assignments are explicit and centralized, including data-plane Cosmos assignments.

### 6) App topology as data
- `containerAppsList`, `modelDeploymentList`, `databaseContainersList`, `storageAccountContainersList` drive infra shape.
- New app/model/service behavior should be added by extending these lists and mapping logic.

---

## Current Container App Port Behavior

Container app ingress and Dapr app port are parameterized per app entry:
- `app.target_port` when provided.
- fallback to `8080` when omitted.

Pattern in `main.bicep`:
- `ingressTargetPort: int(app.?target_port ?? 8080)`
- `dapr.appPort: int(app.?target_port ?? 8080)`

Implications:
- If you add apps in `main.parameters.json`, you can set `target_port` explicitly.
- If omitted, app config defaults to 8080.

---

## Parameterization Guidance

When adding new capability, follow this sequence:
1. Add parameter in `main.bicep` with description and sensible default.
2. Add corresponding value in `main.parameters.json` (literal or `"${ENV_VAR}"`).
3. If substitution can resolve to empty, add fallback handling in Bicep.
4. Wire the value to modules/resources.
5. If runtime needs the value, publish it to App Configuration through `appConfigPopulate`.
6. If downstream automation needs it, expose as Bicep output.

Good practices:
- Keep booleans as true/false semantics in Bicep.
- Keep names deterministic (resource token + abbreviations).
- Keep module params minimal but explicit.
- Preserve idempotency.

---

## Reusing This Landing Zone from Another Repository

This section is critical for derived accelerators.

### Recommended consumption model
Use this repository as an **infra submodule** mounted at `infra/` in the consumer repo.

Why:
- Consumer gets a stable IaC core.
- Consumer customizes only overlays (`main.parameters.json`, `manifest.json`, optional scripts).
- Infra updates are versioned by submodule pin.

### Pinning strategy for consistency
Pin submodule to a specific landing zone release/tag.

Example commands to add and pin the submodule to `v1.0.0`:
```bash
git submodule add https://github.com/Azure/bicep-ptn-aiml-landing-zone.git infra
git -C infra fetch --tags
git -C infra checkout tags/v1.0.0
git config -f .gitmodules submodule.infra.branch v1.0.0
git config -f .gitmodules submodule.infra.ignore dirty
git add .gitmodules infra
git commit -m "Add infra submodule pinned to v1.0.0"
```

Initialization command for consumers:
```bash
git submodule update --init --recursive
```

Example `.gitmodules` pattern:
```ini
[submodule "infra"]
	path = infra
	url = https://github.com/Azure/bicep-ptn-aiml-landing-zone.git
	branch = v1.0.0
	ignore = dirty
```

Notes:
- Keep pin explicit to avoid drift between environments.
- Treat infra version bumps as controlled upgrades.

### Consumer `azure.yaml` pattern
Use:
- `infra.provider: bicep`
- `infra.path: infra`
- `infra.module: main`
- `preprovision` hook to prepare submodule and overlays.

### Preprovision mechanism (important)
A robust preprovision hook should:
1. Run `git submodule update --init --recursive`.
2. Detect `azd init` ZIP scenario (no gitlink/submodule metadata in git index).
3. If `infra/main.bicep` is missing, clone infra repo directly using `.gitmodules` URL + pinned ref.
4. Copy consumer overlay files into `infra/`:
   - `main.parameters.json`
   - `manifest.json`

Result:
- Consumer-specific parameters override landing zone defaults.
- Consumer controls component graph and release metadata without forking IaC templates.

---

## `manifest.json` Contract and Jumpbox Bootstrap Pattern

`manifest.json` in this repository currently contains:
- landing zone release metadata (`tag`, `repo`)
- `ailz_tag` — the landing zone release tag (used to construct the `install.ps1` URL and passed to the jumpbox script)
- optional `components` array

### Why this matters in network-isolated deployments
When `deployVM` + `deploySoftware` are used, the VM custom script extension runs `install.ps1`.
`install.ps1`:
- installs tools (az, azd, git, etc.)
- clones this repo by release
- initializes azd environment
- reads `manifest.json.components`
- clones each component repo at pinned tags
- copies `.azure` environment context into each component repo

This enables post-provision work from the jumpbox where public access is constrained.

### Consumer pattern for derived accelerators
In a consumer repo, set `manifest.json` to:
- set `ailz_tag` to the desired landing zone release tag
- define component repos/tags the jumpbox should clone
- keep all tags pinned for reproducibility

Use this as the primary mechanism to bootstrap isolated deployments without reauthoring infra templates.

---

## Module Map (High-Level)

- `modules/ai-foundry/*`: AI Foundry account/project and service connections.
- `modules/networking/*`: subnet, private endpoint, private DNS modules.
- `modules/security/*`: role assignment wrappers (control-plane and Cosmos data-plane).
- `modules/container-apps/*`: app list shaping for configuration publishing.
- `modules/app-configuration/*`: key-value population in App Configuration.

Rule:
- Reuse existing module patterns before creating new module files.
- Keep custom logic centralized and avoid duplicated resource blocks.

---

## Deployment Modes

### Standard mode
- Faster setup.
- Public networking where applicable.

### Zero Trust mode
- Enable network isolation.
- Private DNS and private endpoints activated.
- Jumpbox/Bastion workflow becomes central for post-provision operations.

Do not mix assumptions between these modes.

---

## Operational Commands

Typical operator flow:
```bash
az login
azd auth login
azd provision
```

Parameter overrides:
```bash
azd env set NETWORK_ISOLATION true
azd env set USE_UAI true
azd env set ENABLE_AGENTIC_RETRIEVAL true
```

You can also update `main.parameters.json` directly instead of using `azd env set`.
Use `azd env set` when you want per-environment values without editing files; use `main.parameters.json` when you want explicit, versioned defaults in source control.

---

## Change Checklist

Before submitting changes, verify:
1. Feature flags still gate optional resources correctly.
2. New params exist in both `main.bicep` and `main.parameters.json` when required.
3. Network isolation path still works (private DNS/PE dependencies intact).
4. Role assignments remain least-privilege and scoped correctly.
5. App Configuration population includes any new runtime settings.
6. Names remain deterministic and compliant.
7. Changes are compatible with submodule consumer pattern.
8. Documentation is updated for any user-visible change (see **Documentation Consistency**).

---

## Documentation Consistency

Documentation must always match the **current, shipped** implementation. Any
change with a user-visible effect — a new/renamed feature flag or parameter, a
changed default, new module behavior, a new deployment mode, an output
consumers rely on, or a breaking change — MUST be documented **in the same
change set**, never deferred.

Where landing-zone documentation lives:

- **In this repo (always update these in the same PR):**
  - `README.md` — overview, parameters, feature flags, quick start.
  - `CHANGELOG.md` — every change, under `[Unreleased]` on `develop` and the
    versioned header on a release branch.
  - `docs/` runbooks — `runbook-standalone.md`, `runbook-hub-spoke.md`,
    `v2-migration.md`. Update the relevant runbook when the deployment flow,
    topology, or migration steps change.
- **Public AI Landing Zone site (separate repo):** the narrative published at
  https://azure.github.io/AI-Landing-Zones/bicep is sourced from the
  `Azure/AI-Landing-Zones` repository, where the documentation source now lives
  on the `main` branch (the full MkDocs project under `docs/` and `mkdocs.yml`),
  not in this repo. The site is built and published automatically to the
  `gh-pages` branch on every push to `main`, so `gh-pages` is generated output,
  not the source you edit. When a change alters the public bicep landing-zone
  story (architecture, design areas, consumer-facing parameters/flags,
  what's-new), open a **companion PR against `main` of `Azure/AI-Landing-Zones`**
  and link it from this PR's description.

Rules:
- A change is **not done** until the matching docs are updated, or you have
  confirmed none are affected.
- When unsure, grep the docs/README for the flag, parameter, or output name
  you touched and update every place it appears.
- Treat any drift between the published site and the deployed behavior as a
  bug, not a cosmetic issue.

---

## Branching and Release Flow

- `develop` is the integration branch for ongoing work; `main` holds released,
  tagged versions.
- Before starting any new work, sync `develop` with `main` first. Never branch
  from a `develop` that is behind a shipped release. Merge or fast-forward `main`
  into `develop`, then create your feature branch from the updated `develop`.
- Cut releases from `main`: land the validated change on `main`, tag the exact
  version (for example `v2.1.6`, with the tag and the GitHub release title equal
  to the version and no product prefix), and publish notes from `CHANGELOG.md`.
- Right after a release, reconcile `develop` so it contains everything on `main`.
  The next feature branch must start from a state that already includes the
  release.

---

## Semantic Versioning and Downstream Signals

This landing zone uses semantic versioning. For every change, classify the
release impact with judgment:

- **Major**: breaking parameter, output, naming, topology, or deployment
  behavior changes.
- **Minor**: backward-compatible features, new opt-in parameters, new modules,
  or expanded supported scenarios.
- **Patch**: bug fixes or internal refactors that do not add capabilities or
  require consumers to change.

When the impact is **major** or **minor**, explicitly call out that the public
Portal experience and the Terraform landing-zone implementation need follow-up
parity review or updates. Patch-only bug fixes do not require those downstream
Portal/Terraform signals unless the fix changes a shared contract.

---

## Do and Do Not

Do:
- Prefer extending parameter lists over hardcoded values.
- Keep modules reusable and environment-agnostic.
- Preserve compatibility for downstream repos consuming this as `infra/`.
- Keep release pinning explicit in consumer patterns.

Do not:
- Assume a single workload topology.
- Break fallback behavior for substituted params.
- Couple consumer-specific app logic directly into landing zone core unless generic.
- Remove the `manifest.json` bootstrap contract used by jumpbox automation.

---

## External Reference for a Full Consumer Implementation

For an end-to-end example of the submodule + preprovision override + manifest bootstrap pattern in practice, see:
- https://github.com/azure/gpt-rag

Use that reference to validate mechanics, but keep this repository generic and reusable.

## Engineering Standards (Bicep / IaC)

### Clean Code and Modularity

This is an IaC-first repository in Bicep. Keep templates modular, readable, and
reusable; avoid letting `main.bicep` or any module accumulate hardcoded,
workload-specific logic.

- Keep `main.bicep` as the orchestrator: compose AVM and custom modules under
  feature-flag conditions (`if (...)`). Put reusable resource logic in focused
  modules under `modules/` rather than inlining duplicated resource blocks.
- Reuse existing module patterns and `constants/constants.bicep` (role IDs,
  naming abbreviations) before creating new module files or literals. Avoid
  duplication and speculative abstractions.
- Drive infra shape from data, not branches: extend the topology lists
  (`containerAppsList`, `modelDeploymentList`, `databaseContainersList`,
  `storageAccountContainersList`) and their mapping logic instead of adding
  per-workload conditionals.
- Use clear, descriptive symbolic names for resources, modules, parameters, and
  variables. Add a `@description` to every parameter; comment only non-obvious
  decisions.
- Keep module parameters minimal but explicit, and preserve idempotency.

### Parameterization, Identity, and Safety

- Never hardcode tenant/subscription/resource names; derive names
  deterministically (resource token + abbreviations) and keep tenant/sub IDs
  out of templates.
- Add new capability in the documented sequence: parameter in `main.bicep`
  (with description + sensible default) → value in `main.parameters.json`
  (literal or `"${ENV_VAR}"`) → fallback handling if substitution can resolve
  empty → wire to modules → publish to App Configuration via
  `appConfigPopulate` if runtime needs it → expose as output if downstream
  automation needs it.
- Keep role assignments explicit, centralized, and least-privilege.
- Preserve both deployment modes (Standard and Zero Trust / network isolation):
  do not break private DNS / private endpoint dependencies or the substituted-
  parameter fallback behavior. Keep changes compatible with the submodule
  consumer pattern.

### Validating Changes

```bash
az bicep build --file main.bicep   # lint/compile before submitting
```

End-to-end validation is `azd provision` from a consumer (e.g. the GPT-RAG
core) with the appropriate `main.parameters.json`. Run through the **Change
Checklist** and **Documentation Consistency** sections above before submitting.
