param($password,
    $dbsource,
    $defaultDnsDomain = "contoso.com",
    $defaultDomain = $dnsDomain)

Start-Transcript "C:\deploy-sqlvm-log.txt"

# Check domain status
If ((Get-CimInstance  -ClassName Win32_computersystem).domain -notmatch "\.") {
    Write-Warning "This computer ($($env:COMPUTERNAME)) is not a member of a domain!"
}

# Set up data disk
Write-Output "Setting up data disk"
$disk = Get-Disk | where-object PartitionStyle -eq "RAW"
$disk | Initialize-Disk -PartitionStyle MBR -PassThru -confirm:$false
$partition = $disk | New-Partition -UseMaximumSize -DriveLetter F
$partition | Format-Volume -Confirm:$false -Force

# Failover clustering
Write-Output "Installing failover clustering"
Install-WindowsFeature -Name "Failover-Clustering" `
                       -IncludeManagementTools `
                       -IncludeAllSubFeature

Install-WindowsFeature RSAT-Clustering-PowerShell

# DB folders
Write-Output "Creating folders"
$logs = "F:\Logs"
$data = "F:\Data"
$backups = "F:\Backup" 
[system.io.directory]::CreateDirectory($logs)
[system.io.directory]::CreateDirectory($data)
[system.io.directory]::CreateDirectory($backups)

# Setup the data, backup and log directories as well as mixed mode authentication
Write-Output "Set up data, backup and log directories in SQL, plus mixed-mode auth"
Import-Module "sqlps" -DisableNameChecking
Add-Type -AssemblyName "Microsoft.SqlServer.Smo"
$sqlesq = New-Object -TypeName Microsoft.SqlServer.Management.Smo.Server -ArgumentList "SQLVM1"
$sqlesq.Settings.LoginMode = [Microsoft.SqlServer.Management.Smo.ServerLoginMode]::Mixed
$sqlesq.Settings.DefaultFile = $data
$sqlesq.Settings.DefaultLog = $logs
$sqlesq.Settings.BackupDirectory = $backups
$sqlesq.Alter() 

# Restart the SQL Server service
Write-Output "Restart SQL"
Restart-Service -Name "MSSQLSERVER" -Force

# Re-enable the sa account and set a new password to enable login
Write-Output "Re-enable 'sa' account, and set password to $password"
Invoke-Sqlcmd -ServerInstance SQLVM1 -Database "master" -Query "ALTER LOGIN sa ENABLE" 
Invoke-Sqlcmd -ServerInstance SQLVM1 -Database "master" -Query "ALTER LOGIN sa WITH PASSWORD = '$password'"

#Add local administrators group as sysadmin
Write-Output "Add local admins as sysadmin"
Invoke-Sqlcmd -ServerInstance SQLVM1 -Database "master" -Query "CREATE LOGIN [BUILTIN\Administrators] FROM WINDOWS"
Invoke-Sqlcmd -ServerInstance SQLVM1 -Database "master" -Query "ALTER SERVER ROLE sysadmin ADD MEMBER [BUILTIN\Administrators]"

# Build Firewall Rules for SQL & AOG
Write-Output "Firewall rules"
New-NetFirewallRule -DisplayName "SQL Server" -Direction Inbound -Protocol TCP -LocalPort 1433 -Action allow 
New-NetFirewallRule -DisplayName "SQL AG Endpoint" -Direction Inbound -Protocol TCP -LocalPort 5022 -Action allow 
New-NetFirewallRule -DisplayName "SQL AG Load Balancer Probe Port" -Direction Inbound -Protocol TCP -LocalPort 59999 -Action allow

# The SPNs seem to end up in the wrong containers (COMPUTERNAME) as opposed to Domain user
# This is a bit of a hack to make sure it is straight. 
# See also: https://support.microsoft.com/en-sg/help/811889/how-to-troubleshoot-the-cannot-generate-sspi-context-error-message
Write-Output "Resetting SPNs"
$dnsDomain = $env:USERDNSDOMAIN
If ($dnsDomain -match "\.") {
    # if user account running is using a domain account with a DNS zone, use the user's domain name as well.
    $domain = $env:USERDOMAIN
} else {
    # if user account running is using a local account witouth a DNS zone, use the default DNS domain and domain passed. 
    $dnsDomain = $defaultDnsDomain
    $domain = $defaultDomain
}

