<#
rebuild.ps1 - rebuilds the Falcon + AAP Notepad++ demo after the CloudFormation stack (demo-stack.json) is up.

Run from Windows PowerShell on your laptop, in this folder:
    .\rebuild.ps1 -AapIp <AapPublicIp output of the stack>

What it does (each stage is safe to re-run; -Stage runs just one):
  Host       create the 'ansible' user, install ansible-core, upload + unpack the AAP 2.7 bundle
  Install    write the installer inventory for the new hostname and run the AAP containerized install (30-60 min)
  Mock       install the mock Falcon service on port 9080
  Configure  create every AAP object (credentials, project, inventory, job templates, EDA project,
             credentials, Event Stream, rulebook activation) and the fire-demo-event settings
  Verify     wait for Windows, run Reset, fire one event end to end, check it remediates, reset again

Inputs, all in the kit folder (default: Documents\falcon-aap-demo-rebuild):
  aap-bundle-2.7-11.tar (+ .sha256)          the offline AAP installer, saved from the original lab
  secrets\inventory-growth.orig              the original installer inventory (holds the install passwords)
  secrets\manifest_*.zip                     AAP subscription manifest
  secrets\pms-aaponaws-1026.pem              SSH key for the AAP host
  secrets\falcon-demo-token                  Event Stream token
  secrets\rebuild-secrets.psd1               WindowsAdminPassword (created on first run; fill it in)
#>
param(
    [Parameter(Mandatory = $true)][string]$AapIp,
    [ValidateSet('All', 'Host', 'Install', 'Mock', 'Configure', 'Verify')][string]$Stage = 'All',
    [string]$KitDir = (Join-Path $env:USERPROFILE 'Documents\falcon-aap-demo-rebuild'),
    [string]$AapHost = '',
    [switch]$SkipEndToEnd
)
$ErrorActionPreference = 'Stop'
$OutputEncoding = New-Object System.Text.UTF8Encoding $false

$Bundle      = 'ansible-automation-platform-containerized-setup-bundle-2.7-11-x86_64'
$OldHost     = 'ec2-18-216-91-202.us-east-2.compute.amazonaws.com'
$AapPrivIp   = '172.31.2.66'
$WinPrivIp   = '172.31.12.7'
$RepoUrl     = 'https://github.com/PhillipMSchwartz/falcon-notepadpp-demo.git'
$RawBase     = 'https://raw.githubusercontent.com/PhillipMSchwartz/falcon-notepadpp-demo/main'
$SecretsDir  = Join-Path $KitDir 'secrets'

function Say($msg) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg) -ForegroundColor Cyan }
function Fail($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------- secrets and key
$SecretsFile = Join-Path $SecretsDir 'rebuild-secrets.psd1'
if (-not (Test-Path $SecretsFile)) {
    @"
@{
    # Same value you typed for the WindowsAdminPassword parameter of the CloudFormation stack.
    WindowsAdminPassword = ''
    # Optional: AAP admin password. Leave empty to keep the one in inventory-growth.orig.
    AapAdminPassword     = ''
}
"@ | Set-Content -Encoding UTF8 $SecretsFile
    Fail "Created $SecretsFile. Fill in WindowsAdminPassword, then run this script again."
}
$Secrets = Import-PowerShellDataFile $SecretsFile
if (-not $Secrets.WindowsAdminPassword) { Fail "WindowsAdminPassword is empty in $SecretsFile" }

$InvOrig = Join-Path $SecretsDir 'inventory-growth.orig'
if (-not (Test-Path $InvOrig)) { Fail "Missing $InvOrig" }
$InvText = Get-Content -Raw $InvOrig
$AdminPw = $Secrets.AapAdminPassword
if (-not $AdminPw) {
    $m = [regex]::Match($InvText, '(?m)^gateway_admin_password=(.*)$')
    if (-not $m.Success) { Fail 'gateway_admin_password not found in inventory-growth.orig' }
    $AdminPw = $m.Groups[1].Value.Trim().Trim("'").Trim('"')
}
$TokenFile = Join-Path $SecretsDir 'falcon-demo-token'
if (-not (Test-Path $TokenFile)) { Fail "Missing $TokenFile" }
$Token = (Get-Content -Raw $TokenFile).Trim()

$KeySrc = Get-ChildItem $SecretsDir -Filter '*.pem' | Select-Object -First 1
if (-not $KeySrc) { Fail "No .pem key in $SecretsDir" }
$KeyDir = Join-Path $env:TEMP 'aapdemo-rebuild'
New-Item -ItemType Directory -Force $KeyDir | Out-Null
$Key = Join-Path $KeyDir 'key.pem'
Copy-Item $KeySrc.FullName $Key -Force
icacls $Key /inheritance:r /grant:r "$($env:USERNAME):R" | Out-Null

$Ssh = @('-i', $Key, '-o', 'StrictHostKeyChecking=accept-new', '-o', 'UserKnownHostsFile=' + (Join-Path $KeyDir 'known_hosts'), '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', '-o', 'ServerAliveInterval=30')
$Target = "ec2-user@$AapIp"

function Remote([string]$script) {
    # Runs a bash script on the AAP host. Sent as base64 because Windows PowerShell 5.1 adds CRLF and a BOM
    # to anything piped into a native command.
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($script -replace "`r", '')))
    & ssh @Ssh $Target "echo $b64 | base64 -d | bash"
    if ($LASTEXITCODE -ne 0) { Fail "remote step failed (exit $LASTEXITCODE)" }
}
function RemoteOut([string]$script) {
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($script -replace "`r", '')))
    return ((& ssh @Ssh $Target "echo $b64 | base64 -d | bash") -join "`n").Trim()
}
function Upload([string]$local, [string]$remote) {
    & scp @Ssh -q $local "${Target}:$remote"
    if ($LASTEXITCODE -ne 0) { Fail "upload of $local failed" }
}

