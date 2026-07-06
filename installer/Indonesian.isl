; *** Inno Setup 6 Indonesian messages (Bahasa Indonesia) ***
; Provided with Logix so the agent installer can offer an EN/ID language
; picker. Values are ASCII-only (Indonesian needs no diacritics), so this
; file is safe regardless of BOM/codepage. Keys mirror Default.isl exactly.

[LangOptions]
LanguageName=Bahasa Indonesia
LanguageID=$0421
LanguageCodePage=0

[Messages]

; *** Application titles
SetupAppTitle=Pemasangan
SetupWindowTitle=Pemasangan - %1
UninstallAppTitle=Hapus Instalasi
UninstallAppFullTitle=Hapus Instalasi %1

; *** Misc. common
InformationTitle=Informasi
ConfirmTitle=Konfirmasi
ErrorTitle=Kesalahan

; *** SetupLdr messages
SetupLdrStartupMessage=Ini akan memasang %1. Apakah Anda ingin melanjutkan?
LdrCannotCreateTemp=Tidak dapat membuat berkas sementara. Pemasangan dibatalkan
LdrCannotExecTemp=Tidak dapat menjalankan berkas di direktori sementara. Pemasangan dibatalkan
HelpTextNote=

; *** Startup error messages
LastErrorMessage=%1.%n%nKesalahan %2: %3
SetupFileMissing=Berkas %1 tidak ada di direktori pemasangan. Perbaiki masalah ini atau dapatkan salinan baru dari program.
SetupFileCorrupt=Berkas pemasangan rusak. Dapatkan salinan baru dari program.
SetupFileCorruptOrWrongVer=Berkas pemasangan rusak, atau tidak cocok dengan versi Pemasangan ini. Perbaiki masalah ini atau dapatkan salinan baru dari program.
InvalidParameter=Parameter yang tidak valid diberikan pada baris perintah:%n%n%1
SetupAlreadyRunning=Pemasangan sedang berjalan.
WindowsVersionNotSupported=Program ini tidak mendukung versi Windows yang dijalankan komputer Anda.
WindowsServicePackRequired=Program ini membutuhkan %1 Service Pack %2 atau yang lebih baru.
NotOnThisPlatform=Program ini tidak akan berjalan pada %1.
OnlyOnThisPlatform=Program ini harus dijalankan pada %1.
OnlyOnTheseArchitectures=Program ini hanya dapat dipasang pada versi Windows untuk arsitektur prosesor berikut:%n%n%1
WinVersionTooLowError=Program ini membutuhkan %1 versi %2 atau yang lebih baru.
WinVersionTooHighError=Program ini tidak dapat dipasang pada %1 versi %2 atau yang lebih baru.
AdminPrivilegesRequired=Anda harus masuk sebagai administrator saat memasang program ini.
PowerUserPrivilegesRequired=Anda harus masuk sebagai administrator atau anggota grup Power Users saat memasang program ini.
SetupAppRunningError=Pemasangan mendeteksi bahwa %1 sedang berjalan.%n%nTutup semua instansinya sekarang, lalu klik OK untuk melanjutkan, atau Batal untuk keluar.
UninstallAppRunningError=Penghapusan mendeteksi bahwa %1 sedang berjalan.%n%nTutup semua instansinya sekarang, lalu klik OK untuk melanjutkan, atau Batal untuk keluar.

; *** Startup questions
PrivilegesRequiredOverrideTitle=Pilih Mode Pemasangan
PrivilegesRequiredOverrideInstruction=Pilih mode pemasangan
PrivilegesRequiredOverrideText1=%1 dapat dipasang untuk semua pengguna (membutuhkan hak administrator), atau untuk Anda saja.
PrivilegesRequiredOverrideText2=%1 dapat dipasang untuk Anda saja, atau untuk semua pengguna (membutuhkan hak administrator).
PrivilegesRequiredOverrideAllUsers=Pasang untuk &semua pengguna
PrivilegesRequiredOverrideAllUsersRecommended=Pasang untuk &semua pengguna (disarankan)
PrivilegesRequiredOverrideCurrentUser=Pasang untuk sa&ya saja
PrivilegesRequiredOverrideCurrentUserRecommended=Pasang untuk sa&ya saja (disarankan)

