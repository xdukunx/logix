# On-demand screen capture for the Logix Control "screenshot" feature. Kept in
# its OWN script (not logbook_common.ps1) because the capture-and-upload pattern
# trips Windows Defender's AMSI; isolating it means an AV objection breaks only
# this one feature, not the whole agent. The SCREENSHOT command handler in
# logbook_common.ps1 (Invoke-LogbookScreenshotCapture) shells out to this.
# Never silent: that handler drops an on-screen notice for the timer widget
# before invoking this.
param([Parameter(Mandatory=$true)][string]$CommandId, [switch]$STAChild)
$ErrorActionPreference = 'Stop'
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA' -and -not $STAChild) {
    Start-Process powershell.exe -WindowStyle Hidden -Wait -ArgumentList @(
        '-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-CommandId',$CommandId,'-STAChild') | Out-Null
    exit 0
}
. 'C:\Program Files\Logix\logbook_common.ps1'

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
$bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
try {
    $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
} finally {
    $graphics.Dispose()
}
# Downscale to <=1280px wide -- plenty for the dashboard preview and keeps the
# base64 payload well under the server's upload cap.
$maxWidth = 1280
$sendBitmap = $bitmap
if ($bitmap.Width -gt $maxWidth) {
    $scale = $maxWidth / $bitmap.Width
    $sendBitmap = New-Object System.Drawing.Bitmap $bitmap, $maxWidth, ([int]([Math]::Round($bitmap.Height * $scale)))
    $bitmap.Dispose()
}
try {
    $stream = New-Object System.IO.MemoryStream
    $jpegCodec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
    $encParams = New-Object System.Drawing.Imaging.EncoderParameters 1
    $encParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality, [long]60)
    $sendBitmap.Save($stream, $jpegCodec, $encParams)
    $imageB64 = [Convert]::ToBase64String($stream.ToArray())
    $stream.Dispose()
} finally {
    $sendBitmap.Dispose()
}

$serverUrl = Get-LogbookConfigEnv -Key 'LOGIX_SERVER_URL'
if (-not $serverUrl) { throw 'LOGIX_SERVER_URL is not configured' }
$serverKey = Get-LogbookDeviceApiKey
if (-not $serverKey) { $serverKey = Get-LogbookConfigEnv -Key 'LOGIX_SERVER_API_KEY' }
$headers = @{ 'Content-Type' = 'application/json' }
if ($serverKey) { $headers['X-API-Key'] = $serverKey }
$payload = @{
    hostname     = $env:COMPUTERNAME
    command_id   = $CommandId
    image_base64 = $imageB64
    content_type = 'image/jpeg'
}
$apiUrl = $serverUrl.TrimEnd('/') + '/api/control/screenshot/upload'
Invoke-RestMethod -Uri $apiUrl -Method Post -Body ($payload | ConvertTo-Json -Depth 3) -Headers $headers -TimeoutSec 15 -UseBasicParsing | Out-Null
Write-LogbookInfo "Screenshot uploaded (command_id: $CommandId)."
