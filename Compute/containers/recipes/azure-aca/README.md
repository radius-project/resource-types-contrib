# Azure Container Apps: delegated native TCP

**Experimental; native TCP only. HTTP, TLS and UDP Routes are not supported
and fail explicitly.** No HTTP proxy sidecar is installed. ACA app ingress
selects a port within one Container App, not an HTTP rule or workload name.
Its environment-level HTTP routing selects Container Apps, not different
workload ports in the same Radius Containers group. Supporting the full
Radius HTTP path/header/method/query contract requires a separate design.

These [Bicep](bicep/azure-aca-containers.bicep) and
[Terraform](terraform/main.tf) recipes implement the approved relationship
contract in [radius-project/radius#13481](https://github.com/radius-project/radius/pull/13481).
They require an unreleased delegation-capable Radius runtime and compatible
recipe-pack Bicep definitions. The type annotation alone does not enable this
feature. Terraform additionally requires Radius's normal Azure credential
configuration to include the AzAPI provider, not only AzureRM. No CLI cache,
plaintext recipe credential, or pod-environment workaround is supported.
Use a runtime that excludes read-only Terraform data sources from managed
cleanup inventory; the existing environment must never become target-owned.
Normal template-driven group planning is a separate Radius dependency;
direct recipe deployment or `provisionGroup` validation is not proof that
`rad deploy` planning works.

## Ownership and lifecycle

Register Containers with `acceptsDelegationFrom: ['Radius.Compute/routes']`
and Routes with `kind: 'delegated'` and flat
`delegatesTo: 'Radius.Compute/containers'`. There is no route recipe source,
selector or all-application route scan. Radius resolves the existing typed
`rules[].destinationContainer.resourceId` relationship and supplies only
related Routes through `context.resource.incomingReferences`.

One target recipe owns the entire `Microsoft.App/containerApps` resource.
Delegates own no platform resources or Terraform state. Each result preserves
every incoming Route ID and revision and returns a TCP `listener`. The target's
`hosts` map contains only workloads currently exposed by Routes. Internal
listeners use the ACA app name; external listeners use its Azure-assigned FQDN.
The listener port is the **exposed** port, not necessarily the destination port.

The app name is derived from the case-normalized Radius target ID, not route
names or ports. Route additions, updates, deletion and recreation preserve the
app identity and the supplied workload configuration. No Routes means explicit
`ingress: null`, empty `hosts`, and no delegated outputs: workload containers
and their fixed replica count remain. Port mappings for inactive ports are
ignored so retained operator mappings do not prevent deletion of the last Route.
Radius must supply saved target desired inputs for route-only operations and
reject target deletion while live delegates remain.

Terraform uses **AzAPI for the whole Container App**, with AzureRM data sources
only for the existing resource group/environment. AzureRM's Container App
resource lacks additional TCP port mappings; splitting an AzureRM-managed app
and an AzAPI patch would introduce competing owners. Terraform state and the
returned native resource ID belong only to the target. Bicep native inventory
is discovered by Radius, so the recipe does not duplicate that ID in `result`.
Switching recipe languages/ownership on existing resources is not a supported
migration procedure.

## Supported input and platform limits

Every Route must explicitly use `kind: 'TCP'`, have no hostnames, and have
nonempty `rules`. **Every rule is validated**, not just `rules[0]`.
`matches` must be empty, and all rules of one Route must select the same
regular workload name and declared TCP destination port. Several Routes may
share an endpoint. Several different endpoints may be contributed to one
target by separate Routes. One Route selecting several different endpoints
cannot be represented by native TCP ingress plus the schema's single listener,
so it fails rather than silently losing rules. Cross-target ownership remains
the runtime's validation responsibility.

ACA supports one main TCP port plus five additional ports: at most **six
distinct destination ports per target**. Ports must be integers in 1-65535;
36985 is reserved by ACA. External ingress additionally reserves **exposed**
ports 80/443; targeting workload port 80 and exposing it as 8080 is allowed.
Exposed ports must be distinct within this app. Workload containers share an
ACA network namespace, so different regular workloads cannot declare the same
port; a workload can declare aliases for its own port. UDP declarations and
Routes to init containers or undeclared ports fail. Lowercased workload names
must be unique and must meet Azure's container naming rules.

| Input | Behavior |
| --- | --- |
| `containers.*.image`, `command`, `args` | Preserved; init containers are placed in `initContainers`. Images must be accessible without private registry credentials. |
| `containers.*.env.*.value` | Literal values; explicit env vars override generated connection vars. Do not put secret material in literal env values. |
| Ordinary connections | Inject `CONNECTION_<NAME>_<PROPERTY>` from resolved connection data, excluding framework metadata; `disableDefaultEnvVars` is respected for regular and init containers. |
| `resources.requests` / `resources.limits` | CPU and memory allocation, using limits then requests then recipe defaults. When both specify a dimension they must agree: ACA cannot implement distinct Kubernetes requests and limits. Memory must be a positive multiple of 256 MiB so its Gi value has at most two decimal places; allocations are never rounded. Azure validates supported CPU/memory combinations. |
| `replicas` | Positive fixed replica count, default 1; no scale-to-zero/autoscaling. |
| `restartPolicy` | Absent or `Always` only. |
| Probes, `workingDir`, mounts/volumes, `autoScaling`, extensions, platform options | Unsupported and rejected rather than ignored. |
| `env.valueFrom`, direct Secrets connections, producer-managed secret references | Unsupported and rejected when active. Disabled connection injection is allowed; secrets are not flattened into plaintext configuration. |

The broad existing Containers test app exercises Kubernetes/ACI-only fields
and is **not** an ACA compatibility test. Use the dedicated
[TCP application](../../test/azure-aca/app.bicep), not the generic `make test-recipe`
application, for this experimental slice.

## Parameters and registration

The managed environment already exists and is never created, changed or
deleted by these recipes. Configure the Radius Azure provider for the app's
resource group and use an explicitly authorized execution identity. Neither
recipe creates role assignments, networking or credentials.

| Parameter | Default / requirement |
| --- | --- |
| `containerAppsEnvironmentName` | Required existing environment name. |
| `containerAppsEnvironmentResourceGroupName` | App deployment resource group by default; override when the environment is elsewhere in the same subscription. |
| `containerAppsLocation` | Required **Bicep only**, matching the environment region. Terraform reads the existing environment's location. |
| `containerAppsExternalIngress` | `false`: reachable within the ACA environment. External TCP requires a VNet-enabled environment; its exposure still depends on that environment's network boundary. |
| `containerAppsExposedPorts` | `{}`: target ports are exposed unchanged. Optional target-port-number keys map to exposed port numbers. |
| `containerAppsDefaultCpu` | `0.25` per workload (Bicep decimal string, Terraform number). |
| `containerAppsDefaultMemoryInMib` | `512` per workload. |

External exposed ports must be unique **across the managed environment**,
including other apps' main and additional TCP ports. The recipe can validate
its own mappings only; the operator must allocate ports across targets, and
Azure errors must be surfaced. Internal ports can be reused by different apps.
An internal app name is resolvable only in its ACA environment.

The [example pack](../../test/azure-aca/recipe-pack.bicep) registers the two types together,
with an operator-supplied immutable Bicep OCI source or Terraform module URL.
It is deliberately not a released/default pack under `recipe-packs/`: current
published Radius pack definitions do not understand delegated registration.
Do not attach it to an existing nondelegated environment as an implicit
ownership migration.

Default build/test discovery, including the broad `azure` platform filter,
excludes this experimental platform so released Radius CI keeps its existing
behavior. Select `RECIPE_PLATFORM_FILTER=azure-aca` explicitly when discovering
these recipes. Direct publication/build commands below still address the
individual recipe without changing production pack registrations.

Publish Bicep with Radius's bundled Bicep version to a registry you own:

```bash
rad bicep publish \
  --file Compute/containers/recipes/azure-aca/bicep/azure-aca-containers.bicep \
  --target br:<registry>/<path>:<unique-tag>
```

Package Terraform with the repository's existing build tooling:

```bash
make build-terraform-recipe RECIPE_PATH=Compute/containers/recipes/azure-aca/terraform
```

Using compatible delegation-enabled definitions, deploy the example pack with
the actual environment name, region, recipe kind and immutable source, then
attach it with `rad env update --recipe-packs`. Register/build the Containers
and Routes types only if absent; retain the typed route relationship from the
lower resource-type layer. Once normal deployment planning is available:

```bash
rad deploy Compute/containers/test/azure-aca/app.bicep --workspace <workspace>
```

## Focused checks

With Node, Terraform 1.7+, public AzureRM/AzAPI provider access and the installed
Radius Bicep binary:

```bash
BICEP_CLI="$HOME/.rad/bin/bicep" make test-aca-tcp-recipes
```

These cloud-free tests evaluate Bicep resource snapshots and Terraform mocked
plans, including all-rule validation, two workloads/two routes, the six-port
boundary, rejected protocols/destinations, exact delegate IDs/revisions,
connection precedence, fixed replicas and explicit ingress removal. They do
not establish real Azure acceptance or Radius deployment planning.

For real ACA verification, use an isolated, authorized runtime and test apps
in the existing environment; keep baseline apps and networking untouched.
Verify combined target/delegate provisioning, route-only changes with saved
target inputs, multiple ports, empty contributions, recreation, listeners and
live TCP from a separate in-environment client. Compare target inventory and
unrelated resource records before/after; delegates must own no native inventory
or Terraform state. Delete only test-owned resources through Radius and confirm
their native apps are absent before removing the isolated runtime.
