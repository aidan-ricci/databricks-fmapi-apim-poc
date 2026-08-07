#!/usr/bin/env bash
#
# Self-contained proof that the private architecture works.
#
# Runs the SAME authenticated calls twice - once from wherever you run this
# (public internet), once from inside the VNet - and prints them side by side.
# Only the request origin differs, so any difference in outcome is network
# enforcement rather than authentication.
#
# Nothing here is destructive: every call is a read or a small model inference.
#
# Usage (from the repo root):
#   ./scripts/prove-it.sh
#
# Prerequisites: az CLI logged in to the target tenant, and a deployed
# stack under ../infra (for terraform outputs and the APIM subscription key).
#
set -uo pipefail

# Terraform config lives in ../infra relative to this script.
cd "$(dirname "$0")/../infra"

# Every value is read from `terraform output` (or `az`), never hardcoded:
# workspace hostnames, private endpoint IPs and the NAT egress address are all
# assigned by Azure at create time, so a hardcoded copy would be wrong the moment
# the stack is rebuilt - and wrong in the worst way, because a stale hostname
# still looks plausible.
# Read all outputs once as JSON and index in. `terraform output -raw <name>`
# prints a "No outputs found" warning to STDOUT (not stderr) when the stack is
# down, which would pollute the values; -json returns a clean {} instead.
_OUT="$(terraform output -json 2>/dev/null || echo '{}')"
o() {
  python3 -c '
import json,sys
d=json.loads(sys.argv[1] or "{}")
v=d.get(sys.argv[2],{}).get("value")
if isinstance(v,list): v=v[0] if v else None
print(v if v is not None else "")' "$_OUT" "$1" 2>/dev/null
}

RG="$(o resource_group_name)"
VM="$(o jumpbox_name)"
WS_HOST="$(o workspace_url)"; WS_HOST="${WS_HOST#https://}"
APIM_HOST="$(o apim_gateway_url)"; APIM_HOST="${APIM_HOST#https://}"
FN_HOST="$(o function_hostname)"
FMAPI_EP="$(terraform console <<<'var.fmapi_endpoint_name' 2>/dev/null | tr -d '"')"
PE_IP_WORKSPACE="$(o workspace_private_endpoint_ip)"
NAT_EGRESS_IP="$(o nat_gateway_egress_ip)"
JUMPBOX_PRIVATE_IP="$(o jumpbox_private_ip)"
APIM_PRIVATE_IP="$(o apim_private_ips)"
APIM_MODE="$(o apim_mode)"          # External = public gateway, Internal = private VIP
# Function app name is the first label of its hostname.
FUNCTION_APP_NAME="${FN_HOST%%.*}"

# Databricks' fixed AAD application id - the resource you request a token for.
DBX_RESOURCE="2ff814a6-3304-4ab8-85cb-cd0e6f879c1d"
TENANT="$(az account show --query tenantId -o tsv 2>/dev/null)"

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
info() { printf '        %s\n' "$1"; }

# Fail loudly rather than running a suite of meaningless checks against empty
# hostnames, which is what a torn-down stack would otherwise produce.
if [[ -z "$WS_HOST" || -z "$APIM_HOST" || -z "$FN_HOST" ]]; then
  echo
  echo "ERROR: no live stack found - terraform outputs are empty."
  echo "Deploy first (terraform apply), then re-run this script."
  exit 1
fi

echo
echo "============================================================"
echo " Gathering credentials"
echo "============================================================"

TOK="$(az account get-access-token --resource "$DBX_RESOURCE" --tenant "$TENANT" \
  --query accessToken -o tsv 2>/dev/null)"
if [[ -z "$TOK" ]]; then
  echo "ERROR: could not get an AAD token. Run:"
  echo "  az login --tenant $TENANT"
  exit 1
fi
info "AAD token for Databricks: ${#TOK} chars"

SUB="$(terraform output -raw apim_subscription_key 2>/dev/null)"
[[ -n "$SUB" ]] && info "APIM subscription key: ${#SUB} chars" \
                || info "APIM subscription key: MISSING (terraform state?)"

FNKEY="$(az functionapp keys list -n "$FUNCTION_APP_NAME" -g "$RG" \
  --query 'functionKeys.default' -o tsv 2>/dev/null)"
[[ -n "$FNKEY" ]] && info "Function host key: ${#FNKEY} chars" \
                  || info "Function host key: MISSING"

# ---------------------------------------------------------------------------
echo
echo "============================================================"
echo " PART 1 - from HERE (public internet)."
echo "============================================================"
echo
echo "The workspace, FMAPI, and Function must all be refused from here - they are"
echo "private. A 403 'Unauthorized network access' is the signal: the token is"
echo "valid, the ORIGIN is not, so that is network policy rather than auth."
if [[ "$APIM_MODE" != "Internal" ]]; then
  echo
  echo "APIM is the exception. In External mode its gateway is public by design,"
  echo "so the APIM -> Function -> FMAPI call below must SUCCEED from this machine"
  echo "while the direct workspace and Function calls stay refused."
