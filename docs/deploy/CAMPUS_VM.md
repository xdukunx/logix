# Going live on a campus VM

Everything up to now has run on one laptop, over `https://localhost`. That
proves the software; it does not prove a deployment. This is the path from
there to a lab that keeps recording when nobody is looking after it.

The topology this document assumes:

```
  lab workstations  --HTTPS-->  campus VM  ( Caddy :443 -> Logix :8791 -> SQLite )
     Logix agent                             backup / retention / watchdog on a timer
```

The workstations never talk to Logix directly. Caddy is the only thing exposed,
and Logix listens on loopback only — that is not a hardening extra, it is the
design: **Logix speaks plain HTTP and always will.**

---

## 1. What to ask campus IT for

Ask once, with everything on the list, or you will be waiting on three separate
tickets.

| Item | Value to request | Why |
| --- | --- | --- |
| VM | 2 vCPU, 4 GB RAM, 40 GB disk | SQLite + FastAPI; a lab of ~30 workstations is nowhere near this |
| OS | Ubuntu LTS **or** Windows Server | Both supported by `install/setup_server.py`; pick whichever your IT actually maintains |
| Address | a **fixed** IP, and ideally a DNS name | Agents are configured with this. Changing it later means touching every workstation |
| Inbound | TCP **443** from the lab subnet only | The only port that needs to be reachable |
| Outbound | 443 to the internet *(optional)* | Only for a real TLS certificate and Telegram alerts; the system works fully without it |
| Backups | VM-level snapshot, or a place to copy to | See §6 — backups on the same disk do not survive that disk |

**Ask for the DNS name.** A name like `logix.ftmm.unair.ac.id` is worth pushing
for: with it, Caddy fetches a real certificate automatically and no workstation
ever has to be told to trust anything. Without it you are distributing a root
certificate to every machine by hand (§4), which works but is a chore you repeat
for every new PC.

## 2. Install the server

On the VM, from a clone of this repo:

```bash
python3 install/setup_server.py --admin-emails you@ftmm.unair.ac.id --install-deps --service
```

This writes `server/.env`, generates the secrets, installs dependencies, and
registers the server to start at boot — a systemd unit on Linux, a Task
Scheduler entry on Windows. `--service` also registers the housekeeping jobs
(backup, report cleanup, retention, watchdog). Confirm:

```bash
python3 ops/go_live.py check
```

## 3. Put TLS in front of it

Pick the file that matches what you got in §1:

| You have | Use | Certificate |
| --- | --- | --- |
| a DNS name reachable from the internet | `docs/deploy/Caddyfile` | Let's Encrypt, automatic, renews itself |
| a LAN name or a bare IP | `docs/deploy/Caddyfile.lab` | Caddy's own CA — see §4 |

Edit the address at the top of the file, then run Caddy as a service so it
comes back after a reboot (`caddy run` in a terminal does not).

## 4. Certificate trust (only if you used `tls internal`)

Caddy issues its own certificate. It is exactly as strong as a public one; the
difference is that nothing else knows Caddy's authority yet. An agent on an
untrusting machine will **refuse to connect** — that refusal is the feature
working, not a bug.

On the server, once:

```bash
caddy trust
```

Then export the root and install it on each workstation, into **Trusted Root
Certification Authorities (Local Machine)**. Caddy prints the path on first run;
it is usually `%AppData%\Caddy\pki\authorities\local\root.crt` on Windows or
`~/.local/share/caddy/pki/authorities/local/root.crt` on Linux.

`windows/install_logbook_tasks.ps1 -ServerCertPath <root.crt>` does this as part
of installing an agent, so it is one step rather than two.

This whole section disappears if you get a real DNS name. That is the argument
for pushing on it in §1.

## 5. Enrol the workstations

One hostname-pinned, single-use invite per machine — the code only works on the
computer it was issued for, so a leaked code enrols nothing.

1. Dashboard → **Perangkat** → *Tambah perangkat* → generate a code
2. On the workstation:

```powershell
powershell -ExecutionPolicy Bypass -File windows\bootstrap-client.ps1 -ServerUrl https://logix.ftmm.unair.ac.id -InviteCode XXXX-XXXX-XXXX-XXXX
```

Enrolment rate-limiting counts **failures only**, so commissioning a whole room
back-to-back is fine; it used to cap at ten machines per five minutes.

Afterwards, check the fleet reports the build you expect:

```bash
sqlite3 server/central_logix.db "SELECT hostname, agent_version, last_seen FROM devices ORDER BY agent_version;"
```

A `NULL` there is a machine updated by hand-copying files without the `VERSION`
stamp — use `windows/update_installed_client.ps1`, which copies the set.

## 6. Before you call it done

- [ ] **Reboot the VM** and confirm the server and Caddy both come back on their
      own. This is the single most common thing to discover the hard way.
- [ ] **Off-host backups.** `ops/backup_db.py` writes to the same disk as the
      database. Add a nightly `rclone`/`rsync` push, or a VM snapshot schedule.
- [ ] **Run a restore drill** on a copy: `python3 ops/restore_db.py --latest`.
      A backup nobody has restored is a hope, not a backup.
- [ ] **Set the retention window.** `privacy.retention_days` defaults to 365.
      This is student personal data; the number should be a decision somebody
      made, not a default nobody looked at.
- [ ] **Watchdog credentials.** `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` in
      `server/.env`, or the watchdog runs and tells nobody.
- [ ] **An external uptime check** on `/api/health`. A watchdog on the same host
      cannot report that the host is down.
- [ ] **Clear the test fixtures.** Devices named `E2E-*` come from the Playwright
      suite; delete them from the registry before the lab uses it for real.

---

## What has actually been rehearsed

Not to be confused with what is deployed. On a developer laptop, over a
**non-loopback** TLS address (`https://192.168.1.7:8443`, certificate validated
in full, SAN `IP Address=192.168.1.7`), this exact sequence was run end to end:

```
  admin login over LAN + TLS ......... 200
  invite created .................... 201
  workstation enrolled .............. 200
  heartbeat (version + clock) ....... 200
  session logged .................... 200
  impersonating another host ........ 403   <- correctly refused
```

So the parts that usually break on move-in day — certificate naming for a
non-`localhost` origin, enrolment across the network, per-device key scoping —
are known to work. What remains genuinely untested is the VM itself: boot
order, the firewall, and whether it all comes back after a reboot.
