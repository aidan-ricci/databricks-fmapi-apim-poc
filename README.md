# Internet → APIM → private Databricks FMAPI (Azure)

Terraform that exposes the Databricks Foundation Model APIs (FMAPI) to the public
internet through API Management while the workspace and the calling Function stay
private. An internet caller hits the public APIM gateway; APIM forwards to a
Python Azure Function over its private endpoint; the Function mints an OAuth token
and calls FMAPI over Private Link; the response returns the same way.

```
                         ┌──────────────── VNet 10.180.0.0/16 ────────────────┐
                         │                                                    │
  internet ──▶ APIM (External, public gateway) ──▶ Function (private endpoint)│
   caller        snet-apim .4.0/24               │      snet .3.0/24          │
   (your IP)                                      ▼                           │
                         │        Databricks workspace (public access OFF) ───┤
                         │              FMAPI over Private Link               │
                         │        host .1.0/24 / container .2.0/24            │
                         └────────────────────────────────────────────────────┘
```

A self-contained reference pattern. It provisions billable resources and opens a
public gateway to your allowlisted IPs — treat any deployment as your own to
secure and tear down.

## Contents

```
infra/       all Terraform — run terraform commands from here
scripts/     helper scripts (each operates on ../infra)
function/    Python Azure Function
```

| Path | Purpose |
|---|---|
| `infra/network.tf` | VNet, 8 subnets, NSGs, NAT Gateway |
| `infra/databricks.tf` | Classic workspace + web-auth workspace, private DNS, private endpoints |
| `infra/apim.tf` | Internal-mode APIM, private DNS, sample egress API |
| `infra/apim-fmapi.tf` | APIM → Function API, backend, product, subscription |
| `infra/function-infra.tf` | Key Vault, storage, EP1 plan, Function App, DNS zones, RBAC |
| `infra/jumpbox.tf` | Optional B1s jumpbox (disabled by default) |
| `infra/{variables,outputs,versions,main}.tf` | Inputs, outputs, providers, resource group |
| `infra/terraform.tfvars.example` | Copy to `infra/terraform.tfvars` to start |
| `function/` | Python Function: OAuth mint + FMAPI call |
| `scripts/prove-it.sh` | Verification: refused publicly, works in-VNet |
| `scripts/seed-sp-secret.sh` | Writes the SP OAuth secret into the private Key Vault |
| `scripts/teardown.sh` | Destroy and purge soft-deleted debris |

Scripts may be run from anywhere; each resolves `../infra` relative to itself.

## Requirements

- An Azure subscription with Contributor plus rights to create role assignments,
  and a Databricks account you can create a workspace in.
- Azure CLI, Terraform (>= 1.5), `func` (Azure Functions Core Tools), and the
  Databricks CLI.

```bash
az login --tenant <your-tenant-id>
az account set --subscription <your-subscription-id>
```

Set `subscription_id` in `infra/terraform.tfvars`; it has no default.

> This provisions billable resources (APIM, an EP1 Function plan, a NAT
> Gateway). Run `terraform destroy` when finished — see Cleanup.

