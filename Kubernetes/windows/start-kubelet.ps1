Param(
    $clusterCIDR="172.20.0.0/16",
    $NetworkMode = "L2Bridge",
    $NetworkName = "l2bridge",
    [ValidateSet("process", "hyperv")]
    $IsolationType = "process"
)

$WorkingDir = "c:\k"
ipmo $WorkingDir\helper.psm1

# Todo : Get these values using kubectl
$KubeDnsSuffix ="svc.cluster.local"
$KubeDnsServiceIp="172.20.0.10"
$serviceCIDR="172.20.0.0/16"
$hostName=$(Get-HostName)
$CNIPath = [Io.path]::Combine($WorkingDir , "cni")
$CNIConfig = [Io.path]::Combine($CNIPath, "config", "$NetworkMode.conf")

$endpointName = "cbr0"
$vnicName = "vEthernet ($endpointName)"


function
Update-CNIConfig($podCIDR)
{
    $jsonSampleConfig = '{
  "cniVersion": "0.2.0",
  "name": "<NetworkMode>",
  "type": "wincni.exe",
  "master": "Ethernet",
  "capabilities": { "portMappings": true },
  "ipam": {
     "environment": "azure",
     "subnet":"<PODCIDR>",
     "routes": [{
        "GW":"<PODGW>"
     }]
  },
  "dns" : {
    "Nameservers" : [ "172.20.0.10" ],
    "Search": [ "svc.cluster.local" ]
  },
  "AdditionalArgs" : [
    {
      "Name" : "EndpointPolicy", "Value" : { "Type" : "OutBoundNAT", "ExceptionList": [ "<ClusterCIDR>", "<ServerCIDR>", "<MgmtSubnet>" ] }
    },
    {
      "Name" : "EndpointPolicy", "Value" : { "Type" : "ROUTE", "DestinationPrefix": "<ServerCIDR>", "NeedEncap" : true }
    },
    {
      "Name" : "EndpointPolicy", "Value" : { "Type" : "ROUTE", "DestinationPrefix": "<MgmtIP>/32", "NeedEncap" : true }
    }
  ]
}'
    #Add-Content -Path $CNIConfig -Value $jsonSampleConfig

    $configJson =  ConvertFrom-Json $jsonSampleConfig
    $configJson.name = $NetworkMode.ToLower()
    $configJson.ipam.subnet=$podCIDR
    $configJson.ipam.routes[0].GW = Get-PodEndpointGateway $podCIDR
    $configJson.dns.Nameservers[0] = $KubeDnsServiceIp
    $configJson.dns.Search[0] = $KubeDnsSuffix

    $configJson.AdditionalArgs[0].Value.ExceptionList[0] = $clusterCIDR
    $configJson.AdditionalArgs[0].Value.ExceptionList[1] = $serviceCIDR
    $configJson.AdditionalArgs[0].Value.ExceptionList[2] = Get-MgmtSubnet

    $configJson.AdditionalArgs[1].Value.DestinationPrefix  = $serviceCIDR
    $configJson.AdditionalArgs[2].Value.DestinationPrefix  = "$(Get-MgmtIpAddress)/32"

    if (Test-Path $CNIConfig) {
        Clear-Content -Path $CNIConfig
    }

    Write-Host "Generated CNI Config [$configJson]"

    Add-Content -Path $CNIConfig -Value (ConvertTo-Json $configJson -Depth 20)
}

function
Test-PodCIDR($podCIDR)
{
    return $podCIDR.length -gt 0
}

# Main

RegisterNode $false $hostName
$podCIDR = Get-PodCIDR $hostName

# startup the service
$podGW = Get-PodGateway $podCIDR
ipmo C:\k\hns.psm1

# Create a L2Bridge to trigger a vSwitch creation. Do this only once
if(!(Get-HnsNetwork | ? Name -EQ "External"))
{
    New-HNSNetwork -Type $NetworkMode -AddressPrefix "172.20.255.0/30" -Gateway "172.20.255.1" -Name "External" -Verbose
}

$hnsNetwork = Get-HnsNetwork | ? Name -EQ $NetworkName.ToLower()
if( !$hnsNetwork )
{
    $hnsNetwork = New-HNSNetwork -Type $NetworkMode -AddressPrefix $podCIDR -Gateway $podGW -Name $NetworkName.ToLower() -Verbose
}

$podEndpointGW = Get-PodEndpointGateway $podCIDR
$hnsEndpoint = Get-HnsEndpoint | ? Name -EQ $endpointName.ToLower()
if( !$hnsEndpoint )
{
    $hnsEndpoint = New-HnsEndpoint -NetworkId $hnsNetwork.Id -Name $endpointName -IPAddress $podEndpointGW -Gateway "0.0.0.0" -Verbose
}

Attach-HnsHostEndpoint -EndpointID $hnsEndpoint.Id -CompartmentID 1

netsh int ipv4 set int "$vnicName" for=en
#netsh int ipv4 set add "vEthernet (cbr0)" static $podGW 255.255.255.0
Update-CNIConfig $podCIDR

if ($IsolationType -ieq "process")
{
    c:\k\kubelet.exe --hostname-override=$hostName --v=6 `
        --pod-infra-container-image=kubeletwin/pause --resolv-conf="" `
        --allow-privileged=true --enable-debugging-handlers `
        --cluster-dns=$KubeDnsServiceIp --cluster-domain=cluster.local `
        --kubeconfig=c:\k\config --hairpin-mode=promiscuous-bridge `
        --image-pull-progress-deadline=20m --cgroups-per-qos=false `
        --log-dir=c:\k --logtostderr=false --enforce-node-allocatable="" `
        --network-plugin=cni --cni-bin-dir="c:\k\cni" --cni-conf-dir "c:\k\cni\config"
}
elseif ($IsolationType -ieq "hyperv")
{
    c:\k\kubelet.exe --hostname-override=$hostName --v=6 `
        --pod-infra-container-image=kubeletwin/pause --resolv-conf="" `
        --allow-privileged=true --enable-debugging-handlers `
        --cluster-dns=$KubeDnsServiceIp --cluster-domain=cluster.local `
        --kubeconfig=c:\k\config --hairpin-mode=promiscuous-bridge `
        --image-pull-progress-deadline=20m --cgroups-per-qos=false `
        --feature-gates=HyperVContainer=true --enforce-node-allocatable="" `
        --log-dir=c:\k --logtostderr=false `
        --network-plugin=cni --cni-bin-dir="c:\k\cni" --cni-conf-dir "c:\k\cni\config"
}
