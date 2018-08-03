# WindowsDocker
A guide to getting started with hosting Windows Containers in an enterprise environment:
 - On-premises virtual machines (VMware)
 - Corporate HTTP proxy
 - Windows Server 1803 container hosts running Docker 17.06.2-ee-16 with Docker Swarm
 - Ingress handled by Traefik, a reverse proxy / load balancer http://traefik.io

# Architecture
For this example we will build a 3-node Docker Swarm cluster to host containerized ASP.NET web applications utilising MS SQL databases from outside the cluster. This represents a common lift-and-shift scenario.

We're keeping this one simple: there's no container image registry or CI/CD. 
See the /GitLab folder for that, which builds on this guide.

The idea is that clients will:
 1. Request a website (i.e. reports.apps.local)
 2. Be directed to any of the container hosts
 3. Traefik grabs the request and matches reports.apps.local against any Frontend Rules
 4. Traefik forwards the request to a matching Backend (i.e. the container) over Swarm's overlay network
 5. IIS running in the container handles the request and replies to Traefik
 6. Traefik relays it back to the client

The container host's networking has 3 layers: the external network (host network), the bridge network, and the Docker Swarm overlay network. The Docker daemon manages the bridge and overlay networks for you. Further reading on how these work together: https://docs.docker.com/network/

Architecting your storage is highly dependent on what your containers are doing, so please see the official guidelines: https://docs.docker.com/storage/

### DNS
DNS Round Robin is used to send requests to the Traefik instances on each host. Create new A records with the external IP of each host, all pointing to the same FQDN (i.e. apps.local). Create a wildcard (*) CNAME for this FQDN so that you can add arbitrary new web services without needing new DNS records (i.e. reports.apps.local, timeclock.apps.local, etc). In Active Directory DNS this will appear as a new stub zone in your domain.

# Container Host VMs
Create a new VM for each host and install Windows Server 1803. The process is straightforward with the following caveats:
 - Enable hardware virtualization on the VM (VMware: Hardware settings > CPU)
 - When using the VMXNET3 network adapter you must install VMware Tools before Windows can detect it
 - Add a 2nd hard drive for Docker to store its data, volume D:

Use the SCONFIG utility to rename the computer, set a static IP, reboot, and then join the domain.

### Docker Prerequisites
Some additional Windows Features need to be installed: Hyper-V and Windows Containers. We'll also disable Windows Defender and Windows Firewall, as you likely have different solutions to use in their place.

    Install-WindowsFeature "RSAT-Hyper-V-Tools" -IncludeAllSubFeature -IncludeManagementTools
    Install-WindowsFeature "Hyper-V" -IncludeAllSubFeature -IncludeManagementTools
    Install-WindowsFeature -Name "Containers" -IncludeAllSubFeature -IncludeManagementTools
    Remove-WindowsFeature -Name "Windows-Defender"
    Get-NetFirewallProfile | Set-NetFirewallProfile -Enabled false
Reboot the host.

### Install Docker
Since you're behind a corporate proxy nothing is easy and the usual installation methods don't work. Download Docker manually on your workstation; URLs to .zip files for each version are in https://download.docker.com/components/engine/windows-server/index.json

#### Installation
Copy the .zip to your host, extract it to C:\Program Files, register the daemon as a service, and add it to your PATH:

    # Obtain the zip file.
    mkdir C:\Packages -Force
    Copy-Item "\\fileshare\Docker" "C:\Packages" -Recurse
    
    # Extract the archive.
    dir C:\Packages\Docker *.zip | Expand-Archive -DestinationPath $Env:ProgramFiles -Force
    
    # Clean up the zip file.
    Remove-Item C:\Packages\Docker -Force
    
    # Modify PATH to persist across sessions.
    If ([Environment]::GetEnvironmentVariable("PATH",[EnvironmentVariableTarget]::Machine) -notlike "*$env:ProgramFiles\docker;*") {
        $newPath = "$env:ProgramFiles\docker;" + [Environment]::GetEnvironmentVariable("PATH",[EnvironmentVariableTarget]::Machine)
        [Environment]::SetEnvironmentVariable("PATH", $newPath,[EnvironmentVariableTarget]::Machine)
    }
    
    # Register the Docker daemon as a service.
    & "$env:ProgramFiles\docker\dockerd.exe" "--register-service"

