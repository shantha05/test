param($user, $password, $dbsource, $scripturl)

Start-Transcript "C:\deploy-sql-wrapper-log.txt"

# Get the second script
$script = "D:\script.ps1"
Write-Output "Download $scripturl to $deployScript"
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12;
Invoke-WebRequest $scripturl -OutFile $script

Write-Output "Create credential"
$securePwd =  ConvertTo-SecureString "$password" -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential("SQLVM1\demouser@contoso.com", $securePwd)

Write-Output "Enable remoting and invoke"
Enable-PSRemoting -force
Set-NetFirewallRule -Name "WINRM-HTTP-In-TCP-PUBLIC" -RemoteAddress Any
Invoke-Command -FilePath $script -Credential $credential -ComputerName SQLVM1.contoso.com -ArgumentList $password, $dbsource
Disable-PSRemoting -Force

Stop-Transcript
