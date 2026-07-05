; ============================================================================
; Logix Agent — official Windows wizard installer (Inno Setup 6).
;
; Produces a single LogixAgentSetup.exe that deploys the sign-in/timer agent,
; installs AnyDesk 7 (for the dashboard "Remote" action), lays down the native
; Python logging core, collects the central-server settings, registers the
; non-elevated monitor scheduled task, and starts it. Runs elevated end-to-end.
;
; BUILD:  compile this file with Inno Setup 6 (ISCC.exe logix-agent.iss) — see
;         installer\README.md. Output lands in installer\Output\.
;
; Layout it installs:
;   C:\Program Files\Logix\      <- agent scripts + AnyDesk installer (read-only)
;   C:\ProgramData\Logix\        <- native Python core (log_physical.py, paths.py)
;   C:\ProgramData\MindLabLogbook\ <- runtime state (created by the agent)
; ============================================================================

#define AppName "Logix Agent"
#define AppVersion "1.0.0"
#define AppPublisher "MindLab"
#define SrcRoot ".."

[Setup]
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
; Agent scripts hardcode C:\Program Files\Logix, so the location is fixed.
DefaultDirName={commonpf64}\Logix
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64compatible
ArchitecturesAllowed=x64compatible
OutputDir=Output
OutputBaseFilename=LogixAgentSetup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName={#AppName}

[Files]
; Agent scripts -> C:\Program Files\Logix
Source: "{#SrcRoot}\windows\*.ps1"; DestDir: "{app}"; Flags: ignoreversion
; AnyDesk installer bundled so setup can deploy it silently
Source: "assets\anydesk-7-0-0.exe"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
; Optional branding logo (popup uses C:\Program Files\Logix\logo.png)
Source: "{#SrcRoot}\windows\logo.png"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
; Native Python logging core -> C:\ProgramData\Logix (Get-LogixCoreDir default)
Source: "{#SrcRoot}\logix\log_physical.py"; DestDir: "{commonappdata}\Logix"; Flags: ignoreversion
Source: "{#SrcRoot}\logix\paths.py"; DestDir: "{commonappdata}\Logix"; Flags: ignoreversion

[Run]
; Register the monitor task (non-elevated principal), install AnyDesk, write
; config.env from the wizard inputs, and start the agent -- all unattended.
Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\install_logbook_tasks.ps1"" -NonInteractive -RunNow -ServerUrl ""{code:GetServerUrl}"" -ServerApiKey ""{code:GetServerKey}"" -DeviceName ""{code:GetDeviceName}"" -AnyDeskInstaller ""{app}\anydesk-7-0-0.exe"""; \
  StatusMsg: "Registering Logix agent, installing AnyDesk, starting monitor..."; \
  Flags: runhidden waituntilterminated

[UninstallRun]
; Best-effort teardown: stop the monitor and unregister the task.
Filename: "schtasks.exe"; Parameters: "/End /TN ""MindLab Report Logbook Monitor"""; Flags: runhidden; RunOnceId: "StopTask"
Filename: "schtasks.exe"; Parameters: "/Delete /TN ""MindLab Report Logbook Monitor"" /F"; Flags: runhidden; RunOnceId: "DelTask"

[Code]
var
  ConfigPage: TInputQueryWizardPage;

procedure InitializeWizard;
begin
  ConfigPage := CreateInputQueryPage(wpSelectDir,
    'Central Server', 'Where should this device report?',
    'Enter the Logix central server details. These are written to ' +
    'C:\ProgramData\Logix\config.env and can be changed later.');
  ConfigPage.Add('Server URL (e.g. http://192.168.1.10:8000):', False);
  ConfigPage.Add('Server API key (X-API-Key / ingest key):', False);
  ConfigPage.Add('Device name (blank = this PC''s hostname):', False);
  ConfigPage.Values[0] := 'http://localhost:8000';
end;

function GetServerUrl(Param: string): string;
begin
  Result := Trim(ConfigPage.Values[0]);
end;

function GetServerKey(Param: string): string;
begin
  Result := Trim(ConfigPage.Values[1]);
end;

function GetDeviceName(Param: string): string;
begin
  Result := Trim(ConfigPage.Values[2]);
end;

// Warn (don't block) if no Python is on PATH -- the sign-in/timer/lock/remote
// features are pure PowerShell and work regardless, but the local session-log
// bridge (log_physical.py) needs Python 3.
procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
begin
  if CurStep = ssPostInstall then
  begin
    if not Exec('cmd.exe', '/c where python || where py', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then
      MsgBox('Logix installed. Note: Python 3 was not found on PATH. The agent ' +
             'runs fine, but local session logging (log_physical.py) needs ' +
             'Python 3 — install it from python.org to enable it.', mbInformation, MB_OK);
  end;
end;
