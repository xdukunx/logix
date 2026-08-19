<a id="readme-top"></a>

[![CI][ci-shield]][ci-url]
[![License: MIT][license-shield]][license-url]
[![PII: local by default][pii-shield]][pii-url]
[![Latest release][release-shield]][release-url]

[![Debian/Ubuntu][deb-shield]][releases-url]
[![Fedora/RHEL][rpm-shield]][releases-url]
[![Homebrew][brew-shield]][packaging-url]
[![Chocolatey][choco-shield]][packaging-url]
[![Winget][winget-shield]][packaging-url]

<br />
<div align="center">
  <h3 align="center">Logix</h3>

  <p align="center">
    A privacy-first sign-in logbook for shared lab computers — Log &middot; Track &middot; Integrate.
    <br />
    <a href="docs/GETTING_STARTED.md"><strong>Explore the docs »</strong></a>
    <br />
    <br />
    <a href="docs/HOSTING.md">Host the server</a>
    &middot;
    <a href="https://github.com/xdukunx/logix/issues/new?labels=bug&template=bug_report.md">Report Bug</a>
    &middot;
    <a href="https://github.com/xdukunx/logix/issues/new?labels=enhancement&template=feature_request.md">Request Feature</a>
  </p>
</div>

<!-- TABLE OF CONTENTS -->
<details>
  <summary>Table of Contents</summary>
  <ol>
    <li>
      <a href="#about-the-project">About The Project</a>
      <ul>
        <li><a href="#built-with">Built With</a></li>
      </ul>
    </li>
    <li><a href="#privacy-read-this">Privacy (read this)</a></li>
    <li>
      <a href="#getting-started">Getting Started</a>
      <ul>
        <li><a href="#is-this-for-you">Is this for you?</a></li>
        <li><a href="#setup-step-by-step">Setup, step by step</a></li>
        <li><a href="#quick-start">Quick start</a></li>
        <li><a href="#install-via-a-package-manager">Install via a package manager</a></li>
      </ul>
    </li>
    <li>
      <a href="#usage">Usage</a>
      <ul>
        <li><a href="#what-it-captures">What it captures</a></li>
        <li><a href="#the-dashboard-on-the-workstation-itself">The dashboard on the workstation</a></li>
        <li><a href="#the-admin-dashboard-optional">The admin dashboard</a></li>
        <li><a href="#customization">Customization</a></li>
      </ul>
    </li>
    <li><a href="#roadmap">Roadmap</a></li>
    <li><a href="#contributing">Contributing</a></li>
    <li><a href="#license">License</a></li>
    <li><a href="#contact">Contact</a></li>
    <li><a href="#acknowledgments">Acknowledgments</a></li>
  </ol>
</details>

<!-- ABOUT THE PROJECT -->
## About The Project

<p align="center">
  <img src="docs/screenshots/login-screen.svg" alt="Logix admin login mockup" width="46%">
  &nbsp;&nbsp;
  <img src="docs/screenshots/admin-dashboard.svg" alt="Logix admin dashboard mockup" width="46%">
</p>
<p align="center"><sub>Illustrative mockups of the optional admin dashboard — not live screenshots.</sub></p>

Logix records **who** used a lab computer, **how** (SSH, AnyDesk, or physically
at the keyboard), and **when** — then turns that into attendance/usage reports.
It was built for a shared computational-chemistry workstation at **FTMM UNAIR**
and published as a reference you can adapt.

Logix ships as **two things**: **Logix Device** (a workstation — logs sessions,
stores them locally, reports on them) and **Logix Server** (optional, one per
lab — dashboard, fleet management, combined reports). A device is a finished
product on its own; the server is a layer on top of it, and a device can be
paired to one, or unpaired from one, at any time from the app itself. See
[docs/DEVICE_AND_SERVER.md](docs/DEVICE_AND_SERVER.md).