#### daemon.json
Create C:\ProgramData\docker\config\daemon.json. We only need 3 options in it:

    {
      "data-root": "D:\\ProgramData\\Docker",
      "hosts": ["tcp://<IP address>:2375","npipe://"],
      "mtu": 1500
    }

"data-root" will have Docker create its image cache (and everything else) on your D: volume. This is desirable because we don't want to back it up, as all the images will either be downloadable from the Internet or a local registry (i.e. GitLab). Most backup software supports excluding volumes or disk #s.

"hosts" tells the Docker API to listen on both TCP port 2375 (for traefik), and named pipes (for running docker.exe commands from the shell).

"mtu" allegedly sets the TCP/IP max packet size to 1500 bytes, but isn't yet supported on Windows and you'll normally see 1450 within containers.

#### MTU
Hopefully all this is resolved in future versions of Docker EE and/or Windows Server 2016. It may not apply to you.

An issue I encountered in testing Server 1709/Docker-EE-17.06.2-ee-8 through Server 1803/Docker EE 17.06.2-ee-16 was that some TCP traffic coming back from containers was being dropped. The packets were set to Don't Fragment, and their size exceeded the interface MTU. My dirty hack for this was to force the host's external interface (Eth0) back to MTU=1500 -- it gets set to 1450 by Swarm.

    C:\>netsh int ipv4 show int
    
    Idx     Met         MTU          State                Name
    ---  ----------  ----------  ------------  ---------------------------
      1          75  4294967295  connected     Loopback Pseudo-Interface 1
      5        5000        1500  connected     vEthernet (nat)
     11          15        1450  connected     vEthernet (Ethernet0)   

    C:\>netsh int ipv4 set int 11 mtu=1500
    Ok.
But Swarm is going to want to set it back to 1450 on you whenever it recreates the HNS networks (i.e. when dockerd is restarted, on reboot, or leaving/joining a swarm). I used PowerShell DSC to test and enforce MTU=1500.

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

#### Proxy
Docker can be made proxy-aware by setting the HTTP_PROXY, HTTPS_PROXY and NO_PROXY environment variables. These are not passed down to the containers.

    [Environment]::SetEnvironmentVariable("HTTP_PROXY", "http://username:password@proxy.local:1234/", [EnvironmentVariableTarget]::Machine)
    [Environment]::SetEnvironmentVariable("HTTPS_PROXY", "http://username:password@proxy.local:1234/", [EnvironmentVariableTarget]::Machine)
    [Environment]::SetEnvironmentVariable("NO_PROXY", ".local, localhost", [EnvironmentVariableTarget]::Machine)
In my environment there was no need to configure proxy settings anywhere else, i.e. under netsh winhttp or the Internet Options proxy settings.
#### Testing
Reboot the host, then test it. You should be able to search the public docker registry:

    PS C:\> docker search microsoft
    NAME                                       DESCRIPTION                                     STARS     OFFICIAL   AUTOMATED
    microsoft/dotnet                           Official images for .NET Core and ASP.NET ...   1006                 [OK]
    microsoft/mssql-server-linux               Official images for Microsoft SQL Server o...   806
    microsoft/aspnet                           ASP.NET is an open source server-side Web ...   745                  [OK]
    microsoft/aspnetcore                       Official images for running compiled ASP.N...   448                  [OK]

Errors at this stage are likely proxy-related. Tweak your environment variables, restart the Docker service, and try again. Once it's working, try downloading a sample container image:

    docker pull microsoft/dotnet-samples

#### Docker Swarm
Initialize swarm mode and create an overlay network for Traefik:

    docker swarm init
    docker network create -d overlay --attachable traefik-net

