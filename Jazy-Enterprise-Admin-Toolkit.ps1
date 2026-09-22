#requires -Version 5.1
<#
Jazy Enterprise IT Admin Toolkit
Version: 1.0
Purpose: Windows workstation/server diagnostics, identity checks, security checks,
         controlled repair actions, logging, and HTML reporting.

IMPORTANT:
- Test in a non-production environment first.
- Repair actions can modify system/network state and require confirmation.
- Some commands/features are unavailable on certain Windows editions or servers.
#>

$ErrorActionPreference = "Continue"
$ToolkitVersion = "1.0"
$ToolkitRoot = Join-Path $env:ProgramData "JazyAdminToolkit"
$LogDir = Join-Path $ToolkitRoot "Logs"
$ReportDir = Join-Path $ToolkitRoot "Reports"

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null

$SessionStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile = Join-Path $LogDir "JazyToolkit_$SessionStamp.log"

function Write-Log {
    param([string]$Message, [ValidateSet("INFO","WARN","ERROR","ACTION")] [string]$Level="INFO")
    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Add-Content -Path $LogFile -Value $line
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Pause-Toolkit {
    Write-Host ""
    [void](Read-Host "Press ENTER to return to the menu")
}

function Invoke-Safe {
    param([string]$Name, [scriptblock]$Script)
    Write-Log "Started: $Name"
    try {
        & $Script
        Write-Log "Completed: $Name"
    } catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        Write-Log "$Name failed: $($_.Exception.Message)" "ERROR"
    }
}

function Confirm-Change {
    param([string]$Action)
    Write-Host ""
    Write-Host "WARNING: This action can change the local system state." -ForegroundColor Yellow
    $answer = Read-Host "Run '$Action'? Type YES to continue"
    return ($answer -ceq "YES")
}

function Require-Admin {
    if (-not (Test-IsAdmin)) {
        Write-Host "This action requires an elevated PowerShell session." -ForegroundColor Yellow
        Write-Host "Right-click Windows Terminal/PowerShell and select Run as administrator."
        Write-Log "Blocked action because session was not elevated." "WARN"
        return $false
    }
    return $true
}

function Show-Header {
    Clear-Host
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $boot = $os.LastBootUpTime
    $uptime = if ($boot) { (Get-Date) - $boot } else { $null }
    $admin = if (Test-IsAdmin) {"YES"} else {"NO"}

    Write-Host "==================================================================" -ForegroundColor Cyan
    Write-Host "             JAZY ENTERPRISE IT ADMIN TOOLKIT v$ToolkitVersion" -ForegroundColor Cyan
    Write-Host "==================================================================" -ForegroundColor Cyan
    Write-Host (" Computer : {0}" -f $env:COMPUTERNAME)
    Write-Host (" User     : {0}\{1}" -f $env:USERDOMAIN,$env:USERNAME)
    Write-Host (" Domain   : {0}" -f $cs.Domain)
    Write-Host (" OS       : {0}" -f $os.Caption)
    if ($uptime) { Write-Host (" Uptime   : {0}d {1}h {2}m" -f $uptime.Days,$uptime.Hours,$uptime.Minutes) }
    Write-Host (" Elevated : {0}" -f $admin)
    Write-Host "==================================================================" -ForegroundColor Cyan
}

function Show-Menu {
    Show-Header
    Write-Host @"

 [ SYSTEM HEALTH ]                 [ NETWORK ]
  1. System Summary                 6. IP Configuration
  2. CPU / RAM                      7. Connectivity Test
  3. Disk / Volume Health           8. DNS Diagnostics
  4. Recent System Errors           9. Active Connections
  5. Windows Update Status         10. Network Adapters

 [ IDENTITY / DOMAIN ]             [ SECURITY ]
 11. Domain Information            17. Microsoft Defender Status
 12. Discover Domain Controller    18. Windows Firewall Status
 13. AD Secure Channel             19. BitLocker Status
 14. Entra / Domain Join Status    20. Failed Logon Events
 15. Group Policy Result           21. Local Administrators
 16. Current User / Groups         22. SMB Configuration

 [ CONTROLLED REPAIR ]             [ REPORTING ]
 23. GPUpdate /Force               30. Generate Full HTML Report
 24. Flush DNS                     31. Open Reports Folder
 25. SFC /ScanNow                  32. Open Logs Folder
 26. DISM ScanHealth
 27. DISM RestoreHealth
 28. Reset Winsock
 29. Reset TCP/IP

  0. Exit
"@
}

