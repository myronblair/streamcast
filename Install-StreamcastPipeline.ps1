#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Sets up a Windows 10/11 box to multicast-stream a system audio source (e.g. a
    browser tab playing Pandora/Spotify/etc.) to a Viking-style SIP/multicast paging
    horn, as a persistent background Windows service.

.DESCRIPTION
    Installs:
      - VB-Audio Virtual Cable (virtual audio device to capture app output)
      - ffmpeg (encodes captured audio to RTP multicast)
      - NSSM (wraps ffmpeg as an auto-restarting Windows service)
    Then registers an NSSM service that captures the "CABLE Output" device and
    streams it as G.711 u-law RTP to the multicast address/port you configure below.

    This script only handles the parts that CAN be automated. Two steps still need
    a human at the keyboard, one time, after this script finishes:
      1. Log into the streaming service (Pandora, etc.) in a browser on this machine.
      2. Windows Settings > System > Sound > Volume mixer > set that browser tab's
         (or app's) OUTPUT device to "CABLE Input (VB-Audio Virtual Cable)".
    There is no supported scriptable way to do step 2 for a specific browser tab -
    Windows does not expose per-app audio routing via PowerShell/WMI.

.NOTES
    Run this from an elevated PowerShell prompt:
        powershell -ExecutionPolicy Bypass -File .\Install-StreamcastPipeline.ps1

    Tested pattern originates from two real deployments (2026): a remote-site
    Windows PC feeding Viking 300TB-IP horns via Pandora, and a dedicated
    "streamcast" Proxmox VM feeding a home-network Viking horn on its own VLAN.
#>

# ============================================================================
# CONFIGURATION - edit these before running
# ============================================================================
$MulticastAddress = "239.1.1.50"      # private multicast range 239.0.0.0/8 - avoid 224.0.0.x (reserved)
$MulticastPort     = 5004             # must match the horn's configured multicast paging-source port
$AudioCodec        = "pcm_mulaw"      # G.711u - matches Viking 300TB-IP's documented supported codec
$SampleRate        = 8000
$Channels          = 1
$InstallDir        = "C:\StreamCast"
$ServiceName       = "StreamcastFFmpeg"

# ============================================================================
# 0. Sanity checks
# ============================================================================
$OSVersion = [System.Environment]::OSVersion.Version
Write-Host "Detected OS version: $OSVersion (script works identically on Windows 10 and 11 - both use the same WDM/dshow audio subsystem VB-Cable and ffmpeg rely on)"

if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir | Out-Null
}
$ProgressPreference = 'SilentlyContinue'   # massively speeds up Invoke-WebRequest

# ============================================================================
# 1. VB-Audio Virtual Cable
# ============================================================================
$vbCableInstalled = Get-CimInstance Win32_SoundDevice | Where-Object { $_.Name -like "*VB-Audio Virtual Cable*" }
if ($vbCableInstalled) {
    Write-Host "[1/3] VB-Audio Virtual Cable already installed - skipping."
} else {
    Write-Host "[1/3] Installing VB-Audio Virtual Cable..."
    $vbZip = Join-Path $InstallDir "vbcable.zip"
    $vbDir = Join-Path $InstallDir "vbcable"
    Invoke-WebRequest -Uri "https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack45.zip" -OutFile $vbZip
    Expand-Archive -Path $vbZip -DestinationPath $vbDir -Force
    # -i = install, -h = hidden/no UI. Driver is signed by VB-Audio; no manual "trust this driver" prompt expected.
    Start-Process -FilePath (Join-Path $vbDir "VBCABLE_Setup_x64.exe") -ArgumentList "-i","-h" -Wait
    Write-Host "      Installed. A reboot is sometimes required before the device shows up - verify with:"
    Write-Host "      Get-CimInstance Win32_SoundDevice | Where-Object Name -like '*VB-Audio*'"
}

# ============================================================================
# 2. ffmpeg
# ============================================================================
$ffmpegExe = Join-Path $InstallDir "ffmpeg\ffmpeg.exe"
if (Test-Path $ffmpegExe) {
    Write-Host "[2/3] ffmpeg already present - skipping."
} else {
    Write-Host "[2/3] Downloading ffmpeg..."
    $ffZip = Join-Path $InstallDir "ffmpeg.zip"
    $ffExtract = Join-Path $InstallDir "ffmpeg_extract"
    Invoke-WebRequest -Uri "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip" -OutFile $ffZip
    Expand-Archive -Path $ffZip -DestinationPath $ffExtract -Force
    # gyan.dev ships it inside a version-named subfolder - flatten it to a fixed path so the
    # service command line below doesn't need to know the version number.
    $innerBin = Get-ChildItem -Path $ffExtract -Directory | Select-Object -First 1 | ForEach-Object { Join-Path $_.FullName "bin" }
    New-Item -ItemType Directory -Path (Join-Path $InstallDir "ffmpeg") -Force | Out-Null
    Copy-Item -Path (Join-Path $innerBin "*") -Destination (Join-Path $InstallDir "ffmpeg") -Recurse -Force
    Write-Host "      Installed to $InstallDir\ffmpeg"
}

