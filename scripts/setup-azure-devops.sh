#!/usr/bin/env bash
# Provisions the Azure DevOps project, pipeline, workload-identity-federation
# service connection, and dev/prod Environments described in the pipeline
# setup guide - using `az` + the `azure-devops` CLI extension instead of the
# portal. Safe to re-run: every step checks for an existing object first.
#
# Two things this script cannot do for you, because they require an
# interactive consent flow with no API equivalent:
#   1. Authorizing the "Azure Pipelines" GitHub App for this repo.
#   2. Choosing who approves deployments to the `prod` Environment.
# The script pauses at each and tells you exactly where to click.
#
# Prerequisites:
#   - az cli, logged in (`az login`) as a user with:
#       * permission to create Azure DevOps projects/pipelines in the org
#       * Owner or User Access Administrator on the target subscription
#         (needed to grant the app registration Contributor)
#   - jq
#
# Usage:
#   ORG_URL=https://dev.azure.com/<org> \
#   PROJECT_NAME=securebicep \
#   GITHUB_REPO=<owner>/securebicep \
#   SUBSCRIPTION_ID=<sub-id> \
#   ./scripts/setup-azure-devops.sh

set -euo pipefail

# ---- Configuration ---------------------------------------------------------
ORG_URL="${ORG_URL:?Set ORG_URL, e.g. https://dev.azure.com/your-org}"
PROJECT_NAME="${PROJECT_NAME:-securebicep}"
GITHUB_REPO="${GITHUB_REPO:?Set GITHUB_REPO as <owner>/securebicep}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:?Set SUBSCRIPTION_ID to the target Azure subscription}"
SERVICE_CONNECTION_NAME="${SERVICE_CONNECTION_NAME:-securebicep-service-connection}"
FEDERATED_APP_NAME="${FEDERATED_APP_NAME:-${SERVICE_CONNECTION_NAME}-wif}"
PIPELINE_NAME="${PIPELINE_NAME:-${PROJECT_NAME}}"
YML_PATH="${YML_PATH:-azure-pipelines.yml}"
ENVIRONMENTS=(dev prod)
DEVOPS_RESOURCE_ID="499b84ac-1321-427f-aa17-267ca6975798" # fixed AAD resource id for dev.azure.com

command -v jq >/dev/null || { echo "jq is required"; exit 1; }
az extension show --name azure-devops >/dev/null 2>&1 || az extension add --name azure-devops
az devops configure --defaults organization="$ORG_URL" project="$PROJECT_NAME"

SUBSCRIPTION_NAME="$(az account show --subscription "$SUBSCRIPTION_ID" --query name -o tsv)"
TENANT_ID="$(az account show --subscription "$SUBSCRIPTION_ID" --query tenantId -o tsv)"

echo "== 1. Azure DevOps project =="
if ! az devops project show --project "$PROJECT_NAME" >/dev/null 2>&1; then
  az devops project create --name "$PROJECT_NAME" --organization "$ORG_URL" --visibility private
else
  echo "Project '$PROJECT_NAME' already exists, skipping."
fi
PROJECT_ID="$(az devops project show --project "$PROJECT_NAME" --query id -o tsv)"

echo
echo "== 2. GitHub App authorization (manual) =="
echo "Open ${ORG_URL}/${PROJECT_NAME}/_settings/boards-external-integration (or Pipelines > New pipeline > GitHub)"
echo "and grant the 'Azure Pipelines' GitHub App access to ${GITHUB_REPO} if you haven't already."
read -r -p "Press Enter once the GitHub App is authorized for ${GITHUB_REPO}... " _

echo
echo "== 3. Pipeline pointing at ${YML_PATH} =="
if [[ ! -f "$YML_PATH" ]]; then
  echo "No ${YML_PATH} at repo root yet - skipping pipeline creation. Re-run once it exists."
elif az pipelines show --name "$PIPELINE_NAME" >/dev/null 2>&1; then
  echo "Pipeline '$PIPELINE_NAME' already exists, skipping."
else
  az pipelines create \
    --name "$PIPELINE_NAME" \
    --repository "https://github.com/${GITHUB_REPO}" \
    --repository-type github \
    --branch main \
    --yml-path "$YML_PATH" \
    --skip-first-run
fi

echo
echo "== 4. Workload identity federation app registration =="
APP_ID="$(az ad app list --display-name "$FEDERATED_APP_NAME" --query "[0].appId" -o tsv)"
if [[ -z "$APP_ID" ]]; then
  APP_JSON="$(az ad app create --display-name "$FEDERATED_APP_NAME")"
  APP_ID="$(echo "$APP_JSON" | jq -r .appId)"
  APP_OBJECT_ID="$(echo "$APP_JSON" | jq -r .id)"
  az ad sp create --id "$APP_ID" >/dev/null
else
  echo "App '$FEDERATED_APP_NAME' already exists ($APP_ID), reusing."
  APP_OBJECT_ID="$(az ad app show --id "$APP_ID" --query id -o tsv)"
  az ad sp show --id "$APP_ID" >/dev/null 2>&1 || az ad sp create --id "$APP_ID" >/dev/null