* Works standalone on a single machine — no server, no network, nothing leaves the box. Sessions are logged to local SQLite and **reports open on the device itself**, no terminal required.
* Optionally scales to a whole lab with a central server, a live admin dashboard, and remote lock/message/screenshot commands (Logix Control).
* Treats personal data (names, student IDs, IPs) as a first-class concern, not an afterthought — see [Privacy](#privacy-read-this) below.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

### Built With

* [![Python][Python.badge]][Python-url]
* [![FastAPI][FastAPI.badge]][FastAPI-url]
* [![React][React.badge]][React-url]
* [![TypeScript][TypeScript.badge]][TypeScript-url]
* [![Vite][Vite.badge]][Vite-url]
* [![SQLite][SQLite.badge]][SQLite-url]
* [![PowerShell][PowerShell.badge]][PowerShell-url]

<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- PRIVACY -->
## Privacy (read this)

Logix handles personal data — names, student IDs (NIM), and IP addresses — so
this is the most important thing to understand:

* **By default, everything stays on the local computer.** Nothing is uploaded unless you explicitly turn on server sync.
* **This repository contains code only.** The database, reports, and logs are git-ignored and must never be committed.
* **If you deploy this, the collected data is your responsibility.** Tell users their sessions are logged and follow your institution's data rules.

Details: [docs/PRIVACY.md](docs/PRIVACY.md) &middot; [SECURITY.md](SECURITY.md) &middot; [ETHICAL_USE.md](ETHICAL_USE.md).

<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- GETTING STARTED -->
## Getting Started

### Is this for you?

* **One computer** — install the agent below; sessions log **locally**, nothing else to set up.
* **A whole lab** — add a [central server](docs/HOSTING.md) for one dashboard, downloadable reports, and remote lock/message/screenshot commands across every machine.

### Setup, step by step

Two situations. Pick the one you are in.

---

#### A. Just one computer

Nothing to host, nothing to connect. Sessions are recorded on that machine
and stay there.

**Step 1 — install.** Open PowerShell **as Administrator** (right-click →
*Run as Administrator*) and run:

```powershell
irm https://raw.githubusercontent.com/xdukunx/logix/main/windows/bootstrap-client.ps1 | iex
```

**Step 2 — that is all.** Lock and unlock the computer. The sign-in card
appears, someone fills it in, and the session is being recorded.

**Step 3 — look at the data.** Start menu → **Laporan Logix**. The dashboard
opens in your browser, on this machine only.

You never have to touch a server, and no data leaves the computer.

---

#### B. A whole lab (one server, many computers)

The server is a place the workstations send their sessions to, so you can see
every machine in one dashboard. Workstations keep working normally if the
server is down — they just catch up later.

You will do this once on the server, then once per workstation.

**Step 1 — get the server ready.**

On the machine that will be the server:

```bash
git clone https://github.com/xdukunx/logix.git
cd logix
python ops/go_live.py init --admin-email you@campus.ac.id
```

This makes a clean database and prints your **admin password** and an
**ingest key**. Write the password down — you sign in to the dashboard with
it. Both are saved to `server/.env.production`.

**Step 2 — tell the server which computers exist.**

Make a text file, one line per workstation:

```
WS-01,Simulation node
WS-02,Analysis node
WS-03
```

Then:

```bash
python ops/go_live.py register --devices stations.txt
```

It prints one **invite code** per workstation. Each code only works on the
machine it was made for, so it is safe to print the list and walk around the
lab with it. Codes are single use and expire after 15 minutes.

**Step 3 — turn the server on.**

```bash
caddy run --config docs/deploy/Caddyfile.lab   # HTTPS; edit it first to set your server name
python ops/serve.py                            # Logix itself
```

Open `https://your-server-name` in a browser and sign in with the email you
gave in Step 1 and the password it printed.

**Step 4 — install on each workstation, and connect it.**

This is the step that connects a computer to the server. One command, on the
workstation, as Administrator:

```powershell
LogixAgentSetup.exe /VERYSILENT `
  /SERVERURL=https://your-server-name `
  /INVITECODE=A1B2-C3D4-E5F6-7890 `
  /DEVICENAME="WS-01 - Simulation node"
```

Use the invite code that Step 2 printed **for that machine**. The installer
does the rest: it introduces itself to the server, receives a key that
belongs to that computer alone, deletes the shared key, and starts running.

If you prefer clicking, just run `LogixAgentSetup.exe` with no flags and the
wizard asks for the same three things.

> If your server uses its own certificate (the `Caddyfile.lab` setup rather
> than a public domain), add `/SERVERCERT=<path to root.crt>` so the
> workstation trusts it.

**Step 5 — check it worked.**

On the workstation: Start menu → **Laporan Logix** → **Server** tab. It
should say *All changes synchronized*. On the server dashboard, the machine
appears in the device list within a few seconds.

**Step 6 — lock the door.**

Once every workstation has enrolled:

```bash
python ops/go_live.py lockdown   # now only per-device keys are accepted
python ops/go_live.py check      # tells you if anything is still unsafe
```

`lockdown` refuses to run while any registered machine has not enrolled yet,
so it cannot accidentally cut off a workstation you have not got to.

---

#### If something is not connecting

Open **Laporan Logix → Server** on the workstation. It tells you which of
these it is, in plain words:

| It says | What it means |
|---|---|
| *Local only* | No server configured. This is fine — it is the default. |
| *Synchronization disabled* | A server is set, but privacy mode is `local_only`. Set `LOGIX_PRIVACY_MODE=admin_full_sync` in `config.env` to allow sending. |
| *Server could not be reached* | Network or address problem. Local logging keeps working. |
| *The server rejected this workstation's credentials* | The device key is wrong or was revoked — re-enrol with a fresh invite code. |
| *N waiting to synchronize* | It is connected and catching up. Press **Sync now** if you do not want to wait. |

<p align="right">(<a href="#readme-top">back to top</a>)</p>

### Quick start

**Windows lab PC, one line** (in an elevated PowerShell — right-click PowerShell → "Run as Administrator"). Installs the core logger *and* the sign-in popup / timer widget:

```powershell
irm https://raw.githubusercontent.com/xdukunx/logix/main/windows/bootstrap-client.ps1 | iex
```

**Linux / macOS**, or if you'd rather clone the repo yourself first:

```bash
git clone https://github.com/xdukunx/logix.git
cd logix

# Linux / macOS
sudo ./install/install.sh

# Windows (core logger only, no sign-in popup — use the one-liner above for that)
.\install\install.ps1
```

That's it for local-only use — sessions are now logged to a local SQLite
database. Generate an Excel report any time:

```bash
python logbook_report.py     # writes an .xlsx into <data-dir>/reports
```

Either installer also asks (or takes flags) to point the device at a central
server. Full walkthrough, flags, and mass-deployment: [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md).

<p align="right">(<a href="#readme-top">back to top</a>)</p>

### Running a lab: server + workstations

Four commands on the server, then one installer run per workstation. Everything
below — clean database, generated secrets, HTTPS, and each device's own
credential — is set up by these steps; there is nothing to configure by hand
afterwards.

**On the server**

```bash
# 1. Clean database + generated admin password and ingest key -> server/.env.production
python ops/go_live.py init --admin-email you@campus.ac.id

# 2. Pre-register the lab. One line per station: hostname[,display name]
python ops/go_live.py register --devices stations.txt

# 3. HTTPS. Edit docs/deploy/Caddyfile.lab first to set your server's name
caddy run --config docs/deploy/Caddyfile.lab

# 4. Start Logix itself (loopback only -- Caddy is the way in)
python ops/serve.py
```

`init` **refuses to reuse a development database**: a dev DB carries test
devices, sessions with real names and NIMs, and keys that have been sitting in
a working tree. `register` prints one invite code per station, each **pinned to
that hostname** — a code that leaks is worthless anywhere else, so it is safe to
print the table and carry it round the lab. Codes are single-use and expire in
15 minutes.

**On each workstation** — one command, fully unattended:

```powershell
LogixAgentSetup.exe /VERYSILENT `
  /SERVERURL=https://logix.lab `
  /INVITECODE=A1B2-C3D4-E5F6-7890 `
  /SERVERCERT=\\server\share\root.crt `
  /DEVICENAME="WS-07 - GPU-A100"
```

That single run does all of it: trusts the server's certificate, performs the
enrolment **handshake** and stores a key belonging to that machine alone, wipes
the shared bootstrap key from disk, registers the logon task, and starts the
agent. Leave the flags off and the wizard asks for the same things instead.

`/SERVERCERT` is only needed for a lab server that issues its own certificate
(`Caddyfile.lab`). With a public domain and a real certificate, omit it.

**Finally, close the door**

```bash
python ops/go_live.py lockdown   # only per-device keys work from now on
python ops/go_live.py check      # fails on anything still unsafe
```

`lockdown` refuses to run while any registered device has yet to enrol, so it
cannot cut a straggler off. After it, the shared ingest key is inert: a leaked
copy no longer lets anything report as a device.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

### Install via a package manager

| Platform | Ships | Command |
|---|---|---|
| 🐧 **Debian / Ubuntu** | core + `logix` CLI | `curl -fsSLO "$(curl -fsSL https://api.github.com/repos/xdukunx/logix/releases/latest \| grep -oE 'https://[^"]+\.deb')" && sudo apt install ./logix_*_all.deb` |
| 🎩 **Fedora / RHEL** | core + `logix` CLI | `sudo dnf install "$(curl -fsSL https://api.github.com/repos/xdukunx/logix/releases/latest \| grep -oE 'https://[^"]+\.rpm')"` |
| 🍺 **Homebrew** (macOS/Linux) | core + `logix` CLI | `brew install xdukunx/logix/logix` *(tap not published yet — formula's ready, see below)* |
| 🍫 **Chocolatey** (Windows) | full sign-in agent | `choco install logix` *(pending community-feed moderation — see below)* |
| 🪟 **Winget** (Windows) | full sign-in agent | `winget install MindLab.Logix` *(pending winget-pkgs PR — see below)* |

`.deb`/`.rpm` are built and attached to every [Release][releases-url]
automatically — grab the latest and run **`sudo logix configure`** once.
Homebrew/Chocolatey/Winget manifests are already written and checksummed
against the current release; only the publish step (pushing to each
ecosystem's registry, which needs an account on that service) is pending.
Full matrix, local build/test commands, and exact publish steps for each:
[packaging/README.md](packaging/README.md).

<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- USAGE EXAMPLES -->
## Usage

### What it captures

| Session type | Detected via | Linux | macOS | Windows |
|---|---|:---:|:---:|:---:|
| **Physical** (at the keyboard) | sign-in popup on lock/unlock | — | — | ✅ |
| **SSH** | shell hook, logged on login/logout | ✅ | ✅ | — |
| **AnyDesk** | remote session detected at login | — | — | ✅ |

All three write through **one idempotent bridge** (`log_physical.py`) into a
local SQLite database — re-running never double-counts a session. The
logging bridge and Excel reports themselves run on all three OSes; only the
capture methods above are platform-specific.

### The dashboard on the workstation itself

Every device has its own console, opened from the Start-menu shortcut
**Laporan Logix** (or `windows\logix_reports.ps1`). It is a small local web
page — no account, no network, no installer beyond Logix itself — served by
Python's standard library and opened in the browser that is already on the
machine. It binds to `127.0.0.1` only and needs a one-time token, so nothing
else on the lab network can reach it.

Three pages:

| Page | Answers |
|---|---|
| **Overview** | What is happening on this workstation *right now* |
| **Logs** | What has happened here before |
| **Server** | How this workstation relates to the central server |

**Overview** shows the workstation name, live health, and who is signed in.
Health is four real readings, each drawn in the shape that suits it: one
block per actual CPU core (filled by that core's own load), bars for memory
and disk capacity, a dial for GPU utilisation, plus a moving line built from
samples taken while the page is open. Where the hardware reports it, GPU
temperature, power draw and clock appear too.

Anything the machine cannot report says **Unavailable** rather than showing a
zero — an absent GPU and an idle GPU must never look the same. CPU
temperature and fan speed are *not* shown, because reading them on Windows
needs a kernel-level driver, which would work against Logix staying small.

**Logs** is the local history: search, date range, filters by user and job
type, a details panel, and export. Everything is answered from the local
database, so it all works with the network unplugged. Search runs in SQL
across the whole history rather than only the rows on screen, and the page
loads 50 sessions at a time — on a workstation with 10,000 recorded sessions
a page costs about 20 ms.

**Export** produces an `.xlsx` (or `.csv` if `openpyxl` is not installed)
containing exactly what the filters on screen are showing — never the whole
database when the view is filtered.

### The admin dashboard (optional)

The central server adds a web dashboard: live machine status, session search,
usage analytics, device enrollment with revocable keys, Excel report
downloads, and remote **lock / message / power / screenshot** commands
(Logix Control — every screenshot notifies the user, never silently).

Setup, HTTPS, and admin sign-in: [docs/HOSTING.md](docs/HOSTING.md).

### Customization

| What | How |
|---|---|
| Paths / DB location | [`logix/paths.py`](logix/paths.py) — env var → `config.env` → OS default |
| Sign-in popup branding & fields | JSON config, no code edits — copy [`windows/logbook_config.example.json`](windows/logbook_config.example.json) |
| Google Sheets sync (optional) | redacted, aggregated, on a schedule — [docs/GOING_LIVE.md](docs/GOING_LIVE.md) |

<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- ROADMAP -->
## Roadmap

- [x] Cross-platform core: logging bridge, Excel reports, one-command installers
- [x] Central admin server + React dashboard (monitoring, devices, analytics, settings)
- [x] Local email + password admin auth (no external OAuth dependency)
- [x] Logix Control: remote lock / message / power / screenshot, per-device enrollment keys
- [x] One-liner installers for both the server and the Windows agent
- [ ] Live Google Sheets push validation against a real spreadsheet (tooling is done and unit-tested; blocked only on real credentials)
- [ ] A native macOS/Linux GUI for physical at-keyboard capture (by decision, not currently planned — SSH already covers the POSIX side)

Full detail and in-progress work: [docs/ROADMAP.md](docs/ROADMAP.md) and [docs/AUDIT_AND_ROADMAP.md](docs/AUDIT_AND_ROADMAP.md).

<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- CONTRIBUTING -->
## Contributing

Contributions, bug reports, and suggestions are welcome.

1. Fork the Project
2. Create your Feature Branch (`git checkout -b feature/AmazingFeature`)
3. Commit your Changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the Branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

Read [AGENTS.md](AGENTS.md) first — repo conventions and PII handling rules.
Never commit real session data, DB files, or a filled-in `.env` (see
[Privacy](#privacy-read-this)).

```bash
python -m pytest tests/ -q     # redaction gate, upsert, server hardening
```

CI runs this same suite on Linux, macOS, and Windows against a synthetic
database only — never real data.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- LICENSE -->
## License

Distributed under the MIT License. See [`LICENSE`](LICENSE) for more information.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- CONTACT -->
## Contact

Project Link: [https://github.com/xdukunx/logix](https://github.com/xdukunx/logix)

Found a security issue? Please report it privately — see [SECURITY.md](SECURITY.md) — rather than opening a public issue.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- ACKNOWLEDGMENTS -->
## Acknowledgments

* Built for the computational-chemistry workstation at **FTMM UNAIR**
* [Astryx design system](frontend/.claude/CLAUDE.md) — the component system the admin dashboard is built on
* [Best-README-Template](https://github.com/othneildrew/Best-README-Template) — this README's structure
* [Img Shields](https://shields.io) for the badges above

<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- MARKDOWN LINKS & IMAGES -->
[ci-shield]: https://img.shields.io/github/actions/workflow/status/xdukunx/logix/ci.yml?branch=main&style=for-the-badge&label=CI
[ci-url]: https://github.com/xdukunx/logix/actions/workflows/ci.yml
[license-shield]: https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge
[license-url]: LICENSE
[pii-shield]: https://img.shields.io/badge/PII-local%20by%20default-critical.svg?style=for-the-badge
[pii-url]: #privacy-read-this
[release-shield]: https://img.shields.io/github/v/release/xdukunx/logix?style=for-the-badge&label=release&color=success
[release-url]: https://github.com/xdukunx/logix/releases/latest
[releases-url]: https://github.com/xdukunx/logix/releases/latest
[packaging-url]: packaging/README.md
[deb-shield]: https://img.shields.io/badge/Debian%2FUbuntu-.deb-A81D33?style=for-the-badge&logo=debian&logoColor=white
[rpm-shield]: https://img.shields.io/badge/Fedora%2FRHEL-.rpm-51A2DA?style=for-the-badge&logo=fedora&logoColor=white
[brew-shield]: https://img.shields.io/badge/Homebrew-manifest%20ready-FBB040?style=for-the-badge&logo=homebrew&logoColor=white
[choco-shield]: https://img.shields.io/badge/Chocolatey-manifest%20ready-80B5E3?style=for-the-badge&logo=chocolatey&logoColor=white
[winget-shield]: https://img.shields.io/badge/Winget-manifest%20ready-0078D4?style=for-the-badge&logo=windowsterminal&logoColor=white
[Python.badge]: https://img.shields.io/badge/Python-3776AB?style=for-the-badge&logo=python&logoColor=white
[Python-url]: https://www.python.org/
[FastAPI.badge]: https://img.shields.io/badge/FastAPI-009688?style=for-the-badge&logo=fastapi&logoColor=white
[FastAPI-url]: https://fastapi.tiangolo.com/
[React.badge]: https://img.shields.io/badge/React-20232A?style=for-the-badge&logo=react&logoColor=61DAFB
[React-url]: https://react.dev/
[TypeScript.badge]: https://img.shields.io/badge/TypeScript-3178C6?style=for-the-badge&logo=typescript&logoColor=white
[TypeScript-url]: https://www.typescriptlang.org/
[Vite.badge]: https://img.shields.io/badge/Vite-646CFF?style=for-the-badge&logo=vite&logoColor=white
[Vite-url]: https://vitejs.dev/
[SQLite.badge]: https://img.shields.io/badge/SQLite-003B57?style=for-the-badge&logo=sqlite&logoColor=white
[SQLite-url]: https://www.sqlite.org/
[PowerShell.badge]: https://img.shields.io/badge/PowerShell-5391FE?style=for-the-badge&logo=powershell&logoColor=white
[PowerShell-url]: https://learn.microsoft.com/en-us/powershell/
