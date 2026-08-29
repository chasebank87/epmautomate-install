# EPM Automate installer

Windows does not ship `sh`, so `curl | sh` cannot run in PowerShell. Use the native runner for your OS. Both pull the same client from your Cloud EPM environment.

**Linux / macOS / WSL / Git Bash**

```sh
curl -fsSL https://raw.githubusercontent.com/chasebank87/epmautomate-install/master/install.sh | sh
```

**Windows PowerShell or Command Prompt** (no Git required)

```powershell
powershell -ExecutionPolicy Bypass -c "irm https://raw.githubusercontent.com/chasebank87/epmautomate-install/master/install.ps1 | iex"
```

That PowerShell line is the Windows equivalent of `curl | sh`: it works in PowerShell and in `cmd.exe`.

From a clone: `sh install.sh` (Unix) or `powershell -ExecutionPolicy Bypass -File .\install.ps1` (Windows).

## What it does

Oracle does not publish EPM Automate on a public CDN. The installer downloads from **your Cloud EPM environment** (Settings and Actions → Downloads), then:

| OS | Action |
| --- | --- |
| Windows | Downloads `EPM Automate.exe` and launches the GUI installer (UAC). You walk through the wizard. |
| Linux / macOS | Ensures Java 17, extracts `EPMAutomate.tar`, puts `epmautomate` on your `PATH`, and runs `epmautomate upgrade` when credentials are available. |

WSL is Linux (tar install), not the Windows exe.

## Credentials

```sh
export EPM_URL='https://epm-xxx.epm.region.ocs.oraclecloud.com/epmcloud'
export EPM_USER='you@company.com'
export EPM_PASSWORD='...'
```

```powershell
$env:EPM_URL = 'https://epm-xxx.epm.region.ocs.oraclecloud.com/epmcloud'
$env:EPM_USER = 'you@company.com'
$env:EPM_PASSWORD = '...'
powershell -ExecutionPolicy Bypass -c "irm https://raw.githubusercontent.com/chasebank87/epmautomate-install/master/install.ps1 | iex"
```

| Variable | Also (Unix) | Purpose |
| --- | --- | --- |
| `EPM_URL` | `--url` | Cloud EPM base URL (required unless a local installer file is set) |
| `EPM_USER` | `--user` | Identity-domain user |
| `EPM_PASSWORD` | `--password` | Password |
| `EPM_DOMAIN` | `--domain` | Classic identity domain (4th `login` argument) |
| `EPM_TOKEN` | `--token` | Bearer token instead of basic auth |
| `EPM_INSTALL_DIR` | `--prefix` | Unix install directory |
| `EPM_INSTALLER` | `--from-file` | Local `EPM Automate.exe` or `EPMAutomate.tar` |
| `EPM_SKIP_JAVA` | `--skip-java` | Do not install a JRE |
| `EPM_SKIP_UPGRADE` | `--skip-upgrade` | Skip `epmautomate upgrade` on Unix |

Defaults on Unix: `$HOME/.local/oracle/epmautomate` (or `/opt/oracle/epmautomate` as root). A wrapper is installed at `~/.local/bin/epmautomate`.

## Notes

- **Java 17** is required on Linux/macOS (Windows bundles a JRE). The Unix script installs OpenJDK 17 via `apt` / `dnf` / `yum` when it can.
- **Windows** install requires an administrator. Default path is `Program Files\Oracle\EPM Automate`. After the GUI finishes, run `epmautomate upgrade` from an elevated prompt so the client matches the latest cloud release.
- **MFA:** Cloud EPM REST basic auth does not work for MFA users. Use a service account without MFA, or download from the UI and set `EPM_INSTALLER`.
- Inspect before running: `curl -fsSL .../install.sh | less` or `irm .../install.ps1 | more`
