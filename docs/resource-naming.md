# Resource naming

This landing zone generates resource names for you. By default it follows the
Cloud Adoption Framework (CAF) naming pattern, and it does not require you to set
any naming input. A plain `azd provision` produces valid, readable, standards
aligned names.

This page is the full reference for how names are built, the defaults for every
token, the per resource length limits, and how to override or pin names.

## Quick summary

- CAF naming is the default (`resourceNamingMode = caf`).
- You do not have to set any token. Every CAF token has a safe default.
- Names are automatically bounded to each Azure resource limit and never end in
  a trailing hyphen.
- Names are deterministic, so redeploying the same environment produces the same
  names (idempotent).
- Explicit per resource name parameters still win over generated names.

## Naming pattern

Generated CAF names follow this shape:

```
<type>-<workload>-<environment>-<region>-<instance>
```

Example Key Vault name:

```
kv-a1b2c3-dev-eus2-001
```

Resources that do not allow hyphens (storage accounts and the container
registry) use a compacted form with the hyphens removed:

```
sta1b2c3deveus2001
```

## The four CAF tokens and their defaults

You can adopt CAF naming with zero configuration. Each token resolves to a
sensible default when you leave it empty.

| Token | Environment variable | Default when empty | Notes |
|---|---|---|---|
| Workload | `CAF_WORKLOAD_NAME` | 6 character deterministic hash | Derived from subscription id, environment name, and location. Stable per environment. |
| Environment | `CAF_ENVIRONMENT_NAME` | azd environment name | The value of `AZURE_ENV_NAME`. |
| Region | `CAF_REGION_NAME` | azd location, abbreviated | `AZURE_LOCATION` mapped to a short CAF code, for example `eastus2` becomes `eus2`. |
| Instance | `CAF_INSTANCE` | `001` | Increment only for a second parallel copy of the same workload in the same environment and region. |

The workload default is a hash rather than a word so that names are unique and
idempotent without any input. Set a meaningful workload name when you prefer a
readable value:

```
azd env set CAF_WORKLOAD_NAME contosoai
```

## Region abbreviations

The region token is abbreviated so names stay within Azure length limits. The
deployment location (`AZURE_LOCATION`) is mapped to a short code. Regions that
are not in the map fall back to the first 5 characters of the region string.

A selection of the mappings:

| Region | Code | Region | Code |
|---|---|---|---|
| eastus | eus | westeurope | weu |
| eastus2 | eus2 | northeurope | neu |
| centralus | cus | swedencentral | sdc |
| westus2 | wus2 | uksouth | uks |
| westus3 | wus3 | francecentral | frc |
| brazilsouth | brs | germanywestcentral | gwc |
| canadacentral | cnc | australiaeast | aue |
| japaneast | jpe | southeastasia | sea |

The complete map lives in `main.bicep` (`_cafRegionAbbrs`). To use an explicit
region token instead of the derived one:

```
azd env set CAF_REGION_NAME eus2
```

## Per resource prefixes and length limits

Every generated name is bounded to the Azure limit for that resource type. If a
name would exceed the limit it is trimmed, and a trailing hyphen left by
trimming is removed so the name stays valid.

| Resource | Prefix | Max length | Form |
|---|---|---|---|
| AI Foundry account | `aif-` | 64 | hyphenated |
| AI Foundry project | `aifp-` | 64 | hyphenated |
| AI Foundry storage | `staif` | 24 | compact |
| AI Foundry search | `srch-aif-` | 60 | hyphenated |
| AI Foundry Cosmos DB | `cosmos-aif-` | 44 | hyphenated |
| Bing search | `bing-` | 64 | hyphenated |
| App Configuration | `appcs-` | 50 | hyphenated |
| Application Insights | `appi-` | 64 | hyphenated |
| Container Apps environment | `cae-` | 32 | hyphenated |
| Container Registry | `cr` | 50 | compact |
| Cosmos DB account | `cosmos-` | 44 | hyphenated |
| Cosmos DB database | `cosmosdb-` | 63 | hyphenated |
| Key Vault | `kv-` | 24 | hyphenated |
| Log Analytics workspace | `log-` | 63 | hyphenated |
| Search service | `srch-` | 60 | hyphenated |
| Speech service | `spch-` | 64 | hyphenated |
| Storage account | `st` | 24 | compact |
| Virtual Network | `vnet-` | 64 | hyphenated |

Because storage accounts and the container registry are capped at short limits
and do not allow hyphens, their names carry the compacted stem and may drop the
region or instance suffix when the environment name is long. Uniqueness is still
guaranteed by the workload hash.

## Idempotency

All tokens are deterministic. The workload hash is derived from a stable set of
inputs (subscription id, environment name, location), and the other tokens come
from fixed inputs. Redeploying the same environment therefore produces the same
names, so `azd provision` updates existing resources in place rather than
creating parallel copies.

## Overriding names

You have two levels of control.

Override a single token to change the shape of all generated names:

```
azd env set CAF_WORKLOAD_NAME contosoai
azd env set CAF_INSTANCE 002
```

Override one specific resource name to bypass generation for that resource only.
Explicit name parameters always win, in both CAF and legacy modes:

- `aiFoundryAccountName`
- `containerRegistryName`
- `keyVaultName`
- `storageAccountName`
- `vnetName`
- and the other `*Name` parameters in `main.bicep`

## Legacy naming and upgrading existing deployments

Before this release the default was the older `resourceToken` based naming
(names such as `kv-5ggywq7b6wfxi`). CAF is now the default, which is a breaking
change for existing deployments: provisioning with defaults will generate new
names and can create parallel resources instead of updating the ones you already
have.

To keep your current names, pin legacy mode before provisioning:

```
azd env set RESOURCE_NAMING_MODE legacy
```

Legacy mode reproduces the exact pre release names, so an existing environment
updates in place.

## Standard and Zero Trust

Naming is identical in Standard and Zero Trust (network isolated) deployments.
The `NETWORK_ISOLATION` setting does not change how names are generated.
