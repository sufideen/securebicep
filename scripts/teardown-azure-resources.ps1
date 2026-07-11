<#
.SYNOPSIS
  Deletes the billable Azure resource groups created by this repo's
  pipelines, so you can start clean and redeploy later via the pipeline
  YAML files. Does NOT touch the Azure DevOps project, service connection,
  app registration/federated credential, or Environments - those are cheap
  to keep and re-running scripts/setup-azure-devops.ps1 later would just
  recreate them anyway, so there's no need to tear them down too.

.NOTES
  Requires az cli (`az login`) as a user with Contributor (or better) on the
  target subscription. Prompts for a typed confirmation before deleting
  anything - deleting a resource group deletes everything inside it,
  including Azure Firewall and Bastion, which are not cheap to leave running
  but also not something to delete by accident.

.EXAMPLE
  ./scripts/teardown-azure-resources.ps1 -SubscriptionId <sub-id>
#>

param(
    [Parameter(Mandatory = $true)][string]$SubscriptionId,
    [string[]]$ResourceGroups = @(
        "rg-securebicep-hub",
        "rg-securebicep-dev",
        "rg-securebicep-test",
        "rg-securebicep-prod"
    )
)

az account set --subscription $SubscriptionId

Write-Host "Checking which of these resource groups actually exist..."
$existing = @()
foreach ($rg in $ResourceGroups) {
    az group show --name $rg *>$null
    if ($LASTEXITCODE -eq 0) {
        $existing += $rg
        Write-Host "  - $rg (exists)"
    } else {
        Write-Host "  - $rg (not found, skipping)"
    }
}

if ($existing.Count -eq 0) {
    Write-Host "Nothing to delete."
    exit 0
}

Write-Host ""
Write-Host "This will PERMANENTLY DELETE these resource groups and everything in them"
Write-Host "(including Azure Firewall and Bastion, if deployed - the expensive bits):"
$existing | ForEach-Object { Write-Host "  - $_" }
Write-Host ""
$confirm = Read-Host "Type DELETE to confirm"
if ($confirm -ne "DELETE") {
    Write-Host "Aborted, nothing was deleted."
    exit 1
}

foreach ($rg in $existing) {
    Write-Host "Deleting $rg (not waiting for completion - deletion continues in the background)..."
    az group delete --name $rg --yes --no-wait
}

Write-Host ""
Write-Host "Delete requests submitted for: $($existing -join ', ')"
Write-Host "Check progress with: az group list --query `"[?starts_with(name, 'rg-securebicep')].{name:name, state:properties.provisioningState}`" -o table"