; *** Misc. errors
ErrorCreatingDir=Pemasangan tidak dapat membuat direktori "%1"
ErrorTooManyFilesInDir=Tidak dapat membuat berkas di direktori "%1" karena berisi terlalu banyak berkas

; *** Setup common messages
ExitSetupTitle=Keluar dari Pemasangan
ExitSetupMessage=Pemasangan belum selesai. Jika Anda keluar sekarang, program tidak akan terpasang.%n%nAnda dapat menjalankan Pemasangan lagi di lain waktu untuk menyelesaikannya.%n%nKeluar dari Pemasangan?
AboutSetupMenuItem=&Tentang Pemasangan...
AboutSetupTitle=Tentang Pemasangan
AboutSetupMessage=%1 versi %2%n%3%n%nHalaman utama %1:%n%4
AboutSetupNote=
TranslatorNote=

; *** Buttons
ButtonBack=< &Kembali
ButtonNext=&Berikutnya >
ButtonInstall=&Pasang
ButtonOK=OK
ButtonCancel=Batal
ButtonYes=&Ya
ButtonYesToAll=Ya untuk Se&mua
ButtonNo=&Tidak
ButtonNoToAll=T&idak untuk Semua
ButtonFinish=&Selesai
ButtonBrowse=&Telusuri...
ButtonWizardBrowse=Te&lusuri...
ButtonNewFolder=&Buat Folder Baru

; *** "Select Language" dialog messages
SelectLanguageTitle=Pilih Bahasa Pemasangan
SelectLanguageLabel=Pilih bahasa yang digunakan selama pemasangan.

; *** Common wizard text
ClickNext=Klik Berikutnya untuk melanjutkan, atau Batal untuk keluar dari Pemasangan.
BeveledLabel=
BrowseDialogTitle=Telusuri Folder
BrowseDialogLabel=Pilih folder pada daftar di bawah, lalu klik OK.
NewFolderName=Folder Baru

; *** "Welcome" wizard page
WelcomeLabel1=Selamat datang di Wizard Pemasangan [name]
WelcomeLabel2=Ini akan memasang [name/ver] pada komputer Anda.%n%nDisarankan untuk menutup semua aplikasi lain sebelum melanjutkan.

; *** "Password" wizard page
WizardPassword=Kata Sandi
PasswordLabel1=Pemasangan ini dilindungi kata sandi.
PasswordLabel3=Masukkan kata sandi, lalu klik Berikutnya untuk melanjutkan. Kata sandi bersifat peka huruf besar/kecil.
PasswordEditLabel=&Kata sandi:
IncorrectPassword=Kata sandi yang Anda masukkan salah. Coba lagi.

; *** "License Agreement" wizard page
WizardLicense=Perjanjian Lisensi
LicenseLabel=Baca informasi penting berikut sebelum melanjutkan.
LicenseLabel3=Baca Perjanjian Lisensi berikut. Anda harus menyetujui ketentuan perjanjian ini sebelum melanjutkan pemasangan.
LicenseAccepted=Saya &menyetujui perjanjian
LicenseNotAccepted=Saya &tidak menyetujui perjanjian

; *** "Information" wizard pages
WizardInfoBefore=Informasi
InfoBeforeLabel=Baca informasi penting berikut sebelum melanjutkan.
InfoBeforeClickLabel=Bila Anda siap melanjutkan Pemasangan, klik Berikutnya.
WizardInfoAfter=Informasi
InfoAfterLabel=Baca informasi penting berikut sebelum melanjutkan.
InfoAfterClickLabel=Bila Anda siap melanjutkan Pemasangan, klik Berikutnya.

