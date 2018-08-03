$website_name = 'EveryApp'
$logDir = "C:\Logs"

Import-Module WebAdministration

#Set logging configuration
$Site = Get-Item IIS:\Sites\$website_name
$Site.LogFile.logExtFileFlags='Date,Time,UserName,SiteName,ComputerName,Method,UriStem,UriQuery,HttpStatus,TimeTaken'
$Site.LogFile.logSiteId = $false
$Site.LogFile.truncateSize = 4294967295
$Site.LogFile.period = "MaxSize"
$Site.LogFile.Directory = $logDir
$Site.id = [int64](Get-Random -Minimum 1000 -Maximum 9999)
$Site | Set-Item

#Set authentication methods
Set-WebConfiguration system.webServer/security/authentication/anonymousAuthentication -PSPath IIS:\ -Location $website_name -Value @{enabled="False"}; `
Set-WebConfiguration system.webServer/security/authentication/windowsAuthentication -PSPath IIS:\ -Location $website_name -Value @{enabled="True"};
Set-WebConfigurationProperty system.webServer/security/authentication/windowsAuthentication -pspath IIS:\ -location $website_name -name "authPersistNonNTLM" -value "False"

#Healthcheck for Traefik
New-WebVirtualDirectory -Site $website_name -Name Healthcheck -PhysicalPath c:\healthcheck
Set-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -location "$website_name/healthcheck" -filter "system.webServer/security/authentication/anonymousAuthentication" -name "enabled" -value "True"