# ---------------------------------------------------------------- wait for SSH, learn the public hostname
Say "Waiting for SSH on $AapIp ..."
$ok = $false
for ($i = 0; $i -lt 60; $i++) { & ssh @Ssh $Target 'true' 2>$null; if ($LASTEXITCODE -eq 0) { $ok = $true; break }; Start-Sleep 10 }
if (-not $ok) { Fail "no SSH to $AapIp after 10 minutes (check the stack, MyIp and the key)" }
if (-not $AapHost) {
    $AapHost = RemoteOut 'T=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60"); curl -s -H "X-aws-ec2-metadata-token: $T" http://169.254.169.254/latest/meta-data/public-hostname'
}
if (-not $AapHost) { Fail 'could not read the public hostname from instance metadata' }
$Base = "https://$AapHost"
Say "AAP host: $AapHost"

# ---------------------------------------------------------------- Host
function Stage-Host {
    Say 'Host: ansible user, packages'
    Remote @'
set -euo pipefail
id ansible >/dev/null 2>&1 || sudo useradd -m ansible
echo 'ansible ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/ansible >/dev/null
sudo chmod 440 /etc/sudoers.d/ansible
sudo loginctl enable-linger ansible
sudo dnf install -y -q ansible-core tar >/dev/null
echo host-ready
'@
    $have = (& ssh @Ssh $Target "sudo test -d /home/ansible/$Bundle/bundle && echo yes || echo no").Trim()
    if ($have -eq 'yes') { Say 'Host: bundle already unpacked'; return }
    $tar = Join-Path $KitDir 'aap-bundle-2.7-11.tar'
    if (-not (Test-Path $tar)) { Fail "Missing $tar" }
    Say 'Host: uploading the 4 GB AAP bundle (this takes a while) ...'
    Upload $tar '/var/tmp/aap-bundle-2.7-11.tar'
    $sum = ((Get-Content (Join-Path $KitDir 'aap-bundle-2.7-11.tar.sha256')) -split '\s+')[0]
    Remote @"
set -euo pipefail
echo '$sum  /var/tmp/aap-bundle-2.7-11.tar' | sha256sum -c --quiet
sudo tar -C /home/ansible -xf /var/tmp/aap-bundle-2.7-11.tar
sudo chown -R ansible:ansible /home/ansible/$Bundle
rm -f /var/tmp/aap-bundle-2.7-11.tar
echo unpacked
"@
}

