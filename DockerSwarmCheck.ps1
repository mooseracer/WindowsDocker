#PRTG Custom EXE Script Sensor. Parses the results of 'docker node ls' into XML. Run it against the Docker host.
$ComputerName = "$($args[0])"

#Return results of 'docker node ls' as an object
Function parseNodes {
    param($nodes)

    $result = [PSCustomObject]@()

    For ($i = 1; $i -lt $nodes.Length; $i++) {
        $line = $nodes[$i] -replace "\*",""
        $line = $line -split "\s+"
        $properties = @{
            'ID' = $line[0]
            'HOSTNAME' = $line[1]
            'STATUS' = $line[2]
            'AVAILABILITY' = $line[3]
           'MANAGERSTATUS' = $line[4]
        }
        $nodeObj = New-Object -TypeName PSObject -Property $properties
        $result += $nodeObj
    }

    return $result
}


$status = -1
$Managerstatus = -1
$Availability = -1

$nodes = Invoke-Command -ComputerName $ComputerName -ScriptBlock {& docker node ls} -ErrorAction SilentlyContinue
If ($nodes) {
    $swarmStatus = parseNodes $nodes
    $swarmStatus = $swarmStatus | ? {$_.HOSTNAME -like "*$ComputerName*"}
    If ($swarmStatus.Status -eq 'Ready') {$status = 1}
    Else {$status = 0}

    If ($swarmStatus.Managerstatus -eq 'Unreachable') {$Mangerstatus = 0}
    Else {$Managerstatus = 1}

    If ($swarmStatus.Availability -eq 'Active') {$Availability = 1}
    Else {$Availability = 0}

$xmlOutput = @"
<prtg>
  <result>
    <channel>STATUS</channel>
    <value>$status</value>
    <float>0</float>
    <unit>#</unit>
  </result>
  <result>
    <channel>MANAGERSTATUS</channel>
    <value>$Managerstatus</value>
    <float>0</float>
    <unit>#</unit>
  </result>
  <result>
    <channel>AVAILABILITY</channel>
    <value>$Availability</value>
    <float>0</float>
    <unit>#</unit>
  </result>
</prtg>
"@
}
Else {Write-Host "<prtg><error>1</error><text>Node disconnected from swarm</text></prtg>"}

Write-Host $xmlOutput #Return
Exit 0