; *** "User Information" wizard page
WizardUserInfo=Informasi Pengguna
UserInfoDesc=Masukkan informasi Anda.
UserInfoName=&Nama Pengguna:
UserInfoOrg=&Organisasi:
UserInfoSerial=Nomor &Seri:
UserInfoNameRequired=Anda harus memasukkan nama.

; *** "Select Destination Location" wizard page
WizardSelectDir=Pilih Lokasi Tujuan
SelectDirDesc=Di mana [name] akan dipasang?
SelectDirLabel3=Pemasangan akan memasang [name] ke folder berikut.
SelectDirBrowseLabel=Untuk melanjutkan, klik Berikutnya. Jika ingin memilih folder lain, klik Telusuri.
DiskSpaceGBLabel=Dibutuhkan setidaknya [gb] GB ruang disk kosong.
DiskSpaceMBLabel=Dibutuhkan setidaknya [mb] MB ruang disk kosong.
CannotInstallToNetworkDrive=Pemasangan tidak dapat memasang ke drive jaringan.
CannotInstallToUNCPath=Pemasangan tidak dapat memasang ke path UNC.
InvalidPath=Anda harus memasukkan path lengkap dengan huruf drive; contoh:%n%nC:\APP%n%natau path UNC dalam bentuk:%n%n\\server\share
InvalidDrive=Drive atau share UNC yang Anda pilih tidak ada atau tidak dapat diakses. Pilih yang lain.
DiskSpaceWarningTitle=Ruang Disk Tidak Cukup
DiskSpaceWarning=Pemasangan membutuhkan setidaknya %1 KB ruang kosong, tetapi drive yang dipilih hanya memiliki %2 KB tersedia.%n%nApakah Anda tetap ingin melanjutkan?
DirNameTooLong=Nama folder atau path terlalu panjang.
InvalidDirName=Nama folder tidak valid.
BadDirName32=Nama folder tidak boleh mengandung karakter berikut:%n%n%1
DirExistsTitle=Folder Sudah Ada
DirExists=Folder:%n%n%1%n%nsudah ada. Apakah Anda tetap ingin memasang ke folder tersebut?
DirDoesntExistTitle=Folder Tidak Ada
DirDoesntExist=Folder:%n%n%1%n%ntidak ada. Apakah Anda ingin folder tersebut dibuat?

; *** "Select Components" wizard page
WizardSelectComponents=Pilih Komponen
SelectComponentsDesc=Komponen mana yang akan dipasang?
SelectComponentsLabel2=Pilih komponen yang ingin Anda pasang; hapus centang komponen yang tidak ingin dipasang. Klik Berikutnya bila siap melanjutkan.
FullInstallation=Pemasangan penuh
CompactInstallation=Pemasangan ringkas
CustomInstallation=Pemasangan kustom
NoUninstallWarningTitle=Komponen Sudah Ada
NoUninstallWarning=Pemasangan mendeteksi komponen berikut sudah terpasang pada komputer Anda:%n%n%1%n%nMenghapus centang komponen ini tidak akan menghapus instalasinya.%n%nApakah Anda tetap ingin melanjutkan?
ComponentSize1=%1 KB
ComponentSize2=%1 MB
ComponentsDiskSpaceGBLabel=Pilihan saat ini membutuhkan setidaknya [gb] GB ruang disk.
ComponentsDiskSpaceMBLabel=Pilihan saat ini membutuhkan setidaknya [mb] MB ruang disk.

; *** "Select Additional Tasks" wizard page
WizardSelectTasks=Pilih Tugas Tambahan
SelectTasksDesc=Tugas tambahan mana yang akan dilakukan?
SelectTasksLabel2=Pilih tugas tambahan yang ingin dilakukan Pemasangan saat memasang [name], lalu klik Berikutnya.

