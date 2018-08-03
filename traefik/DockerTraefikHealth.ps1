##PRTG Custom EXE Script Sensor. PRTG probe needs access to the Docker hosts on ports 80, 8080, 2375.
#Also requires functional WinRM from PRTG.
#Have every traefik container try to ping every backend IP, track any failures, and parse them into XML for PRTG.

#User variables
$DockerHosts = @('host1','host2','host3')
$traefikURL = 'apps.local:8080'


#Query the Docker API for all containers named traefik and keep track of which host they're on
$traefiks = @()
Foreach ($DockerHost in $DockerHosts) {
    $Containers = Invoke-RestMethod "http://$DockerHost`:2375/containers/json"
    #$traefikID = $Containers | ? {$_.Names -like "*traefik"} | % {$_.networksettings.networks.'traefik-net'.ipaddress}
    $traefikIDs = $Containers | ? {$_.Names -like "*traefik"} | Select -ExpandProperty Id
    Foreach ($traefikID in $traefikIDs) {
        $traefiks += [PSCustomObject]@{
            "DockerHost" = $DockerHost
            "ContainerID" = $traefikID
        }
    }
}

#Query the Traefik API's docker provider, capture all backend URLs
#the dynamic object names make this annoying
$backendURLs = @()
$traefikDockerProvider = Invoke-RestMethod "http://$traefikURL/api/providers/docker"
$backendNames = $traefikDockerProvider.backends | Get-Member | ? {$_.MemberType -eq 'NoteProperty'} | Select -ExpandProperty Name
Foreach ($backendName in $backendNames) {
    $backend = $traefikDockerProvider.backends."$backendName"
    $serverIDs = $backend.servers | Get-Member | ? {$_.MemberType -eq 'NoteProperty'} | Select -ExpandProperty Name
    Foreach ($serverID in $serverIDs) {
        $backendURLs += $traefikDockerProvider.backends."$backendName".servers."$serverID".url
    }
}
#Convert URLs to IPs ("http://10.0.0.100:80" to "10.0.0.100")
$backendIPs = @()
Foreach ($URL in $backendURLs) {
    $URL -match ':\/\/(.*):' | % { If ($matches) {$backendIPs += $matches[1]}}
}

#Have every traefik container try to ping every backend IP, track any failures
$results = @()
"DockerHost Source:TraefikContainerID                                        Dest:BackendIP Pingable"
Foreach ($traefik in $traefiks) {
    $cmd = {
        param($ContainerID,$backendIP)
        $ping = docker exec $ContainerID ping -4 -n 2 $backendIP 2>&1
        If ($ping | Select-String "reply from $backendIP") {Return $true}
        Else {Return $false}
    }
    Foreach ($backendIP in $backendIPs) {        
        $result = Invoke-Command -ComputerName $traefik.DockerHost -ScriptBlock $cmd -ArgumentList $traefik.ContainerID,$backendIP
        "$($traefik.DockerHost) $($traefik.ContainerID) $backendIP $result"
        $results += [PSCustomObject]@{
            "DockerHost" = $traefik.DockerHost
            "BackendIP" = $backendIP
            "Ping" = $result
        }
    }
}

$endpointCount = ($results | Select BackendIP -Unique).Count
$failCounts = @()
Foreach ($DockerHost in $DockerHosts) {
    $failCounts += ($results | ? {$_.DockerHost -eq $DockerHost -and $_.Ping -eq $false}).Count
}

#Compile into an XML report for PRTG
$xmlOutput = @"
<prtg>
  <result>
    <channel>Total Endpoint Count</channel>
    <value>$endpointCount</value>
    <float>0</float>
    <unit>#</unit>
  </result>
  <result>
    <channel>$($DockerHosts[0]) Fail Count</channel>
    <value>$($failCounts[0])</value>
    <float>0</float>
    <unit>#</unit>
  </result>
  <result>
    <channel>$($DockerHosts[1]) Fail Count</channel>
    <value>$($failCounts[1])</value>
    <float>0</float>
    <unit>#</unit>
  </result>
  <result>
    <channel>$($DockerHosts[2]) Fail Count</channel>
    <value>$($failCounts[2])</value>
    <float>0</float>
    <unit>#</unit>
  </result>
</prtg>
"@

Write-Host $xmlOutput
Exit 0