# Rebuilding the demo from nothing

Three steps rebuild the whole lab as it was on 2026-11-19: one CloudFormation stack in the AWS console, one password in a file, one script on your laptop. Allow about 90 minutes, most of it unattended.

The script recreates both servers at their old private IPs (AAP `172.31.2.66`, Windows `172.31.12.7`), the AAP 2.7 install, every AAP object, the mock Falcon service and `fire-demo-event`. Only the AAP public address and the Event Stream URL are new.

## What you need (the rebuild kit)

Everything lives in `Documents\falcon-aap-demo-rebuild` on your laptop. Keep a copy somewhere safe (OneDrive, USB drive), because the AAP bundle cannot be downloaded again without a Red Hat login.

| File | What it is |
| --- | --- |
| `aap-bundle-2.7-11.tar` + `.sha256` | The offline AAP 2.7-11 installer (4.5 GB) |
| `pms-aaponaws-1026.pub` | Public half of the SSH key, to import into a new AWS account |
| `rebuild\demo-stack.json`, `rebuild\rebuild.ps1` | The CloudFormation template and the rebuild script (also in this repo) |
| `secrets\inventory-growth.orig` | The original installer settings, including all install passwords |
| `secrets\manifest_AAPwot_*.zip` | AAP subscription manifest |
| `secrets\pms-aaponaws-1026.pem` | SSH private key |
| `secrets\falcon-demo-token` | Event Stream token |
| `secrets\rebuild-secrets.psd1` | Created on first run; you put the Windows password in it |

The `secrets` folder never goes to GitHub.

AAP pulls the playbooks and rulebook from the public GitHub repo [PhillipMSchwartz/falcon-notepadpp-demo](https://github.com/PhillipMSchwartz/falcon-notepadpp-demo), so keep it public. A full copy of the repo is in the kit's `repo` folder in case it is ever lost.

## Step 1: Create the stack (AWS console, about 10 minutes)

1. Sign in to the AWS console and pick region **US East (Ohio) us-east-2**. In another region, change the **RhelAmiId** parameter in step 4 to that region's current RHEL 10 AMI.
2. **Key pair:** go to **EC2 > Key pairs**. If `pms-aaponaws-1026` isn't listed, click **Actions > Import key pair**, name it `pms-aaponaws-1026`, choose the file `pms-aaponaws-1026.pub` from the kit, and click **Import key pair**.
3. Go to **CloudFormation > Stacks > Create stack > With new resources (standard)**. Choose **Upload a template file**, pick `rebuild\demo-stack.json` from the kit, then click **Next**.
4. Fill in:
    - **Stack name:** `falcon-demo`
    - **KeyName:** `pms-aaponaws-1026`
    - **MyIp:** your public IP followed by `/32` (search "what is my ip"), e.g. `203.0.113.5/32`
    - **WindowsAdminPassword:** a new password of 12+ characters with upper and lower case letters, a digit and a symbol, and no single quotes. Write it down; you need it in step 2.
    - Leave the other parameters as they are.
5. Click **Next**, **Next**, then **Submit**. Wait until the status is **CREATE_COMPLETE**.
6. Open the **Outputs** tab and copy **AapPublicIp**.

## Step 2: Put the Windows password in the secrets file

1. Open PowerShell and run:

    ```powershell
    cd "$env:USERPROFILE\Documents\falcon-aap-demo-rebuild\rebuild"
    .\rebuild.ps1 -AapIp <AapPublicIp>
    ```

    The first run creates `secrets\rebuild-secrets.psd1` and stops.
2. Open that file in Notepad, put the step 1 password between the quotes after `WindowsAdminPassword`, and save it.

If PowerShell refuses to run the script, first run `Set-ExecutionPolicy -Scope Process Bypass`.

## Step 3: Run the rebuild (about 60-90 minutes, unattended)

```powershell
.\rebuild.ps1 -AapIp <AapPublicIp>
```

The script prints each stage as it goes:

1. **Host:** creates the `ansible` user, installs `ansible-core`, uploads and unpacks the 4.5 GB bundle.
2. **Install:** writes the installer settings for the new hostname and runs the AAP install (30-60 minutes).
3. **Mock:** installs the mock Falcon service on port 9080, `fire-demo-event` and the token file.
4. **Configure:** creates the Falcon credential type and credentials, the Windows Host credential, the project, the Windows Endpoints inventory, both job templates, the EDA project, both EDA credentials, the Event Stream and the `falcon-spotlight-events` activation, then writes `/etc/falcon-demo.env`.
5. **Verify:** waits for Windows, runs **Reset Notepad++ (demo)**, fires one event, checks that EDA launched the remediation and it succeeded, then resets again.

It ends by printing the new AAP URL, the mock Falcon page and the SSH command. The demo is then ready, exactly as before. Sign in to AAP as `admin` with the same password as before.

If a stage fails, fix what it reports and rerun the same command; finished stages are skipped or harmlessly redone. `-Stage <name>` runs only that stage, and `-SkipEndToEnd` skips the test event.

## After the rebuild

- The AAP address is new. Update the links in the run script and anywhere you bookmarked the old one (ask Claude to do it).
- Only `MyIp` can reach the new environment. If your IP changes, edit the inbound rules of the `falcon-demo-aap-sg` and `falcon-demo-windows-sg` security groups.
- To tear it down, delete the `falcon-demo` stack in CloudFormation. That removes every resource it created.