; *** "Select Start Menu Folder" wizard page
WizardSelectProgramGroup=Pilih Folder Menu Start
SelectStartMenuFolderDesc=Di mana Pemasangan akan menempatkan pintasan program?
SelectStartMenuFolderLabel3=Pemasangan akan membuat pintasan program di folder Menu Start berikut.
SelectStartMenuFolderBrowseLabel=Untuk melanjutkan, klik Berikutnya. Jika ingin memilih folder lain, klik Telusuri.
MustEnterGroupName=Anda harus memasukkan nama folder.
GroupNameTooLong=Nama folder atau path terlalu panjang.
InvalidGroupName=Nama folder tidak valid.
BadGroupName=Nama folder tidak boleh mengandung karakter berikut:%n%n%1
NoProgramGroupCheck2=&Jangan buat folder Menu Start

; *** "Ready to Install" wizard page
WizardReady=Siap Memasang
ReadyLabel1=Pemasangan siap mulai memasang [name] pada komputer Anda.
ReadyLabel2a=Klik Pasang untuk melanjutkan pemasangan, atau klik Kembali jika ingin meninjau atau mengubah pengaturan.
ReadyLabel2b=Klik Pasang untuk melanjutkan pemasangan.
ReadyMemoUserInfo=Informasi pengguna:
ReadyMemoDir=Lokasi tujuan:
ReadyMemoType=Tipe pemasangan:
ReadyMemoComponents=Komponen terpilih:
ReadyMemoGroup=Folder Menu Start:
ReadyMemoTasks=Tugas tambahan:

; *** TDownloadWizardPage wizard page and DownloadTemporaryFile
DownloadingLabel2=Mengunduh berkas...
ButtonStopDownload=&Hentikan unduhan
StopDownload=Apakah Anda yakin ingin menghentikan unduhan?
ErrorDownloadAborted=Unduhan dibatalkan
ErrorDownloadFailed=Unduhan gagal: %1 %2
ErrorDownloadSizeFailed=Gagal mendapatkan ukuran: %1 %2
ErrorProgress=Progres tidak valid: %1 dari %2
ErrorFileSize=Ukuran berkas tidak valid: diharapkan %1, ditemukan %2

; *** TExtractionWizardPage wizard page and ExtractArchive
ExtractingLabel=Mengekstrak berkas...
ButtonStopExtraction=&Hentikan ekstraksi
StopExtraction=Apakah Anda yakin ingin menghentikan ekstraksi?
ErrorExtractionAborted=Ekstraksi dibatalkan
ErrorExtractionFailed=Ekstraksi gagal: %1

; *** Archive extraction failure details
ArchiveIncorrectPassword=Kata sandi salah
ArchiveIsCorrupted=Arsip rusak
ArchiveUnsupportedFormat=Format arsip tidak didukung

; *** "Preparing to Install" wizard page
WizardPreparing=Bersiap Memasang
PreparingDesc=Pemasangan sedang bersiap memasang [name] pada komputer Anda.
PreviousInstallNotCompleted=Pemasangan/penghapusan program sebelumnya belum selesai. Anda perlu memulai ulang komputer untuk menyelesaikannya.%n%nSetelah memulai ulang komputer, jalankan Pemasangan lagi untuk menyelesaikan pemasangan [name].
CannotContinue=Pemasangan tidak dapat dilanjutkan. Klik Batal untuk keluar.
ApplicationsFound=Aplikasi berikut menggunakan berkas yang perlu diperbarui oleh Pemasangan. Disarankan agar Anda mengizinkan Pemasangan menutup aplikasi ini secara otomatis.
ApplicationsFound2=Aplikasi berikut menggunakan berkas yang perlu diperbarui oleh Pemasangan. Disarankan agar Anda mengizinkan Pemasangan menutup aplikasi ini secara otomatis. Setelah pemasangan selesai, Pemasangan akan mencoba menjalankan ulang aplikasi tersebut.
CloseApplications=&Tutup aplikasi secara otomatis
DontCloseApplications=&Jangan tutup aplikasi
ErrorCloseApplications=Pemasangan tidak dapat menutup semua aplikasi secara otomatis. Disarankan agar Anda menutup semua aplikasi yang menggunakan berkas yang perlu diperbarui sebelum melanjutkan.
PrepareToInstallNeedsRestart=Pemasangan harus memulai ulang komputer Anda. Setelah memulai ulang, jalankan Pemasangan lagi untuk menyelesaikan pemasangan [name].%n%nApakah Anda ingin memulai ulang sekarang?

