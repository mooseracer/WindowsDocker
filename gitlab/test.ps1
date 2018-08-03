#Start test container, try an HTTP GET, look for status 200
param($SERVICE_NAME, $IMAGE)

$testCommand = {Invoke-WebRequest -UseBasicParsing http://localhost | Select StatusCode}

docker run -d --name $SERVICE_NAME $IMAGE
start-sleep -s 20
$testResult = docker exec $SERVICE_NAME powershell.exe -Command $testCommand
docker rm $SERVICE_NAME -f

If ($testResult.StatusCode -eq "200") {Return 0}
Else {Return $testResult}