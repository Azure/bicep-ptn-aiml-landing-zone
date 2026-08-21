# Terraform repository interface

## Producer

`Azure/bicep-ptn-aiml-landing-zone` owns the approved structured handoff and dispatch. Pending drafts
are not consumer input.

## Consumer

`Azure/terraform-azurerm-avm-ptn-aiml-landing-zone` owns coding-agent execution, Terraform source,
branches, draft pull requests, AVM validation, deployment, evidence, merge, and release.

## Request

The dispatch payload contains only:

- event type `parity-proposal-requested`;
- handoff, provenance, and capability IDs;
- source PR number when the provenance is an alignment assessment;
- pinned Bicep and Terraform commits.
- for baseline provenance, the distinct inventory artifact commit and inventory review URL.

The consumer retrieves the full reviewed handoff from the immutable source commit and validates it
against `terraform-handoff.schema.json`. It verifies the exact committed inventory bytes and never
infers the inventory artifact commit from the pinned Bicep implementation commit.

## Required consumer response

The target draft PR links to the source assessment or reviewed baseline inventory, handoff,
capability IDs, and baselines. It states compatibility and migration impact, covers both affected
supported scenarios, lists required AVM checks, and identifies any blocked provider capability. The
response records the PR URL in the handoff through a reviewed source-repository update.

## Authorization

The source publication job uses a protected environment and ephemeral GitHub App token. The coding
agent cannot merge. Target branch protection and CODEOWNERS approval remain authoritative.

## Evidence boundary

Target CI may report static checks and plans, but only approved test-subscription deployment plus a
reviewed capability comparison can advance a scenario to parity.