; *** "Installing" wizard page
WizardInstalling=Memasang
InstallingLabel=Harap tunggu selagi Pemasangan memasang [name] pada komputer Anda.

; *** "Setup Completed" wizard page
FinishedHeadingLabel=Menyelesaikan Wizard Pemasangan [name]
FinishedLabelNoIcons=Pemasangan telah selesai memasang [name] pada komputer Anda.
FinishedLabel=Pemasangan telah selesai memasang [name] pada komputer Anda. Aplikasi dapat dijalankan melalui pintasan yang terpasang.
ClickFinish=Klik Selesai untuk keluar dari Pemasangan.
FinishedRestartLabel=Untuk menyelesaikan pemasangan [name], Pemasangan harus memulai ulang komputer Anda. Apakah Anda ingin memulai ulang sekarang?
FinishedRestartMessage=Untuk menyelesaikan pemasangan [name], Pemasangan harus memulai ulang komputer Anda.%n%nApakah Anda ingin memulai ulang sekarang?
ShowReadmeCheck=Ya, saya ingin membaca berkas README
YesRadio=&Ya, mulai ulang komputer sekarang
NoRadio=&Tidak, saya akan memulai ulang komputer nanti
RunEntryExec=Jalankan %1
RunEntryShellExec=Lihat %1

; *** "Setup Needs the Next Disk" stuff
ChangeDiskTitle=Pemasangan Membutuhkan Disk Berikutnya
SelectDiskLabel2=Masukkan Disk %1 dan klik OK.%n%nJika berkas pada disk ini ada di folder selain yang ditampilkan di bawah, masukkan path yang benar atau klik Telusuri.
PathLabel=&Path:
FileNotInDir2=Berkas "%1" tidak dapat ditemukan di "%2". Masukkan disk yang benar atau pilih folder lain.
SelectDirectoryLabel=Tentukan lokasi disk berikutnya.

; *** Installation phase messages
SetupAborted=Pemasangan tidak selesai.%n%nPerbaiki masalah ini dan jalankan Pemasangan lagi.
AbortRetryIgnoreSelectAction=Pilih tindakan
AbortRetryIgnoreRetry=&Coba lagi
AbortRetryIgnoreIgnore=&Abaikan kesalahan dan lanjutkan
AbortRetryIgnoreCancel=Batalkan pemasangan
RetryCancelSelectAction=Pilih tindakan
RetryCancelRetry=&Coba lagi
RetryCancelCancel=Batal

; *** Installation status messages
StatusClosingApplications=Menutup aplikasi...
StatusCreateDirs=Membuat direktori...
StatusExtractFiles=Mengekstrak berkas...
StatusDownloadFiles=Mengunduh berkas...
StatusCreateIcons=Membuat pintasan...
StatusCreateIniEntries=Membuat entri INI...
StatusCreateRegistryEntries=Membuat entri registri...
StatusRegisterFiles=Mendaftarkan berkas...
StatusSavingUninstall=Menyimpan informasi penghapusan...
StatusRunProgram=Menyelesaikan pemasangan...
StatusRestartingApplications=Menjalankan ulang aplikasi...
StatusRollback=Mengembalikan perubahan...

