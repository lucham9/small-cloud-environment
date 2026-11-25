#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
Small cloud environment - secure, operator-driven Windows role configuration.
Run on the intended Windows Server 2022 instance after its Terraform bootstrap.
Passwords are requested interactively and never written to Terraform or files.
The actions rename/restart servers and configure a directory or CA; run them
only on the matching, newly provisioned server in an authorized environment.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('DC1', 'DC2', 'MSCA', 'NPS')]
    [string]$ServerRole,

    [Parameter(Mandatory)]
    [ValidateSet('PromotePrimary', 'PromoteSecondary', 'JoinMember', 'ConfigureCA', 'RegisterNPS')]
    [string]$Action,

    [Parameter(Mandatory)]
    [ValidatePattern('^(?=.{3,253}$)([A-Za-z0-9][A-Za-z0-9-]*\.)+[A-Za-z]{2,63}$')]
    [string]$DomainName,

    [ValidatePattern('^[A-Za-z][A-Za-z0-9-]{0,14}$')]
    [string]$NetbiosName = 'SMALLCLOUD',

    [ValidatePattern('^[A-Za-z0-9 ._-]{3,64}$')]
    [string]$CACommonName = 'SmallCloud-RootCA'
)

$ErrorActionPreference = 'Stop'
$allowedRole = @{
    PromotePrimary = 'DC1'
    PromoteSecondary = 'DC2'
    ConfigureCA = 'MSCA'
    RegisterNPS = 'NPS'
}
if ($Action -eq 'JoinMember') {
    if ($ServerRole -notin @('MSCA', 'NPS')) { throw 'Only member servers use JoinMember.' }
} elseif ($allowedRole[$Action] -ne $ServerRole) {
    throw 'The selected action does not match the server role.'
}

$expectedIP = @{ DC1='10.20.2.10'; DC2='10.20.2.11'; MSCA='10.20.2.20'; NPS='10.20.2.21' }[$ServerRole]
$interface = Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -eq $expectedIP } | Select-Object -First 1
if (-not $interface) { throw "This server must own $expectedIP for role $ServerRole." }

$expectedName = "SC-$ServerRole"
if ($env:COMPUTERNAME -ne $expectedName) {
    Rename-Computer -NewName $expectedName -Force
    Write-Host 'Hostname changed. Restart this server, reconnect, and rerun the same command.'
    return
}

$computer = Get-CimInstance Win32_ComputerSystem
switch ($Action) {
    'PromotePrimary' {
        if ($computer.PartOfDomain) { throw 'This server already belongs to a domain; promotion was not repeated.' }
        Import-Module ADDSDeployment
        $dsrm = Read-Host 'Enter a unique Directory Services Restore Mode password' -AsSecureString
        Install-ADDSForest -DomainName $DomainName -DomainNetbiosName $NetbiosName `
            -InstallDns -SafeModeAdministratorPassword $dsrm -NoRebootOnCompletion:$true -Force
        Set-DnsClientServerAddress -InterfaceIndex $interface.InterfaceIndex -ServerAddresses '10.20.2.10','10.20.2.11'
        Write-Host 'Forest configured. Restart DC1 before continuing with DC2 or member servers.'
        Write-Host 'After reboot, configure DNS forwarding: Set-DnsServerForwarder -IPAddress 10.20.0.2'
    }
    'PromoteSecondary' {
        if ($computer.DomainRole -ge 4) { throw 'This server is already a domain controller.' }
        Set-DnsClientServerAddress -InterfaceIndex $interface.InterfaceIndex -ServerAddresses '10.20.2.10'
        Resolve-DnsName "_ldap._tcp.dc._msdcs.$DomainName" -Type SRV -ErrorAction Stop | Out-Null
        $credential = Get-Credential -Message 'Enter a domain administrator authorized to add this domain controller'
        $dsrm = Read-Host 'Enter a unique Directory Services Restore Mode password' -AsSecureString
        Install-ADDSDomainController -DomainName $DomainName -Credential $credential -InstallDns `
            -SafeModeAdministratorPassword $dsrm -NoRebootOnCompletion:$true -Force
        Set-DnsClientServerAddress -InterfaceIndex $interface.InterfaceIndex -ServerAddresses '10.20.2.10','10.20.2.11'
        Write-Host 'Secondary domain controller configured. Restart DC2, then check replication.'
    }
    'JoinMember' {
        if ($computer.PartOfDomain) { throw 'This server is already domain joined; verify its domain before proceeding.' }
        Set-DnsClientServerAddress -InterfaceIndex $interface.InterfaceIndex -ServerAddresses '10.20.2.10','10.20.2.11'
        Resolve-DnsName "_ldap._tcp.dc._msdcs.$DomainName" -Type SRV -ErrorAction Stop | Out-Null
        $credential = Get-Credential -Message 'Enter a domain account authorized to join this server'
        Add-Computer -DomainName $DomainName -Credential $credential
        Write-Host 'Domain join configured. Restart this server before configuring CA or NPS.'
    }
    'ConfigureCA' {
        if (-not $computer.PartOfDomain -or $computer.Domain -ne $DomainName) { throw 'Join this server to the specified domain and restart first.' }
        $activeCA = Get-ItemPropertyValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -Name Active -ErrorAction SilentlyContinue
        if ($activeCA) { throw 'A CA is already configured; inspect it before making changes.' }
        Import-Module ADCSDeployment
        $caOptions = @{
            CAType = 'EnterpriseRootCA'
            CACommonName = $CACommonName
            CryptoProviderName = 'RSA#Microsoft Software Key Storage Provider'
            KeyLength = 3072
            HashAlgorithmName = 'SHA256'
            ValidityPeriod = 'Years'
            ValidityPeriodUnits = 10
            Force = $true
        }
        Install-AdcsCertificationAuthority @caOptions
        Write-Host 'CA configured. Set and validate AIA/CDP publication before issuing production certificates.'
        Write-Host 'Review certificate templates, enrollment permissions, renewal and protected CA backups.'
    }
    'RegisterNPS' {
        if (-not $computer.PartOfDomain -or $computer.Domain -ne $DomainName) { throw 'Join this server to the specified domain and restart first.' }
        & netsh nps add registeredserver $DomainName $expectedName
        if ($LASTEXITCODE) { throw 'NPS Active Directory registration failed.' }
        Set-Service -Name IAS -StartupType Automatic
        Start-Service -Name IAS
        Write-Host 'NPS registered. Complete RADIUS clients and policies in nps.msc.'
        Write-Host 'Obtain a server certificate from MSCA, choose EAP policy, and enter client secrets securely.'
        Write-Host 'Do not enable a broad allow-all network policy.'
    }
}