### Install Traefik
We'll be running Traefik as a container, mapping it to a folder holding its configuration files. See the /traefik section for the Dockerfile and config examples, and a detailed explanation. Copy them to C:\traefik on your host, build the image, and start the container:

    docker build -t traefik:latest
    docker run -d -v c:/traefik:C:/etc/traefik `
     -p 80:80 -p 443:443 -p 8080:8080 `
     --network traefik-net `
     --restart always `
     --name traefik `
    traefik:latest

You can browse the dashboard at http://host1.local:8080. You won't have anything under the Docker or File providers yet.

### Run a Sample Container
#### Manually
    docker run -d -p 8081:80 --name sample microsoft/dotnet-samples
This starts the container in detached mode (as opposed to attached mode, which brings your command prompt into the container), maps port 8081 on the host to port 80 in the container, gives it a friendly name of "sample", and uses the microsoft/dotnet-samples image.
Attach to the container and start powershell:

    docker exec -it sample powershell.exe

Now every command you use is within the context of the container. IIS should be working, test it locally and then exit back to the host.

    Invoke-WebRequest -UseBasicParsing http://localhost
    Exit
Now try it from the host and your workstation:

    Invoke-WebRequest -UseBasicParsing http://host1.local:8081
You should also be able to get it to work via http://localhost:8081; if you can't check your proxy settings.
Stop the container once you're done.

    docker rm -f sample

#### Swarm
Docker Swarm allows you to deploy 'services' defined by YAML files. You can write out a desired configuration outcome and Swarm will try to make it happen. See the official documentation for an overview (https://docs.docker.com/engine/swarm) and available configuration options (https://docs.docker.com/compose/compose-file). Pay special attention to the limitations in Swarm mode. The Swarm routing mesh, which would handle ingress from clients and direct them to the correct containers, is not yet supported. This is one reason why we're using Traefik.

Copy docker-compose.yml out of /dotnet-sample. Deploy it and check your Traefik dashboard:

    docker stack deploy -c docker-compose.yml sample
How does this work? Traefik is querying the Docker API and looking for new 'services' with particular labels. These would be the "traefik.x" lines in docker-compose.yml. Frontends and Backends get built and updated on the fly, and you don't have to worry about which host any given container is on. The Swarm overlay network you created, traefik-net, hosts all the traffic between Traefik and your Swarm containers. If you don't connect the container to traefik-net, it won't be reachable.

Browse your sample app via its Frontend label, i.e. http://sample.apps.local.

Viewing Swarm services and containers:

    docker stack ls
    docker service ls
    docker service ps <stackname_servicename>
    docker ps
See container IPs:

    docker network inspect traefik-net
Ping your sample container from the traefik container:

    docker exec traefik ping <IP address>

Tear it down:

    docker stack rm <stackname>

### Adding New Hosts
Do everything again. And again.** Once you have two new hosts ready, get your Swarm token from the original host:

    docker swarm join-token manager
Copy/paste the output and run it on your new hosts. Check their availability:

    docker node ls
Optionally, you can set some labels on them which can be used for placement preferences in the docker-compose files.

    docker node update --label-add myLabel=myValue host1
** Seriously though, you have a few options for duplicating your original host. You could leave the swarm, sysprep the VM, clone it, and change the MAC address. Better would be to script the host configuration into your configuration management tool of choice (i.e. PowerShell DSC, Ansible, Chef). Store it in Git and use it to stand up new hosts, and enjoy your self-documenting config. See the /dsc folder for my implementation.

# Next Steps
- Add support for integrated Windows Authentication for your IIS containers, connect them to SQL, and get some logs. See /windowsauth.
 - Configure your backups. I exclude D: (disk 1) to save space and increase backup speed. This may not be best for you, as your RTO will be limited by the time it takes to re-download the images.
 - Get a certificate for Traefik, it can handle SSL termination for you. Add a wildcard to the Subject Alt Name (i.e. *.apps.local) and now you're SSL-ready for arbitrary additional services.
- Implement a container image registry. I used GitLab's, see the /gitlab folder.
- Install GitLab-Runner agents on your hosts and start playing with CI/CD.
- Implement some health monitoring. I like to monitor the Swarm status, as well as checking that each traefik container can ping every backend IP. See DockerSwarmCheck.ps1 and /traefik/DockerTraefikHealth.ps1 for some custom PRTG sensors I made. You can also make use of the HealthCheck feature in Dockerfiles.