function Get-SystemSummary {
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $bios = Get-CimInstance Win32_BIOS
    [PSCustomObject]@{
        ComputerName = $env:COMPUTERNAME
        Manufacturer = $cs.Manufacturer
        Model = $cs.Model
        Domain = $cs.Domain
        PartOfDomain = $cs.PartOfDomain
        OS = $os.Caption
        Version = $os.Version
        Build = $os.BuildNumber
        BIOS = $bios.SMBIOSBIOSVersion
        LastBoot = $os.LastBootUpTime
    } | Format-List
}

function Get-CpuRam {
    $cpu = Get-CimInstance Win32_Processor
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    Write-Host "`nCPU" -ForegroundColor Cyan
    $cpu | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors,LoadPercentage | Format-Table -AutoSize
    [PSCustomObject]@{
        TotalRAM_GB = [math]::Round($cs.TotalPhysicalMemory/1GB,2)
        FreeRAM_GB = [math]::Round($os.FreePhysicalMemory*1KB/1GB,2)
        UsedRAM_GB = [math]::Round(($cs.TotalPhysicalMemory-($os.FreePhysicalMemory*1KB))/1GB,2)
    } | Format-List
}

function Get-DiskHealth {
    Write-Host "`nPhysical Disks" -ForegroundColor Cyan
    if (Get-Command Get-PhysicalDisk -ErrorAction SilentlyContinue) {
        Get-PhysicalDisk | Select-Object FriendlyName,MediaType,HealthStatus,OperationalStatus,
            @{N="SizeGB";E={[math]::Round($_.Size/1GB,2)}} | Format-Table -AutoSize
    }
    Write-Host "`nVolumes" -ForegroundColor Cyan
    Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" |
        Select-Object DeviceID,VolumeName,
        @{N="SizeGB";E={[math]::Round($_.Size/1GB,2)}},
        @{N="FreeGB";E={[math]::Round($_.FreeSpace/1GB,2)}},
        @{N="FreePct";E={if($_.Size){[math]::Round(($_.FreeSpace/$_.Size)*100,1)}}} |
        Format-Table -AutoSize
}

function Get-RecentSystemErrors {
    Get-WinEvent -FilterHashtable @{LogName='System'; Level=1,2; StartTime=(Get-Date).AddDays(-1)} -ErrorAction SilentlyContinue |
        Select-Object -First 30 TimeCreated,Id,ProviderName,LevelDisplayName,Message |
        Format-Table -Wrap
}

function Get-UpdateStatus {
    $svc = Get-Service wuauserv -ErrorAction SilentlyContinue
    Write-Host "Windows Update service:" $svc.Status
    Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 15 HotFixID,Description,InstalledOn | Format-Table -AutoSize
}

function Get-IPInfo {
    Get-NetIPConfiguration | Format-List InterfaceAlias,InterfaceDescription,IPv4Address,IPv6Address,IPv4DefaultGateway,DNSServer
}

function Test-Network {
    $targets = @("1.1.1.1","8.8.8.8","microsoft.com")
    foreach ($t in $targets) {
        Write-Host "`nTesting $t" -ForegroundColor Cyan
        Test-NetConnection $t -InformationLevel Detailed
    }
}

function Test-DNS {
    Write-Host "`nConfigured DNS servers" -ForegroundColor Cyan
    Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object {$_.ServerAddresses} |
        Select-Object InterfaceAlias,ServerAddresses | Format-Table -AutoSize
    Write-Host "`nResolution test" -ForegroundColor Cyan
    Resolve-DnsName microsoft.com -ErrorAction Continue
}

function Get-Connections {
    Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
        Sort-Object RemoteAddress |
        Select-Object -First 50 LocalAddress,LocalPort,RemoteAddress,RemotePort,OwningProcess |
        Format-Table -AutoSize
}

