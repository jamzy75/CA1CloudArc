param(
    [string]$Location = "norwayeast",
    [string]$AdminUsername = "ca1admin"
)



# Check Az module and context
if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    Write-Error "Az PowerShell module not found. Install-Module Az and try again."
    exit 1
}

if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
    Write-Error "No Azure context found. Run Connect-AzAccount before running this script."
    exit 1
}

$rgName     = "ca1_rg"
$vmName     = "ca1-vm"
$vnetName   = "ca1-vnet"
$subnetName = "ca1-subnet"
$nsgName    = "ca1-nsg"
$pipName    = "ca1-pip"
$nicName    = "ca1-nic"

Write-Host "Using resource group: $rgName in $Location"

# 1. Resource group – create if missing
$rg = Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue
if (-not $rg) {
    Write-Host "Creating resource group $rgName..."
    $rg = New-AzResourceGroup -Name $rgName -Location $Location
} else {
    Write-Host "Resource group $rgName already exists. Reusing it."
}

# 2. If VM already exists, treat as already set up
$existingVm = Get-AzVM -ResourceGroupName $rgName -Name $vmName -ErrorAction SilentlyContinue
if ($existingVm) {
    Write-Host "VM $vmName already exists in $rgName. Setup is idempotent – nothing new to create."
    $publicIp = Get-AzPublicIpAddress -ResourceGroupName $rgName -Name $pipName -ErrorAction SilentlyContinue
    if ($publicIp) {
        Write-Host "Current public IP: $($publicIp.IpAddress)"
        Write-Host "SSH: ssh $AdminUsername@$($publicIp.IpAddress)"
        Write-Host "HTTP: http://$($publicIp.IpAddress):8080/"
    }
    exit 0
}

# 3. Prompt for VM admin password
$securePassword = Read-Host -Prompt "Enter password for VM local admin user '$AdminUsername'" -AsSecureString
$cred = New-Object System.Management.Automation.PSCredential ($AdminUsername, $securePassword)

# 4. Load cloud-init file
$cloudInitPath = Join-Path -Path (Get-Location) -ChildPath "vm_init.yml"
if (-not (Test-Path $cloudInitPath)) {
    Write-Error "Cloud-init file vm_init.yml not found in current directory. Run setup.ps1 from the repo root."
    exit 1
}

$cloudInitContent = Get-Content -Path $cloudInitPath -Raw
$cloudInitEncoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($cloudInitContent))

# 5. Networking – VNet + subnet
$vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $rgName -ErrorAction SilentlyContinue
if (-not $vnet) {
    Write-Host "Creating VNet $vnetName and subnet $subnetName..."
    $subnetConfig = New-AzVirtualNetworkSubnetConfig -Name $subnetName -AddressPrefix "10.0.1.0/24"
    $vnet = New-AzVirtualNetwork -Name $vnetName `
        -ResourceGroupName $rgName `
        -Location $Location `
        -AddressPrefix "10.0.0.0/16" `
        -Subnet $subnetConfig
} else {
    Write-Host "VNet $vnetName already exists."
    # Ensure the subnet exists inside the VNet (repair partial setup)
    $subnet = $vnet.Subnets | Where-Object { $_.Name -eq $subnetName }
    if (-not $subnet) {
        Write-Host "Subnet $subnetName missing, creating it in existing VNet..."
        $vnet | Add-AzVirtualNetworkSubnetConfig -Name $subnetName -AddressPrefix "10.0.1.0/24" | Set-AzVirtualNetwork
        $vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $rgName
    }
}

$subnet = $vnet.Subnets | Where-Object { $_.Name -eq $subnetName }

# 6. NSG with SSH and Tomcat (8080) rules
$nsg = Get-AzNetworkSecurityGroup -Name $nsgName -ResourceGroupName $rgName -ErrorAction SilentlyContinue
if (-not $nsg) {
    Write-Host "Creating NSG $nsgName..."
    $nsg = New-AzNetworkSecurityGroup -Name $nsgName -ResourceGroupName $rgName -Location $Location

    $nsg | Add-AzNetworkSecurityRuleConfig `
        -Name "Allow-SSH" `
        -Protocol Tcp `
        -Direction Inbound `
        -Priority 1000 `
        -SourceAddressPrefix "*" `
        -SourcePortRange "*" `
        -DestinationAddressPrefix "*" `
        -DestinationPortRange 22 `
        -Access Allow | Set-AzNetworkSecurityGroup

    $nsg | Add-AzNetworkSecurityRuleConfig `
        -Name "Allow-Tomcat-8080" `
        -Protocol Tcp `
        -Direction Inbound `
        -Priority 1010 `
        -SourceAddressPrefix "*" `
        -SourcePortRange "*" `
        -DestinationAddressPrefix "*" `
        -DestinationPortRange 8080 `
        -Access Allow | Set-AzNetworkSecurityGroup
} else {
    Write-Host "NSG $nsgName already exists."
}

# 7. Public IP
$publicIp = Get-AzPublicIpAddress -Name $pipName -ResourceGroupName $rgName -ErrorAction SilentlyContinue
if (-not $publicIp) {
    Write-Host "Creating public IP $pipName (Standard SKU)..."
    $publicIp = New-AzPublicIpAddress `
        -Name $pipName `
        -ResourceGroupName $rgName `
        -Location $Location `
        -AllocationMethod Static `
        -Sku Standard
} else {
    Write-Host "Public IP $pipName already exists."
}


# 8. NIC
$nic = Get-AzNetworkInterface -Name $nicName -ResourceGroupName $rgName -ErrorAction SilentlyContinue
if (-not $nic) {
    Write-Host "Creating NIC $nicName..."
    $nic = New-AzNetworkInterface `
        -Name $nicName `
        -ResourceGroupName $rgName `
        -Location $Location `
        -SubnetId $subnet.Id `
        -NetworkSecurityGroupId $nsg.Id `
        -PublicIpAddressId $publicIp.Id
} else {
    Write-Host "NIC $nicName already exists."
}

# 9. VM with Ubuntu and cloud-init
Write-Host "Creating VM $vmName with Ubuntu 22.04 and cloud-init..."

$vmConfig = New-AzVMConfig -VMName $vmName -VMSize "Standard_B1s" |
    Set-AzVMOperatingSystem -Linux -ComputerName $vmName -Credential $cred |
    Set-AzVMSourceImage -PublisherName "Canonical" -Offer "0001-com-ubuntu-server-jammy" -Skus "22_04-lts-gen2" -Version "latest" |
    Add-AzVMNetworkInterface -Id $nic.Id

# Attach cloud-init
$vmConfig.OSProfile.CustomData = $cloudInitEncoded

New-AzVM -ResourceGroupName $rgName -Location $Location -VM $vmConfig

$publicIp = Get-AzPublicIpAddress -ResourceGroupName $rgName -Name $pipName
Write-Host "VM created. Public IP: $($publicIp.IpAddress)"
Write-Host "SSH: ssh $AdminUsername@$($publicIp.IpAddress)"
Write-Host "HTTP: http://$($publicIp.IpAddress):8080/"