# ---------------------------------------------------------------- Install
function Stage-Install {
    Say 'Install: inventory for the new hostname + subscription manifest'
    $inv = $InvText.Replace($OldHost, $AapHost) -replace "`r", ''
    $inv = [regex]::Replace($inv, '(?m)^gateway_admin_password=.*$', "gateway_admin_password='$AdminPw'")
    if ($inv -notmatch '(?m)^controller_license_file=') { $inv = $inv.TrimEnd() + "`ncontroller_license_file=/home/ansible/manifest.zip`n" }
    $tmp = Join-Path $KeyDir 'inventory-growth'
    [IO.File]::WriteAllText($tmp, $inv, (New-Object System.Text.UTF8Encoding $false))
    $manifest = Get-ChildItem $SecretsDir -Filter 'manifest_*.zip' | Select-Object -First 1
    if (-not $manifest) { Fail "No manifest_*.zip in $SecretsDir" }
    Upload $tmp '/var/tmp/inventory-growth'
    Upload $manifest.FullName '/var/tmp/manifest.zip'
    Remove-Item $tmp
    Remote @"
set -euo pipefail
sudo install -m 600 -o ansible -g ansible /var/tmp/inventory-growth /home/ansible/$Bundle/inventory-growth
sudo install -m 600 -o ansible -g ansible /var/tmp/manifest.zip /home/ansible/manifest.zip
rm -f /var/tmp/inventory-growth /var/tmp/manifest.zip
sudo rm -f /home/ansible/install.rc
sudo -iu ansible bash -c 'cd ~/$Bundle && nohup bash -c "ansible-playbook -i inventory-growth ansible.containerized_installer.install > ~/install.log 2>&1; echo \`$? > ~/install.rc" >/dev/null 2>&1 &'
echo started
"@
    Say 'Install: AAP installer running on the host (30-60 min). Progress: ~ansible/install.log'
    for ($i = 0; $i -lt 120; $i++) {
        Start-Sleep 60
        $rc = (& ssh @Ssh $Target 'sudo cat /home/ansible/install.rc 2>/dev/null || echo running').Trim()
        if ($rc -ne 'running') { break }
        if ($i % 5 -eq 4) { Say ("Install: still running ({0} min) - {1}" -f ($i + 1), ((& ssh @Ssh $Target "sudo grep -E '^TASK' /home/ansible/install.log | tail -n 1") -join '')) }
    }
    if ($rc -ne '0') {
        & ssh @Ssh $Target 'sudo tail -n 40 /home/ansible/install.log'
        Fail "AAP install did not succeed (rc=$rc)"
    }
    Say 'Install: AAP is installed'
}

# ---------------------------------------------------------------- Mock
function Stage-Mock {
    Say 'Mock: installing mock Falcon on port 9080'
    Remote @"
set -euo pipefail
R=$RawBase/mock
sudo mkdir -p /opt/mock-falcon
sudo curl -fsSL -o /opt/mock-falcon/mock_falcon.py `$R/mock_falcon.py
sudo curl -fsSL -o /opt/mock-falcon/send_falcon_event.py `$R/send_falcon_event.py
sudo curl -fsSL -o /etc/systemd/system/mock-falcon.service `$R/mock-falcon.service
sudo curl -fsSL -o /usr/local/bin/fire-demo-event `$R/fire_demo_event.sh
sudo chmod 755 /usr/local/bin/fire-demo-event
sudo systemctl daemon-reload
sudo systemctl enable --now mock-falcon
sudo systemctl restart mock-falcon
sleep 2
curl -sf -X POST http://${AapPrivIp}:9080/oauth2/token >/dev/null && echo mock-ok
"@
    $tmp = Join-Path $KeyDir 'tok'
    [IO.File]::WriteAllText($tmp, $Token, (New-Object System.Text.UTF8Encoding $false))
    Upload $tmp '.falcon-demo-token'
    Remove-Item $tmp
    & ssh @Ssh $Target 'chmod 600 ~/.falcon-demo-token'
}

# ---------------------------------------------------------------- AAP API helpers
add-type @"
using System.Net; using System.Security.Cryptography.X509Certificates;
public class TrustAllCerts : ICertificatePolicy { public bool CheckValidationResult(ServicePoint s, X509Certificate c, WebRequest r, int p) { return true; } }
"@ -ErrorAction SilentlyContinue
[Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCerts
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Auth = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("admin:$AdminPw")) }

