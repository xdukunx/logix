# RPM spec for the Logix cross-platform core + CLI.
# Used for:
#   - Fedora COPR builds (copr-cli / the COPR GitHub webhook)
#   - local rpmbuild: rpmbuild -ba packaging/rpm/logix.spec
#
# Packages the core (logging bridge, report generator, SQL helper, GSheet
# sync, SSH-login hook), the `logix` CLI, and the configure wizard. Not the
# Windows sign-in agent. noarch: it's pure Python (stdlib only).

%global logixlib /opt/software/logix

Name:           logix
Version:        1.1.1
Release:        1%{?dist}
Summary:        Privacy-first sign-in logbook for shared lab computers (core + CLI)

License:        MIT
URL:            https://github.com/xdukunx/logix
# COPR/rpmbuild expects the release tarball named logix-%{version}.tar.gz with
# a top-level logix-%{version}/ directory (GitHub's auto-generated tag tarball
# matches when %setup -n is pointed at it; see -n below).
Source0:        %{url}/archive/refs/tags/v%{version}/logix-%{version}.tar.gz

BuildArch:      noarch
Requires:       python3

%description
Logix records who used a shared computer, when, and for what purpose -- never
screen contents or keystrokes. This package installs the cross-platform
logging core, report generator, Google Sheets sync (with a redaction gate),
the SSH-login hook, and the `logix` command. Run `sudo logix configure` once
after install. The physical at-keyboard sign-in prompt is Windows-only.

%prep
%setup -q -n logix-%{version}

%build
# Nothing to build -- pure Python, stdlib only.

%install
rm -rf %{buildroot}
install -d -m 0755 %{buildroot}%{logixlib}
install -m 0644 logix/paths.py            %{buildroot}%{logixlib}/paths.py
install -m 0644 logix/log_physical.py     %{buildroot}%{logixlib}/log_physical.py
install -m 0644 logix/logbook_report.py   %{buildroot}%{logixlib}/logbook_report.py
install -m 0644 logix/logbook_sql.py      %{buildroot}%{logixlib}/logbook_sql.py
install -m 0644 logix/logbook_ssh_login.py %{buildroot}%{logixlib}/logbook_ssh_login.py
install -m 0644 logix/gsheet_sync.py      %{buildroot}%{logixlib}/gsheet_sync.py
install -m 0644 install/install.py        %{buildroot}%{logixlib}/install.py
install -m 0644 VERSION                   %{buildroot}%{logixlib}/VERSION

install -d -m 0755 %{buildroot}%{_bindir}
install -m 0755 packaging/bin/logix       %{buildroot}%{_bindir}/logix

install -d -m 0755 %{buildroot}%{_docdir}/logix
install -m 0644 docs/PRIVACY.md           %{buildroot}%{_docdir}/logix/PRIVACY.md
install -m 0644 README.md                 %{buildroot}%{_docdir}/logix/README.md

%files
%{_bindir}/logix
%dir %{logixlib}
%{logixlib}/paths.py
%{logixlib}/log_physical.py
%{logixlib}/logbook_report.py
%{logixlib}/logbook_sql.py
%{logixlib}/logbook_ssh_login.py
%{logixlib}/gsheet_sync.py
%{logixlib}/install.py
%{logixlib}/VERSION
%doc %{_docdir}/logix/PRIVACY.md
%doc %{_docdir}/logix/README.md

%post
echo ""
echo "Logix core installed. One-time setup:  sudo logix configure"
echo "SSH capture (Linux): sudo ln -sf %{logixlib}/logix-ssh-hook.sh /etc/profile.d/zz_logbook_ssh.sh"
echo "Privacy: records who/how/when only -- see %{_docdir}/logix/PRIVACY.md"
echo ""

%changelog
* Mon Jul 21 2026 MindLab <noreply@github.com> - 1.1.1-1
- Attach deb/rpm to the GitHub Release on this tag (packaging work merged
  after v1.1.0 was cut).
* Mon Jul 21 2026 MindLab <noreply@github.com> - 1.1.0-1
- Initial RPM packaging of the Logix core + CLI.
