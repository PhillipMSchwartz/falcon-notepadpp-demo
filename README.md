# Falcon + Ansible Automation Platform: Notepad++ CVE Remediation Demo (AWS)

**What you will build:** an event-driven remediation flow for a **simulated** Notepad++ vulnerability on a Windows Server 2025 EC2 instance.

> **Simulated vulnerability.** `DEMO-CVE-0001` is a made-up id. The lab treats Notepad++ builds below `8.8.2` as "vulnerable" and remediates by upgrading from `8.8.1`. The upgrade is real; the vulnerability is not. Both values live in `playbooks/vars/notepadpp.yml`; any two published releases work.
>
> **Target app change.** The original package targeted Windows Notepad (CVE-2026-20841). Windows Server 2025 does not ship the Store Notepad app, so this lab uses Notepad++.

```
 [Falcon: SIMULATED]                       [REAL]                                 [REAL]
 send_falcon_event.py  --webhook-->  Event-Driven Ansible  --launches-->  AAP job template  --WinRM-->  Windows Server 2025 (EC2)
   (stands in for Fusion SOAR)        (rulebook matches)            (remediate_notepadpp.yml)        (Notepad++ updated)
          |                                                                     |
          v                                                                     v
   mock_falcon.py  <------- playbook polls "Spotlight" until finding closes ----+
```

**Be upfront on camera:** Falcon and the vulnerability are simulated. Event-Driven Ansible, the AAP job, WinRM and the Notepad++ update are real. Suggested line: *"Falcon and the vulnerability are simulated in this lab. The automation, the rule, the job and the remediation are all real, and pointing this at a real Falcon tenant and a real CVE is a credential change, a Fusion workflow and two version numbers."*

---

## 1. Repo layout

Push this whole folder to a Git repo AAP can read (GitHub/GitLab; a private repo needs a Source Control credential).

| Path | Used by | Purpose |
|---|---|---|
| `playbooks/remediate_notepadpp.yml` | Job template **Remediate Notepad++ CVE** | Check version, update if below fixed, assert, poll Falcon |
| `playbooks/reset_notepadpp.yml` | Job template **Reset Notepad++ (demo)** | Reinstall the vulnerable build between takes (replaces VM snapshots) |
| `playbooks/vars/notepadpp.yml` | Both playbooks | Simulated vulnerability id and versions |
| `rulebooks/falcon_events.yml` | EDA rulebook activation | High severity Notepad++ event -> launch remediation |
| `collections/requirements.yml` | Project sync | Installs `ansible.windows` |
| `inventory/windows_endpoints.yml` | AAP inventory | Host `WS-0142` (set the private IP) |
| `credential-types/*.yml` | AAP > Credential Types | Injects Falcon API settings as env vars |
| `windows/Prepare-DemoHost.ps1` | Windows instance, once, elevated | WinRM HTTPS, firewall, disables Notepad++ updater |
| `mock/mock_falcon.py` | AAP host (systemd service) | Fake Falcon API plus status page, port 9080 |
| `mock/mock-falcon.service` | AAP host, `/etc/systemd/system/` | Keeps the mock running across reboots |
| `mock/send_falcon_event.py` | AAP host (or any box with Python 3) | Fires the "Falcon detected it" event |

## 2. Machines (all in AWS)

