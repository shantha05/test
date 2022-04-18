param($user, $password, $dbsource, $scripturl)

Start-Transcript "C:\deploy-sql-wrapper-log.txt"

# Get the second script
$script = "D:\script.ps1"
Write-Output "Download $scripturl to $deployScript"
Invoke-WebRequest $scripturl -OutFile $script

Write-Output "Create credential"
$securePwd =  ConvertTo-SecureString "$password" -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential("$env:COMPUTERNAME\$user", $securePwd)

Write-Output "Enable remoting and invoke"
Enable-PSRemoting -force
Set-NetFirewallRule -Name "WINRM-HTTP-In-TCP-PUBLIC" -RemoteAddress Any
Invoke-Command -FilePath $script -Credential $credential -ComputerName $env:COMPUTERNAME -ArgumentList $password, $dbsource
Disable-PSRemoting -Force

Stop-Transcript