function Api([string]$method, [string]$path, $body = $null) {
    $p = @{ Uri = "$Base$path"; Method = $method; Headers = $Auth; ContentType = 'application/json'; TimeoutSec = 120 }
    if ($null -ne $body) { $p.Body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $body -Depth 12)) }
    try { Invoke-RestMethod @p }
    catch {
        $detail = ''
        if ($_.Exception.Response) { $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream()); $detail = $sr.ReadToEnd() }
        Fail "$method $path -> $($_.Exception.Message) $detail"
    }
}
function Find([string]$path, [string]$name) {
    $r = Api GET ("{0}?name={1}" -f $path, [Uri]::EscapeDataString($name))
    if ($r.results -and $r.results.Count -gt 0) { return $r.results[0] }
    return $null
}
function Ensure([string]$path, [string]$name, [hashtable]$body, [switch]$CreateOnly) {
    $body.name = $name
    $o = Find $path $name
    if ($o) {
        if ($CreateOnly) { Say "  keep    $name"; return $o }
        Say "  update  $name"; return (Api PATCH "$path$($o.id)/" $body)
    }
    Say "  create  $name"; return (Api POST $path $body)
}
function WaitFor([string]$what, [scriptblock]$check, [int]$minutes = 15) {
    for ($i = 0; $i -lt ($minutes * 6); $i++) { $v = & $check; if ($v) { return $v }; Start-Sleep 10 }
    Fail "timed out waiting for $what"
}
function WaitJob([string]$path) {
    $j = WaitFor "job $path" { $x = Api GET $path; if ($x.status -in 'successful', 'failed', 'error', 'canceled') { $x } } 20
    return $j
}

