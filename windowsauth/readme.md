# EveryApp
EveryApp is a sample Windows container that:
- is ASP.NET on IIS,
- with integrated Windows authentication,
- connecting to an external SQL server (not a container)

Before building and deploying EveryApp we'll need to:
- Create a gMSA in AD
- Install it on the host and create a Docker credentialspec
- Add the gMSA as a SQL login and grant it read access to your test database
- Update the SQL connection string and sample SQL query in EveryApp

### gMSA Creation and Configuration
Microsoft's solution for kerberos-in-containers is to use a group Managed Service Account (gMSA), fed to the container through the Docker engine's credentialspec feature. Please review the [official documentation](https://github.com/MicrosoftDocs/Virtualization-Documentation/tree/live/windows-server-container-tools/ServiceAccounts), and obtain the latest CredentialSpec.psm1 module.

Install the Active Directory PowerShell module:

    Install-WindowsFeature RSAT-AD-PowerShell
    Import-Module ActiveDirectory

Create a new gMSA (requires domain admin):

    New-ADServiceAccount -name DOCKER -DnsHostName apps.local -PrincipalsAllowedToRetrieveManagedPassword host1$,host2$,host3$

Install the gMSA on each host:

    Install-ADServiceAccount DOCKER

Create a Docker credentialspec JSON based on the gMSA, also on each host:

    Import-Module CredentialSpec.psm1
    New-CredentialSpec -Name docker -AccountName DOCKER

### MS SQL Configuration
Make sure your hosts have access to the SQL server instance through your firewall (default TCP 1433). Create or use a test database, and add the gMSA as a SQL login with permissions on the database. Sample TSQL:

    USE [master]
    GO
    CREATE LOGIN [local\DOCKER$] FROM WINDOWS WITH DEFAULT_DATABASE=[master]
    GO
    USE [TestDB]
    GO
    CREATE USER [local\DOCKER$] FOR LOGIN [local\DOCKER$] WITH DEFAULT_SCHEMA=[dbo]
    GO
    ALTER ROLE [db_datareader] ADD MEMBER [local\DOCKER$]
    GO
 
 ### Customize EveryApp
 Download /everyapp to a host. Modify /EveryApp/default.aspx, lines 10 and 14. 'Data Source' will be the FQDN of your SQL server. (And since this server is external to your Swarm overlay network, it **must** be the whole FQDN.) 'Initial Catalog' is the database name.

    cmd.CommandText = "SELECT col1,col2 FROM table1";
 The SQL query depends on what's in your test database. This example supposes your database has a table 'table1', with columns 'col1' and 'col2', with at least one record. The method reader.GetString(0) gets 'col1', reader.GetString(1) gets 'col2', etc. Feel free to add more if needed.

### Build EveryApp
On the host, change to the directory containing the Dockerfile:

    docker build -t everyapp .

We'll go over the key components of the build.

    FROM microsoft/aspnet:latest
    SHELL ["powershell", "-command"]
    RUN Install-WindowsFeature Web-Windows-Auth
An IIS server with ASP.NET installed, maintained by Microsoft. It doesn't come with Web-Windows-Auth installed, so we do that.

    COPY EveryApp C:\EveryApp
    COPY healthcheck C:\healthcheck
EveryApp website files get copied to C:\EveryApp and C:\healthcheck.

    EXPOSE 80
    RUN Remove-Website -Name 'Default Web Site'; `
        New-Website -Name 'EveryApp' -Port 80 -PhysicalPath 'C:\EveryApp';
Containers are expected to publish port 80. Remove the default IIS website, and add our own.

    COPY Set-IIS.ps1 C:\Set-IIS.ps1
    RUN C:\Set-IIS.ps1; Remove-Item C:\Set-IIS.ps1
We do a bunch of custom IIS logging configuration and security settings in a separate script. IIS will output logs to C:\Logs, which we'll expose as a volume on the host during deployment. On our main EveryApp website, anonymous auth is disabled and windows auth is enabled. A new virtual directory is created for C:\healthcheck that permits anonymous auth. We do this to support Traefik's built-in healthcheck feature, which otherwise would fail when trying to use windows auth.

### Deploy EveryApp
Copy your modified EveryApp folder to your remaining hosts and build the image again. (If we had an image repository we wouldn't need to do this.) Also create a C:\logs\everyapp folder on each host. Deploy the app:

    docker stack deploy -c docker-compose.yml everyapp

Important aspects of this docker-compose.yml:

    credential_spec:
      file: DOCKER.json
This matches up with what your New-CredentialSpec cmdlet created, and hooks the containers spawned by this service to your gMSA. Your IIS application pool, even though running as SYSTEM in the container, will authenticate externally as the gMSA.

    volumes:
      - C:/logs/everyapp:C:/logs
    
    volumes:
      logs:
This maps the C:\logs\everyapp folder on each host to C:\logs within the container, allowing you to see the IIS logs in real time. You could have an external log server scrape these folders.

    - "traefik.backend.healthcheck.healthcheck=/health"
This enabled traefik's built-in healthcheck routine, which regularly tests the path and disables any backends that fail the test. If all backends fail then traefik returns a 'Service unavailable' page. Different ports and intervals are available, see the [docs](https://docs.traefik.io/configuration/backends/docker/). The syntax here is counter-intuitive -- the path is specified between the last period and the "=", not after the slash. i.e:
http://mywebsite/selftest would be "traefik.backend.healthcheck.selftest=/health"

## Sample Website Output

DOMAIN\USERNAME: LOCAL\TESTUSER  
  
SELECT col1,col2 FROM table1  
b s  
c d  
c d  
h d  
m n  
n t  
o t  
o y  
r d  
r d