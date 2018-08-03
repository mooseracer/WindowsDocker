# PowerShell DSC
DSC-DockerHost.ps1 is meant for standing up a newly joined Server 2016 VM. It's meant to live on a remote file share along with its supporting files. Things it handles:
- The required Windows Features
- HTTP proxy environment variables
- Docker installation
- Docker daemon.json creation
- Git installation
- Gitlab-Runner installation and registration
- Eth0 MTU=1500 enforcement

#### User Variables
Modify the following sections to suit your own environment:

    $packageSource  =  '\\fileserver\share'
    $dockerDataPath  =  'D:\ProgramData\Docker'
    Environment HTTP_PROXY - Value
    Environment HTTPS_PROXY - Value
    Environment NO_PROXY - Value
    #Register GitLab-Runner
	    $RunnerArgs  =  @(`
		    '--url="https://gitlab.yourdomain.com/"',`
#### Usage
From the host, remotely invoke the script:

    powershell.exe -ExecutionPolicy bypass -File \\fileserver\share\DSC-DockerHost.ps1
Expect an automatic reboot. By default the configuration will be re-evaluated every 15 minutes.

Commands for managing DSC:

    Get-DSCConfigurationStatus
    Get-DSCConfiguration
    Remove-DSCConfigurationDocument -Stage {Pending|Current}

#### Supporting Files
Git: [https://git-scm.com/download/win](https://git-scm.com/download/win)

GitLab-Runner: [https://gitlab-runner-downloads.s3.amazonaws.com/latest/binaries/gitlab-runner-windows-amd64.exe](https://gitlab-runner-downloads.s3.amazonaws.com/latest/binaries/gitlab-runner-windows-amd64.exe)

Docker-EE zip: parse link for the version you want from [https://download.docker.com/components/engine/windows-server/index.json](https://download.docker.com/components/engine/windows-server/index.json)

CredentialSpec.psm1: https://github.com/MicrosoftDocs/Virtualization-Documentation/tree/live/windows-server-container-tools/ServiceAccounts