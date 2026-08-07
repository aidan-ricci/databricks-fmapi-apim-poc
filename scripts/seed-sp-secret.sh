#!/usr/bin/env bash
#
# Seed the Databricks SP OAuth secret into the private Key Vault.
#
# Key Vault has no public access, so the write must happen from inside the VNet.
# This runs it on the jumpbox via the VM agent using its managed identity - no
# SSH session and no stored credential needed.
#
# Usage (from the repo root):
#   ./scripts/seed-sp-secret.sh                 # prompts, input hidden
#   ./scripts/seed-sp-secret.sh --verify        # check what is currently stored
#
set -euo pipefail

# Terraform config lives in ../infra relative to this script.
cd "$(dirname "$0")/../infra"

# Read names from Terraform so this follows a changed prefix automatically and
# cannot write to a stale vault left over from a previous deployment. Read all
# outputs as JSON: `terraform output -raw <name>` prints a warning to STDOUT
# when the stack is down, which would otherwise be captured as a value.
_OUT="$(terraform output -json 2>/dev/null || echo '{}')"
o() {
  python3 -c '
import json,sys
d=json.loads(sys.argv[1] or "{}")
v=d.get(sys.argv[2],{}).get("value")
print(v if v is not None else "")' "$_OUT" "$1" 2>/dev/null
}

RG="$(o resource_group_name)"
VAULT="$(o key_vault_name)"
VM="$(o jumpbox_name)"
# The secret NAME is an input, not an output.
SECRET_NAME="$(terraform console <<<'var.databricks_sp_secret_name' 2>/dev/null | tr -d '"')"
[[ -z "$SECRET_NAME" ]] && SECRET_NAME="databricks-sp-oauth-secret"

if [[ -z "$RG" || -z "$VAULT" || -z "$VM" ]]; then
  echo "ERROR: could not read Terraform outputs - is the stack deployed?" >&2
  echo "Run 'terraform output' to check." >&2
  exit 1
fi

run_on_jumpbox() {
  az vm run-command invoke -n "$VM" -g "$RG" --command-id RunShellScript \
    --query "value[0].message" -o tsv --scripts "$1"
}

if [[ "${1:-}" == "--verify" ]]; then
  echo "Current state of $SECRET_NAME in $VAULT:"
  run_on_jumpbox "az login --identity -o none && az keyvault secret show \
    --vault-name $VAULT --name $SECRET_NAME \
    --query '{name:name,enabled:attributes.enabled,version_created:attributes.created,value_length:length(value)}' -o json"
  echo
  echo "Compare value_length against what the account console showed you. This"
  echo "script never prints the secret. The known-bad value is 8 chars, which is"
  echo "the literal placeholder '<SECRET>' seeded by mistake on 2026-08-06."
  exit 0
fi

# Prefer a hidden interactive prompt so the secret never lands in shell history.
# But `read` needs a TTY: in a non-interactive context (piped stdin, an agent
# harness, CI) it gets EOF instantly and the script would exit with no visible
# message. So fall back to reading stdin, and if neither is available say so
# loudly on stdout rather than dying quietly on stderr.
if [[ -t 0 ]]; then
  read -rsp "Paste the Databricks SP OAuth secret (input hidden): " SECRET
  echo
else
  SECRET="$(cat || true)"
  SECRET="${SECRET%%$'\n'*}"   # first line only
fi

if [[ -z "$SECRET" ]]; then
  echo "No secret received - nothing was written."
  echo
  echo "This script needs an interactive terminal to prompt. If you are running it"
  echo "somewhere without a TTY, pipe the value in instead:"
  echo
  echo "  printf '%s' 'THE-OAUTH-SECRET' | ./seed-sp-secret.sh"
  echo
  echo "or read it from a file that you delete afterwards:"
  echo
  echo "  ./seed-sp-secret.sh < /tmp/sp-secret.txt && rm -f /tmp/sp-secret.txt"
  exit 1
fi

# Guard against the exact mistake of pasting the placeholder: a literal
# '<SECRET>' is 8 chars and would otherwise store silently and report success.
# Errors go to stdout: some harnesses do not surface stderr, and a silent
# refusal is worse than a noisy one when a credential is involved.
if [[ "$SECRET" == *"<"* || "$SECRET" == *">"* ]]; then
  echo "ERROR: value contains angle brackets - looks like an unsubstituted placeholder."
  echo "Nothing was written."
  exit 1
fi

# Length heuristic only. The exact format of a Databricks OAuth secret has NOT
# been verified in this environment, so this warns rather than refuses - a hard
# threshold risks rejecting a valid credential that happens to be short.
if (( ${#SECRET} < 30 )); then
  echo "WARNING: the value is only ${#SECRET} chars, which looks short for an"
  echo "OAuth secret. Writing it anyway - verify with --verify afterwards, and"
  echo "confirm the length matches what the console showed you."
  echo
fi

echo "Writing a ${#SECRET}-char secret to $VAULT/$SECRET_NAME via the jumpbox..."

# The secret is interpolated into the run-command payload, so it does transit the
# Azure control plane. Acceptable for a sandbox test; for anything long-lived,
# seed the vault from an interactive Bastion session instead so the value never
# leaves the VM.
run_on_jumpbox "az login --identity -o none && az keyvault secret set \
  --vault-name $VAULT --name $SECRET_NAME --value '$SECRET' -o none && echo SEEDED"

echo
echo "Verifying..."
run_on_jumpbox "az login --identity -o none && az keyvault secret show \
  --vault-name $VAULT --name $SECRET_NAME --query 'length(value)' -o tsv"
echo "^ should match ${#SECRET}"
