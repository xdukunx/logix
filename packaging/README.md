# Logix packaging

Install Logix through native package managers instead of `install.sh` /
`irm | iex`. Two payloads:

- **Linux/macOS packages** ship the **cross-platform core** (`logix` CLI +
  logging bridge, report generator, SQL helper, Google Sheets sync, SSH-login
  hook). Pure Python, stdlib only, depends on `python3`. **Not** the Windows
  sign-in agent.
- **Windows packages** (Chocolatey, Winget) wrap the official
  **`LogixAgentSetup.exe`** wizard from GitHub Releases — the full at-keyboard
  sign-in agent.

Single source of version truth: the top-level [`VERSION`](../VERSION) file
(`1.1.0`). Every manifest below reads/matches it.

## Matrix

| Ecosystem | Payload | Command | Status |
|---|---|---|---|
| **Winget** (Windows) | Agent `.exe` | `winget install MindLab.Logix` | Manifest ready ([winget/](winget/)); submit to `microsoft/winget-pkgs` |
| **Chocolatey** (Windows) | Agent `.exe` | `choco install logix` | Package ready ([chocolatey/](chocolatey/)); push to community feed |
| **.deb / .rpm** (Linux) | Core + CLI | `apt install ./logix_*.deb` / `dnf install ./logix-*.rpm` | Built by CI, attached to each `v*` Release ([nfpm.yaml](nfpm.yaml)) |
| **PPA** (Ubuntu) | Core + CLI | `apt install logix` (after `add-apt-repository`) | Source packaging ready ([deb/debian/](deb/debian/)); upload to Launchpad |
| **COPR** (Fedora) | Core + CLI | `dnf copr enable … && dnf install logix` | Spec ready ([rpm/logix.spec](rpm/logix.spec)); build on COPR |
| **Homebrew** (macOS/Linux) | Core + CLI | `brew install xdukunx/logix/logix` | Formula ready ([homebrew/logix.rb](homebrew/logix.rb)); publish a tap |

The `.deb`/`.rpm` are the only ones fully automated end-to-end (CI builds and
attaches them). The rest are ready-to-publish artifacts whose final step needs
an account you own (Launchpad, COPR, the winget-pkgs repo, chocolatey.org, a
Homebrew tap repo) — steps below.

---

## What a Linux/macOS install lays down

| Path | Contents |
|---|---|
| `/usr/bin/logix` | CLI entry point ([bin/logix](bin/logix)) |
| `/opt/software/logix/*.py` | core modules + the `configure` wizard |
| `/opt/software/logix/VERSION` | version marker |
| `/opt/software/logix/{config.env,logix.db,reports/,device.json}` | created at runtime by `logix configure` |

`logix` subcommands: `configure` (one-time setup), `query`, `report`, `log`,
`sync`, `version`. After install: **`sudo logix configure`**.

macOS/Homebrew keeps the core in the formula prefix and writes runtime data to
`/Library/Application Support/Logix`.

---

## Build & test locally

### `.deb` + `.rpm` (nfpm — one config, both formats)
```sh
# needs nfpm: https://nfpm.goreleaser.com
export VERSION=$(cat VERSION)
nfpm package --config packaging/nfpm.yaml --packager deb --target dist/
nfpm package --config packaging/nfpm.yaml --packager rpm --target dist/
sudo apt install ./dist/logix_*.deb        # or: sudo dnf install ./dist/logix-*.rpm
sudo logix configure
```
CI already does this on every push (artifacts) and attaches the packages to the
Release on `v*` tags — see [`.github/workflows/build-installer.yml`](../.github/workflows/build-installer.yml).

### Winget (validate locally)
```powershell
winget validate --manifest packaging/winget
winget install --manifest packaging/winget      # local install test
```

### Chocolatey (pack + local install)
```powershell
choco pack packaging/chocolatey/logix.nuspec
choco install logix -s . -y
# with server config:
choco install logix -s . --params "'/ServerUrl:https://logix.example.org /ApiKey:KEY /DeviceName:WS-07'"
```

