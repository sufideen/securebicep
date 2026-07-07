<#
.SYNOPSIS
  Provisions the Azure DevOps project, pipeline, workload-identity-federation
  service connection, and dev/prod Environments described in the pipeline
  setup guide - using `az` + the `azure-devops` CLI extension instead of the
  portal. Safe to re-run: every step checks for an existing object first.

  Two things this script cannot do for you, because they require an
  interactive consent flow with no API equivalent:
    1. Authorizing the "Azure Pipelines" GitHub App for this repo.
    2. Choosing who approves deployments to the `prod` Environment.
  The script pauses at each and tells you exactly where to click.

.NOTES
  Prerequisites: az cli (`az login`) as a user with permission to create
  Azure DevOps projects/pipelines in the org, and Owner or User Access
  Administrator on the target subscription (needed to grant the app
  registration Contributor). No jq/bash required - pure PowerShell + az.

.EXAMPLE
  ./scripts/setup-azure-devops.ps1 `
    -OrgUrl https://dev.azure.com/<org> `
    -ProjectName securebicep `
    -GitHubRepo <owner>/securebicep `
    -SubscriptionId <sub-id>
#>

param(
    [Parameter(Mandatory = $true)][string]$OrgUrl,
    [string]$ProjectName = "securebicep",
    [Parameter(Mandatory = $true)][string]$GitHubRepo,
    [Parameter(Mandatory = $true)][string]$SubscriptionId,
    [string]$ServiceConnectionName = "securebicep-service-connection",
    [string]$FederatedAppName = "$ServiceConnectionName-wif",
    [string]$PipelineName = $ProjectName,
    [string]$YmlPath = "azure-pipelines.yml"
)

$ErrorActionPreference = "Stop"
$Environments = @("dev", "prod")
$DevOpsResourceId = "499b84ac-1321-427f-aa17-267ca6975798" # fixed AAD resource id for dev.azure.com

function Get-TempJsonFile($Object) {
    $path = [System.IO.Path]::GetTempFileName()
    $Object | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding utf8
    return $path
}

az extension show --name azure-devops *>$null
if ($LASTEXITCODE -ne 0) { az extension add --name azure-devops }
az devops configure --defaults organization=$OrgUrl project=$ProjectName | Out-Null

$SubscriptionName = (az account show --subscription $SubscriptionId --query name -o tsv)
$TenantId = (az account show --subscription $SubscriptionId --query tenantId -o tsv)

Write-Host "== 1. Azure DevOps project =="
az devops project show --project $ProjectName *>$null
if ($LASTEXITCODE -ne 0) {
    az devops project create --name $ProjectName --organization $OrgUrl --visibility private
} else {
    Write-Host "Project '$ProjectName' already exists, skipping."
}
$ProjectId = (az devops project show --project $ProjectName --query id -o tsv)

Write-Host ""
Write-Host "== 2. GitHub App authorization (manual) =="
Write-Host "Open $OrgUrl/$ProjectName/_settings/boards-external-integration (or Pipelines > New pipeline > GitHub)"
Write-Host "and grant the 'Azure Pipelines' GitHub App access to $GitHubRepo if you haven't already."
Read-Host "Press Enter once the GitHub App is authorized for $GitHubRepo"

Write-Host ""
Write-Host "== 3. Pipeline pointing at $YmlPath =="
if (-not (Test-Path $YmlPath)) {
    Write-Host "No $YmlPath at repo root yet - skipping pipeline creation. Re-run once it exists."
} else {
    az pipelines show --name $PipelineName *>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Pipeline '$PipelineName' already exists, skipping."
    } else {
        az pipelines create `
            --name $PipelineName `
            --repository "https://github.com/$GitHubRepo" `
            --repository-type github `
            --branch main `
            --yml-path $YmlPath `
            --skip-first-run
    }
}

Write-Host ""
Write-Host "== 4. Workload identity federation app registration =="
$AppId = (az ad app list --display-name $FederatedAppName --query "[0].appId" -o tsv)
if ([string]::IsNullOrWhiteSpace($AppId)) {
    $appJson = az ad app create --display-name $FederatedAppName | ConvertFrom-Json
    $AppId = $appJson.appId
    $AppObjectId = $appJson.id
    az ad sp create --id $AppId | Out-Null
} else {
    Write-Host "App '$FederatedAppName' already exists ($AppId), reusing."
    $AppObjectId = (az ad app show --id $AppId --query id -o tsv)
    az ad sp show --id $AppId *>$null
    if ($LASTEXITCODE -ne 0) { az ad sp create --id $AppId | Out-Null }
}