; *** Misc. errors
ErrorInternal2=Kesalahan internal: %1
ErrorFunctionFailedNoCode=%1 gagal
ErrorFunctionFailed=%1 gagal; kode %2
ErrorFunctionFailedWithMessage=%1 gagal; kode %2.%n%3
ErrorExecutingProgram=Tidak dapat menjalankan berkas:%n%1

; *** Registry errors
ErrorRegOpenKey=Kesalahan membuka kunci registri:%n%1\%2
ErrorRegCreateKey=Kesalahan membuat kunci registri:%n%1\%2
ErrorRegWriteKey=Kesalahan menulis ke kunci registri:%n%1\%2

; *** INI errors
ErrorIniEntry=Kesalahan membuat entri INI di berkas "%1".

; *** File copying errors
FileAbortRetryIgnoreSkipNotRecommended=&Lewati berkas ini (tidak disarankan)
FileAbortRetryIgnoreIgnoreNotRecommended=&Abaikan kesalahan dan lanjutkan (tidak disarankan)
SourceIsCorrupted=Berkas sumber rusak
SourceDoesntExist=Berkas sumber "%1" tidak ada
SourceVerificationFailed=Verifikasi berkas sumber gagal: %1
VerificationSignatureDoesntExist=Berkas tanda tangan "%1" tidak ada
VerificationSignatureInvalid=Berkas tanda tangan "%1" tidak valid
VerificationKeyNotFound=Berkas tanda tangan "%1" menggunakan kunci yang tidak dikenal
VerificationFileNameIncorrect=Nama berkas salah
VerificationFileTagIncorrect=Tag berkas salah
VerificationFileSizeIncorrect=Ukuran berkas salah
VerificationFileHashIncorrect=Hash berkas salah
ExistingFileReadOnly2=Berkas yang ada tidak dapat diganti karena ditandai hanya-baca.
ExistingFileReadOnlyRetry=&Hapus atribut hanya-baca dan coba lagi
ExistingFileReadOnlyKeepExisting=&Pertahankan berkas yang ada
ErrorReadingExistingDest=Terjadi kesalahan saat mencoba membaca berkas yang ada:
FileExistsSelectAction=Pilih tindakan
FileExists2=Berkas sudah ada.
FileExistsOverwriteExisting=&Timpa berkas yang ada
FileExistsKeepExisting=&Pertahankan berkas yang ada
FileExistsOverwriteOrKeepAll=&Lakukan ini untuk konflik berikutnya
ExistingFileNewerSelectAction=Pilih tindakan
ExistingFileNewer2=Berkas yang ada lebih baru daripada yang akan dipasang Pemasangan.
ExistingFileNewerOverwriteExisting=&Timpa berkas yang ada
ExistingFileNewerKeepExisting=&Pertahankan berkas yang ada (disarankan)
ExistingFileNewerOverwriteOrKeepAll=&Lakukan ini untuk konflik berikutnya
ErrorChangingAttr=Terjadi kesalahan saat mencoba mengubah atribut berkas yang ada:
ErrorCreatingTemp=Terjadi kesalahan saat mencoba membuat berkas di direktori tujuan:
ErrorReadingSource=Terjadi kesalahan saat mencoba membaca berkas sumber:
ErrorCopying=Terjadi kesalahan saat mencoba menyalin berkas:
ErrorDownloading=Terjadi kesalahan saat mencoba mengunduh berkas:
ErrorExtracting=Terjadi kesalahan saat mencoba mengekstrak arsip:
ErrorReplacingExistingFile=Terjadi kesalahan saat mencoba mengganti berkas yang ada:
ErrorRestartReplace=RestartReplace gagal:
ErrorRenamingTemp=Terjadi kesalahan saat mencoba mengganti nama berkas di direktori tujuan:
ErrorRegisterServer=Tidak dapat mendaftarkan DLL/OCX: %1
ErrorRegSvr32Failed=RegSvr32 gagal dengan kode keluar %1
ErrorRegisterTypeLib=Tidak dapat mendaftarkan type library: %1