# ---------------------------------------------------------------- Configure
function Stage-Configure {
    $C = '/api/controller/v2/'; $E = '/api/eda/v1/'
    Say "Configure: waiting for the AAP API at $Base"
    WaitFor 'AAP API' { try { (Invoke-RestMethod -Uri "$Base/api/gateway/v1/ping/" -TimeoutSec 15).status -eq 'good' } catch { $false } } 20 | Out-Null
    $org = (Find "${C}organizations/" 'Default').id
    $eeId = (Find "${C}execution_environments/" 'Default execution environment').id

    Say 'Configure: Automation Controller'
    $ct = Ensure "${C}credential_types/" 'Falcon API (demo)' @{
        kind = 'cloud'; description = 'Injects Falcon API settings as env vars (lab uses mock_falcon.py)'
        inputs = @{ fields = @(
                @{ id = 'base_url'; type = 'string'; label = 'Falcon API base URL'; help_text = 'Lab: http://<mock host>:9080   Real: your Falcon cloud API URL' },
                @{ id = 'client_id'; type = 'string'; label = 'API client ID' },
                @{ id = 'client_secret'; type = 'string'; label = 'API client secret'; secret = $true }); required = @('base_url', 'client_id', 'client_secret') }
        injectors = @{ env = @{ FALCON_API_BASE = '{{ base_url }}'; FALCON_CLIENT_ID = '{{ client_id }}'; FALCON_CLIENT_SECRET = '{{ client_secret }}' } }
    } -CreateOnly
    $falconCred = Ensure "${C}credentials/" 'Falcon API (demo)' @{ organization = $org; credential_type = $ct.id; description = 'Points at mock_falcon.py on the AAP host'
        inputs = @{ base_url = "http://${AapPrivIp}:9080"; client_id = 'demo'; client_secret = 'demo' } }
    $machineType = (Api GET "${C}credential_types/?namespace=ssh").results[0].id
    $winCred = Ensure "${C}credentials/" 'Windows Host' @{ organization = $org; credential_type = $machineType
        inputs = @{ username = 'Administrator'; password = $Secrets.WindowsAdminPassword } }

    $proj = Ensure "${C}projects/" 'Falcon Notepad++ Demo' @{ organization = $org; scm_type = 'git'; scm_url = $RepoUrl; scm_branch = 'main'
        scm_update_on_launch = $true; scm_clean = $true; default_environment = $eeId; description = 'Falcon + AAP Notepad++ remediation demo' }
    Api POST "${C}projects/$($proj.id)/update/" @{} | Out-Null
    WaitFor 'project sync' { $p = Api GET "${C}projects/$($proj.id)/"; if ($p.status -eq 'successful') { $p } elseif ($p.status -in 'failed', 'error') { Fail 'project sync failed' } } | Out-Null

    $inv = Ensure "${C}inventories/" 'Windows Endpoints' @{ organization = $org; description = 'Falcon Notepad++ demo targets' }
    $grp = Find "${C}inventories/$($inv.id)/groups/" 'windows_endpoints'
    $grpVars = "ansible_connection: winrm`nansible_port: 5985`nansible_winrm_transport: ntlm`nansible_winrm_scheme: http`nansible_winrm_message_encryption: always`n"
    if ($grp) { Api PATCH "${C}groups/$($grp.id)/" @{ variables = $grpVars } | Out-Null } else { $grp = Api POST "${C}inventories/$($inv.id)/groups/" @{ name = 'windows_endpoints'; variables = $grpVars } }
    $h = Find "${C}inventories/$($inv.id)/hosts/" 'WS-0142'
    if ($h) { Api PATCH "${C}hosts/$($h.id)/" @{ variables = "ansible_host: $WinPrivIp`n" } | Out-Null } else { Api POST "${C}groups/$($grp.id)/hosts/" @{ name = 'WS-0142'; inventory = $inv.id; variables = "ansible_host: $WinPrivIp`n" } | Out-Null }

    $jtR = Ensure "${C}job_templates/" 'Remediate Notepad++ CVE' @{ job_type = 'run'; inventory = $inv.id; project = $proj.id; playbook = 'playbooks/remediate_notepadpp.yml'
        ask_limit_on_launch = $true; ask_variables_on_launch = $true; extra_vars = "cve_id: DEMO-CVE-0001`n"; execution_environment = $eeId
        description = 'Updates Notepad++ to the fixed build and confirms the Falcon finding closes' }
    $jtS = Ensure "${C}job_templates/" 'Reset Notepad++ (demo)' @{ job_type = 'run'; inventory = $inv.id; project = $proj.id; playbook = 'playbooks/reset_notepadpp.yml'
        execution_environment = $eeId; description = 'Reinstalls the vulnerable Notepad++ build between demo takes' }
    foreach ($jt in @($jtR, $jtS)) {
        $have = (Api GET "${C}job_templates/$($jt.id)/credentials/").results | ForEach-Object { $_.id }
        foreach ($cid in @($winCred.id, $falconCred.id)) { if ($have -notcontains $cid) { Api POST "${C}job_templates/$($jt.id)/credentials/" @{ id = $cid } | Out-Null } }
    }

    Say 'Configure: Event-Driven Ansible'
    $ep = Ensure "${E}projects/" 'Falcon Notepad++ Demo' @{ organization_id = $org; url = $RepoUrl; scm_branch = 'main'; description = 'Rulebooks for the Falcon + AAP demo' } -CreateOnly
    WaitFor 'EDA project import' { $p = Api GET "${E}projects/$($ep.id)/"; if ($p.import_state -eq 'completed') { $p } elseif ($p.import_state -eq 'failed') { Fail "EDA project import failed: $($p.import_error)" } } | Out-Null
    $rb = WaitFor 'rulebook' { (Api GET "${E}rulebooks/?project_id=$($ep.id)").results | Where-Object { $_.name -eq 'falcon_events.yml' } | Select-Object -First 1 }
    $src = (Api GET "${E}rulebooks/$($rb.id)/sources/").results[0]
    $aapType = Find "${E}credential-types/" 'Red Hat Ansible Automation Platform'
    $tokType = Find "${E}credential-types/" 'Token Event Stream'
    $aapCred = Ensure "${E}eda-credentials/" 'AAP ( EDA Demo )' @{ organization_id = $org; credential_type_id = $aapType.id
        inputs = @{ host = "$Base/api/controller/"; username = 'admin'; password = $AdminPw; verify_ssl = $false } } -CreateOnly
    $tokCred = Ensure "${E}eda-credentials/" 'Falcon Webhook Token (demo)' @{ organization_id = $org; credential_type_id = $tokType.id
        inputs = @{ auth_type = 'token'; token = $Token; http_header_key = 'Authorization' } } -CreateOnly
    $es = Ensure "${E}event-streams/" 'falcon-spotlight-stream' @{ organization_id = $org; eda_credential_id = $tokCred.id; test_mode = $false } -CreateOnly
    $de = Find "${E}decision-environments/" 'Hub Default Decision Environment'
    $mapping = "- source_name: $($src.name)`n  event_stream_id: $($es.id)`n  event_stream_name: $($es.name)`n  rulebook_hash: $($src.rulebook_hash)`n"
    $act = Ensure "${E}activations/" 'falcon-spotlight-events' @{ description = 'Falcon Notepad++ findings -> Remediate Notepad++ CVE'
        organization_id = $org; project_id = $ep.id; rulebook_id = $rb.id; decision_environment_id = $de.id; eda_credentials = @($aapCred.id)
        source_mappings = $mapping; restart_policy = 'always'; log_level = 'info'; is_enabled = $true } -CreateOnly
    WaitFor 'activation Running' { $a = Api GET "${E}activations/$($act.id)/"; if ($a.status -eq 'running') { $a } elseif ($a.status -in 'error', 'failed') { Fail "activation failed: $($a.status_message)" } } 20 | Out-Null

    $esUrl = (Api GET "${E}event-streams/$($es.id)/").url
    Say "Configure: Event Stream URL $esUrl"
    Remote @"
printf 'EDA_URL=%s\nMOCK_URL=%s\n' '$esUrl' 'http://${AapPrivIp}:9080' | sudo tee /etc/falcon-demo.env >/dev/null
echo env-written
"@
}

