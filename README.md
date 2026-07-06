# securebicep

A hands-on reference for building Azure infrastructure the way you'd actually want it
built: a hub-and-spoke network, isolated Dev and Prod environments, and a pipeline that
refuses to deploy anything it hasn't scanned first. Everything here is modular Bicep,
and every design decision is explained so you can adapt it to your own environment
instead of copy-pasting blindly.

If you're here to learn how Checkov and PSRule fit into a real pipeline, or how a
hub-and-spoke topology actually enforces zero trust rather than just diagramming it,
this repo is for you.

## What's in here

```
bicep/
  main.bicep                 # Subscription-scope orchestrator: hub + every spoke, one command
  hub/main.bicep              # Shared hub network (vnet, firewall, bastion, DNS, logging)
  spoke/main.bicep            # Reusable spoke template - deployed once per environment
  modules/
    network/                  # nsg, vnet, peering, routeTable, firewall, bastion, private DNS
    storage/                  # zero-trust storage account
    monitoring/                # Log Analytics workspace
  parameters/
    hub.bicepparam
    dev.bicepparam
    prod.bicepparam
azure-pipelines.yml            # Validate -> Security gate -> Deploy Dev -> Deploy Prod
.checkov.yaml                  # Checkov configuration
ps-rule.yaml                    # PSRule.Rules.Azure configuration
```

Every `.bicep` file under `modules/` does one thing and takes plain parameters - no
hidden magic, no shared state between modules. `hub/main.bicep` and `spoke/main.bicep`
compose those building blocks into the two halves of the topology, and `main.bicep`
composes *those* into the full stack when you want everything at once.

## The architecture

```
                              ┌─────────────────────────────┐
                              │      rg-securebicep-hub      │
                              │                              │
                              │   vnet-hub  10.0.0.0/16       │
                              │  ┌────────────────────────┐  │
                              │  │ AzureFirewallSubnet     │  │
                              │  │   Azure Firewall  (afw) │  │
                              │  ├────────────────────────┤  │
                              │  │ AzureBastionSubnet      │  │
                              │  │   Azure Bastion         │  │
                              │  ├────────────────────────┤  │
                              │  │ snet-shared             │  │
                              │  └────────────────────────┘  │
                              │                              │
                              │  Log Analytics (centralized) │
                              │  privatelink.blob... DNS zone│
                              └───────────────┬──────────────┘
                                 peered   ▲    │    ▲   peered
                             (fwd traffic)│    │    │(fwd traffic)
                     ┌───────────────────┘    │    └───────────────────┐
                     │                         │                        │
         ┌───────────▼───────────┐             │            ┌───────────▼───────────┐
         │  rg-securebicep-dev    │             │            │  rg-securebicep-prod   │
         │  vnet-dev 10.1.0.0/16  │      no direct peering    │  vnet-prod 10.2.0.0/16 │
         │  ┌──────────────────┐ │      between spokes -      │  ┌──────────────────┐ │
         │  │ snet-app          │ │      all cross-spoke       │  │ snet-app          │ │
         │  │  -> firewall route│ │      traffic transits      │  │  -> firewall route│ │
         │  ├──────────────────┤ │      the hub firewall       │  ├──────────────────┤ │
         │  │ snet-data         │ │                            │  │ snet-data         │ │
         │  │  private endpoint │ │                            │  │  private endpoint │ │
         │  │  -> Storage acct  │ │                            │  │  -> Storage acct  │ │
         │  └──────────────────┘ │                            │  └──────────────────┘ │
         └────────────────────────┘                            └────────────────────────┘
```

Dev and Prod are structurally identical - same modules, same NSG shape, same
private-endpoint pattern, same geo-redundant storage - they only differ in address
space and (in a real org) which subscription/service connection they live in. That symmetry is
intentional: security posture shouldn't be something you "remember" to add to Prod
later. It's baked into the module, so every environment gets it for free.

## Security first, not security eventually

It's tempting to build the network, get it working, and bolt on security controls
afterwards. This repo takes the opposite approach: every module ships with its
strictest reasonable defaults, and you have to deliberately loosen something to make
it less secure - not the other way around.

A few concrete examples from the code:

- **Storage accounts default to `publicNetworkAccess: 'Disabled'`.** The only path in
  is a private endpoint on the data subnet. There's no "we'll lock it down later" step.
- **`allowSharedKeyAccess` is `false`.** Access keys and connection strings simply
  don't work against these accounts - callers must authenticate with Azure AD
  (managed identity, ideally), so a leaked key can never be the incident.
