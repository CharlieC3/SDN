Param(
[parameter(Mandatory = $false)] $LogDir = "C:\k",
$NetworkName = "l2bridge"
)

$networkName = $NetworkName.ToLower()
ipmo c:\k\hns.psm1
ipmo c:\k\helper.psm1

$hostName=$(Get-HostName)

Get-HnsPolicyList | Remove-HnsPolicyList

c:\k\kube-proxy.exe --v=4 --proxy-mode=kernelspace --feature-gates="WinDSR=false" --hostname-override=$hostName --kubeconfig=c:\k\config --network-name=$networkName --enable-dsr=false --log-dir=$LogDir --logtostderr=false