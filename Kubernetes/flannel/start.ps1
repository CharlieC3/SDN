﻿Param(
    [parameter(Mandatory = $true)] $ManagementIP,
    [ValidateSet("l2bridge", "overlay",IgnoreCase = $true)] [parameter(Mandatory = $false)] $NetworkMode="l2bridge",
    [parameter(Mandatory = $false)] $ClusterCIDR="10.244.0.0/16",
    [parameter(Mandatory = $false)] $KubeDnsServiceIP="10.96.0.10",
    [parameter(Mandatory = $false)] $ServiceCIDR="10.96.0.0/12",
    [parameter(Mandatory = $false)] $InterfaceName="Ethernet",
    [parameter(Mandatory = $false)] $LogDir = "C:\k"
)

$BaseDir = "c:\k"
$NetworkMode = $NetworkMode.ToLower()
$NetworkName = "cbr0"

if ($NetworkMode -eq "overlay")
{
    $NetworkName = "vxlan0"
}

# Use helpers to setup binaries, conf files etc.
$helper = "c:\k\helper.psm1"
if (!(Test-Path $helper))
{
    Start-BitsTransfer https://raw.githubusercontent.com/Microsoft/SDN/master/Kubernetes/windows/helper.psm1 -Destination c:\k\helper.psm1
}
ipmo $helper

$install = "c:\k\install.ps1"
if (!(Test-Path $install))
{
    Start-BitsTransfer https://raw.githubusercontent.com/Microsoft/SDN/master/Kubernetes/windows/install.ps1 -Destination c:\k\install.ps1
}

# Download files, move them, & prepare network
powershell $install -NetworkMode $NetworkMode -clusterCIDR $ClusterCIDR -KubeDnsServiceIP $KubeDnsServiceIP -serviceCIDR $ServiceCIDR -InterfaceName $InterfaceName -LogDir $LogDir

# Register node
powershell $BaseDir\start-kubelet.ps1 -RegisterOnly -NetworkMode $NetworkMode
ipmo C:\k\hns.psm1

# Start Infra services
# Start Flanneld
StartFlanneld -ipaddress $ManagementIP -NetworkName $NetworkName
Start-Sleep 1
if ($NetworkMode -eq "overlay")
{
    GetSourceVip -ipAddress $ManagementIP -NetworkName $NetworkName
}

# Start kubelet
Start powershell -ArgumentList "-File $BaseDir\start-kubelet.ps1 -NetworkMode $NetworkMode -KubeDnsServiceIP $KubeDnsServiceIP -LogDir $LogDir"
Start-Sleep 10

# Start kube-proxy
start powershell -ArgumentList " -File $BaseDir\start-kubeproxy.ps1 -NetworkMode $NetworkMode -clusterCIDR $ClusterCIDR -NetworkName $NetworkName -LogDir $LogDir"