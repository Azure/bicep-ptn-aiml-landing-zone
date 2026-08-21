# Parity workflow event contract

## Assessment event

- Trigger: pull request closed with `merged=true`.
- Accepted base branch: `develop`.
- Idempotency key: source repository + PR number + merge SHA.
- Trusted input: event metadata and files at the trusted merged/base commit.
- Prohibited behavior: executing code from an untrusted PR head in a privileged context.
- Persistence: schema-validate first, then serialize append-only commits to the dedicated
  `terraform-parity-assessments` ledger branch with a workflow concurrency key. Never push directly
  to `develop`.
- Result: exactly one pending assessment record or the existing matching record. Because the ledger
  branch is not `develop`, persisting an assessment cannot recursively create another assessment.

## Approval event

- Trigger: protected GitHub environment approval by a configured parity reviewer.
- Preconditions: exactly one approved provenance form is valid, referenced capabilities exist, and
  no conflicting active handoff exists. Ongoing work requires a final approved assessment; initial
  catch-up work requires `inventoryCommitSha` to contain the exact digest-matching inventory and an
  auditable `inventoryReviewUrl`. The Bicep source commit is never substituted for the inventory
  artifact commit. Handoff authorization separately requires `approvalUrl`, `approvedBy`, and
  `approvedAt`; issue #136 is context, not approval evidence.
- Result: approved handoff eligible for dispatch.

## Dispatch event

- Mechanism: `repository_dispatch` to the configured Terraform repository.
- Payload: handoff ID, provenance type and ID, source PR number when applicable, immutable commits,
  and capability IDs.
- Excluded: raw credentials, Azure identifiers, raw PR title/body, and full source diff.
- Authentication: ephemeral token from a narrowly scoped GitHub App.
- Duplicate behavior: return the existing active proposal; never create a second proposal.
- Pending, rejected, and superseded handoffs are never dispatch-eligible. Pending baseline drafts
  can record gap coverage only. T033 also requires the same approved-state authorization even though
  it uses the target repository's existing contribution path rather than the future US3 dispatch.

## Failure behavior

Schema errors, unknown IDs, branch mismatch, missing approval, stale baseline, permission failure,
or target rejection fail explicitly and leave the gap open. Retrying is safe. Rejected or obsolete
records are superseded rather than deleted.