## Deploy

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
# In terraform.tfvars set at least: prefix, remove_after, and
# apim_ingress_cidrs to your public IP as a /32 (curl -s https://api.ipify.org).
# Without apim_ingress_cidrs the public gateway lets nobody in.
terraform init
terraform plan
terraform apply
```

APIM Developer SKU takes 30–45 minutes to provision, so a full apply runs roughly
45–70 minutes. This is expected.

The default `apim_virtual_network_type = "External"` gives APIM a public gateway
for the inbound test; `apim_ingress_cidrs` controls who may reach it. Validation
rejects `0.0.0.0/0`, so use a narrow CIDR (e.g. your public IP as a /32) — some
Azure environments also strip internet-wide NSG rules by policy.

### Finding the values you need

Every value the setup asks for is discoverable from the CLI or the account
console — no guessing. `<profile>` below is an account-admin Databricks CLI
profile (step 2 shows how to create one with `databricks auth login`).

| Value | Where it goes | How to find it |
|---|---|---|
| `subscription_id` | `terraform.tfvars` | `az account show --query id -o tsv` |
| `location` | `terraform.tfvars` | your target region, e.g. `eastus2` (must be a region with FMAPI pay-per-token) |
| Your public IP | `apim_ingress_cidrs`, `jumpbox_ssh_source_cidrs` (as `/32`) | `curl -s https://api.ipify.org` — re-check it before each session; a rotated IP silently times out at the APIM NSG |
| SSH public key | `jumpbox_ssh_public_key` | `cat ~/.ssh/id_ed25519.pub` (or generate: `ssh-keygen -t ed25519`) |
| Databricks **account id** | account CLI login, metastore assignment | account console `https://accounts.azuredatabricks.net` → top-right menu, or read an existing account profile: `grep -A2 '\[<profile>\]' ~/.databrickscfg` |
| SP **client id** | `databricks_sp_client_id` | account console → *User management → Service principals*, or `databricks account service-principals list -p <profile> -o json` (field `applicationId`) |
| **Metastore id** | metastore assignment (step 2) | `databricks account metastores list -p <profile> -o json` — pick one whose `region` matches `location` |
| Workspace **numeric id** | metastore assignment (step 2) | after apply, from `workspace_url`: `terraform -chdir=infra output -raw workspace_url` → the `adb-<ID>.<n>` segment is the id; or `databricks account workspaces list -p <profile> -o json` |
| `fmapi_endpoint_name` | `terraform.tfvars` | list serving endpoints from the jumpbox (workspace API — the UI is private): see the snippet below. Confirm the name is `READY` before applying |

List the workspace's serving endpoints (once the jumpbox and workspace exist) so
you can set `fmapi_endpoint_name` to one that really exists:
```bash
WS=$(terraform -chdir=infra output -raw workspace_url); WS=${WS#https://}
RG=$(terraform -chdir=infra output -raw resource_group_name)
TOK=$(az account get-access-token \
  --resource 2ff814a6-3304-4ab8-85cb-cd0e6f879c1d --query accessToken -o tsv)
az vm run-command invoke -n "$(terraform -chdir=infra output -raw jumpbox_name)" -g "$RG" \
  --command-id RunShellScript --query "value[0].message" -o tsv --scripts "
curl -sS -H 'Authorization: Bearer $TOK' 'https://$WS/api/2.0/serving-endpoints' \
  | python3 -c 'import sys,json; [print(e[\"name\"], e.get(\"state\",{}).get(\"ready\")) for e in json.load(sys.stdin)[\"endpoints\"]]'"
```