fi
echo

code=$(curl -sS --max-time 20 -H "Authorization: Bearer $TOK" \
  -o /tmp/p1a.txt -w '%{http_code}' \
  "https://$WS_HOST/api/2.0/preview/scim/v2/Me" 2>/dev/null)
if [[ "$code" == "403" ]]; then
  pass "workspace API refused (HTTP 403)"
  info "$(head -c 70 /tmp/p1a.txt)"
else
  fail "workspace API returned HTTP $code - expected 403"
fi

code=$(curl -sS --max-time 20 -X POST -H "Authorization: Bearer $TOK" \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"x"}],"max_tokens":5}' \
  -o /tmp/p1b.txt -w '%{http_code}' \
  "https://$WS_HOST/serving-endpoints/$FMAPI_EP/invocations" 2>/dev/null)
if [[ "$code" == "403" ]]; then
  pass "FMAPI inference refused (HTTP 403)"
  info "$(head -c 70 /tmp/p1b.txt)"
else
  fail "FMAPI returned HTTP $code - expected 403"
fi

# APIM behaves oppositely by mode. External mode is the whole point of the
# inbound test: this call originates on the public internet and must SUCCEED,
# reaching the private Function and FMAPI and returning a model completion.
# Internal mode has no public gateway, so the same call must be unresolvable.
if [[ "$APIM_MODE" == "Internal" ]]; then
  code=$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' \
    "https://$APIM_HOST/fmapi/chat" 2>/dev/null)
  if [[ "$code" == "000" ]]; then
    pass "APIM gateway unresolvable (curl code 000)"
    info "internal-mode APIM has no public DNS record at all"
  else
    fail "APIM returned HTTP $code - expected 000 (no public endpoint)"
  fi
else
  # THE inbound test: internet -> public APIM -> private Function -> FMAPI.
  code=$(curl -sS --max-time 90 -X POST \
    -H "Ocp-Apim-Subscription-Key: $SUB" -H 'Content-Type: application/json' \
    -d '{"messages":[{"role":"user","content":"reply with exactly: DELTA"}],"max_tokens":8}' \
    -o /tmp/p1c.txt -w '%{http_code}' "https://$APIM_HOST/fmapi/chat" 2>/dev/null)
  if [[ "$code" == "200" ]]; then
    said=$(python3 -c "import json;print(json.load(open('/tmp/p1c.txt'))['choices'][0]['message']['content'])" 2>/dev/null)
    pass "internet -> APIM -> Function -> FMAPI (HTTP 200)"
    info "model said: ${said:-<parse failed>}"
    info "this call left from THIS machine on the public internet"
  else
    fail "APIM returned HTTP $code - expected 200 (is your IP in apim_ingress_cidrs?)"
    info "$(head -c 120 /tmp/p1c.txt)"
  fi

  # Auth still gates the public endpoint: without the key it must be refused.
  code=$(curl -sS --max-time 30 -X POST -H 'Content-Type: application/json' \
    -d '{"messages":[{"role":"user","content":"x"}]}' \
    -o /dev/null -w '%{http_code}' "https://$APIM_HOST/fmapi/chat" 2>/dev/null)
  if [[ "$code" == "401" ]]; then
    pass "public APIM without a subscription key refused (HTTP 401)"
  else
    fail "APIM without key returned HTTP $code - expected 401"
  fi
fi

code=$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' \
  "https://$FN_HOST/api/health" 2>/dev/null)
if [[ "$code" == "403" ]]; then
  pass "Function app refused (HTTP 403)"
else
  fail "Function returned HTTP $code - expected 403"
fi

echo
info "Expected non-failure: https://$WS_HOST/login.html returns 200 publicly."
info "That is a static asset from the shared regional edge (52.254.24.96),"
info "served before workspace network policy applies. Not exposure."
code=$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' \
  "https://$WS_HOST/login.html" 2>/dev/null)
info "  observed: HTTP $code"

# ---------------------------------------------------------------------------
echo
echo "============================================================"
echo " PART 2 - from INSIDE the VNet. Same creds. Everything must work."
echo "============================================================"
echo
echo "These run on the jumpbox via the Azure VM agent (az vm run-command),"
echo "so the HTTP requests originate at ${JUMPBOX_PRIVATE_IP:-the jumpbox} - not on this machine."
echo "Watch the 'via' addresses: they are private endpoint IPs."
echo

