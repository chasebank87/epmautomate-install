# EPM Automate installer

One script. One command. It detects Windows vs Linux/macOS and installs the matching Oracle EPM Automate client.

```sh
curl -fsSL https://raw.githubusercontent.com/chasebank87/epmautomate-install/master/install.sh | sh
```

From a clone:

```sh
sh install.sh
```

On Windows use **Git Bash** (or any environment that has `curl` and `sh`). Paste the same line. WSL is treated as Linux and gets the Unix install, which is what you want on WSL.

## What it does

Oracle does not publish EPM Automate on a public CDN. The script pulls the current client from **your Cloud EPM environment** (Settings and Actions → Downloads), then:

| OS | Action |
| --- | --- |
| Windows | Downloads `EPM Automate.exe` and launches the GUI installer (UAC). You walk through the wizard. |
| Linux / macOS | Ensures Java 17, extracts `EPMAutomate.tar`, puts `epmautomate` on your `PATH`, and runs `epmautomate upgrade` when credentials are available. |

## Credentials

Set these (or the script will prompt when it can read `/dev/tty`):

```sh
export EPM_URL='https://epm-xxx.epm.region.ocs.oraclecloud.com/epmcloud'
export EPM_USER='you@company.com'
export EPM_PASSWORD='...'
curl -fsSL https://raw.githubusercontent.com/chasebank87/epmautomate-install/master/install.sh | sh
```

Piped flags work too:

```sh
curl -fsSL https://raw.githubusercontent.com/chasebank87/epmautomate-install/master/install.sh | sh -s -- --url "$EPM_URL" --user "$EPM_USER"
```

Prefer prompting or `EPM_PASSWORD` over `--password` so the secret is not on the command line.

| Variable | Also | Purpose |
| --- | --- | --- |
| `EPM_URL` | `--url` | Cloud EPM base URL (required unless `--from-file`) |
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

- **Java 17** is required on Linux/macOS (Windows bundles a JRE). The script installs OpenJDK 17 via `apt` / `dnf` / `yum` when it can.
- **Windows** install requires an administrator. Default path is `Program Files\Oracle\EPM Automate`. After the GUI finishes, run `epmautomate upgrade` from an elevated prompt so the client matches the latest cloud release.
- **MFA:** Cloud EPM REST basic auth does not work for MFA users. Use a service account without MFA, or download from the UI and pass `--from-file`.
- Inspect before piping: `curl -fsSL .../install.sh | less`