Write-Host "== 5. Contributor role assignment on subscription =="
$existingAssignment = az role assignment list --assignee $AppId --scope "/subscriptions/$SubscriptionId" --role Contributor -o tsv
if ([string]::IsNullOrWhiteSpace($existingAssignment)) {
    az role assignment create --assignee $AppId --role Contributor --scope "/subscriptions/$SubscriptionId" | Out-Null
} else {
    Write-Host "Contributor assignment already present, skipping."
}

Write-Host ""
Write-Host "== 6. Azure DevOps service connection (Workload Identity Federation) =="
$existingEndpointId = az devops service-endpoint list --query "[?name=='$ServiceConnectionName'].id" -o tsv
if ([string]::IsNullOrWhiteSpace($existingEndpointId)) {
    $endpointBody = @{
        name          = $ServiceConnectionName
        type          = "azurerm"
        url           = "https://management.azure.com/"
        authorization = @{
            scheme     = "WorkloadIdentityFederation"
            parameters = @{
                tenantid         = $TenantId
                serviceprincipalid = $AppId
            }
        }
        data = @{
            subscriptionId   = $SubscriptionId
            subscriptionName = $SubscriptionName
            environment      = "AzureCloud"
            scopeLevel       = "Subscription"
            creationMode     = "Manual"
        }
        isShared    = $false
        isReady     = $true
        serviceEndpointProjectReferences = @(
            @{
                projectReference = @{ id = $ProjectId; name = $ProjectName }
                name              = $ServiceConnectionName
            }
        )
    }
    $endpointBodyFile = Get-TempJsonFile $endpointBody
    $endpointJson = az rest --method post `
        --uri "$OrgUrl/$ProjectName/_apis/serviceendpoint/endpoints?api-version=7.1-preview.4" `
        --resource $DevOpsResourceId `
        --body "@$endpointBodyFile" | ConvertFrom-Json
    Remove-Item $endpointBodyFile

    $endpointId = $endpointJson.id
    $issuer = $endpointJson.authorization.parameters.workloadIdentityFederationIssuer
    $subject = $endpointJson.authorization.parameters.workloadIdentityFederationSubject

    Write-Host "Registering federated credential on the app registration..."
    $fedCredBody = @{
        name      = $ServiceConnectionName
        issuer    = $issuer
        subject   = $subject
        audiences = @("api://AzureADTokenExchange")
    }
    $fedCredBodyFile = Get-TempJsonFile $fedCredBody
    az ad app federated-credential create --id $AppObjectId --parameters "@$fedCredBodyFile" | Out-Null
    Remove-Item $fedCredBodyFile

    Write-Host "Authorizing the connection for all pipelines..."
    $permBody = @{
        allPipelines = @{ authorized = $true }
        resource     = @{ type = "endpoint"; id = $endpointId }
    }
    $permBodyFile = Get-TempJsonFile $permBody
    az rest --method patch `
        --uri "$OrgUrl/$ProjectName/_apis/pipelines/pipelinePermissions/endpoint/$endpointId?api-version=7.1-preview.1" `
        --resource $DevOpsResourceId `
        --body "@$permBodyFile" | Out-Null
    Remove-Item $permBodyFile
} else {
    Write-Host "Service connection '$ServiceConnectionName' already exists ($existingEndpointId), skipping."
}

Write-Host ""
Write-Host "== 7. Environments =="
$existingEnvs = (az rest --method get `
    --uri "$OrgUrl/$ProjectName/_apis/pipelines/environments?api-version=7.1-preview.1" `
    --resource $DevOpsResourceId | ConvertFrom-Json).value.name

foreach ($env in $Environments) {
    if ($existingEnvs -contains $env) {
        Write-Host "Environment '$env' already exists, skipping."
    } else {
        $envBodyFile = Get-TempJsonFile @{ name = $env; description = "" }
        az rest --method post `
            --uri "$OrgUrl/$ProjectName/_apis/pipelines/environments?api-version=7.1-preview.1" `
            --resource $DevOpsResourceId `
            --body "@$envBodyFile" | Out-Null
        Remove-Item $envBodyFile
        Write-Host "Created environment '$env'."
    }
}

Write-Host ""
Write-Host "== 8. Prod approvals (manual) =="
Write-Host "Open $OrgUrl/$ProjectName/_environments and add an 'Approvals' check to 'prod'"
Write-Host "(Approvals > Approvals and checks > + > Approvals) with the required approvers."
Write-Host "This step needs a human decision, so it isn't scripted here."

Write-Host ""
Write-Host "Done. Service connection: $ServiceConnectionName (app $AppId, tenant $TenantId)"
