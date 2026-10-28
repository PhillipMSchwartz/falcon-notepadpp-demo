<#
Prepare-DemoHost.ps1
Run once in an ELEVATED PowerShell on the Windows Server 2025 EC2 instance (RDP or Session Manager).

What it does
  1. Enables PowerShell remoting and a WinRM HTTPS listener (port 5986, self-signed cert; lab use)
  2. Opens the Windows firewall for 5986 (you still need an EC2 security group rule from AAP)
  3. Disables the Notepad++ auto-updater, if Notepad++ is installed
  4. Prints the installed Notepad++ version, hostname and IPs

You do not need to install the vulnerable Notepad++ by hand: the "Reset Notepad++ (demo)" job
template (playbooks/reset_notepadpp.yml) does that, and you run it before every take.

If Windows blocks the script:  Set-ExecutionPolicy -Scope Process Bypass
#>
$ErrorActionPreference = 'Stop'

Write-Host '== 1. WinRM over HTTPS =='
Enable-PSRemoting -Force -SkipNetworkProfileCheck
$existing = Get-ChildItem WSMan:\localhost\Listener | Where-Object { $_.Keys -contains 'Transport=HTTPS' }
if (-not $existing) {
    $cert = New-SelfSignedCertificate -DnsName $env:COMPUTERNAME -CertStoreLocation Cert:\LocalMachine\My -NotAfter (Get-Date).AddYears(2)
    New-Item -Path WSMan:\localhost\Listener -Transport HTTPS -Address * -CertificateThumbPrint $cert.Thumbprint -Force | Out-Null
}

Write-Host '== 2. Windows firewall =='
if (-not (Get-NetFirewallRule -DisplayName 'WinRM HTTPS (demo)' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName 'WinRM HTTPS (demo)' -Direction Inbound -Protocol TCP -LocalPort 5986 -Action Allow | Out-Null
}
Write-Host 'Reminder: the EC2 security group must allow WinRM from the AAP instance (5985, or 5986 for HTTPS).'

Write-Host '== 3. Notepad++ auto-updater =='
$nppDir = 'C:\Program Files\Notepad++'
$updater = Join-Path $nppDir 'updater'
if (Test-Path $updater) { Remove-Item $updater -Recurse -Force; Write-Host 'Updater removed.' }
else { Write-Host 'No updater folder found (already removed, or Notepad++ not installed).' }

Write-Host '== 4. This host =='
$k = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Notepad++'
$ver = if (Test-Path $k) { (Get-ItemProperty $k).DisplayVersion } else { 'not installed' }
Write-Host ('Notepad++: {0}' -f $ver)
Write-Host ('Hostname:  {0}' -f $env:COMPUTERNAME)
Write-Host ('IPs:       {0}' -f ((Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -notlike '169.*' | Where-Object IPAddress -ne '127.0.0.1').IPAddress -join ', '))
