# escape=`

FROM microsoft/aspnet:latest
SHELL ["powershell", "-command"]

RUN Install-WindowsFeature Web-Windows-Auth

#Copy website files
COPY EveryApp C:\EveryApp
COPY healthcheck C:\healthcheck

#Configure website
EXPOSE 80
RUN Remove-Website -Name 'Default Web Site'; `
    New-Website -Name 'EveryApp' -Port 80 -PhysicalPath 'C:\EveryApp';

COPY Set-IIS.ps1 C:\Set-IIS.ps1
RUN C:\Set-IIS.ps1; Remove-Item C:\Set-IIS.ps1
