#!/usr/bin/env bash
#
# Full teardown for the Databricks Private Link -> APIM -> FMAPI test stack.
#
# terraform destroy alone leaves four kinds of debris:
#   1. APIM soft-deleted, name reserved 48h  -> blocks re-apply with the same name
#   2. Key Vault soft-deleted, 7d retention  -> blocks re-apply with the same name
#   3. Databricks managed resource group     -> frequently orphaned by the platform
#      (67 already sitting in this subscription from other engineers)
#   4. The VNet, its NSGs and the NAT Gateway, whenever anything Terraform does
#      not own still holds an interface in the VNet - most often the Bastion
#      host, which is why it is deleted in step 1 rather than last.
#
# Usage (from the repo root):
#   ./scripts/teardown.sh              # destroy, then purge, with confirmation
#   ./scripts/teardown.sh --dry-run    # show what would happen, change nothing
#   ./scripts/teardown.sh --yes        # skip the confirmation prompt
#
set -euo pipefail

DRY_RUN=false
ASSUME_YES=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --yes|-y)  ASSUME_YES=true ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# Terraform config lives in ../infra relative to this script.
cd "$(dirname "$0")/../infra"

# Read config from Terraform rather than hardcoding, so a changed prefix or
# region cannot leave the wrong thing behind.
PREFIX="$(terraform console <<<'var.prefix' 2>/dev/null | tr -d '"' || echo '')"
LOCATION="$(terraform console <<<'var.location' 2>/dev/null | tr -d '"' || echo '')"
SUB_ID="$(terraform console <<<'var.subscription_id' 2>/dev/null | tr -d '"' || echo '')"

if [[ -z "$PREFIX" || -z "$LOCATION" ]]; then
  echo "ERROR: could not read prefix/location from Terraform. Run from the project dir." >&2
  exit 1
fi

RG="${PREFIX}-rg"
APIM_NAME="${PREFIX}-apim"
KV_NAME="${PREFIX}-kv"
WS_MANAGED_RG="${PREFIX}-ws-managed-rg"
WEBAUTH_MANAGED_RG="${PREFIX}-webauth-managed-rg"

run() {
  if $DRY_RUN; then
    echo "  [dry-run] $*"
  else
    echo "  + $*"
    "$@" || echo "    (non-fatal: continuing)"
  fi
}

cat <<BANNER

============================================================
 Teardown: $PREFIX
   subscription : ${SUB_ID:-<current>}
   region       : $LOCATION
   resource grp : $RG
============================================================

This destroys the workspace, APIM, Function, Key Vault, and all
networking, then purges soft-deleted APIM and Key Vault so the
names are immediately reusable.

Purges are IRREVERSIBLE.

BANNER

if $DRY_RUN; then
  echo ">>> DRY RUN - nothing will be changed."
elif ! $ASSUME_YES; then
  read -r -p "Type the prefix ($PREFIX) to confirm: " reply
  [[ "$reply" == "$PREFIX" ]] || { echo "Aborted."; exit 1; }
fi

# ---------------------------------------------------------------------------
# 0. Remove any delete locks. FE engineers lock web-auth workspaces (there is
#    already one in this subscription), and a lock makes destroy fail partway.
# ---------------------------------------------------------------------------
echo
echo "[0/6] Checking for delete locks in $RG..."
if ! $DRY_RUN; then
  LOCKS="$(az lock list --resource-group "$RG" --query "[].id" -o tsv 2>/dev/null || true)"
  if [[ -n "$LOCKS" ]]; then
    while read -r lock_id; do
      [[ -n "$lock_id" ]] && run az lock delete --ids "$lock_id"
    done <<< "$LOCKS"
  else
    echo "  none found"
  fi
else
  echo "  [dry-run] would list and delete locks in $RG"
fi

# ---------------------------------------------------------------------------
# 1. Bastion host - MUST go before terraform destroy.
#
#    Bastion is created out of band (`az network bastion create`) so Terraform
#    has no record of it, but it holds an interface in the VNet. Deleting it
#    after destroy is too late: the VNet delete fails while Bastion still
#    occupies it, which strands the VNet, its NSGs and the NAT Gateway as
#    untracked orphans. Observed on 2026-08-07 - destroy removed APIM, both
#    workspaces, the Function, Key Vault, storage, the VM and every private
#    endpoint, then left those three behind and emptied the state file, so
#    Terraform could no longer see them at all.
#
#    Deterministic, not a race: any run with a Bastion present fails this way.
# ---------------------------------------------------------------------------
BASTION="${PREFIX}-bastion"
echo
echo "[1/6] Deleting Bastion host (blocks VNet deletion if left in place)..."
if $DRY_RUN; then
  echo "  [dry-run] would delete Bastion host $BASTION if present"
else
  if az network bastion show -n "$BASTION" -g "$RG" >/dev/null 2>&1; then
    # --yes is required: without a TTY the CLI aborts with "Operation cancelled."
    run az network bastion delete -n "$BASTION" -g "$RG" --yes
  else
    echo "  no Bastion host named $BASTION"
  fi
fi

# ---------------------------------------------------------------------------
# 2. terraform destroy
# ---------------------------------------------------------------------------
echo
echo "[2/6] terraform destroy (APIM alone takes 30-45 min)..."
if $DRY_RUN; then
  # `|| true` matters: with pipefail, a grep that matches nothing (empty state)
  # would abort the script before the purge steps ever run.
  terraform plan -destroy -no-color 2>&1 \
    | grep -E "^Plan:|will be destroyed|No changes" | head -20 || true
  echo "  [dry-run] would run: terraform destroy -auto-approve"