This table is only for the inputs you provide *before and during* setup; once
deployed, every runtime value (URLs, keys, IPs) is a Terraform output — see
[Environment values](#environment-values).

### Databricks-side prerequisites

Terraform provisions the Azure resources, but the workspace it creates is empty
and **its UI is private** (public network access is disabled) — you cannot log
into `https://adb-<id>.<n>.azuredatabricks.net` from a browser. That is expected.
The setup therefore splits into two kinds of action:

- **Account console (public browser)** — `https://accounts.azuredatabricks.net`.
  The *account* portal, not the private *workspace* UI, so always reachable. Used
  for account-level objects: service principals and metastores.
- **Workspace API (private, via jumpbox)** — anything scoped to the workspace
  (assigning the SP, granting permissions). The workspace REST API is reachable
  over Private Link from inside the VNet even though the UI is not, and the
  identity that ran `terraform apply` is a workspace admin. The commands below
  drive it with `az vm run-command` on the jumpbox — no browser, no inbound port.

Two starting points decide how much you actually do:

- **New workspace (default).** Terraform provisions a fresh, empty workspace, so
  every object below must be created and wired up. Do all of steps 1–5 in order.
- **Pre-existing workspace.** You already have a workspace with a metastore
  assigned, a service principal, and FMAPI endpoints enabled. Most of the
  bootstrap is done — mainly point `terraform.tfvars` at the existing values and
  confirm the SP can reach the endpoint. Do only the steps the table marks.

Each step is annotated with the case it applies to; skip any whose output already
exists — this is a one-time bootstrap, not per-deploy work.

| Step | New workspace | Pre-existing workspace |
|---|---|---|
| 1 — create/choose the SP | create it; set client id in `terraform.tfvars` | reuse the existing SP; just set its client id |
| 2 — assign/create a metastore | required (account admin) | already assigned — verify only |
| 3 — seed the SP OAuth secret | required | required (this stack's Key Vault still needs the secret) |
| 4a — add SP to the workspace | required | skip if the SP is already a member |
| 4b — grant SP `CAN_QUERY` | only if invocation returns `403` | skip if already granted |
| 5 — publish the Function code | required | required |

> A metastore-backed SP that is already a workspace member can invoke FMAPI with
> no explicit endpoint grant, so treat step 4b as a fallback for a `403`, not a
> mandatory step.

**1. Create or choose the service principal (account console, external).**
*New workspace:* create one — Account console → *User management → Service
principals → Add*, and generate an **OAuth secret** (not a PAT).
*Pre-existing workspace:* reuse an SP you already have. Either way, record the
**client id** (an application UUID, not a secret) and set it in
`infra/terraform.tfvars`:
```hcl
databricks_sp_client_id = "<client-id>"
```
Then push it into the deployed Function (don't rely on re-apply — its
`app_settings` are under `ignore_changes`):
```bash
az functionapp config appsettings set -n "$(terraform -chdir=infra output -raw function_hostname | cut -d. -f1)" \
  -g "$(terraform -chdir=infra output -raw resource_group_name)" \
  --settings "DATABRICKS_SP_CLIENT_ID=<client-id>"
```

**2. Assign a metastore to the workspace (account admin).**
FMAPI requires a Unity Catalog metastore; without one, invocation returns
`METASTORE_DOES_NOT_EXIST`. Assignment is an **account-admin, account-level**
operation — not possible from the workspace API, and `az` has no metastore
commands at all (a metastore is a Databricks account-plane object ARM does not
model).

*Pre-existing workspace:* almost certainly already done — **verify only** (below),
and skip the rest if it returns a summary. *New workspace:* a fresh workspace has
none, so you must assign one. Check current state from the jumpbox:
```bash
# 404 METASTORE_DOES_NOT_EXIST = none assigned; a JSON summary = already done, skip.
az vm run-command invoke -n "$(terraform -chdir=infra output -raw jumpbox_name)" \
  -g "$(terraform -chdir=infra output -raw resource_group_name)" \
  --command-id RunShellScript --query "value[0].message" -o tsv --scripts "
TOK=\$(curl -s ...)   # workspace admin token, as in step 4
curl -sS -H \"Authorization: Bearer \$TOK\" \
  'https://<workspace-host>/api/2.1/unity-catalog/metastore_summary'"
```

If none is assigned, either use the console (**Account console → *Data →
Metastores* → select/create a metastore in the workspace's region → *Assign to
workspace* → `<prefix>-ws`**) or the account CLI with an account-admin profile:
```bash
# Authenticate to the ACCOUNT (browser SSO) — this is the account that owns the
# Azure AD tenant your workspace lives in, not an arbitrary account id.
databricks auth login --host https://accounts.azuredatabricks.net \
  --account-id <your-account-id> --profile acct-admin

# Reuse an existing metastore in the workspace's region rather than creating one.
databricks account metastores list -p acct-admin -o json   # pick one in-region

# Assign it. WORKSPACE_ID is the numeric id (terraform output workspace numeric
# id, or the adb-<id> in the workspace URL).
databricks account metastore-assignments create <WORKSPACE_ID> <METASTORE_ID> \
  -p acct-admin
```
The assigning identity must be an **account admin**; a plain workspace-admin AAD
token is rejected (the account API redirects to a login flow). If you lack
account admin, this is the one step to hand to someone who has it.

**3. Seed the SP OAuth secret into Key Vault (jumpbox). Both cases.**
Required either way: the secret lives only in *this* stack's Key Vault, always
freshly created by Terraform. Key Vault has no public access, so the write
originates inside the VNet. `seed-sp-secret.sh` uses the jumpbox's managed
identity, never writing the value to disk or state:
```bash
./scripts/seed-sp-secret.sh            # hidden prompt
./scripts/seed-sp-secret.sh --verify   # confirms length, never prints the value
```

**4. Add the SP to the workspace and grant it endpoint access (workspace API,
via jumpbox).** An account-level SP is not automatically a workspace member. The
UI is private, so drive the workspace SCIM/permissions API with your admin AAD
token from the jumpbox.

*New workspace:* run **4a** (add the SP). Run **4b** only if invocation later
returns `403` — a metastore-backed SP that is a workspace member can usually
invoke without an explicit grant.
*Pre-existing workspace:* skip **4a** if the SP is already a member and **4b** if
it already has access; run whichever is missing.
```bash
WS=$(terraform -chdir=infra output -raw workspace_url); WS=${WS#https://}
RG=$(terraform -chdir=infra output -raw resource_group_name)
CID=$(terraform -chdir=infra console <<<'var.databricks_sp_client_id' | tr -d '"')
EP=$(terraform -chdir=infra console <<<'var.fmapi_endpoint_name' | tr -d '"')
TOK=$(az account get-access-token \
  --resource 2ff814a6-3304-4ab8-85cb-cd0e6f879c1d --query accessToken -o tsv)

# 4a. add the SP as a workspace member (HTTP 201 = created)
az vm run-command invoke -n "$(terraform -chdir=infra output -raw jumpbox_name)" -g "$RG" \
  --command-id RunShellScript --query "value[0].message" -o tsv --scripts "
curl -sS -X POST -H 'Authorization: Bearer $TOK' -H 'Content-Type: application/scim+json' \
  -d '{\"schemas\":[\"urn:ietf:params:scim:schemas:core:2.0:ServicePrincipal\"],\"applicationId\":\"$CID\",\"displayName\":\"fmapi-sp\",\"active\":true}' \
  -w '\nHTTP %{http_code}\n' 'https://$WS/api/2.0/preview/scim/v2/ServicePrincipals'"

# 4b. grant the SP CAN_QUERY on the serving endpoint
az vm run-command invoke -n "$(terraform -chdir=infra output -raw jumpbox_name)" -g "$RG" \
  --command-id RunShellScript --query "value[0].message" -o tsv --scripts "
curl -sS -X PATCH -H 'Authorization: Bearer $TOK' -H 'Content-Type: application/json' \
  -d '{\"access_control_list\":[{\"service_principal_name\":\"$CID\",\"permission_level\":\"CAN_QUERY\"}]}' \
  -w '\nHTTP %{http_code}\n' 'https://$WS/api/2.0/serving-endpoints/$EP/permissions'"
```
The Databricks AAD resource id `2ff814a6-3304-4ab8-85cb-cd0e6f879c1d` above is
fixed for all Azure Databricks tenants — the resource you request a token for,
not a secret.

**5. Publish the Function code (jumpbox). Both cases.** The Function is always
created fresh by this stack, so its code must be published, and it has no public
access — so `func publish` must run inside the VNet. Package the `function/`
directory, ship it to the jumpbox, and publish with a remote build there — see
`scripts/prove-it.sh` for the working pattern, or run `func azure functionapp
publish <name> --python --build remote` from any host with VNet access.

Verify each hop with `./scripts/prove-it.sh` before the public test.

## Environment values

There is no `.env`. All live values are Terraform outputs, so read them with
`terraform -chdir=infra output` (always current, never stale):

```bash
terraform -chdir=infra output                          # all non-sensitive values
terraform -chdir=infra output -raw workspace_url
terraform -chdir=infra output -raw apim_subscription_key   # sensitive
```

The three credentials — APIM subscription key, Function host key, and Databricks
SP OAuth secret — are retrieved on demand, never stored. The SP secret lives only
in Key Vault, read by the Function at runtime via managed identity.

## Testing

The headline test is the inbound chain, run from your own machine on the public
internet:

```bash
SUB=$(terraform -chdir=infra output -raw apim_subscription_key)
curl -s -X POST "$(terraform -chdir=infra output -raw fmapi_chat_url)" \
  -H "Ocp-Apim-Subscription-Key: $SUB" \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"say hi"}]}' | jq
```

A model completion proves the whole path: internet → public APIM → Function
(private endpoint) → FMAPI (Private Link) → back. The same call without the key
returns 401 — the gateway is public but still authenticated. A timeout means
your IP is not in `apim_ingress_cidrs`.

`./scripts/prove-it.sh` runs the full matrix side by side — workspace and
Function refused when called directly from your machine, the APIM inbound chain
succeeding from that same machine, everything working from inside the VNet — so
the difference is origin, not credentials.

To isolate a single hop from inside the VNet (jumpbox), test innermost outward:

```bash
tf() { terraform -chdir=infra output -raw "$1"; }
RG=$(tf resource_group_name)
WS=$(tf workspace_url)
FN=$(tf function_hostname)
FNKEY=$(az functionapp keys list -n "${FN%%.*}" -g "$RG" \
  --query 'functionKeys.default' -o tsv)

nslookup "${WS#https://}"                          # jumpbox: expect a 10.180.3.x

curl -s "https://$FN/api/health?code=$FNKEY" | jq

curl -s -X POST "https://$FN/api/chat?code=$FNKEY" \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"say hi"}]}' | jq
```

Starting a cluster is the definitive back-end Private Link test: under
`network_security_group_rules_required = NoAzureDatabricksRules`, a broken
back-end path presents as clusters stuck in PENDING rather than an explicit
network error. `prove-it.sh` verifies DNS and API reachability only.

| Symptom | Cause |
|---|---|
| `invalid_client` at token mint | SP not added to the workspace |
| `403` at invocation | SP lacks CAN QUERY on the endpoint |
| `invalid_scope` | `scope` must be exactly `all-apis` |
| `RESOURCE_DOES_NOT_EXIST` | `fmapi_endpoint_name` incorrect — verify under *Serving* |
| `METASTORE_DOES_NOT_EXIST` | no UC metastore assigned to the workspace — see prerequisite step 2 (account-admin) |
| Connect error with DNS hint | private DNS zone not resolving, or `vnet_route_all_enabled` off |
| Key Vault 403 | RBAC propagation lag; retry after a few minutes |
| Clusters will not start | broken back-end Private Link under `NoAzureDatabricksRules` — check DNS first |
| APIM call from internet times out | your IP not in `apim_ingress_cidrs`, or APIM is in Internal mode |
| APIM call returns 401 | missing/incorrect `Ocp-Apim-Subscription-Key` |

## The jumpbox

The inbound test runs from your own machine — no jumpbox needed. But the
workspace, Key Vault, and Function all have public access disabled, so the
one-time setup that must originate inside the VNet — seeding the SP secret,
publishing the Function, opening the workspace UI — requires one.

```hcl
create_jumpbox           = true
jumpbox_ssh_public_key   = file("~/.ssh/id_ed25519.pub")
jumpbox_ssh_source_cidrs = ["<your.public.ip>/32"]   # never 0.0.0.0/0
```

A B1s VM (~$7.59/mo) is used instead of Bastion Basic (~$139/mo); cloud-init
installs the Azure CLI, Databricks CLI, and `func` tools.

## Cleanup

```bash
./scripts/teardown.sh --dry-run    # preview
./scripts/teardown.sh              # destroy and purge, with confirmation
```

`terraform destroy` alone leaves debris that blocks re-applying with the same
names. `teardown.sh` handles it, is idempotent, and reads the prefix and region
from Terraform.

| Debris | Effect | Handled by |
|---|---|---|
| APIM soft-deleted | name reserved 48h | `az apim deletedservice purge` |
| Key Vault soft-deleted | name reserved 7d | `az keyvault purge` |
| Databricks managed RG | frequently orphaned | `az group delete` |
| Delete locks | destroy fails partway | removed first |

The Bastion host is deleted before `terraform destroy`, since it holds a VNet
interface that otherwise blocks VNet deletion. The service principal and any
manually created AAD app registration are not Terraform-owned and must be removed
in the Databricks/Azure console.

## Constraints

- **Private Link depends on private DNS.** A missing or unlinked private DNS zone
  causes hostnames to resolve publicly, which presents as Private Link failure.
- **`browser_authentication` is limited to one per region per private DNS zone**
  and requires a dedicated web-auth workspace. This stack scopes its own zone to
  its own VNet to avoid collision. Without it, API and CLI access over Private
  Link still function; only browser SSO is affected.
- **Changing `public_network_access_enabled` or the injected VNet forces
  workspace replacement.** Review the plan before applying such changes.

## Cost

Approximately **$250/month** if left running (APIM ~$50, Function EP1 ~$150, NAT
Gateway ~$40, jumpbox ~$7.59, remainder minimal). Run `terraform destroy` when
finished.

## License

MIT — see [LICENSE](LICENSE).