- **NSGs default-deny.** Every NSG in this repo ends in an explicit `DenyAllInbound`
  / `DenyAllOutbound` rule at priority 4096. Azure already denies by default implicitly
  - we make it explicit anyway, so anyone reading the NSG (or a security review, or an
  auditor) can see the intent without having to know Azure's implicit rule set.
- **`checkov` and `ps-rule-assert` run before any deployment step, with
  `continueOnError: false`.** A failing scan stops the pipeline. There is no "ship now,
  fix later" lane.

## Layered security (defense in depth)

No single control here is meant to be the whole story. If one layer is misconfigured
or bypassed, another is there to catch it:

| Layer | Control | What it stops |
|---|---|---|
| Edge | Azure Firewall in the hub, egress rules scoped to known spoke ranges | Uncontrolled outbound traffic from any workload |
| Network | Subnet-level NSGs, explicit allow + explicit deny | Lateral movement between the app and data subnets, or from either subnet to the internet |
| Routing | User-defined routes forcing `0.0.0.0/0` through the firewall | A misconfigured NSG rule that would otherwise let traffic straight out to the internet |
| Segmentation | Spokes peer only to the hub, never to each other | A compromised Dev workload reaching Prod directly |
| Identity | Storage accounts require Azure AD auth; no shared keys | Credential theft turning into data access |
| Data path | Private endpoints only; public network access disabled | Internet-facing exposure of storage, even by misconfiguration |
| Visibility | Every NSG, storage account, and firewall ships logs to a centralized Log Analytics workspace | Blind spots - if something does get through, there's a trail |
| Pipeline | Checkov + PSRule gate every deployment | Insecure IaC reaching Azure in the first place |

Any one of these failing doesn't mean the environment is compromised - that's the
point of layering them.

## Zero trust, applied

"Zero trust" gets used as a buzzword a lot. Here's what it actually means in this
repo, concretely:

- **No implicit trust between spokes.** Dev and Prod are peered to the hub, not to
  each other. There is no network path from Dev to Prod that doesn't pass through the
  hub firewall, where it can be inspected, logged, and denied.
- **No implicit trust between subnets.** The app subnet can reach the data subnet on
  443 and nothing else; the data subnet accepts *only* from the app subnet. Neither
  subnet trusts "the vnet" as a whole.
- **No standing public exposure.** Nothing in this topology has a public IP except the
  firewall and Bastion themselves - the two resources whose entire job is to be a
  controlled front door. VMs are reached exclusively through Bastion; storage is
  reached exclusively through a private endpoint.
- **Verify explicitly, every time.** Storage access requires an Azure AD token, not a
  key that, once issued, is trusted forever. TLS 1.2 and HTTPS are enforced, not
  assumed.
- **Assume breach.** Centralized logging exists so that if a control does fail, you
  can find out - the WAF Security pillar calls this out explicitly, and it's why every
  module here wires into the same Log Analytics workspace instead of each one growing
  its own, easy-to-forget logging setup.

## How this maps to the Well-Architected Framework

| Pillar | How this repo addresses it |
|---|---|
| **Security** | Defense in depth as described above: firewall, NSGs, forced tunneling, private endpoints, Azure AD-only storage access, centralized logging. |
| **Reliability** | Storage blob versioning and soft delete are on by default, and every environment - Dev included - defaults to geo-redundant storage (`Standard_GRS`). Data resilience isn't a "Prod-only" concern here; it's the module default. |
| **Operational Excellence** | Fully modular Bicep with one template per concern, parameter files per environment, and a pipeline that validates (`bicep build`/`lint`) before it ever scans or deploys. |
| **Cost Optimization** | Firewall and Bastion are togglable (`deployFirewall` / `deployBastion`) so you can spin up a cheap Dev-only smoke test without paying for a full hub. Logging, DNS, and the firewall are centralized in the hub instead of duplicated per spoke, so adding an environment doesn't mean paying for a second copy of shared infrastructure. |
| **Performance Efficiency** | Hub-spoke keeps shared services (firewall, DNS, Bastion) centralized instead of duplicated per environment, so scaling a new environment means adding a spoke, not rebuilding shared infrastructure. |

This repo leans hardest on Security, since that's the point of the exercise - but the
other four pillars are never an afterthought.

## The pipeline, stage by stage

`azure-pipelines.yml` has four stages, and each one only runs if the previous one
succeeds:

1. **Validate** - installs the Bicep CLI and runs `bicep build` on every top-level
   template (`hub/main.bicep`, `spoke/main.bicep`, `main.bicep`), plus `bicep lint`.
   This catches typos and type errors before you waste time scanning broken code.