else
  terraform destroy -auto-approve || {
    echo
    echo "  WARNING: destroy did not complete cleanly."
  }

  # Whether or not destroy reported success, confirm the resource group is
  # actually gone. Two things can leave resources behind with Terraform no
  # longer tracking them:
  #   - out-of-band resources holding the VNet (Bastion, policy-injected DNS
  #     resolver links), and
  #   - a destroy that empties terraform.tfstate while Azure objects survive,
  #     which makes `terraform destroy` permanently unable to finish the job.
  # Deleting the group directly is the only reliable way to close that out, and
  # is what the old code merely suggested the operator do by hand.
  if [[ "$(az group exists -n "$RG" 2>/dev/null)" == "true" ]]; then
    echo
    echo "  $RG still exists after destroy. Remaining resources:"
    az resource list -g "$RG" --query '[].{name:name,type:type}' -o table 2>/dev/null | sed 's/^/    /'
    echo
    echo "  Deleting the resource group directly to clear untracked orphans."
    run az group delete -n "$RG" --yes
  fi
fi

# ---------------------------------------------------------------------------
# 3. Purge soft-deleted APIM (48h name reservation otherwise)
# ---------------------------------------------------------------------------
echo
echo "[3/6] Purging soft-deleted APIM..."
if $DRY_RUN; then
  echo "  [dry-run] would purge APIM $APIM_NAME in $LOCATION if soft-deleted"
else
  if az apim deletedservice show --service-name "$APIM_NAME" --location "$LOCATION" >/dev/null 2>&1; then
    run az apim deletedservice purge --service-name "$APIM_NAME" --location "$LOCATION"
  else
    echo "  no soft-deleted APIM named $APIM_NAME"
  fi
fi

# ---------------------------------------------------------------------------
# 4. Purge soft-deleted Key Vault (7d retention otherwise)
# ---------------------------------------------------------------------------
echo
echo "[4/6] Purging soft-deleted Key Vault..."
if $DRY_RUN; then
  echo "  [dry-run] would purge Key Vault $KV_NAME in $LOCATION if soft-deleted"
else
  if az keyvault list-deleted --query "[?name=='$KV_NAME'] | [0].name" -o tsv 2>/dev/null | grep -q .; then
    run az keyvault purge --name "$KV_NAME" --location "$LOCATION"
  else
    echo "  no soft-deleted vault named $KV_NAME"
  fi
fi

# ---------------------------------------------------------------------------
# 5. Orphaned Databricks managed resource groups.
#
#    The platform often fails to remove these. They are named by Terraform here
#    (managed_resource_group_name), so they are predictable - unlike the
#    databricks-rg-* defaults, 54 of which are already orphaned in this sub.
# ---------------------------------------------------------------------------
echo
echo "[5/6] Checking for orphaned Databricks managed resource groups..."
for mrg in "$WS_MANAGED_RG" "$WEBAUTH_MANAGED_RG"; do
  if $DRY_RUN; then
    echo "  [dry-run] would delete $mrg if it still exists"
  elif [[ "$(az group exists -n "$mrg" 2>/dev/null)" == "true" ]]; then
    echo "  $mrg still exists - deleting"
    run az group delete -n "$mrg" --yes --no-wait
  else
    echo "  $mrg already gone"
  fi
done

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
echo
echo "Verifying..."
if $DRY_RUN; then
  echo "  [dry-run] skipped"
else
  for check_rg in "$RG" "$WS_MANAGED_RG" "$WEBAUTH_MANAGED_RG"; do
    printf '  %-40s exists=%s\n' "$check_rg" "$(az group exists -n "$check_rg" 2>/dev/null || echo '?')"
  done
  printf '  %-40s %s\n' "soft-deleted APIM" \
    "$(az apim deletedservice show --service-name "$APIM_NAME" --location "$LOCATION" >/dev/null 2>&1 && echo 'STILL PRESENT' || echo 'clear')"
  printf '  %-40s %s\n' "soft-deleted Key Vault" \
    "$(az keyvault list-deleted --query "[?name=='$KV_NAME'] | [0].name" -o tsv 2>/dev/null | grep -q . && echo 'STILL PRESENT' || echo 'clear')"
fi

# ---------------------------------------------------------------------------
# 6. Account-level objects Terraform never owned.
#
#    The Bastion host is handled in step 1 (it has to go before destroy). What
#    remains here is the Unity Catalog metastore and the Databricks service
#    principal, both created through account-level APIs that Terraform has no
#    record of.
# ---------------------------------------------------------------------------
echo
echo "[6/6] Account-level objects (manual)..."

cat <<METASTORE

  Unity Catalog metastore (NOT deleted automatically - deletion order matters
  and getting it wrong can orphan the assignment):

    name : ${PREFIX}-metastore-${LOCATION}

  To remove it, unassign from the workspace FIRST, then delete:
    Account console -> Data -> Metastores -> ${PREFIX}-metastore-${LOCATION}
      -> Workspaces tab -> unassign ${PREFIX}-ws
      -> then Delete the metastore

  Left manual on purpose: the assignment write could not be done by API in this
  environment (HTTP 303), so the un-assignment likely cannot either. The sandbox
  deletes account-level objects 14 days after creation regardless.

METASTORE

cat <<DONE
Teardown complete.

Also not handled automatically (deliberately):
  - Databricks service principal \`${PREFIX}-fmapi-sp\`. Delete it in the account
    console -> User management -> Service principals. Terraform never owned it.
  - Any AAD app registration you made by hand.
  - Terraform state. Safe to keep, or delete *.tfstate* for a clean slate.
  - ~/.ssh/${PREFIX}-jumpbox{,.pub} - the keypair generated for the jumpbox.

DONE
