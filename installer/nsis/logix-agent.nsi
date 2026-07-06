; ============================================================================
; Logix Agent - NSIS installer (compact, Comnyang-style classic UI).
;
; An alternative to the Inno Setup wizard (installer\logix-agent.iss) with the
; small NSIS window + mascot branding strip + EN/ID language picker. Installs
; the exact same payload and runs the same registrar, so the two are
; functionally interchangeable.
;
; BUILD:  installer\nsis\build.ps1        (real installer)
;         installer\nsis\build.ps1 -Preview  (no-UAC UI preview, installs nothing)
;
; Compile with a define to switch modes:
;   makensis logix-agent.nsi              -> real, elevated installer
;   makensis /DPREVIEW logix-agent.nsi    -> user-level UI preview (no install)
; ============================================================================
Unicode true
!include "nsDialogs.nsh"
!include "LogicLib.nsh"

; Paths are anchored to this script's folder so compile CWD doesn't matter.
!define SRC      "${__FILEDIR__}\..\.."
!define INSTDIRR "${__FILEDIR__}\.."
!define TASKNAME "MindLab Report Logbook Monitor"

Name "Logix"
!ifdef PREVIEW
OutFile "${INSTDIRR}\Output\LogixAgentSetup-nsis-preview.exe"
RequestExecutionLevel user
!else
OutFile "${INSTDIRR}\Output\LogixAgentSetup-nsis.exe"
RequestExecutionLevel admin
!endif
InstallDir "$PROGRAMFILES64\Logix"
SetCompressor /SOLID lzma
XPStyle on
BrandingText "Logix"
Icon "${INSTDIRR}\branding\logix.ico"
UninstallIcon "${INSTDIRR}\branding\logix.ico"

; Mascot strip down the left of every page -- the Comnyang cat-next-to-progress look.
AddBrandingImage left 96

Var Dialog
Var UrlBox
Var KeyBox
Var DeviceBox
Var ServerUrl
Var ServerApiKey
Var DeviceName

; --- Languages (both bundled with NSIS; no custom translation needed) --------
LoadLanguageFile "${NSISDIR}\Contrib\Language files\English.nlf"
LoadLanguageFile "${NSISDIR}\Contrib\Language files\Indonesian.nlf"

LangString CfgTitle  ${LANG_ENGLISH}    "Connect to your Logix server"
LangString CfgTitle  ${LANG_INDONESIAN} "Hubungkan ke server Logix"
LangString CfgBody   ${LANG_ENGLISH}    "Tell this device where the dashboard lives. Saved to C:\ProgramData\Logix\config.env; ask your Logix admin for the address and key."
LangString CfgBody   ${LANG_INDONESIAN} "Beri tahu perangkat ini di mana dashboard berada. Disimpan di C:\ProgramData\Logix\config.env; minta alamat & kunci ke admin Logix."
LangString CfgUrl    ${LANG_ENGLISH}    "Server URL (e.g. https://logix.example.org):"
LangString CfgUrl    ${LANG_INDONESIAN} "URL Server (mis. https://logix.example.org):"
LangString CfgKey    ${LANG_ENGLISH}    "Server API key (ingest key from your server):"
LangString CfgKey    ${LANG_INDONESIAN} "Kunci API server (ingest key dari server kamu):"
LangString CfgDev    ${LANG_ENGLISH}    "Device name (blank = this PC's name):"
LangString CfgDev    ${LANG_INDONESIAN} "Nama perangkat (kosong = nama PC ini):"
LangString NeedUrl   ${LANG_ENGLISH}    "Please enter the Logix server URL."
LangString NeedUrl   ${LANG_INDONESIAN} "Masukkan URL server Logix."
LangString NeedKey   ${LANG_ENGLISH}    "Please enter the server API key."
LangString NeedKey   ${LANG_INDONESIAN} "Masukkan kunci API server."
LangString StatusReg ${LANG_ENGLISH}    "Registering Logix agent, installing AnyDesk, starting monitor..."
LangString StatusReg ${LANG_INDONESIAN} "Mendaftarkan agen Logix, memasang AnyDesk, memulai monitor..."
LangString PyMissing ${LANG_ENGLISH}    "Logix installed. Note: Python 3 wasn't found on PATH; local session logging (log_physical.py) needs it. Install from python.org to enable."
LangString PyMissing ${LANG_INDONESIAN} "Logix terpasang. Catatan: Python 3 tidak ada di PATH; pencatatan sesi lokal (log_physical.py) butuh itu. Pasang dari python.org untuk mengaktifkan."

; --- Pages -------------------------------------------------------------------
Page custom ConfigPageCreate ConfigPageLeave
Page instfiles
UninstPage uninstConfirm
UninstPage instfiles

Function .onInit
  InitPluginsDir
  File "/oname=$PLUGINSDIR\brand.bmp" "${INSTDIRR}\branding\wizard-small.bmp"
  ; Language picker (official languages.nsi pattern): push "", then id/name
  ; pairs, then "A" (auto-count), then the dialog title/text.
  Push ""
  Push ${LANG_ENGLISH}
  Push English
  Push ${LANG_INDONESIAN}
  Push "Bahasa Indonesia"
  Push A
  LangDLL::LangDialog "Logix Setup" "Choose language / Pilih bahasa"
  Pop $LANGUAGE
  StrCmp $LANGUAGE "cancel" 0 +2
    Abort
