<#
 * Copyright Microsoft Corporation
 * 
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 * http://www.apache.org/licenses/LICENSE-2.0
 * 
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
#>

#Command line arguments with defaults
param(
$subscriptionName,
$storageAccount,
$serviceName,
$highAvailabilityType,
$vmName,
$vmSize,
$vmType,
$imageName,
$availabilitySetName,
$dataDisks,
$defaultSqlDataFolder,
$defaultSqlLogFolder,
$defaultSqlBackupFolder,
$adminUsername,
$adminPassword,
$vnetName,
$subnetNames,
$affinityGroup,
$domainDnsName,
$domainInstallerUsername,
$domainInstallerPassword,
$databaseInstallerUsername,
$databaseInstallerPassword,
$choice,
$location,
$scriptFolder
)

#write-host $deployStandaloneSQLIIS (1)
#write-host $deployDomainSQLIIS (2)
#write-host $deploySharePoint (3)

# Create credential object
$secPassword = ConvertTo-SecureString $adminPassword -AsPlainText -Force
$adminCredential = New-Object System.Management.Automation.PSCredential($adminUsername, $secPassword)
$localAdminCredential = New-Object System.Management.Automation.PSCredential(("{0}\{1}" -f $vmName, $adminUsername), $secPassword)

# Ensure correct subscription and storage account is selected
#Select-AzureSubscription -SubscriptionName $subscriptionName
Set-AzureSubscription -SubscriptionName $subscriptionName -CurrentStorageAccount $storageAccount

## Display current subscription
#$currentSubscription = Get-AzureSubscription -Current
#"Current subscription: {0}" -f $currentSubscription.SubscriptionName

# Include script file for shared functions
#$scriptFolder = Split-Path -parent $MyInvocation.MyCommand.Definition
#. "$scriptFolder\..\SharedComponents\SharedFunctions.ps1"