### Homebrew (from a tap)
```sh
brew install --build-from-source packaging/homebrew/logix.rb   # local test
```

---

## Publishing (needs your accounts)

Each of these is the *last* step; the artifacts above are already prepared.

### PPA (Launchpad — Ubuntu `apt install logix`)
1. Create a Launchpad account + a PPA; register a GPG key with it.
2. From the repo root, stage the debian dir and build a signed source package:
   ```sh
   cp -r packaging/deb/debian ./debian
   debuild -S -sa            # builds ../logix_1.1.0_source.changes (signed)
   rm -rf ./debian
   dput ppa:<you>/logix ../logix_1.1.0_source.changes
   ```
3. Edit `debian/changelog`'s distribution (`noble`) per target Ubuntu series;
   `dch` bumps it. Launchpad build farm produces the `.deb`.

### COPR (Fedora — `dnf install logix`)
1. Create a Fedora account, enable COPR, make a project `logix`.
2. Either point COPR at this repo + `packaging/rpm/logix.spec` (webhook build),
   or build an SRPM and upload:
   ```sh
   copr-cli build <you>/logix packaging/rpm/logix.spec
   ```
   `Source0` in the spec points at the GitHub tag tarball, so tag first.

### Winget (`microsoft/winget-pkgs`)
1. Fork `microsoft/winget-pkgs`; copy [`winget/`](winget/) to
   `manifests/m/MindLab/Logix/1.1.0/`.
2. `InstallerSha256` is already set to the v1.1.0 release asset's hash. Open a
   PR; the pipeline validates + merges. Then `winget install MindLab.Logix`.

### Chocolatey (chocolatey.org community feed)
1. Get an API key from chocolatey.org.
2. `checksum64` in [`tools/chocolateyInstall.ps1`](chocolatey/tools/chocolateyInstall.ps1)
   is already the v1.1.0 asset hash. Then:
   ```powershell
   choco pack packaging/chocolatey/logix.nuspec
   choco push logix.1.1.0.nupkg --source https://push.chocolatey.org/ --api-key <KEY>
   ```
   Moderation review follows. Then `choco install logix`.

### Homebrew tap
1. Create a repo `xdukunx/homebrew-logix`; put [`homebrew/logix.rb`](homebrew/logix.rb)
   at `Formula/logix.rb` (`sha256` is already the v1.1.0 source-tarball hash).
2. Users: `brew tap xdukunx/logix && brew install logix`.

---

## Releasing a new version

1. Bump [`VERSION`](../VERSION) and `installer/logix-agent.iss`'s `AppVersion`.
2. Update the version in each manifest here (`rpm/logix.spec`, `deb/debian/changelog`,
   `chocolatey/logix.nuspec` + `tools/chocolateyInstall.ps1`, all three
   `winget/*.yaml`, `homebrew/logix.rb`'s url).
3. Recompute the two hashes from the new release assets and update
   winget/choco (`.exe` sha256) and homebrew (source-tarball sha256):
   ```powershell
   (Get-FileHash LogixAgentSetup.exe -Algorithm SHA256).Hash
   ```
   ```sh
   curl -fsSL <tag-tarball-url> | sha256sum
   ```
4. Tag `vX.Y.Z` — CI builds and attaches `LogixAgentSetup.exe`, `.deb`, `.rpm`.
5. Re-run the account-gated publish steps above.

## Notes

- **Data location.** The Linux packages keep the existing `/opt/software/logix`
  layout the core's `paths.py` resolves to, so a package install upgrades a
  prior `install.sh` install in place. Data/config are created there at runtime.
- **python3 only.** No third-party Python deps (stdlib), so packaging stays
  trivial and the dependency is just `python3`.
- **AnyDesk.** Windows packages don't bundle AnyDesk (a separate app); the
  dashboard "Remote" action activates once AnyDesk is installed on the device.
