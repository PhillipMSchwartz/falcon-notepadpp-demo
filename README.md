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
| `mock/mock_falcon.py` | Helper box | Fake Falcon API plus status page |
| `mock/send_falcon_event.py` | Helper box or laptop | Fires the "Falcon detected it" event |

## 2. Machines (all in AWS)

- **AAP** 2.4 or 2.5+ with Controller and Event-Driven Ansible.
- **Windows Server 2025** EC2 instance. It downloads the Notepad++ installers from GitHub, so it needs outbound internet (or set `npp_release_base` to a folder you host).
- **Helper box:** any Linux instance with Python 3 that AAP can reach. The AAP instance itself works. Runs `mock_falcon.py` on port 8080. No web folder is needed for Notepad++.

### Security group rules

| From | To | Port | Why |
|---|---|---|---|
| AAP | Windows | TCP 5986 | WinRM |
| AAP (execution nodes) | Helper | TCP 8080 | Playbook polls mock Falcon |
| Your browser IP | Helper | TCP 8080 | Mock Falcon status page on camera |
| Where you run the sender | EDA | TCP 5000 (2.4) or the Event Stream URL (2.5+) | Webhook |
| Your IP | Windows | TCP 3389 | RDP, setup only |

Use **private IPs** between instances.

## 3. Setup

### Step 1: Windows instance
1. RDP in as Administrator (EC2 console > Connect > RDP client > Get password).
2. Copy `windows/Prepare-DemoHost.ps1` over and run it in an **elevated** PowerShell. Note the IP it prints.
3. Use `Administrator` (or a new local admin) for the AAP Machine credential.

### Step 2: Helper box
```bash
mkdir -p ~/falcon-demo && cd ~/falcon-demo
# copy mock/mock_falcon.py and mock/send_falcon_event.py here
nohup python3 mock_falcon.py --port 8080 --close-after 3 > mock.log 2>&1 &
```
Open `http://<helper-ip>:8080/`: red "MOCK FALCON" banner, "No findings yet". If the helper is RHEL, also `sudo firewall-cmd --add-port=8080/tcp`.

### Step 3: Git project
1. Set `ansible_host` in `inventory/windows_endpoints.yml` to the Windows private IP.
2. Optionally change the versions in `playbooks/vars/notepadpp.yml` (defaults: 8.8.1 -> 8.8.2).
3. Commit and push.

### Step 4: AAP Controller
1. **Execution environment:** needs `ansible.windows` and `pywinrm`. Either let project sync install the collection (needs an Automation Hub/Galaxy credential) or use an EE that has both. Recent `ee-supported` images include Windows support; check yours.
2. **Credential type** `Falcon API (demo)`: paste `credential-types/falcon_api_input.yml` into Input configuration and `falcon_api_injector.yml` into Injector configuration.
3. **Credentials:**
   - `Falcon API (demo)`: base URL `http://<helper-private-ip>:8080`, client ID `demo`, secret `demo`.
   - **Machine**: Windows username and password.
4. **Project:** your Git repo. Sync, confirm Successful.
5. **Inventory** `Windows Endpoints`: add host `WS-0142` with `ansible_host` and the WinRM vars from `inventory/windows_endpoints.yml`, or source it from the project.
6. **Job templates:**
   - `Remediate Notepad++ CVE` (name must match the rulebook exactly): playbook `playbooks/remediate_notepadpp.yml`; credentials Machine + `Falcon API (demo)`; **Prompt on launch** for **Limit** and **Variables**.
   - `Reset Notepad++ (demo)`: playbook `playbooks/reset_notepadpp.yml`; Machine credential only.

### Step 5: Test by hand
1. Launch **Reset Notepad++ (demo)**. Expect the final assert: Notepad++ 8.8.1 (vulnerable, ready).
2. Register a finding: `curl -X POST http://<helper-ip>:8080/mock/findings -d '{"hostname":"WS-0142","cve":"DEMO-CVE-0001","app":"Notepad++"}'`
3. Launch **Remediate Notepad++ CVE** with Limit `WS-0142` and Variables `cve_id: DEMO-CVE-0001`.
4. Expect: before version, download, silent install, assert passes, Falcon poll retries twice, then OK. Mock page flips to CLOSED.
5. Reset: run the reset template again and `curl http://<helper-ip>:8080/mock/reset`.

### Step 6: Event-Driven Ansible
1. Add the repo as an EDA project; rulebook `rulebooks/falcon_events.yml`.
2. EDA needs an AAP credential (to launch jobs) and a decision environment.
3. Create a **Rulebook Activation** `falcon-spotlight-events`. On 2.5+, create an **Event Stream**, map the webhook source to it, and note its URL. On 2.4, the URL is `http://<eda-host>:5000/endpoint`.
4. Wait for **Running**.

### Step 7: End to end
```bash
python3 send_falcon_event.py --host WS-0142 --cve DEMO-CVE-0001 \
  --mock-url http://<helper-ip>:8080 --eda-url <your EDA URL>
```
Add `--header "Authorization: Bearer <token>"` if your Event Stream uses token auth. Expect a rule match and a job that launches by itself.

## 4. Recording (about 5 minutes)

Before each take: run **Reset Notepad++ (demo)** and reset the mock. The rule throttles per host for 2 minutes, so wait that long between takes.

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

- **Cannot connect (WinRM):** security group allows 5986 from AAP's private IP; `ansible_host` is the private IP; `Get-ChildItem WSMan:\localhost\Listener` shows HTTPS; Machine credential is right.
- **`ansible.windows` not found:** EE lacks it; add a Hub/Galaxy credential for project sync or use a Windows-capable EE.
- **Download fails:** the Windows instance has no outbound internet (check route table / NAT). Test with `Invoke-WebRequest https://github.com` on the host, or host the installers yourself and change `npp_release_base`.
- **Installer exits non-zero / version unchanged:** run the installer by hand with `/S` on the host and check Help > About; make sure Notepad++ was not open in another session.
- **Reset assert fails:** an older uninstall may have left files; delete `C:\Program Files\Notepad++` and rerun the reset.
- **Falcon poll times out:** the EE cannot reach `<helper>:8080` (security group, `firewall-cmd`), or the finding was never registered.
- **No job from the event:** check the activation log, the AAP credential on the activation, the exact template name, and prompt-on-launch for Limit and Variables. Mind the 2-minute throttle.

## 6. Moving to a real Falcon tenant

1. Create a read-only API client (Hosts: Read, Vulnerabilities: Read) and put its values and your cloud's API URL in the `Falcon API (demo)` credential.
2. Build a Fusion SOAR workflow that posts the same JSON to your EDA endpoint (must be reachable over HTTPS).
3. Verify the Spotlight endpoint and filter fields against current CrowdStrike API docs.