# ============================================================================
# 3. NSSM (service wrapper)
# ============================================================================
$nssmExe = Join-Path $InstallDir "nssm.exe"
if (Test-Path $nssmExe) {
    Write-Host "[3/3] NSSM already present - skipping."
} else {
    Write-Host "[3/3] Downloading NSSM..."
    $nssmZip = Join-Path $InstallDir "nssm.zip"
    $nssmExtract = Join-Path $InstallDir "nssm_extract"
    Invoke-WebRequest -Uri "https://nssm.cc/release/nssm-2.24.zip" -OutFile $nssmZip
    Expand-Archive -Path $nssmZip -DestinationPath $nssmExtract -Force
    $arch = if ([Environment]::Is64BitOperatingSystem) { "win64" } else { "win32" }
    Copy-Item -Path (Join-Path $nssmExtract "nssm-2.24\$arch\nssm.exe") -Destination $nssmExe -Force
    Write-Host "      Installed to $nssmExe"
}

# ============================================================================
# 4. Find the actual VB-Cable dshow device name
# ============================================================================
# The exact string ffmpeg needs (e.g. "CABLE Output (VB-Audio Virtual Cable)") can vary
# slightly by VB-Cable version/locale, so look it up live instead of hardcoding it.
$deviceListRaw = & $ffmpegExe -hide_banner -list_devices true -f dshow -i dummy 2>&1 | Out-String
$deviceLine = ($deviceListRaw -split "`r?`n") | Where-Object { $_ -match '"CABLE Output' }
if (-not $deviceLine) {
    Write-Warning "Could not find a 'CABLE Output' audio device via ffmpeg -list_devices. VB-Cable may need a reboot to register, or the install failed. Re-run this script after rebooting if so."
    $CaptureDevice = "CABLE Output (VB-Audio Virtual Cable)"   # fallback guess, matches the default install name
} else {
    $CaptureDevice = ($deviceLine -split '"')[1]
    Write-Host "Found capture device: `"$CaptureDevice`""
}

# ============================================================================
# 5. Register the NSSM service
# ============================================================================
$existingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existingService) {
    Write-Host "Service '$ServiceName' already exists - removing and recreating with current config."
    & $nssmExe stop $ServiceName confirm | Out-Null
    & $nssmExe remove $ServiceName confirm | Out-Null
}

$ffArgs = "-f dshow -i audio=`"$CaptureDevice`" -acodec $AudioCodec -ar $SampleRate -ac $Channels -f rtp rtp://${MulticastAddress}:${MulticastPort}"

& $nssmExe install $ServiceName $ffmpegExe
# NOTE: do NOT use "nssm set ... AppParameters $ffArgs" here -- NSSM's own CLI parser silently
# strips the quotes around $CaptureDevice (since it contains spaces/parentheses), leaving ffmpeg
# with a truncated device name (e.g. "audio=CABLE" instead of the full device string) and a
# silent "Could not find audio only device" failure at runtime. Writing straight to the service's
# registry key bypasses NSSM's parameter parsing entirely and preserves the quotes exactly as built.
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName\Parameters" -Name AppParameters -Value $ffArgs
& $nssmExe set $ServiceName AppDirectory (Join-Path $InstallDir "ffmpeg")
& $nssmExe set $ServiceName Start SERVICE_AUTO_START
& $nssmExe set $ServiceName AppExit Default Restart          # auto-restart if ffmpeg crashes
& $nssmExe set $ServiceName AppStdout (Join-Path $InstallDir "ffmpeg-stdout.log")
& $nssmExe set $ServiceName AppStderr (Join-Path $InstallDir "ffmpeg-stderr.log")

Write-Host ""
Write-Host "Service '$ServiceName' registered (not started yet - audio routing isn't set up)."
Write-Host ""
Write-Host "================================================================"
Write-Host "REMAINING MANUAL STEPS (cannot be scripted):"
Write-Host "  1. Log into your streaming service in a browser on this machine."
Write-Host "  2. Settings > System > Sound > Volume mixer > set that app/tab's"
Write-Host "     output device to 'CABLE Input (VB-Audio Virtual Cable)'."
Write-Host "  3. Then start the stream service:"
Write-Host "       Start-Service $ServiceName"
Write-Host "  4. Configure the horn's multicast paging-source slot (Viking Device"
Write-Host "     Manager or equivalent) to listen on ${MulticastAddress}:${MulticastPort}"
Write-Host "     - use a LOW-priority slot (e.g. Group 9) with Timeout UNCHECKED so"
Write-Host "     paging calls can still interrupt/override the music."
Write-Host "================================================================"