function Get-Adapters {
    Get-NetAdapter | Select-Object Name,InterfaceDescription,Status,LinkSpeed,MacAddress | Format-Table -AutoSize
}

function Get-DomainInfo {
    Get-CimInstance Win32_ComputerSystem | Select-Object Name,Domain,PartOfDomain,Workgroup,UserName | Format-List
}

function Get-DC {
    if ((Get-CimInstance Win32_ComputerSystem).PartOfDomain) {
        nltest /dsgetdc:$env:USERDNSDOMAIN
    } else { Write-Host "Computer is not joined to an Active Directory domain." -ForegroundColor Yellow }
}

function Test-SecureChannel {
    if ((Get-CimInstance Win32_ComputerSystem).PartOfDomain) {
        Test-ComputerSecureChannel -Verbose
    } else { Write-Host "Computer is not joined to an Active Directory domain." -ForegroundColor Yellow }
}

function Get-JoinStatus { dsregcmd /status }
function Get-GPResult { gpresult /r }
function Get-UserGroups { whoami /all }

function Get-Defender {
    if (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue) {
        Get-MpComputerStatus | Select-Object AMServiceEnabled,AntivirusEnabled,AntispywareEnabled,
            RealTimeProtectionEnabled,BehaviorMonitorEnabled,IoavProtectionEnabled,
            AntivirusSignatureLastUpdated,QuickScanAge,FullScanAge | Format-List
    } else { Write-Host "Microsoft Defender cmdlets are not available on this system." -ForegroundColor Yellow }
}

function Get-Firewall {
    Get-NetFirewallProfile | Select-Object Name,Enabled,DefaultInboundAction,DefaultOutboundAction | Format-Table -AutoSize
}

function Get-BitLocker {
    if (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue) {
        Get-BitLockerVolume | Select-Object MountPoint,VolumeStatus,ProtectionStatus,EncryptionPercentage,EncryptionMethod | Format-Table -AutoSize
    } else { Write-Host "BitLocker cmdlets are not available on this system." -ForegroundColor Yellow }
}

function Get-FailedLogons {
    try {
        Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4625; StartTime=(Get-Date).AddDays(-1)} -ErrorAction Stop |
            Select-Object -First 25 TimeCreated,Id,Message | Format-Table -Wrap
    } catch {
        Write-Host "Unable to read Security log. Run elevated and verify audit logging is enabled." -ForegroundColor Yellow
    }
}

function Get-LocalAdmins {
    if (Get-Command Get-LocalGroupMember -ErrorAction SilentlyContinue) {
        Get-LocalGroupMember -Group "Administrators" | Select-Object Name,ObjectClass,PrincipalSource | Format-Table -AutoSize
    } else {
        net localgroup administrators
    }
}

function Get-SMBInfo {
    if (Get-Command Get-SmbServerConfiguration -ErrorAction SilentlyContinue) {
        Get-SmbServerConfiguration | Select-Object EnableSMB1Protocol,EnableSMB2Protocol,RequireSecuritySignature,EnableSecuritySignature | Format-List
    } else { Write-Host "SMB Server configuration cmdlets unavailable." -ForegroundColor Yellow }
}

function Invoke-ControlledAction {
    param([string]$Name,[scriptblock]$Script)
    if (-not (Require-Admin)) { return }
    if (Confirm-Change $Name) {
        Write-Log "User approved repair action: $Name" "ACTION"
        Invoke-Safe $Name $Script
    } else {
        Write-Host "Cancelled." -ForegroundColor Yellow
        Write-Log "User cancelled repair action: $Name" "INFO"
    }
}

function Convert-Section {
    param([string]$Title, $Data)
    try {
        $fragment = $Data | ConvertTo-Html -Fragment
        return "<h2>$Title</h2>$fragment"
    } catch {
        return "<h2>$Title</h2><pre>$($_ | Out-String)</pre>"
    }
}