- **AAP** 2.5+ (built and tested on 2.7, containerized) with Controller and Event-Driven Ansible.
- **Windows Server 2025** EC2 instance. It downloads the Notepad++ installers from GitHub, so it needs outbound internet (or set `npp_release_base` to a folder you host).
- **Mock Falcon** runs on the **AAP host itself** as a systemd service on port **9080** (AAP's nginx already uses 8080). No separate helper box and no web folder are needed.

### Security group rules

| From | To | Port | Why |
|---|---|---|---|
| AAP | Windows | TCP 5985 | WinRM over HTTP with NTLM message encryption (what this lab uses) |
| Your IP | AAP | TCP 9080 | Mock Falcon status page on camera (the playbook's polling stays on the AAP host) |
| Wherever you run the sender | AAP | TCP 443 | Event Stream URL |
| Your IP | AAP | TCP 22 | SSH, to install the mock and run the sender |
| Your IP | Windows | TCP 3389 | RDP, setup only |

Use **private IPs** between instances. WinRM over HTTPS (5986) also works if 5986 is open end to end; see the comment in `inventory/windows_endpoints.yml`.

## 3. Setup

### Step 1: Windows instance
1. RDP in as Administrator (EC2 console > Connect > RDP client > Get password).
2. Copy `windows/Prepare-DemoHost.ps1` over and run it in an **elevated** PowerShell. Note the IP it prints. (Windows Server 2025 already listens on 5985; the script adds the optional HTTPS listener on 5986.)
3. Use `Administrator` (or a new local admin) for the AAP Machine credential.

### Step 2: Mock Falcon on the AAP host
SSH to the AAP host with its EC2 key (`ssh -i <key>.pem ec2-user@<aap-host>`), then:
```bash
R=https://raw.githubusercontent.com/PhillipMSchwartz/falcon-notepadpp-demo/main/mock
sudo mkdir -p /opt/mock-falcon
sudo curl -fsSL -o /opt/mock-falcon/mock_falcon.py $R/mock_falcon.py
sudo curl -fsSL -o /opt/mock-falcon/send_falcon_event.py $R/send_falcon_event.py
sudo curl -fsSL -o /etc/systemd/system/mock-falcon.service $R/mock-falcon.service
sudo systemctl daemon-reload && sudo systemctl enable --now mock-falcon
curl -s -X POST http://<aap-private-ip>:9080/oauth2/token   # expect a fake token
```
Status page: `http://<aap-host>:9080/` (red "MOCK FALCON" banner). Logs: `journalctl -u mock-falcon -f`.

### Step 3: Git project
1. Set `ansible_host` in `inventory/windows_endpoints.yml` to the Windows private IP.
2. Optionally change the versions in `playbooks/vars/notepadpp.yml` (defaults: 8.8.1 -> 8.8.2).
3. Commit and push.

### Step 4: AAP Controller
1. **Execution environment:** the **Default execution environment** (`ee-supported-rhel9`) already has `ansible.windows` and `pywinrm`.
2. **Credential type** `Falcon API (demo)`: paste `credential-types/falcon_api_input.yml` into Input configuration and `falcon_api_injector.yml` into Injector configuration.
3. **Credentials:**
   - `Falcon API (demo)`: base URL `http://<aap-private-ip>:9080`, client ID `demo`, secret `demo` (dummy values for the mock).
   - **Machine**: Windows `Administrator` and its password.
4. **Project:** your Git repo (public, or add a Source Control credential). Sync, confirm Successful.
5. **Inventory** `Windows Endpoints`: group `windows_endpoints` with the WinRM vars from `inventory/windows_endpoints.yml`, and host `WS-0142` with `ansible_host` set to the Windows private IP.
6. **Job templates:**
   - `Remediate Notepad++ CVE` (name must match the rulebook exactly): playbook `playbooks/remediate_notepadpp.yml`; credentials Machine + `Falcon API (demo)`; **Prompt on launch** for **Limit** and **Variables**.
   - `Reset Notepad++ (demo)`: playbook `playbooks/reset_notepadpp.yml`; Machine credential + `Falcon API (demo)` (so it also clears the mock).

### Step 5: Test by hand
1. Launch **Reset Notepad++ (demo)**. Expect the final assert: Notepad++ 8.8.1 (vulnerable, ready).
2. Register a finding (on the AAP host): `curl -X POST http://<aap-private-ip>:9080/mock/findings -d '{"hostname":"WS-0142","cve":"DEMO-CVE-0001","app":"Notepad++"}'`
3. Launch **Remediate Notepad++ CVE** with Limit `WS-0142` and Variables `cve_id: DEMO-CVE-0001`.
4. Expect: before version, download, silent install, assert passes, Falcon poll retries twice, then OK. Mock page flips to CLOSED.
5. Reset: run the reset template again and `curl http://<aap-private-ip>:9080/mock/reset`.

### Step 6: Event-Driven Ansible
1. Add the repo as an EDA project; rulebook `rulebooks/falcon_events.yml`.
2. Under **Automation Decisions > Infrastructure > Credentials**, create:
   - a **Red Hat Ansible Automation Platform** credential (URL `https://<aap-host>/api/controller/`, an AAP user, Verify SSL off for a self-signed cert), so EDA can launch jobs;
   - a **Token Event Stream** credential with a token you choose (header key `Authorization`).
3. Create an **Event Stream** `falcon-spotlight-stream` with the token credential, and note its URL.
4. Create a **Rulebook Activation** `falcon-spotlight-events`: the rulebook, the AAP credential, the **Hub Default Decision Environment** (the `registry.redhat.io` one fails without a Red Hat registry login), and map the rulebook's source `__SOURCE_1` to the Event Stream.
5. Wait for **Running**.

### Step 7: End to end
On the AAP host:
```bash
python3 -B /opt/mock-falcon/send_falcon_event.py --host WS-0142 --cve DEMO-CVE-0001 \
  --mock-url http://<aap-private-ip>:9080 --eda-url <Event Stream URL> \
  --header "Authorization: <your token>" --insecure
```
The token goes in as-is (no "Bearer"). `--insecure` skips TLS verification for AAP's self-signed certificate. Expect `HTTP 200`, a rule match, and a **Remediate Notepad++ CVE** job that launches by itself within a second or two.

### Demo-day shortcuts (on the AAP host)
- **One-click reset:** with the `Falcon API (demo)` credential attached, **Reset Notepad++ (demo)** also clears the mock's findings.
- **Short sender command:** install `mock/fire_demo_event.sh` as `/usr/local/bin/fire-demo-event`, put `EDA_URL=...` and `MOCK_URL=...` in `/etc/falcon-demo.env`, and store your token once:
  ```bash
  umask 077; printf '%s' 'YOUR_TOKEN' > ~/.falcon-demo-token
  ```
  Then on camera just run `fire-demo-event`.
- **Survives reboots:** AAP services and `mock-falcon` start at boot, and the activation's restart policy is `always`. Give the instance an **Elastic IP**, or its public DNS name (used by the Event Stream URL and the EDA credential) changes after a stop/start.

## 4. Recording (about 5 minutes)

Before each take: run **Reset Notepad++ (demo)** (it also clears the mock). The rule throttles per host for 2 minutes, so wait that long between takes.

| Time | Screen | Say |
|---|---|---|
| 0:00 | Mock Falcon page | "Falcon detects a vulnerable Notepad++, Event-Driven Ansible reacts, AAP remediates, and we confirm the finding closes. Falcon and the vulnerability are simulated; the automation and the fix are live." |
| 0:30 | Windows: Notepad++ Help > About (8.8.1) | "For this lab, builds below 8.8.2 are flagged by a simulated finding, DEMO-CVE-0001. This server runs 8.8.1." |
| 1:00 | AAP > Templates > Remediate Notepad++ CVE | "The template ties together inventory, playbook and credentials; operators never handle secrets." |
| 1:40 | `remediate_notepadpp.yml` | "It records the version, updates only if below the fixed build, asserts the result, then checks Falcon until the finding closes." |
| 2:20 | AAP > Rulebook Activations, then the rule | "One rule: a High severity Notepad++ finding launches this template, limited to the affected host." |
| 2:50 | Terminal: `send_falcon_event.py` | "This is the event Falcon Fusion would send." Show mock page: **OPEN**. |
| 3:15 | Rule audit > launched job | "The rule matched and the job launched on its own." |
| 3:30 | Live job output | Before version, download, install, assert, Falcon poll, recap. |
| 4:30 | Mock page **CLOSED**; job history | "Finding closed, with a full audit trail in AAP." |
| 4:50 | Close | "With a real tenant, the mock URL becomes the Falcon API URL and a Fusion workflow sends the webhook." |

## 5. Troubleshooting

- **Cannot connect (WinRM), "connect timeout":** the port is blocked. This lab uses 5985; check the security group allows it from AAP's private IP and `ansible_host` is the Windows private IP. If you switch to 5986, both the security group and the HTTPS listener (`Get-ChildItem WSMan:\localhost\Listener`) must be in place.
- **`ansible.windows` not found:** EE lacks it; use the Default execution environment (`ee-supported`).
- **Activation fails with "Please login to the Red Hat Registry":** pick the **Hub** decision environment instead of the `registry.redhat.io` one.
- **Sender gets HTTP 401/403:** the token in `--header "Authorization: ..."` doesn't match the Token Event Stream credential. **SSL error:** add `--insecure`.
- **Download fails:** the Windows instance has no outbound internet (check route table / NAT). Test with `Invoke-WebRequest https://github.com` on the host, or host the installers yourself and change `npp_release_base`.
- **Installer exits non-zero / version unchanged:** run the installer by hand with `/S` on the host and check Help > About; make sure Notepad++ was not open in another session.
- **Reset assert fails:** an older uninstall may have left files; delete `C:\Program Files\Notepad++` and rerun the reset.
- **Falcon poll times out:** the EE cannot reach `<aap-private-ip>:9080` (`systemctl status mock-falcon`), or the finding was never registered.
- **No job from the event:** check the activation log, the AAP credential on the activation, the exact template name, and prompt-on-launch for Limit and Variables. Mind the 2-minute throttle.

## 6. Moving to a real Falcon tenant

1. Create a read-only API client (Hosts: Read, Vulnerabilities: Read) and put its values and your cloud's API URL in the `Falcon API (demo)` credential.
2. Build a Fusion SOAR workflow that posts the same JSON to your EDA endpoint (must be reachable over HTTPS).
3. Verify the Spotlight endpoint and filter fields against current CrowdStrike API docs.
