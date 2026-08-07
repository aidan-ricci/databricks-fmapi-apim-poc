# Internet → APIM → private Databricks FMAPI (Azure)

Terraform for exposing the Databricks Foundation Model APIs (FMAPI) to the
public internet through API Management, while the workspace and the Function that
calls FMAPI stay private. An internet caller hits the public APIM gateway; APIM
forwards to a Python Azure Function over its private endpoint; the Function mints
an OAuth token and calls FMAPI over Private Link; the response returns the same
way.

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

The direction is inbound: **internet → APIM → Function → FMAPI → response.** The
workspace and Function are never directly reachable from outside; only the APIM
gateway is public, and only to the caller IPs you allowlist.

APIM mode is a variable. The default (`External`) is the inbound test above; set
`apim_virtual_network_type = "Internal"` for the reverse egress variant (private
Databricks → APIM → internet), in which case the gateway has no public endpoint.

A self-contained reference pattern. It provisions billable resources and opens a
public gateway to your allowlisted IPs, so treat any deployment as your own to
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

- An Azure subscription with Contributor (and enough rights to create role
  assignments), plus a Databricks account you can create a workspace in.
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

APIM Developer SKU takes 30–45 minutes to provision; a full apply is roughly
45–70 minutes. This is expected.

The default `apim_virtual_network_type = "External"` gives APIM a public gateway
so the inbound test works. `apim_ingress_cidrs` controls who may reach it;
validation rejects `0.0.0.0/0`, so use a narrow CIDR (e.g. your public IP as a
/32). Some Azure environments also strip internet-wide NSG rules by policy.

### Databricks-side prerequisites

Terraform provisions the Azure resources. Three items must then be created in the
new workspace before the Function can operate:

1. **Service principal.** Account console → *User management → Service
   principals*. Generate an **OAuth secret** (not a PAT). Record the client id
   (an application id, not a secret) and set it in `infra/terraform.tfvars`:
   ```hcl
   databricks_sp_client_id = "<client-id>"
   ```

2. **Seed the secret.** Key Vault has public access disabled, so the write must
   originate inside the VNet. `scripts/seed-sp-secret.sh` performs it via the
   jumpbox without persisting the value to disk or state:
   ```bash
   ./scripts/seed-sp-secret.sh
   ```

3. **Workspace assignment and endpoint permission.** Add the SP to the workspace
   (Admin settings → *Identity and access*); an account-level SP is not
   automatically a member. Enable a pay-per-token FMAPI endpoint under *Serving*,
   set `fmapi_endpoint_name` to its exact name, and grant the SP **CAN QUERY**.

Then re-apply and publish the Function code from inside the VNet:

```bash
cd infra && terraform apply && cd ..
FN=$(terraform -chdir=infra output -raw function_hostname)
cd function && func azure functionapp publish "${FN%%.*}" --python
```

## Environment values

There is no `.env`. All live values are Terraform outputs, so read them with
`terraform -chdir=infra output` (always current, never stale):

```bash
terraform -chdir=infra output                          # all non-sensitive values
terraform -chdir=infra output -raw workspace_url
terraform -chdir=infra output -raw apim_subscription_key   # sensitive
```

The three credentials — APIM subscription key, Function host key, and Databricks
SP OAuth secret — are retrieved on demand, never stored. The SP secret resides
only in Key Vault and is read by the Function at runtime via managed identity.

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
returns 401 — the gateway is public but still authenticated. If it times out,
your IP is not in `apim_ingress_cidrs`.

`./scripts/prove-it.sh` runs the full matrix: it confirms the workspace and
Function are refused when called directly from your machine, that the APIM
inbound chain succeeds from that same machine, and that everything works from
inside the VNet — side by side, so the difference is origin, not credentials.

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

Starting a cluster is the definitive back-end Private Link test: with
`network_security_group_rules_required = NoAzureDatabricksRules`, a broken
back-end path presents as clusters stuck in PENDING rather than an explicit
network error. `prove-it.sh` verifies DNS and API reachability only.

| Symptom | Cause |
|---|---|
| `invalid_client` at token mint | SP not added to the workspace |
| `403` at invocation | SP lacks CAN QUERY on the endpoint |
| `invalid_scope` | `scope` must be exactly `all-apis` |
| `RESOURCE_DOES_NOT_EXIST` | `fmapi_endpoint_name` incorrect — verify under *Serving* |
| Connect error with DNS hint | private DNS zone not resolving, or `vnet_route_all_enabled` off |
| Key Vault 403 | RBAC propagation lag; retry after a few minutes |
| Clusters will not start | broken back-end Private Link under `NoAzureDatabricksRules` — check DNS first |
| APIM call from internet times out | your IP not in `apim_ingress_cidrs`, or APIM is in Internal mode |
| APIM call returns 401 | missing/incorrect `Ocp-Apim-Subscription-Key` |

## The jumpbox

The inbound test itself runs from your own machine — no jumpbox needed. But the
workspace, Key Vault, and Function all have public access disabled, so the
one-time setup that must originate inside the VNet — seeding the SP secret,
publishing the Function, opening the workspace UI — still requires it.

```hcl
create_jumpbox           = true
jumpbox_ssh_public_key   = file("~/.ssh/id_ed25519.pub")
jumpbox_ssh_source_cidrs = ["<your.public.ip>/32"]   # never 0.0.0.0/0
```

A B1s VM (~$7.59/mo) is used in preference to Bastion Basic (~$139/mo). Cloud-init
installs the Azure CLI, Databricks CLI, and `func` tools.

## Cleanup

```bash
./scripts/teardown.sh --dry-run    # preview
./scripts/teardown.sh              # destroy and purge, with confirmation
```

`terraform destroy` alone is insufficient: it leaves debris that blocks
re-applying with the same names. `teardown.sh` handles it, is idempotent, and
reads the prefix and region from Terraform.

| Debris | Effect | Handled by |
|---|---|---|
| APIM soft-deleted | name reserved 48h | `az apim deletedservice purge` |
| Key Vault soft-deleted | name reserved 7d | `az keyvault purge` |
| Databricks managed RG | frequently orphaned | `az group delete` |
| Delete locks | destroy fails partway | removed first |

The Bastion host is deleted before `terraform destroy`, as it holds an interface
in the VNet and otherwise blocks VNet deletion. The service principal and any
manually created AAD app registration are not owned by Terraform and must be
removed in the Databricks/Azure console.

## Constraints

- **Ingress is never opened to `0.0.0.0/0`.** Variable validation rejects
  internet-wide CIDRs; scope `apim_ingress_cidrs` (and the jumpbox SSH CIDRs) to
  known addresses. Some Azure environments also strip internet-wide NSG rules by
  policy.
- **Serverless is not supported.** Azure serverless workspaces support neither
  VNet injection nor Private Link, so this uses a classic Premium-SKU workspace.
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
