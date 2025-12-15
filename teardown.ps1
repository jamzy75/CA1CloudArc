
<#
  teardown.ps1
  Deletes the ca1_rg resource group and all resources it contains.
  Provides a clean teardown step for the Cloud Architecture CA1 environment.
#>



param(
    # Kept for consistency with setup.ps1, not actually used
    [string]$Location = "norwayeast"
)

# This is to ensure Az module and context are available
if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    Write-Error "Az PowerShell module not found. Install-Module Az and try again."
    exit 1
}

if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
    Write-Error "No Azure context found. Run Connect-AzAccount before running this script."
    exit 1
}

$rgName = "ca1_rg"

# Check if the resource group exists
$rg = Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue
if (-not $rg) {
    Write-Host "Resource group $rgName does not exist. Nothing to tear down."
    exit 0
}

Write-Host "Deleting resource group $rgName and all resources in it..."
Write-Host "This operation may take some time to complete."

# Delete the resource group
Remove-AzResourceGroup -Name $rgName -Force -ErrorAction Stop

Write-Host "Teardown completed. Resource group $rgName has been deleted."