2. **IaC_Compliance (`Verify Guardrails and Security`)** - the security gate:
   - **Checkov** scans every Bicep file for misconfigurations (public storage,
     missing TLS enforcement, overly-permissive NSGs, and so on) and emits a SARIF
     report as a build artifact.
   - **PSRule.Rules.Azure** expands the Bicep to ARM and evaluates it against
     Microsoft's own Well-Architected Framework rules, publishing results straight to
     the Azure DevOps Tests tab via NUnit output.
   - Both steps run with `continueOnError: false`. A failure here stops the pipeline
     cold - nothing gets a chance to deploy.
3. **DeployDev** - deploys the hub, captures its outputs (the firewall's private IP
   and the Log Analytics workspace ID), and deploys the Dev spoke using those values.
   No human approval required; Dev is meant to be cheap to iterate on.
4. **DeployProd** - re-uses the hub's outputs and deploys the Prod spoke, but only
   after a human approves the `prod` Environment check in Azure DevOps. Same
   templates as Dev, same guardrails, promoted deliberately rather than automatically.

Every deploy step runs `az deployment group what-if` immediately before the real
`create`, so you always see exactly what's about to change before it happens.

### Configuring the pipeline

Two things need to be set up in Azure DevOps before this pipeline can deploy (scanning
works out of the box - no Azure credentials needed for that):

1. **Service connection** - create an Azure Resource Manager service connection and
   point the `azureServiceConnection` variable in `azure-pipelines.yml` at it (or
   override it via a variable group).
2. **Environments and approvals** - create `dev` and `prod` Environments under
   *Pipelines > Environments*. Leave `dev` unguarded; add a required approval check
   to `prod` so a person has to sign off before anything reaches production.

## Getting started locally

You don't need an Azure subscription to validate or scan this repo - only to actually
deploy it.

**Prerequisites:**
- [Bicep CLI](https://learn.microsoft.com/azure/azure-resource-manager/bicep/install) (bundled with a recent Azure CLI, or install standalone)
- [Checkov](https://www.checkov.io/2.Basics/Installation.html) (`pip install checkov`)
- [PSRule for Azure](https://azure.github.io/PSRule.Rules.Azure/) (PowerShell: `Install-Module -Name PSRule.Rules.Azure`)
- Azure CLI, if you intend to deploy

**Build and lint every template:**
```bash
find bicep -name '*.bicep' -not -path '*/modules/*' -exec bicep build {} --stdout \; > /dev/null
bicep lint bicep/main.bicep
```

**Run the same security gate the pipeline runs:**
```bash
checkov --config-file .checkov.yaml
```
```powershell
Invoke-PSRule -InputPath ./bicep -Module PSRule.Rules.Azure -Option ./ps-rule.yaml
```

**See what a full deployment would do, without changing anything:**
```bash
az deployment sub what-if \
  --location eastus \
  --template-file bicep/main.bicep
```

**Deploy the whole stack yourself (hub + dev + prod, one subscription):**
```bash
az deployment sub create \
  --location eastus \
  --template-file bicep/main.bicep
```

**Or deploy one piece at a time** (this is what the pipeline does, and it's the safer
habit to build - a Dev change should never require touching Prod's deployment):
```bash
az group create -n rg-securebicep-hub -l eastus
az deployment group create -g rg-securebicep-hub \
  --template-file bicep/hub/main.bicep \
  --parameters bicep/parameters/hub.bicepparam

az group create -n rg-securebicep-dev -l eastus
az deployment group create -g rg-securebicep-dev \
  --template-file bicep/spoke/main.bicep \
  --parameters bicep/parameters/dev.bicepparam \
  --parameters hubFirewallPrivateIp=<from-hub-output> logAnalyticsWorkspaceId=<from-hub-output>
```

## Where to take this next

This repo is a solid, honest starting point - not a finished product. A few things
worth doing before you'd call this production-ready in your own tenant:

- **Tighten the firewall rule.** The starter network rule allows HTTPS to `*` from
  spoke ranges so the reference architecture deploys cleanly out of the box. Replace
  it with application rules scoped to the specific FQDNs your workloads actually need.
- **Customer-managed keys.** Storage encryption currently uses Microsoft-managed keys.
  If your compliance regime requires it, add a Key Vault module and switch
  `keySource` to `Microsoft.Keyvault`.
- **Azure Policy.** Pair this pipeline with policy assignments (e.g. deny public IPs
  outside the hub) so the guardrails hold even for resources created outside this
  repo.
- **Firewall Policy resource.** This repo uses classic firewall rule collections for
  simplicity. A `Microsoft.Network/firewallPolicies` resource gives you rule
  reusability and DNS proxy features if you outgrow the basics here.

If you extend this, keep the same rule the rest of the repo follows: make the secure
choice the default, and make anyone who wants something less secure say so
explicitly, in code, where a reviewer can see it.
