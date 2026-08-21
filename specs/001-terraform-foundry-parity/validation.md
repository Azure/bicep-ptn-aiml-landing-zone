# User Story 1 validation

Validated on 2026-08-21 from the user-owned `release/2.6.1` checkout. This
corrective pass remains limited to T010–T020. No Azure deployment, preview,
branch creation or switch, commit, push, release, publication, Terraform source,
or cross-repository proposal was performed.

The active inventory contains 22 grouped capabilities and detailed contracts
for 188 inputs, 61 outputs, and 97 runtime keys (92 literal and 5 pattern).
Input metadata records 38 required/no-default, 125 JSON-literal-default, and 25
compiled-expression-default contracts; 13 inputs have non-empty allowed values.
There are 186 built-in and 2 user-defined input type contracts.

| Command | Exit | Result and proof |
| --- | ---: | --- |
| `npm run test:parity` | 0 | All five parity suites passed. A temporary detached checkout of pinned Bicep commit `64195c01b70974fa7256c2f54a0035fb06804139` compiled without modifying `main.bicep` or retaining ARM output. Tests matched all 188 parameter types, required/default presence, literal values or exact compiled expressions, allowed values, all 61 output types, all 97 runtime contracts, and exactly-once detailed/grouped coverage. |
| `pwsh -NoProfile -File ./scripts/parity/Test-ParityAssets.ps1` | 0 | One active inventory with 22 capabilities passed schema, baseline, reference, scenario, sensitive-value, and evidence-integrity validation. Pinned public subnet defaults are permitted only under detailed source-default metadata; environment evidence remains protected by the private-address check. |
| `pwsh -NoProfile -File ./scripts/parity/Export-ParityMarkdown.ps1 -Check` | 0 | `docs/terraform-parity.md` was byte-identical to deterministic output and exposes input type/default/allowed-value, output type, and runtime literal/pattern metadata. |
| `[IO.File]::ReadAllBytes(...)` plus `SequenceEqual` for the design/runtime inventory schemas | 0 | `specs/001-terraform-foundry-parity/contracts/inventory.schema.json` and `parity/schemas/inventory.schema.json` byte-match at 10,084 bytes. |
| `git diff --check` | 0 | No whitespace errors. |

During direct materialization of the pinned compiled contract, Bicep emitted
existing source warnings for a hard-coded storage host, safe access, one
Managed Environment property type, one unused variable, and unavailable
preview resource types. Compilation succeeded; no warning was suppressed and no
Bicep source was changed.

## Skipped checks

- T021 and later quickstart, evidence, handoff, proposal, and workflow sections
  were not run or changed.
- Copilot asset validation was not run because no agent, skill, instruction, or
  Copilot validation script changed.
- Current-tree Bicep build/lint, deployment preview, and Azure-aware preflight
  were not run because no Bicep, parameter, module, or deployment behavior
  changed. The only compilation was the temporary pinned contract used by the
  deterministic inventory test.
- No Terraform plan/apply or Azure deployment ran. Static source and compiled
  contract inspection are not parity evidence.

## Residual risk

- Every scenario assessment remains `parityDeclared=false`.
  `standalone-standard` remains structurally blocked in Terraform v0.5.1, while
  `standalone-network-isolated` is assessed independently.
- Runtime parity, DNS resolution, endpoint reachability, RBAC effectiveness,
  and scenario deployment behavior still require separately approved
  deployments and reviewed comparisons in the Terraform repository.
- The coverage test requires a local Bicep CLI, or Azure CLI with Bicep, and the
  pinned Git commit to remain available in repository history.
- The previously observed npm audit warning for pinned local validation tooling
  remains unresolved; changing validator dependencies is outside T010–T020.

# User Story 2 handoff validation

Validated on 2026-08-21 from the same user-owned dirty `release/2.6.1`
checkout. This pass implements only T021–T032. It preserves the US1 inventory,
keeps all 44 scenario assessments at `parityDeclared=false`, and leaves T033
unchecked.