; *** Uninstall display name markings
UninstallDisplayNameMark=%1 (%2)
UninstallDisplayNameMarks=%1 (%2, %3)
UninstallDisplayNameMark32Bit=32-bit
UninstallDisplayNameMark64Bit=64-bit
UninstallDisplayNameMarkAllUsers=Semua pengguna
UninstallDisplayNameMarkCurrentUser=Pengguna saat ini

; *** Post-installation errors
ErrorOpeningReadme=Terjadi kesalahan saat mencoba membuka berkas README.
ErrorRestartingComputer=Pemasangan tidak dapat memulai ulang komputer. Lakukan secara manual.

; *** Uninstaller messages
UninstallNotFound=Berkas "%1" tidak ada. Tidak dapat menghapus instalasi.
UninstallOpenError=Berkas "%1" tidak dapat dibuka. Tidak dapat menghapus instalasi
UninstallUnsupportedVer=Berkas log penghapusan "%1" dalam format yang tidak dikenali oleh versi penghapus ini. Tidak dapat menghapus instalasi
UninstallUnknownEntry=Entri tidak dikenal (%1) ditemukan di log penghapusan
ConfirmUninstall=Apakah Anda yakin ingin menghapus %1 sepenuhnya beserta semua komponennya?
UninstallOnlyOnWin64=Pemasangan ini hanya dapat dihapus pada Windows 64-bit.
OnlyAdminCanUninstall=Pemasangan ini hanya dapat dihapus oleh pengguna dengan hak administrator.
UninstallStatusLabel=Harap tunggu selagi %1 dihapus dari komputer Anda.
UninstalledAll=%1 berhasil dihapus dari komputer Anda.
UninstalledMost=Penghapusan %1 selesai.%n%nBeberapa elemen tidak dapat dihapus. Elemen ini dapat dihapus secara manual.
UninstalledAndNeedsRestart=Untuk menyelesaikan penghapusan %1, komputer Anda harus dimulai ulang.%n%nApakah Anda ingin memulai ulang sekarang?
UninstallDataCorrupted=Berkas "%1" rusak. Tidak dapat menghapus instalasi

; *** Uninstallation phase messages
ConfirmDeleteSharedFileTitle=Hapus Berkas Bersama?
ConfirmDeleteSharedFile2=Sistem menunjukkan bahwa berkas bersama berikut tidak lagi digunakan oleh program apa pun. Apakah Anda ingin Penghapusan menghapus berkas bersama ini?%n%nJika masih ada program yang menggunakan berkas ini dan berkas dihapus, program tersebut mungkin tidak berfungsi dengan baik. Jika Anda tidak yakin, pilih Tidak. Membiarkan berkas di sistem tidak akan menimbulkan masalah.
SharedFileNameLabel=Nama berkas:
SharedFileLocationLabel=Lokasi:
WizardUninstalling=Status Penghapusan
StatusUninstalling=Menghapus %1...

; *** Shutdown block reasons
ShutdownBlockReasonInstallingApp=Memasang %1.
ShutdownBlockReasonUninstallingApp=Menghapus %1.

[CustomMessages]

NameAndVersion=%1 versi %2
AdditionalIcons=Pintasan tambahan:
CreateDesktopIcon=Buat pintasan di &desktop
CreateQuickLaunchIcon=Buat pintasan &Quick Launch
ProgramOnTheWeb=%1 di Web
UninstallProgram=Hapus %1
LaunchProgram=Jalankan %1
AssocFileExtension=&Kaitkan %1 dengan ekstensi berkas %2
AssocingFileExtension=Mengaitkan %1 dengan ekstensi berkas %2...
AutoStartProgramGroupDescription=Startup:
AutoStartProgram=Jalankan %1 secara otomatis
AddonHostProgramNotFound=%1 tidak dapat ditemukan di folder yang Anda pilih.%n%nApakah Anda tetap ingin melanjutkan?