OUT=$(az vm run-command invoke -n "$VM" -g "$RG" --command-id RunShellScript \
  --query "value[0].message" -o tsv --scripts "
WS=$WS_HOST
printf 'workspace API   : '; curl -sS --max-time 25 -H 'Authorization: Bearer $TOK' -o /tmp/x1 -w 'HTTP %{http_code} via %{remote_ip}\n' https://\$WS/api/2.0/preview/scim/v2/Me

printf 'FMAPI direct    : '; curl -sS --max-time 60 -X POST -H 'Authorization: Bearer $TOK' -H 'Content-Type: application/json' -d '{\"messages\":[{\"role\":\"user\",\"content\":\"reply with exactly: ALPHA\"}],\"max_tokens\":8}' -o /tmp/x2 -w 'HTTP %{http_code} via %{remote_ip}\n' https://\$WS/serving-endpoints/$FMAPI_EP/invocations
printf '   model said   : '; python3 -c \"import json;print(json.load(open('/tmp/x2'))['choices'][0]['message']['content'])\" 2>/dev/null || echo '(parse failed)'

printf 'Function->FMAPI : '; curl -sS --max-time 90 -X POST -H 'Content-Type: application/json' -d '{\"messages\":[{\"role\":\"user\",\"content\":\"reply with exactly: BRAVO\"}],\"max_tokens\":8}' -o /tmp/x3 -w 'HTTP %{http_code} via %{remote_ip}\n' 'https://$FN_HOST/api/chat?code=$FNKEY'
printf '   model said   : '; python3 -c \"import json;print(json.load(open('/tmp/x3'))['choices'][0]['message']['content'])\" 2>/dev/null || echo '(parse failed)'

printf 'APIM->Fn->FMAPI : '; curl -sS --max-time 90 -X POST -H 'Ocp-Apim-Subscription-Key: $SUB' -H 'Content-Type: application/json' -d '{\"messages\":[{\"role\":\"user\",\"content\":\"reply with exactly: CHARLIE\"}],\"max_tokens\":8}' -o /tmp/x4 -w 'HTTP %{http_code} via %{remote_ip}\n' https://$APIM_HOST/fmapi/chat
printf '   model said   : '; python3 -c \"import json;print(json.load(open('/tmp/x4'))['choices'][0]['message']['content'])\" 2>/dev/null || echo '(parse failed)'

printf 'APIM no key     : '; curl -sS --max-time 30 -X POST -H 'Content-Type: application/json' -d '{\"messages\":[{\"role\":\"user\",\"content\":\"x\"}]}' -o /dev/null -w 'HTTP %{http_code} (expect 401)\n' https://$APIM_HOST/fmapi/chat

printf 'APIM->internet  : '; curl -sS --max-time 60 -H 'Ocp-Apim-Subscription-Key: $SUB' -o /tmp/x5 -w 'HTTP %{http_code} via %{remote_ip}\n' https://$APIM_HOST/egress/zen
printf '   github zen   : '; head -c 60 /tmp/x5; echo

printf 'DNS workspace   : '; getent hosts \$WS | head -1
printf 'DNS apim        : '; getent hosts $APIM_HOST | head -1
printf 'DNS function    : '; getent hosts $FN_HOST | head -1
printf 'egress ip       : '; curl -sS --max-time 25 https://api.ipify.org; echo
" 2>&1)

echo "$OUT" | sed 's/^\[stdout\]//' | grep -v '^Enable succeeded' | grep -v '^\[stderr\]' | grep -v '^$' | sed 's/^/  /'

# ---------------------------------------------------------------------------
echo
echo "============================================================"
echo " How to read this"
echo "============================================================"
# Unquoted heredoc: the addresses below are read from `terraform output` so they
# always match the deployment being tested. A quoted heredoc with hardcoded IPs
# would silently describe a previous stack.
cat <<EOF

  1. The workspace and Function refuse the direct calls from your machine but
     answer from inside the VNet, with identical tokens. A 403 reading
     "Unauthorized network access to workspace: <id>" is Azure rejecting the
     caller's ORIGIN, not the token - an auth problem would fail in both parts.

  2. ALPHA / BRAVO / CHARLIE / DELTA are distinct prompts answered distinctly,
     so nothing is cached or replayed.

  3. The 'via' addresses in part 2 are private endpoint IPs that exist only
     inside the VNet - e.g. ${PE_IP_WORKSPACE:-<ws-pe>} for the workspace. The
     Function reaches FMAPI over that private path.
EOF

if [[ "$APIM_MODE" == "Internal" ]]; then
cat <<EOF

  4. APIM is Internal: its hostname does not resolve at all from your machine
     (part 1 showed curl code 000) and resolves to the private VIP
     ${APIM_PRIVATE_IP:-<apim-vip>} inside the VNet. That asymmetry is the test.

  5. Egress leaves via ${NAT_EGRESS_IP:-<nat-ip>} - the NAT Gateway.
EOF
else
cat <<EOF

  4. APIM is External: the DELTA call in part 1 proves the full inbound chain -
     internet -> public APIM gateway -> Function (private endpoint) -> FMAPI ->
     response - while the workspace and Function themselves stay private. Auth
     still applies: the same endpoint without a subscription key returns 401.

  5. Egress from the workspace and Function leaves via ${NAT_EGRESS_IP:-<nat-ip>}
     - the NAT Gateway.
EOF
fi

cat <<EOF

  Not proven by this script: that a Databricks cluster can launch. Back-end
  Private Link is confirmed here by DNS and API reachability, but a real cluster
  start is the definitive test of the SCC path.

EOF