$user = $env:USERNAME
$computer = $env:COMPUTERNAME
SetSPN -s "MSOLAPSvc.3/$computer.$dnsDomain"    "$domain\$computer$"
SetSPN -s "MSOLAPSvc.3/$computer"               "$domain\$computer$"
SetSPN -d "MSSQLSvc/$computer.$dnsDomain"       "$domain\$computer$"
SetSPN -s "MSSQLSvc/$computer.$dnsDomain"       "$domain\$user"
SetSPN -d "MSSQLSvc/$computer.$dnsDomain`:1433" "$domain\$computer$"
SetSPN -s "MSSQLSvc/$computer.$dnsDomain`:1433" "$domain\$user"

# For secondary servers, we skip restoring the DB. So check first if DB was specified
if (($null -ne $dbsource) -and ($dbsource -ne "")) {
    # Get the Contoso Insurance database backup 
    $dbdestination = "D:\ContosoInsurance.bak"
    Write-Output "Download $dbsource to $dbdestination"
    Invoke-WebRequest $dbsource -OutFile $dbdestination

    # Restore the database from the backup
    Write-Output "Restore the database from backup"
    $mdf = New-Object Microsoft.SqlServer.Management.Smo.RelocateFile("ContosoInsurance", "F:\Data\ContosoInsurance.mdf")
    $ldf = New-Object Microsoft.SqlServer.Management.Smo.RelocateFile("ContosoInsurance_Log", "F:\Logs\ContosoInsurance.ldf")
    Restore-SqlDatabase -ServerInstance Localhost -Database ContosoInsurance `
                        -BackupFile $dbdestination -RelocateFile @($mdf,$ldf) -ReplaceDatabase

    # Put the database into full recovery and run a backup (required for SQL AG)
    Write-Output "Put into full recovery and run backup"
    Invoke-Sqlcmd -ServerInstance Localhost -Database "master" -Query "ALTER DATABASE ContosoInsurance SET RECOVERY FULL"
    Backup-SqlDatabase -ServerInstance Localhost -Database ContosoInsurance
} else {
    Write-Output "No source database specified"
}

# Disable IE Enhanced Security Configuration
Write-Output "Disable IE Enhanced Security"
$AdminKey = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}"
$UserKey = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}"

New-Item -Path $adminKey -Force
New-Item -Path $UserKey -Force
New-ItemProperty -Path $AdminKey -Name "IsInstalled" -Value 0
New-ItemProperty -Path $UserKey -Name "IsInstalled" -Value 0

$HKLM = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Zones\1"
$HKCU = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Zones\1"
Set-ItemProperty -Path $HKLM -Name "1803" -Value 0
Set-ItemProperty -Path $HKCU -Name "1803" -Value 0
$HKLM = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Zones\2"
$HKCU = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Zones\2"
Set-ItemProperty -Path $HKLM -Name "1803" -Value 0
Set-ItemProperty -Path $HKCU -Name "1803" -Value 0
$HKLM = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Zones\3"
$HKCU = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Zones\3"
Set-ItemProperty -Path $HKLM -Name "1803" -Value 0
Set-ItemProperty -Path $HKCU -Name "1803" -Value 0
$HKLM = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Zones\4"
$HKCU = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Zones\4"
Set-ItemProperty -Path $HKLM -Name "1803" -Value 0
Set-ItemProperty -Path $HKCU -Name "1803" -Value 0
$HKLM = "HKLM:\Software\Microsoft\Internet Explorer\Security"
New-ItemProperty -Path $HKLM -Name "DisableSecuritySettingsCheck" -Value 1 -PropertyType DWORD

Write-Output "All done"

Stop-Transcript