fi

echo "== 5. Contributor role assignment on subscription =="
if ! az role assignment list --assignee "$APP_ID" --scope "/subscriptions/${SUBSCRIPTION_ID}" --role Contributor --query "[0]" -o tsv >/dev/null 2>&1 \
   || [[ -z "$(az role assignment list --assignee "$APP_ID" --scope "/subscriptions/${SUBSCRIPTION_ID}" --role Contributor -o tsv)" ]]; then
  az role assignment create \
    --assignee "$APP_ID" \
    --role Contributor \
    --scope "/subscriptions/${SUBSCRIPTION_ID}" >/dev/null
else
  echo "Contributor assignment already present, skipping."
fi

echo
echo "== 6. Azure DevOps service connection (Workload Identity Federation) =="
EXISTING_ENDPOINT_ID="$(az devops service-endpoint list --query "[?name=='${SERVICE_CONNECTION_NAME}'].id" -o tsv)"
if [[ -z "$EXISTING_ENDPOINT_ID" ]]; then
  ENDPOINT_BODY="$(cat <<JSON
{
  "name": "${SERVICE_CONNECTION_NAME}",
  "type": "azurerm",
  "url": "https://management.azure.com/",
  "authorization": {
    "scheme": "WorkloadIdentityFederation",
    "parameters": {
      "tenantid": "${TENANT_ID}",
      "serviceprincipalid": "${APP_ID}"
    }
  },
  "data": {
    "subscriptionId": "${SUBSCRIPTION_ID}",
    "subscriptionName": "${SUBSCRIPTION_NAME}",
    "environment": "AzureCloud",
    "scopeLevel": "Subscription",
    "creationMode": "Manual"
  },
  "isShared": false,
  "isReady": true,
  "serviceEndpointProjectReferences": [
    {
      "projectReference": { "id": "${PROJECT_ID}", "name": "${PROJECT_NAME}" },
      "name": "${SERVICE_CONNECTION_NAME}"
    }
  ]
}
JSON
)"
  ENDPOINT_JSON="$(az rest --method post \
    --uri "${ORG_URL}/${PROJECT_NAME}/_apis/serviceendpoint/endpoints?api-version=7.1-preview.4" \
    --resource "$DEVOPS_RESOURCE_ID" \
    --body "$ENDPOINT_BODY")"
  ENDPOINT_ID="$(echo "$ENDPOINT_JSON" | jq -r .id)"
  ISSUER="$(echo "$ENDPOINT_JSON" | jq -r .authorization.parameters.workloadIdentityFederationIssuer)"
  SUBJECT="$(echo "$ENDPOINT_JSON" | jq -r .authorization.parameters.workloadIdentityFederationSubject)"

  echo "Registering federated credential on the app registration..."
  az ad app federated-credential create --id "$APP_OBJECT_ID" --parameters "$(cat <<JSON
{
  "name": "${SERVICE_CONNECTION_NAME}",
  "issuer": "${ISSUER}",
  "subject": "${SUBJECT}",
  "audiences": ["api://AzureADTokenExchange"]
}
JSON
)" >/dev/null

  echo "Authorizing the connection for all pipelines..."
  az rest --method patch \
    --uri "${ORG_URL}/${PROJECT_NAME}/_apis/pipelines/pipelinePermissions/endpoint/${ENDPOINT_ID}?api-version=7.1-preview.1" \
    --resource "$DEVOPS_RESOURCE_ID" \
    --body "{\"allPipelines\": {\"authorized\": true}, \"resource\": {\"type\": \"endpoint\", \"id\": \"${ENDPOINT_ID}\"}}" >/dev/null
else
  echo "Service connection '$SERVICE_CONNECTION_NAME' already exists (${EXISTING_ENDPOINT_ID}), skipping."
fi

echo
echo "== 7. Environments =="
EXISTING_ENVS="$(az rest --method get \
  --uri "${ORG_URL}/${PROJECT_NAME}/_apis/pipelines/environments?api-version=7.1-preview.1" \
  --resource "$DEVOPS_RESOURCE_ID" | jq -r '.value[].name')"
for env in "${ENVIRONMENTS[@]}"; do
  if echo "$EXISTING_ENVS" | grep -qx "$env"; then
    echo "Environment '$env' already exists, skipping."
  else
    az rest --method post \
      --uri "${ORG_URL}/${PROJECT_NAME}/_apis/pipelines/environments?api-version=7.1-preview.1" \
      --resource "$DEVOPS_RESOURCE_ID" \
      --body "{\"name\": \"${env}\", \"description\": \"\"}" >/dev/null
    echo "Created environment '$env'."
  fi
done

echo
echo "== 8. Prod approvals (manual) =="
echo "Open ${ORG_URL}/${PROJECT_NAME}/_environments and add an 'Approvals' check to 'prod'"
echo "(Approvals > Approvals and checks > + > Approvals) with the required approvers."
echo "This step needs a human decision, so it isn't scripted here."

echo
echo "Done. Service connection: ${SERVICE_CONNECTION_NAME} (app ${APP_ID}, tenant ${TENANT_ID})"
