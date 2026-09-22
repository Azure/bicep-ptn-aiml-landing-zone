# ADR-001: Optional internal API Management in the spoke

- Status: accepted
- Date: 2026-09-21
- Owners: AI Landing Zone maintainers
- Related issue or pull request: none

## Context

The integrated deployment needs an optional Azure API Management instance in
the AILZ spoke. The resource must use the Developer SKU, remain disabled by
default, preserve existing deployments, and follow the spoke's hub-routed
network-isolation model. The affected contracts are `main.bicep`,
`main.parameters.json`, `Deploy-AilzIntegrated.ps1`, spoke subnet allocation,
and operator documentation.

## Prioritized characteristics

| Characteristic | Priority | Measure |
| --- | --- | --- |
| Compatibility | 1 | Existing deployments produce no APIM resources without opt-in |
| Network isolation | 2 | APIM uses internal VNet mode in a dedicated spoke subnet |
| Deployability | 3 | Required APIM control-plane and health-probe paths are present |
| Operability | 4 | Diagnostics target the effective Log Analytics workspace |
| Cost control | 5 | The fixed Developer SKU is explicit and opt-in |

## Alternatives considered

### Internal VNet-injected Developer SKU

Deploy APIM into a dedicated `/27` subnet in a newly created integrated spoke.
Attach a purpose-built NSG and a dedicated route table with hub egress plus the
required direct `ApiManagement` service-tag route. The official APIM AVM was
evaluated first, but its expanded child-resource surface pushed the compiled
template over this repository's 5 MB hard size gate. A focused local module
uses the same current resource schema without unused APIM child resources.
Rollback is removal of the APIM instance and its dedicated network resources.

### Public APIM endpoint in the spoke resource group

Deploy the same SKU without VNet injection. This is simpler and avoids subnet
requirements, but it does not meet the integrated topology's private-access
intent and exposes a public gateway endpoint.

### Do not change

Operators would continue deploying APIM separately, losing consistent naming,
diagnostics, preview coverage, and lifecycle management with the AILZ spoke.

## Decision

Use an opt-in, internal VNet-injected Developer-tier APIM instance in a
dedicated spoke subnet. Use focused local APIM and NSG modules because the
equivalent AVM expansions exceed the repository's compiled-template size gate.
Keep the feature disabled by default. Require a publisher email, hub VNet, hub
firewall next hop, and approved hub-firewall ingress CIDRs when enabled. Do not
support APIM through the existing-VNet or platform-owned route-table paths
until those external contracts can be validated safely.

## Consequences

Enabling the feature adds an APIM instance, a `/27` subnet, an NSG, and a
dedicated route table when this deployment owns spoke routing. APIM provisioning
is comparatively slow and the Developer SKU has no production SLA. Existing
deployments are unchanged while the flag is false.

The hub platform team owns firewall DNAT, APIM dependency egress rules, reverse
VNet peering, and DNS records for the internal APIM endpoint host names. All
gateway ingress traverses the hub firewall. All workload and APIM dependency
egress traverses the hub firewall except the mandatory direct control-plane
response route described below.

## Compatibility and migration

The change is additive. New Bicep parameters and azd environment values have
disabled or empty defaults. CAF and legacy naming both support an explicit APIM
name override. No existing parameter, output, manifest, or resource name is
changed. The root template is already at ARM's 64-output limit, so no APIM
outputs are added.

## Security and identity

APIM receives a system-assigned managed identity. Its gateway uses internal VNet
mode. The dedicated NSG permits Azure API Management control-plane traffic on
TCP 3443, Azure Load Balancer health probes on TCP 6390, and gateway HTTPS only
from approved hub-firewall source CIDRs; a final inbound rule denies other
traffic. The APIM subnet's default route uses the hub firewall. A required
`ApiManagement -> Internet` service-tag route preserves symmetric control-plane
responses on TCP 3443 and is the sole forced-tunneling exception. No secrets or
API subscriptions are created.

## Adoption and rollback

Preview with `-DeployApiManagement`, a publisher email, and `-PreviewOnly`.
Provision only after reviewing the subnet, NSG, route table, and APIM changes.
Disabling the flag stops managing the APIM resources but does not delete them
under ARM incremental deployment mode. To roll back, first export any APIM
data-plane configuration, then remove the APIM service and its dedicated
subnet, NSG, and route table through an approved cleanup change.

## Compliance verification

- Parse the PowerShell script and JSON parameter file.
- Build and lint `main.bicep`.
- Run the compiled-template size gate.
- Run deterministic preflight checks.
- Run Azure What-If with the feature both disabled and enabled before an
  approved test deployment.

## Documentation impact

The repository README documents the new arguments and network behavior. The
public `Azure/AI-Landing-Zones` documentation requires a coordinated update in
its own repository.

## Review trigger

Review this decision when APIM Developer VNet-injection requirements change,
the deployment adopts a production APIM tier, the spoke address plan changes,
or an incident identifies a control-plane, DNS, or forced-tunneling problem.