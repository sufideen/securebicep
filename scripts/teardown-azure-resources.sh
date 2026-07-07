#!/usr/bin/env bash
# Deletes the billable Azure resource groups created by this repo's
# pipelines, so you can start clean and redeploy later via the pipeline
# YAML files. Does NOT touch the Azure DevOps project, service connection,
# app registration/federated credential, or Environments - those are cheap
# to keep and re-running scripts/setup-azure-devops.sh later would just
# recreate them anyway, so there's no need to tear them down too.
#
# Requires az cli (`az login`) as a user with Contributor (or better) on the
# target subscription. Prompts for a typed confirmation before deleting
# anything - deleting a resource group deletes everything inside it,
# including Azure Firewall and Bastion, which are not cheap to leave running
# but also not something to delete by accident.
#
# Usage:
#   SUBSCRIPTION_ID=<sub-id> ./scripts/teardown-azure-resources.sh

set -uo pipefail

SUBSCRIPTION_ID="${SUBSCRIPTION_ID:?Set SUBSCRIPTION_ID to the target Azure subscription}"
RESOURCE_GROUPS=(
  "rg-securebicep-hub"
  "rg-securebicep-dev"
  "rg-securebicep-test"
  "rg-securebicep-prod"
)

az account set --subscription "$SUBSCRIPTION_ID"

echo "Checking which of these resource groups actually exist..."
existing=()
for rg in "${RESOURCE_GROUPS[@]}"; do
  if az group show --name "$rg" >/dev/null 2>&1; then
    existing+=("$rg")
    echo "  - $rg (exists)"
  else
    echo "  - $rg (not found, skipping)"
  fi
done

if [[ ${#existing[@]} -eq 0 ]]; then
  echo "Nothing to delete."
  exit 0
fi

echo
echo "This will PERMANENTLY DELETE these resource groups and everything in them"
echo "(including Azure Firewall and Bastion, if deployed - the expensive bits):"
for rg in "${existing[@]}"; do echo "  - $rg"; done
echo
read -r -p "Type DELETE to confirm: " confirm
if [[ "$confirm" != "DELETE" ]]; then
  echo "Aborted, nothing was deleted."
  exit 1
fi

for rg in "${existing[@]}"; do
  echo "Deleting $rg (not waiting for completion - deletion continues in the background)..."
  az group delete --name "$rg" --yes --no-wait
done

echo
echo "Delete requests submitted for: ${existing[*]}"
echo "Check progress with: az group list --query \"[?starts_with(name, 'rg-securebicep')].{name:name, state:properties.provisioningState}\" -o table"