#calls function to creates a domain joined or stand-alone VM
if ($choice -ne $deployStandaloneSQLIIS) 
   {
  
      CreateDomainJoinedAzureVmIfNotExists `
      -serviceName $serviceName  `
      -vmName $vmName  `
      -size $vmSize  `
      -imageName $imageName  `
      -availabilitySetName $availabilitySetName  `
      -dataDisks $dataDisks `
      -vnetName $vnetName  `
      -subnetNames $subnetNames  `
      -affinityGroup $affinityGroup `
      -adminUsername $adminUserName `
      -adminPassword $adminPassword `
      -domainDnsName $domainDnsName `
      -domainInstallerUsername $domainInstallerUsername `
      -domainInstallerPassword $domainInstallerPassword
  
##   CreateDomainJoinedAzureVmIfNotExists $serviceName $vmName $vmSize $imageName $availabilitySetName $dataDisks $vnetName $subnetNames $affinityGroup $adminUsername $adminPassword `
##	  $domainDnsName $domainInstallerUsername $domainInstallerPassword

   }
   else
   {

   CreateAzureVmIfNotExists `
      -serviceName $serviceName  `
      -vmName $vmName  `
      -size $vmSize  `
      -imageName $imageName  `
      -availabilitySetName $availabilitySetName  `
      -dataDisks ($dataDisks) `
      -vnetName $vnetName  `
      -subnetNames $subnetNames  `
      -affinityGroup $affinityGroup  `
      -adminUsername $adminUserName  `
      -adminPassword $adminPassword  `
      -location $location `
      -scriptFolder $scriptFolder
      
## CreateAzureVmIfNotExists $serviceName $vmName $vmSize $imageName $availabilitySetName $dataDisks $vnetName $subnetNames $affinityGroup $adminUsername $adminPassword $location

#	  $domainDnsName $domainInstallerUsername $domainInstallerPassword
  }

Write-Host
#Get the hosted service WinRM Uri
[System.Uri]$uris = (GetVMConnection -ServiceName $serviceName -vmName $vmName)
if ($uris -eq $null){return}

$Credential = (SetCredential -Username $domainInstallerUsername -Password $domainInstallerPassword)
FormatDisk `
   -uris $uris `
   -Credential $Credential
   
#Write-Host "Enabling CredSSP on $vmName"
#EnableCredSSPServerIfNotEnabledBackwardCompatible $serviceName $vmName $domainInstallerUsername $domainInstallerPassword


##GP 2/13/2014
## Stand alone SQL check
if ($choice -eq $deployStandaloneSQLIIS){$domainInstallerUsername = $databaseInstallerUsername}

Invoke-Command -ConnectionUri $uris.ToString() -Credential $localAdminCredential  `
	-ArgumentList $databaseInstallerUsername, $databaseInstallerPassword, $domainInstallerUsername, $defaultSqlDataFolder, $defaultSqlLogFolder, `
	$highAvailabilityType, $vmType -ScriptBlock {
		param($databaseInstallerUsername, $databaseInstallerPassword, $domainInstallerUsername, $defaultSqlDataFolder, $defaultSqlLogFolder, $highAvailabilityType, $vmType)

   Set-ExecutionPolicy Unrestricted
    
   #Hide green status bar
   $ProgressPreference = "SilentlyContinue"

   # Add Install User as Local Admin
#	net localgroup administrators "$domainInstallerUsername" /Add

	if([string]::IsNullOrEmpty($vmType) -or (-not $vmType.Equals('QUORUM')))
	{
		Write-Host "Configuring firewall..." -NoNewline
		netsh advfirewall firewall add rule name='SQL Server (TCP-In)' program='C:\Program Files\Microsoft SQL Server\MSSQL11.MSSQLSERVER\MSSQL\Binn\sqlservr.exe' dir=in action=allow protocol=TCP  | Out-Null
		Write-Host -ForegroundColor Green "... Firewall configured."
					
		Write-Host "Configuring database permissions and options..." -NoNewline
      Import-Module sqlps -OutVariable $Result -WarningAction SilentlyContinue 
		Invoke-Sqlcmd -ServerInstance $env:COMPUTERNAME -Database master -Query `
		"	    
        USE [master]
        IF Not EXISTS (SELECT name FROM master.sys.server_principals WHERE name = '$databaseInstallerUsername')
        BEGIN
		    CREATE LOGIN [$databaseInstallerUsername] WITH PASSWORD='$databaseInstallerPassword' 
		    EXEC sp_addsrvrolemember '$databaseInstallerUsername', 'dbcreator'
			EXEC sp_addsrvrolemember '$databaseInstallerUsername', 'securityadmin'
        END
        
        IF Not EXISTS (SELECT name FROM master.sys.server_principals WHERE name = '$domainInstallerUsername')
        BEGIN
		    CREATE LOGIN [$domainInstallerUsername] FROM WINDOWS
		    EXEC sp_addsrvrolemember '$domainInstallerUsername', 'sysadmin'
        END      
        EXEC sp_addsrvrolemember 'NT AUTHORITY\SYSTEM', 'sysadmin'
        "

      Invoke-Sqlcmd -ServerInstance $env:COMPUTERNAME -database master -Query `
		"USE [master]
		GO
		sp_configure 'show advanced options', 1;RECONFIGURE WITH OVERRIDE;
		GO
		sp_configure 'max degree of parallelism', 1;RECONFIGURE WITH OVERRIDE;
		GO"
		Write-Host -ForegroundColor Green "... configuration complete."

		Write-Host "Enabling mixed authentication mode and setting folder locations..." -NoNewline
		$s = new-object ('Microsoft.SqlServer.Management.Smo.Server') $env:COMPUTERNAME
		$s.Settings.LoginMode = [Microsoft.SqlServer.Management.Smo.ServerLoginMode]::Mixed
		if(-not [string]::IsNullOrEmpty($defaultSqlDataFolder))
		{
			mkdir $defaultSqlDataFolder | Out-Null
			$s.Settings.DefaultFile = $defaultSqlDataFolder
		}
		if(-not [string]::IsNullOrEmpty($defaultSqlLogFolder))
		{
			mkdir $defaultSqlLogFolder | Out-Null
			$s.Settings.DefaultLog = $defaultSqlLogFolder
		}
		if(-not [string]::IsNullOrEmpty($defaultSqlBackupFolder))
		{
			mkdir $defaultSqlBackupFolder | Out-Null
			$s.Settings.BackupDirectory = $defaultSqlBackupFolder
		}
		$s.Alter()
		Write-Host -ForegroundColor Green "... configuration complete."
      Write-Host "Restartig MSSQLSERVER service" -NoNewline
		Restart-Service -Name MSSQLSERVER -Force -WarningAction SilentlyContinue
		Write-Host -ForegroundColor Green "... restart complete."
	}
   
}
	