# ---------------------------------------------------------------- Verify
function Run-Template([string]$name, [hashtable]$body) {
    $jt = Find '/api/controller/v2/job_templates/' $name
    $l = Api POST "/api/controller/v2/job_templates/$($jt.id)/launch/" $body
    $j = WaitJob "/api/controller/v2/jobs/$($l.id)/"
    Say "  $name -> job $($j.id) $($j.status)"
    if ($j.status -ne 'successful') { Fail "$name failed; see $Base/execution/jobs/playbook/$($j.id)/output" }
    return $j
}
function Stage-Verify {
    $C = '/api/controller/v2/'
    Say 'Verify: waiting for WinRM on the Windows host (first boot can take 10 minutes)'
    $inv = Find "${C}inventories/" 'Windows Endpoints'; $cred = Find "${C}credentials/" 'Windows Host'
    WaitFor 'Windows WinRM' {
        $a = Api POST "${C}inventories/$($inv.id)/ad_hoc_commands/" @{ module_name = 'win_ping'; limit = 'WS-0142'; credential = $cred.id }
        $r = WaitJob "${C}ad_hoc_commands/$($a.id)/"
        if ($r.status -eq 'successful') { $r }
    } 20 | Out-Null
    Run-Template 'Reset Notepad++ (demo)' @{} | Out-Null
    if ($SkipEndToEnd) { return }
    Say 'Verify: firing one event end to end'
    $before = (Api GET "${C}jobs/?order_by=-id&page_size=1").results[0].id
    & ssh @Ssh $Target 'fire-demo-event'
    if ($LASTEXITCODE -ne 0) { Fail 'fire-demo-event failed' }
    $job = WaitFor 'EDA-launched remediation job' { (Api GET "${C}jobs/?order_by=-id&page_size=1&name=Remediate%20Notepad%2B%2B%20CVE").results | Where-Object { $_.id -gt $before } | Select-Object -First 1 } 3
    $j = WaitJob "${C}jobs/$($job.id)/"
    Say "  Remediate Notepad++ CVE (launched by EDA) -> job $($j.id) $($j.status)"
    if ($j.status -ne 'successful') { Fail "remediation failed; see $Base/execution/jobs/playbook/$($j.id)/output" }
    Say 'Verify: resetting for the demo'
    Run-Template 'Reset Notepad++ (demo)' @{} | Out-Null
}

# ---------------------------------------------------------------- run
switch ($Stage) {
    'Host'      { Stage-Host }
    'Install'   { Stage-Install }
    'Mock'      { Stage-Mock }
    'Configure' { Stage-Configure }
    'Verify'    { Stage-Verify }
    'All'       { Stage-Host; Stage-Install; Stage-Mock; Stage-Configure; Stage-Verify }
}
Say 'Done.'
Write-Host ''
Write-Host "AAP:          $Base   (admin)"
Write-Host "Mock Falcon:  http://${AapHost}:9080/"
Write-Host "SSH:          ssh -i `"$($KeySrc.FullName)`" ec2-user@$AapHost   then: fire-demo-event"
