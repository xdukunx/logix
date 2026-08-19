# Setup, step by step

Two situations. Pick the one you are in. (For the one-liners without the
walkthrough, see the README's Quick start.)

---

## A. Just one computer

Nothing to host, nothing to connect. Sessions are recorded on that machine
and stay there.

**Step 1 — install.** Open PowerShell **as Administrator** (right-click →
*Run as Administrator*) and run:

```powershell
irm https://raw.githubusercontent.com/xdukunx/logix/main/windows/bootstrap-client.ps1 | iex
```

**Step 2 — that is all.** Lock and unlock the computer. The sign-in card
appears, someone fills it in, and the session is being recorded.

**Step 3 — look at the data.** Start menu → **Laporan Logix**. A local
dashboard opens in your browser, on this machine only — no account, no
network, served by Python's standard library. Three pages: **Overview**
(what is happening now, live CPU/memory/GPU/storage), **Logs** (searchable
local history, with export), **Server** (only relevant once you connect to
one — see Part B).

You never have to touch a server, and no data leaves the computer.

---

## B. A whole lab (one server, many computers)

The server is a place the workstations send their sessions to, so you can see
every machine in one dashboard. Workstations keep working normally if the
server is down — they just catch up later.

Seven steps: five on the server, one on each workstation, one to finish.

**Step 1 — put the server software on the machine.**

One line, on the machine that will be the server:

```bash
curl -fsSL https://raw.githubusercontent.com/xdukunx/logix/main/install/bootstrap-server.sh | bash
```

Windows: `irm https://raw.githubusercontent.com/xdukunx/logix/main/install/bootstrap-server.ps1 | iex`

It fetches the code and installs what the server needs. Like any
pipe-to-shell installer, read it first if you would rather:
`curl -fsSL <url> -o s.sh && less s.sh`.

**Step 2 — prepare it for real use.**

```bash
cd logix
python ops/go_live.py init --admin-email you@campus.ac.id
```

This is a separate step on purpose. Step 1 installs the software; this one
starts a **clean database** and generates the credentials, because a
database left over from testing carries test devices and real names that
have no business on a server handling students' data. It refuses to reuse
one.

It prints your **admin password** — write it down, you sign in to the
dashboard with it — and saves everything to `server/.env.production`.

**Step 3 — tell the server which computers exist.**

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

**Step 4 — turn the server on.**

```bash
caddy run --config docs/deploy/Caddyfile.lab   # HTTPS; edit it first to set your server name
python ops/serve.py                            # Logix itself
```

Open `https://your-server-name` in a browser and sign in with the email you
gave in Step 2 and the password it printed.

**Step 5 — install on each workstation, and connect it.**

This is the step that connects a computer to the server. One command, on the
workstation, as Administrator:

```powershell
LogixAgentSetup.exe /VERYSILENT `
  /SERVERURL=https://your-server-name `
  /INVITECODE=A1B2-C3D4-E5F6-7890 `
  /DEVICENAME="WS-01 - Simulation node"
```

Use the invite code that Step 3 printed **for that machine**. The installer
does the rest: it introduces itself to the server, receives a key that
belongs to that computer alone, deletes the shared key, and starts running.

If you prefer clicking, just run `LogixAgentSetup.exe` with no flags and the
wizard asks for the same three things.

> If your server uses its own certificate (the `Caddyfile.lab` setup rather
> than a public domain), add `/SERVERCERT=<path to root.crt>` so the
> workstation trusts it — a UNC share such as `\\server\share\root.crt`
> works.

**Step 6 — check it worked.**

On the workstation: Start menu → **Laporan Logix** → **Server** tab. It
should say *All changes synchronized*. On the server dashboard, the machine
appears in the device list within a few seconds.

**Step 7 — lock the door.**

Once every workstation has enrolled:

```bash
python ops/go_live.py lockdown   # now only per-device keys are accepted
python ops/go_live.py check      # tells you if anything is still unsafe
```

`lockdown` refuses to run while any registered machine has not enrolled yet,
so it cannot accidentally cut off a workstation you have not got to.

---

## If something is not connecting

Open **Laporan Logix → Server** on the workstation. It tells you which of
these it is, in plain words:

| It says | What it means |
|---|---|
| *Local only* | No server configured. This is fine — it is the default. |
| *Synchronization disabled* | A server is set, but privacy mode is `local_only`. Set `LOGIX_PRIVACY_MODE=admin_full_sync` in `config.env` to allow sending. |
| *Server could not be reached* | Network or address problem. Local logging keeps working. |
| *The server rejected this workstation's credentials* | The device key is wrong or was revoked — re-enrol with a fresh invite code. |
| *N waiting to synchronize* | It is connected and catching up. Press **Sync now** if you do not want to wait. |

---

## The local dashboard, in more detail

Every device has its own console, opened from the Start-menu shortcut
**Laporan Logix** (or `windows\logix_reports.ps1`). It binds to `127.0.0.1`
only and needs a one-time token, so nothing else on the lab network can
reach it.

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