Five pending, human-reviewable handoffs use honest draft baseline provenance:
`baselineId` plus SHA-256
`33fa2bae3144b79c632a0e8f142a85600989ecd04de8cca8b1a49de5edff44b4`
over the exact Git-normalized `parity/inventory.json` repository bytes. They claim neither an inventory
commit nor review. Their capability sets cover all 44 actionable `partial`,
`absent`, or `blocked` capability/scenario gaps, but the approved
proposal-eligible count is zero. Pending status prevents agent consumption,
dispatch, and T033 authorization.

| Command | Exit | Result and proof |
| --- | ---: | --- |
| `npm run test:parity` | 0 | All nine parity suites passed. Fitness cases prove pending digest-only schema validity, missing approved metadata rejection, source SHA rejection because its inventory blob is absent, exact committed-byte digest and baseline verification in a temporary unreferenced Git repository, mismatch rejection, pending proposal ineligibility, alignment provenance, and retained explicit generator failures. Inventory coverage remained 22 capabilities, 188 inputs, 61 outputs, and 97 runtime keys. |
| `pwsh -NoProfile -File ./scripts/parity/Test-ParityAssets.ps1` | 0 | Reported one inventory, 22 capabilities, zero assessments, five handoffs, zero approved proposal-eligible handoffs, and zero evidence records. Draft coverage, provenance, duplicate, scenario-evidence, and sensitive-content checks passed. |
| Handoff coverage query over `parity/inventory.json` and `parity/handoffs/**/*.json` | 0 | `handoffs=5; pending=5; actionableGaps=44; covered=44; approvedEligible=0; parityDeclared=0`; all required category directories are present. |
| `pwsh -NoProfile -File ./scripts/parity/Export-ParityMarkdown.ps1 -Check` | 0 | The generated inventory view remained byte-identical. Handoff IDs were not added to inventory, so no generated content changed. |
| `pwsh -NoProfile -File ./.github/scripts/Validate-CopilotAssets.ps1` | 0 | Validated six agents, 17 skills, and scoped instructions, including the read-only parity-agent boundary. |
| `pwsh -NoProfile -File ./tests/scripts/Validate-CopilotAssets.Tests.ps1` | 0 | Valid, duplicate-name, unsupported-tool, parity write-tool, approved-provenance boundary, and missing-boundary cases all passed. |
| Design/runtime byte comparison for the Terraform handoff schema | 0 | Design and runtime schemas byte-match at 7,035 bytes; schema version remains `1.0.0` because the assets are unreleased. |
| `git show 64195c01b70974fa7256c2f54a0035fb06804139:parity/inventory.json` | 128 (expected) | Git reported that the path is absent from the pinned Bicep implementation commit, proving it cannot serve as approved inventory provenance. |
| Terraform-source extension scan (`*.tf`, `*.tfvars`, `*.tf.json`) | 0 | No Terraform source files exist in this repository. |
| `git diff --check` | 0 | No whitespace errors. |

No final validation command emitted a warning. The previously recorded npm
audit warning for the pinned local validator remains unresolved and was not
rechecked because dependencies did not change.

## User Story 2 skipped operations and residual risk

- T033 was not executed: no external pull request, target-repository change,
  credential use, dispatch, publication, branch operation, commit, push,
  release, or deployment occurred.
- No Bicep build/lint, What-If, Azure preflight, Terraform plan/apply, or Azure
  deployment ran because deployed infrastructure did not change.
- Every handoff remains `approval.status=pending`. Before proposal work, a
  reviewed repository commit must contain the exact inventory bytes and handoff
  authorization must separately record its URL, approver, and time. Issue #136
  is context and supplies none of this evidence.
- `standalone-standard` remains structurally blocked in Terraform v0.5.1.
  `standalone-network-isolated` remains independently assessed.
- Static validation does not prove runtime behavior, effective RBAC, DNS,
  endpoint reachability, or isolation. Each scenario still requires its own
  approved target-repository deployment and reviewed comparison.