function New-FullReport {
    $report = Join-Path $ReportDir "Jazy_Diagnostic_$SessionStamp.html"
    Write-Host "Collecting diagnostic data..." -ForegroundColor Cyan
    Write-Log "Generating HTML diagnostic report." "ACTION"

    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $bios = Get-CimInstance Win32_BIOS
    $cpu = Get-CimInstance Win32_Processor
    $disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" |
        Select-Object DeviceID,VolumeName,@{N="SizeGB";E={[math]::Round($_.Size/1GB,2)}},
        @{N="FreeGB";E={[math]::Round($_.FreeSpace/1GB,2)}},
        @{N="FreePct";E={if($_.Size){[math]::Round(($_.FreeSpace/$_.Size)*100,1)}}}
    $net = Get-NetIPConfiguration -ErrorAction SilentlyContinue |
        Select-Object InterfaceAlias,InterfaceDescription,
        @{N="IPv4";E={($_.IPv4Address.IPAddress -join ", ")}},
        @{N="Gateway";E={($_.IPv4DefaultGateway.NextHop -join ", ")}}
    $fw = Get-NetFirewallProfile -ErrorAction SilentlyContinue |
        Select-Object Name,Enabled,DefaultInboundAction,DefaultOutboundAction
    $events = Get-WinEvent -FilterHashtable @{LogName='System';Level=1,2;StartTime=(Get-Date).AddDays(-1)} -ErrorAction SilentlyContinue |
        Select-Object -First 25 TimeCreated,Id,ProviderName,LevelDisplayName,Message
    $hotfix = Get-HotFix -ErrorAction SilentlyContinue | Sort-Object InstalledOn -Descending |
        Select-Object -First 15 HotFixID,Description,InstalledOn

    $summary = [PSCustomObject]@{
        Computer = $env:COMPUTERNAME
        User = "$env:USERDOMAIN\$env:USERNAME"
        Domain = $cs.Domain
        PartOfDomain = $cs.PartOfDomain
        Manufacturer = $cs.Manufacturer
        Model = $cs.Model
        OS = $os.Caption
        OSVersion = $os.Version
        Build = $os.BuildNumber
        LastBoot = $os.LastBootUpTime
        BIOS = $bios.SMBIOSBIOSVersion
        TotalRAM_GB = [math]::Round($cs.TotalPhysicalMemory/1GB,2)
        Generated = Get-Date
    }

    $sections = @()
    $sections += Convert-Section "System Summary" $summary
    $sections += Convert-Section "Processor" ($cpu | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors,LoadPercentage)
    $sections += Convert-Section "Disk Capacity" $disks
    $sections += Convert-Section "Network" $net
    $sections += Convert-Section "Firewall Profiles" $fw
    $sections += Convert-Section "Recent Windows Updates" $hotfix
    $sections += Convert-Section "Recent Critical / Error System Events" $events

    if (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue) {
        $def = Get-MpComputerStatus | Select-Object AntivirusEnabled,RealTimeProtectionEnabled,BehaviorMonitorEnabled,AntivirusSignatureLastUpdated
        $sections += Convert-Section "Microsoft Defender" $def
    }

    $css = @"
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:32px;background:#f5f7fa;color:#17202a}
.header{background:#101827;color:white;padding:24px;border-radius:10px}
h1{margin:0} h2{margin-top:30px;color:#123b63}
table{border-collapse:collapse;width:100%;background:white;margin-top:10px}
th,td{border:1px solid #d7dde5;padding:8px;text-align:left;vertical-align:top}
th{background:#e9eef5}
.meta{opacity:.8;margin-top:6px}
.footer{margin-top:30px;font-size:12px;color:#667}
</style>
"@

    $html = @"
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Jazy Enterprise IT Diagnostic Report</title>$css</head>
<body>
<div class="header"><h1>Jazy Enterprise IT Diagnostic Report</h1>
<div class="meta">$($env:COMPUTERNAME) | Generated $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")</div></div>
$($sections -join "`n")
<div class="footer">Generated by Jazy Enterprise IT Admin Toolkit v$ToolkitVersion. Review findings before making production changes.</div>
</body></html>
"@

    Set-Content -Path $report -Value $html -Encoding UTF8
    Write-Log "HTML report generated: $report"
    Write-Host "`nReport created:" -ForegroundColor Green
    Write-Host $report
    Start-Process $report
}

Write-Log "Toolkit session started. Elevated=$(Test-IsAdmin)"

do {
    Show-Menu
    $choice = Read-Host "Select an option"

    switch ($choice) {
        "1"  { Invoke-Safe "System Summary" { Get-SystemSummary }; Pause-Toolkit }
        "2"  { Invoke-Safe "CPU / RAM" { Get-CpuRam }; Pause-Toolkit }
        "3"  { Invoke-Safe "Disk / Volume Health" { Get-DiskHealth }; Pause-Toolkit }
        "4"  { Invoke-Safe "Recent System Errors" { Get-RecentSystemErrors }; Pause-Toolkit }
        "5"  { Invoke-Safe "Windows Update Status" { Get-UpdateStatus }; Pause-Toolkit }
        "6"  { Invoke-Safe "IP Configuration" { Get-IPInfo }; Pause-Toolkit }
        "7"  { Invoke-Safe "Connectivity Test" { Test-Network }; Pause-Toolkit }
        "8"  { Invoke-Safe "DNS Diagnostics" { Test-DNS }; Pause-Toolkit }
        "9"  { Invoke-Safe "Active Connections" { Get-Connections }; Pause-Toolkit }
        "10" { Invoke-Safe "Network Adapters" { Get-Adapters }; Pause-Toolkit }
        "11" { Invoke-Safe "Domain Information" { Get-DomainInfo }; Pause-Toolkit }
        "12" { Invoke-Safe "Domain Controller Discovery" { Get-DC }; Pause-Toolkit }
        "13" { Invoke-Safe "AD Secure Channel" { Test-SecureChannel }; Pause-Toolkit }
        "14" { Invoke-Safe "Entra / Domain Join Status" { Get-JoinStatus }; Pause-Toolkit }
        "15" { Invoke-Safe "Group Policy Result" { Get-GPResult }; Pause-Toolkit }
        "16" { Invoke-Safe "Current User / Groups" { Get-UserGroups }; Pause-Toolkit }
        "17" { Invoke-Safe "Microsoft Defender Status" { Get-Defender }; Pause-Toolkit }
        "18" { Invoke-Safe "Windows Firewall Status" { Get-Firewall }; Pause-Toolkit }
        "19" { Invoke-Safe "BitLocker Status" { Get-BitLocker }; Pause-Toolkit }
        "20" { Invoke-Safe "Failed Logon Events" { Get-FailedLogons }; Pause-Toolkit }
        "21" { Invoke-Safe "Local Administrators" { Get-LocalAdmins }; Pause-Toolkit }
        "22" { Invoke-Safe "SMB Configuration" { Get-SMBInfo }; Pause-Toolkit }

        "23" { Invoke-ControlledAction "GPUpdate /Force" { gpupdate /force }; Pause-Toolkit }
        "24" { Invoke-ControlledAction "Flush DNS Client Cache" { Clear-DnsClientCache; Write-Host "DNS cache cleared." -ForegroundColor Green }; Pause-Toolkit }
        "25" { Invoke-ControlledAction "SFC /ScanNow" { sfc /scannow }; Pause-Toolkit }
        "26" { Invoke-ControlledAction "DISM ScanHealth" { DISM.exe /Online /Cleanup-Image /ScanHealth }; Pause-Toolkit }
        "27" { Invoke-ControlledAction "DISM RestoreHealth" { DISM.exe /Online /Cleanup-Image /RestoreHealth }; Pause-Toolkit }
        "28" { Invoke-ControlledAction "Reset Winsock" { netsh winsock reset; Write-Host "A restart may be required." -ForegroundColor Yellow }; Pause-Toolkit }
        "29" { Invoke-ControlledAction "Reset TCP/IP" { netsh int ip reset; Write-Host "A restart may be required." -ForegroundColor Yellow }; Pause-Toolkit }

        "30" { Invoke-Safe "Generate Full HTML Report" { New-FullReport }; Pause-Toolkit }
        "31" { Start-Process $ReportDir }
        "32" { Start-Process $LogDir }

        "0"  { Write-Log "Toolkit session closed."; Write-Host "Closing toolkit..." -ForegroundColor Cyan }
        default { Write-Host "Invalid option." -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
    }
} while ($choice -ne "0")