FunctionEnd

Function .onGUIInit
  SetBrandingImage /RESIZETOFIT "$PLUGINSDIR\brand.bmp"
FunctionEnd

Function ConfigPageCreate
  nsDialogs::Create 1018
  Pop $Dialog
  ${If} $Dialog == error
    Abort
  ${EndIf}

  ${NSD_CreateLabel} 0 0 100% 22u "$(CfgTitle)"
  Pop $0
  ${NSD_CreateLabel} 0 24u 100% 30u "$(CfgBody)"
  Pop $0

  ${NSD_CreateLabel} 0 60u 100% 11u "$(CfgUrl)"
  Pop $0
  ${NSD_CreateText} 0 72u 100% 12u "http://localhost:8000"
  Pop $UrlBox

  ${NSD_CreateLabel} 0 90u 100% 11u "$(CfgKey)"
  Pop $0
  ${NSD_CreateText} 0 102u 100% 12u ""
  Pop $KeyBox

  ${NSD_CreateLabel} 0 120u 100% 11u "$(CfgDev)"
  Pop $0
  ${NSD_CreateText} 0 132u 100% 12u ""
  Pop $DeviceBox

  nsDialogs::Show
FunctionEnd

Function ConfigPageLeave
  ${NSD_GetText} $UrlBox $ServerUrl
  ${NSD_GetText} $KeyBox $ServerApiKey
  ${NSD_GetText} $DeviceBox $DeviceName
  ${If} $ServerUrl == ""
    MessageBox MB_ICONEXCLAMATION|MB_OK "$(NeedUrl)"
    Abort
  ${EndIf}
  ${If} $ServerApiKey == ""
    MessageBox MB_ICONEXCLAMATION|MB_OK "$(NeedKey)"
    Abort
  ${EndIf}
FunctionEnd

Section "Logix" SecMain
  SetOutPath "$INSTDIR"
!ifndef PREVIEW
  ; Runtime scripts (exclude the dev/test harnesses).
  File /x "test_*.ps1" /x "preview_popup.ps1" "${SRC}\windows\*.ps1"
  File "${INSTDIRR}\assets\anydesk-7-0-0.exe"
  File "${SRC}\windows\logo.png"
  File "${INSTDIRR}\branding\logix.ico"

  ; Native Python core -> C:\ProgramData\Logix (all-users context).
  SetShellVarContext all
  SetOutPath "$APPDATA\Logix"
  File "${SRC}\logix\log_physical.py"
  File "${SRC}\logix\paths.py"
  SetOutPath "$INSTDIR"

  DetailPrint "$(StatusReg)"
  nsExec::ExecToLog 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\install_logbook_tasks.ps1" -NonInteractive -RunNow -ServerUrl "$ServerUrl" -ServerApiKey "$ServerApiKey" -DeviceName "$DeviceName" -AnyDeskInstaller "$INSTDIR\anydesk-7-0-0.exe"'
  Pop $0

  nsExec::ExecToStack 'cmd.exe /c where python || where py'
  Pop $0
  ${If} $0 != 0
    MessageBox MB_ICONINFORMATION|MB_OK "$(PyMissing)"
  ${EndIf}

  WriteUninstaller "$INSTDIR\uninstall.exe"
  !define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\Logix"
  WriteRegStr HKLM "${UNINST_KEY}" "DisplayName" "Logix"
  WriteRegStr HKLM "${UNINST_KEY}" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegStr HKLM "${UNINST_KEY}" "DisplayIcon" "$INSTDIR\logix.ico"
  WriteRegStr HKLM "${UNINST_KEY}" "Publisher" "MindLab"
  WriteRegDWORD HKLM "${UNINST_KEY}" "NoModify" 1
  WriteRegDWORD HKLM "${UNINST_KEY}" "NoRepair" 1
!else
  DetailPrint "PREVIEW build - nothing is installed."
  Sleep 500
  DetailPrint "$(StatusReg)"
  Sleep 1200
!endif
SectionEnd

Section "Uninstall"
  nsExec::ExecToLog 'schtasks.exe /End /TN "${TASKNAME}"'
  nsExec::ExecToLog 'schtasks.exe /Delete /TN "${TASKNAME}" /F'
  Delete "$INSTDIR\*.ps1"
  Delete "$INSTDIR\anydesk-7-0-0.exe"
  Delete "$INSTDIR\logo.png"
  Delete "$INSTDIR\logix.ico"
  Delete "$INSTDIR\uninstall.exe"
  RMDir "$INSTDIR"
  SetShellVarContext all
  Delete "$APPDATA\Logix\log_physical.py"
  Delete "$APPDATA\Logix\paths.py"
  RMDir "$APPDATA\Logix"
  DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Logix"
SectionEnd
