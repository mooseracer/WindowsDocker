[DSCLocalConfigurationManager()]
configuration LCMConfig
{
    Node localhost
    {
        Settings
        {
            ConfigurationMode = 'ApplyAndAutoCorrect'
            RebootNodeIfNeeded = $true
        }
    }
}
LCMConfig
Set-DscLocalConfigurationManager LCMConfig -Verbose

Configuration DockerHost {
    param(
        [string[]]$ComputerName="localhost"
    )
    
    Import-DscResource -ModuleName PsDesiredStateConfiguration

    Node $ComputerName {
        #Source files: DockerEE zip, CredentialSpec.psm1, Git installer, GitLab-Runner
        $packageSource = '\\fileserver\share'

        #Configure Docker
        $daemonRootPath = 'C:\ProgramData\docker\config'
        $daemonFullPath = 'C:\ProgramData\docker\config\daemon.json'
        $dockerDataPath = 'D:\ProgramData\Docker'


        #Windows Features
        Script Hyper-V {
            SetScript = {
                Install-WindowsFeature "RSAT-AD-PowerShell"
                Install-WindowsFeature "RSAT-Hyper-V-Tools" -IncludeAllSubFeature -IncludeManagementTools
                Install-WindowsFeature "Hyper-V" -IncludeAllSubFeature -IncludeManagementTools
                Install-WindowsFeature -Name "Containers" -IncludeAllSubFeature -IncludeManagementTools
                Remove-WindowsFeature -Name "Windows-Defender"
                Get-NetFirewallProfile | Set-NetFirewallProfile -Enabled false
                $global:DSCMachineStatus = 1
            }
            TestScript = {
                If (((Get-WindowsFeature "Hyper-V").InstallState -eq "Installed") `
                    -and ((Get-WindowsFeature "RSAT-Hyper-V-Tools").InstallState -eq "Installed") `
                    -and ((Get-WindowsFeature "Containers").InstallState -eq "Installed") `
                    -and ((Get-WindowsFeature "Windows-Defender").InstallState -ne "Installed") `
                ) {$true}
                Else {$false}
            }
            GetScript = {@{Result =(Get-WindowsFeature "Hyper-V").InstallState}}
        }

        #Set environment variables for Docker
        Environment HTTP_PROXY {
            Name = 'HTTP_PROXY'
            Ensure = 'Present'
            Value = 'http://username:password@proxy.yourdomain.com:1234/'
        }
        Environment HTTPS_PROXY {
            Name = 'HTTPS_PROXY'
            Ensure = 'Present'
            Value = 'http://username:password@proxy.yourdomain.com:1234'
        }
        Environment NO_PROXY {
            Name = 'NO_PROXY'
            Ensure = 'Present'
            Value = 'yourdomain.com,10.0.100.1,10.0.100.2,10.0.100.3' #Domain, and IPs of all Docker Hosts
        }

        #Install Docker
        Script Docker {
            SetScript = {
                # Obtain the zip file.
                mkdir C:\Packages -Force
                del C:\Packages docker*.zip -Force -ErrorAction SilentlyContinue
                Robocopy.exe $using:PackageSource "C:\Packages" docker*
                
                # Extract the archive.
                dir C:\Packages docker*.zip | Expand-Archive -DestinationPath $Env:ProgramFiles -Force

                #Install the CredentialSpec PowerShell module (for integrated Windows Authentication in containers)
                Robocopy.exe $using:PackageSource "C:\Packages" *.psm1
                If (!(Test-Path "$Env:ProgramFiles\WindowsPowerShell\Modules\CredentialSpec")) {mkdir "$Env:ProgramFiles\WindowsPowerShell\Modules\CredentialSpec"}
                Copy-Item "C:\Packages\CredentialSpec.psm1" -Destination "$Env:ProgramFiles\WindowsPowerShell\Modules\CredentialSpec\CredentialSpec.psm1" -Force

                # Modify PATH to persist across sessions.
                If ([Environment]::GetEnvironmentVariable("PATH",[EnvironmentVariableTarget]::Machine) -notlike "*$env:ProgramFiles\docker*") {
                    $newPath = "$env:ProgramFiles\docker;" + [Environment]::GetEnvironmentVariable("PATH",[EnvironmentVariableTarget]::Machine)
                    [Environment]::SetEnvironmentVariable("PATH", $newPath,[EnvironmentVariableTarget]::Machine)
                }

                # Register the Docker daemon as a service.
                & "$env:ProgramFiles\docker\dockerd.exe" "--register-service"
            }
            TestScript = {
                If (Get-Service -Name Docker -ErrorAction SilentlyContinue) {$true}
                Else {$false}
            }
            GetScript = {
                @{Result = (Get-Service -Name Docker -ErrorAction SilentlyContinue).Status}
            }
        }
       
        #Configure Docker
        Script DockerConfig {
            SetScript = {
                #Create docker data folder
                If (!(Test-Path $using:dockerDataPath)) {mkdir $using:dockerDataPath -Force}

                #Generate daemon.json
                $myIPaddress = Get-NetIPAddress | ? {$_.InterfaceAlias -like "*Ethernet0*" -and $_.AddressFamily -eq 'IPv4'} | Select -ExpandProperty IPAddress
                $daemonConfig = @{
                    "hosts" = @("tcp://$myIPaddress`:2375", "npipe://")
                    "mtu" = 1500
                    "data-root" = $dockerDataPath
                }
                $daemonJSON = $daemonConfig | ConvertTo-Json
                Write-Verbose "myIP: $myIPAddress"
                Write-Verbose "JSON: $daemonJSON"

                If (!(Test-Path $using:daemonRootPath)) {mkdir $using:daemonRootPath -Force}
                $using:daemonJSON | Out-File $using:daemonFullPath -Force -Encoding ascii

                Start-Service docker -ErrorAction SilentlyContinue
            }
            TestScript = {
                If (Test-Path $using:daemonFullPath -ErrorAction SilentlyContinue) {$true}
                Else {$false}
            }
            GetScript = {
                @{Result = Test-Path $using:daemonFullPath}
            }
        }

        #Install Git
        Script Git {
            SetScript = {
                mkdir C:\Packages -Force
                Robocopy.exe $using:PackageSource C:\Packages git*

                #Install Git
                $git = dir C:\Packages "Git-*" | Select -ExpandProperty FullName
                Start-Process $git -ArgumentList "/verysilent" -Wait
                # Modify PATH to persist across sessions.
                If ([Environment]::GetEnvironmentVariable("PATH",[EnvironmentVariableTarget]::Machine) -notlike "*$env:ProgramFiles\Git\cmd*") {
                    $newPath = "$env:ProgramFiles\Git\cmd;" + [Environment]::GetEnvironmentVariable("PATH",[EnvironmentVariableTarget]::Machine)
                    [Environment]::SetEnvironmentVariable("PATH", $newPath,[EnvironmentVariableTarget]::Machine)
                }
            }
            TestScript = {
                Test-Path $env:ProgramFiles\Git
            }
            GetScript = {
                @{Result = Test-Path $env:ProgramFiles\Git}
            }
        }

        #Install and register GitLab-Runner
        Script GitLab-Runner {
            SetScript = {
                #Install GitLab-Runner
                $gitlabRunner = dir C:\Packages "*runner*" | Select -ExpandProperty FullName
                mkdir C:\gitlab-runner -Force
                move $gitlabRunner C:\gitlab-runner\gitlab-runner.exe
                CD c:\gitlab-runner
                c:\gitlab-runner\gitlab-runner.exe install
                c:\gitlab-runner\gitlab-runner.exe start

                #Register GitLab-Runner
                $RunnerArgs = @(`
                    'register',`
                    '--non-interactive',`
                    '--locked="false"',`
                    "--name=$env:COMPUTERNAME-PowerShell",`
                    '--url="https://gitlab.yourdomain.com/"',`
                    '--executor="shell"',`
                    '--shell="powershell"',`
                    '--registration-token="EnCfTdAgq6T9vB1JnM2B"'
                )
                $bequiet = c:\gitlab-runner\gitlab-runner.exe $RunnerArgs 2>&1
                $bequiet = c:\gitlab-runner\gitlab-runner.exe verify 2>&1
            }
            TestScript = {
                If (Get-Service gitlab-runner -ErrorAction SilentlyContinue) {$true}
                Else {$false}
            }
            GetScript = {
                @{Result = (Get-Service gitlab-runner -ErrorAction SilentlyContinue).Status}
            }
        }

        #Enforce MTU value, gets changed by Docker Swarm
        Script MTU {
            SetScript = {
                Get-NetIPInterface -AddressFamily IPv4 | ? {$_.InterfaceAlias -like "*Ethernet0*"} | Set-NetIPInterface -NlMtuBytes 1500
            }
            TestScript = {
                $currentMTU = Get-NetIPInterface -AddressFamily IPv4 | ? {$_.InterfaceAlias -like '*Ethernet0*'} | Select -ExpandProperty NlMtu
                If ($currentMTU -eq 1500) {$true}
                Else {$false}
            }
            GetScript = {
                @{Result = Get-NetIPInterface -AddressFamily IPv4 | ? {$_.InterfaceAlias -like '*Ethernet0*'} | Select -ExpandProperty NlMtu}
            }
        }        
    }
}

DockerHost
Start-DscConfiguration DockerHost -Wait -Verbose