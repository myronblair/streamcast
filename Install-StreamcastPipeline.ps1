#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Sets up a Windows 10/11 box to multicast-stream a system audio source (e.g. a
    browser tab playing Pandora/Spotify/etc.) to one or more Viking-style SIP/multicast
    paging horns, as a persistent background Windows service.

.DESCRIPTION
    Installs:
      - VB-Audio Virtual Cable (virtual audio device to capture app output)
      - GStreamer, via MSYS2/pacman (mingw-w64-x86_64-gstreamer + plugins base/good/
        bad/ugly) — encodes captured audio to RTP multicast with an explicit packet
        time (ptime), per Viking support's spec of 50ms.

        NOTE on why MSYS2 instead of the official gstreamer.freedesktop.org Windows
        .exe installer: that installer's silent-install component selection
        (/COMPONENTS=, /TYPE=full) does NOT reliably pull in gst-plugins-good/bad/
        ugly even when it reports success (tested against the 1.28.7 MSVC x86_64
        build) — it silently installs only gst-plugins-base. MSYS2's pacman
        packages each plugin set as its own named package with no ambiguity, so
        that's what this script uses instead. Confirmed working 2026-09-18.

        NOTE on capture element: the official installer's gst-plugins-bad also
        doesn't include dshowaudiosrc in its MinGW build (no DirectShow COM
        wrapper). This script uses wasapi2src instead (GStreamer's own preferred,
        highest-ranked Windows capture element) — VB-Cable's "CABLE Output" shows
        up as a normal WASAPI recording device regardless of which Windows audio
        API accesses it, so this is a drop-in equivalent, not a workaround.
      - NSSM (wraps the pipeline as an auto-restarting Windows service)
    Then writes the actual pipeline command to C:\StreamCast\run-gstreamer.bat and
    registers an NSSM service that runs that file. A desktop shortcut/batch file
    is also created for one-click start/stop/edit.

    Multiple horns need NO changes to this pipeline or this script — multicast is
    inherently one-to-many. Every horn on the same network segment (VLAN30) that
    joins the same multicast group (239.1.1.50:5004 by default below) receives the
    identical stream automatically. See the "ADDING ANOTHER HORN" section at the
    bottom of this file for the horn-side steps.

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

    Works identically on Windows 10 and 11 - confirmed on Windows 10 (build 19045)
    2026-09-18; the WASAPI2 capture path and MSYS2/pacman toolchain used here have
    no OS-version-specific branches.
#>

# ============================================================================
# CONFIGURATION - edit these before running
# ============================================================================
$MulticastAddress = "239.1.1.50"      # private multicast range 239.0.0.0/8 - avoid 224.0.0.x (reserved)
$MulticastPort     = 5004             # must match every horn's configured multicast paging-source port
$AudioCodec        = "mulawenc"       # G.711u - matches Viking 300TB-IP's documented supported codec
$SampleRate        = 8000
$Channels          = 1
$PtimeNs           = 50000000         # 50ms in nanoseconds - per Viking support's spec, both min and max
$InstallDir        = "C:\StreamCast"
$ServiceName       = "StreamcastGStreamer"
$Msys2Root         = "C:\msys64"
$GstBin            = "$Msys2Root\mingw64\bin"

# ============================================================================
# 0. Sanity checks
# ============================================================================
Write-Host "Detected OS version: $([System.Environment]::OSVersion.Version) (script works identically on Windows 10 and 11)"

if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir | Out-Null
}
$ProgressPreference = 'SilentlyContinue'   # massively speeds up Invoke-WebRequest

# ============================================================================
# 1. VB-Audio Virtual Cable
# ============================================================================
$vbCableInstalled = Get-CimInstance Win32_SoundDevice | Where-Object { $_.Name -like "*VB-Audio Virtual Cable*" }
if ($vbCableInstalled) {
    Write-Host "[1/4] VB-Audio Virtual Cable already installed - skipping."
} else {
    Write-Host "[1/4] Installing VB-Audio Virtual Cable..."
    $vbZip = Join-Path $InstallDir "vbcable.zip"
    $vbDir = Join-Path $InstallDir "vbcable"
    Invoke-WebRequest -Uri "https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack45.zip" -OutFile $vbZip
    Expand-Archive -Path $vbZip -DestinationPath $vbDir -Force
    Start-Process -FilePath (Join-Path $vbDir "VBCABLE_Setup_x64.exe") -ArgumentList "-i","-h" -Wait
    Write-Host "      Installed. A reboot is sometimes required before the device shows up - verify with:"
    Write-Host "      Get-CimInstance Win32_SoundDevice | Where-Object Name -like '*VB-Audio*'"
}

# ============================================================================
# 2. GStreamer via MSYS2/pacman (replaces both ffmpeg AND the official
#    gstreamer.freedesktop.org installer - see .DESCRIPTION for why)
# ============================================================================
$gstLaunchExe = Join-Path $GstBin "gst-launch-1.0.exe"
if (Test-Path $gstLaunchExe) {
    Write-Host "[2/4] GStreamer (MSYS2/mingw64) already present - skipping."
} else {
    if (-not (Test-Path "$Msys2Root\usr\bin\bash.exe")) {
        Write-Host "[2/4a] Downloading and installing MSYS2..."
        $msys2Exe = Join-Path $InstallDir "msys2-installer.exe"
        Invoke-WebRequest -Uri "https://github.com/msys2/msys2-installer/releases/download/nightly-x86_64/msys2-x86_64-latest.exe" -OutFile $msys2Exe
        $proc = Start-Process -FilePath $msys2Exe -ArgumentList "in","--confirm-command","--accept-messages","--root",($Msys2Root -replace '\\','/') -Wait -PassThru
        if ($proc.ExitCode -ne 0) { throw "MSYS2 install failed, exit code $($proc.ExitCode)" }
    } else {
        Write-Host "[2/4a] MSYS2 base already present - skipping."
    }

    Write-Host "[2/4b] Installing GStreamer + full plugin set via pacman (large download, several minutes)..."
    $env:MSYSTEM = "MSYS"
    $env:CHERE_INVOKING = "1"
    $bash = "$Msys2Root\usr\bin\bash.exe"
    # First-pass core update (standard MSYS2 headless pattern - safe to run even
    # when there's nothing to update, as on a fresh install).
    & $bash -lc "pacman -Syu --noconfirm --needed" 2>&1 | Write-Host
    & $bash -lc "pacman -S --noconfirm --needed mingw-w64-x86_64-gstreamer mingw-w64-x86_64-gst-plugins-base mingw-w64-x86_64-gst-plugins-good mingw-w64-x86_64-gst-plugins-bad mingw-w64-x86_64-gst-plugins-ugly" 2>&1 | Write-Host

    if (-not (Test-Path $gstLaunchExe)) {
        throw "gst-launch-1.0.exe not found at $GstBin after pacman install - check the output above for errors."
    }
    Write-Host "      Installed to $GstBin"
}

# ============================================================================
# 3. NSSM (service wrapper)
# ============================================================================
$nssmExe = Join-Path $InstallDir "nssm.exe"
if (Test-Path $nssmExe) {
    Write-Host "[3/4] NSSM already present - skipping."
} else {
    Write-Host "[3/4] Downloading NSSM..."
    $nssmZip = Join-Path $InstallDir "nssm.zip"
    $nssmExtract = Join-Path $InstallDir "nssm_extract"
    Invoke-WebRequest -Uri "https://nssm.cc/release/nssm-2.24.zip" -OutFile $nssmZip
    Expand-Archive -Path $nssmZip -DestinationPath $nssmExtract -Force
    $arch = if ([Environment]::Is64BitOperatingSystem) { "win64" } else { "win32" }
    Copy-Item -Path (Join-Path $nssmExtract "nssm-2.24\$arch\nssm.exe") -Destination $nssmExe -Force
    Write-Host "      Installed to $nssmExe"
}

# ============================================================================
# 4. Find the "CABLE Output" WASAPI device ID, write the pipeline .bat, register service
# ============================================================================
# wasapi2src takes a WASAPI endpoint ID (IMMDevice::GetId), not a friendly name -
# discover it live via gst-device-monitor-1.0 rather than hardcoding a GUID that
# is specific to one machine's driver install.
$env:Path = "$GstBin;$env:Path"
Write-Host "Looking up CABLE Output's WASAPI device ID..."
$deviceMonitorOutput = & (Join-Path $GstBin "gst-device-monitor-1.0.exe") Audio/Source 2>&1 | Out-String
$blocks = $deviceMonitorOutput -split "(?=Device found:)"
$cableBlock = $blocks | Where-Object { $_ -match "name\s*:\s*CABLE Output \(VB-Audio Virtual Cable\)" } | Select-Object -First 1
$CaptureDeviceId = $null
if ($cableBlock -and $cableBlock -match "device\.id\s*=\s*(\{[^\}]+\}(?:\.\{[^\}]+\})?)") {
    $CaptureDeviceId = $matches[1]
    Write-Host "Found CABLE Output device ID: $CaptureDeviceId"
} else {
    Write-Warning "Could not find 'CABLE Output' via gst-device-monitor-1.0 - VB-Cable may need a reboot to register. Re-run this script after rebooting if so. Falling back to a placeholder that WILL need manual correction in run-gstreamer.bat."
    $CaptureDeviceId = "REPLACE_ME_RUN_gst-device-monitor-1.0_Audio-Source"
}

Write-Host "[4/4] Writing pipeline script and registering service..."
$runBat = Join-Path $InstallDir "run-gstreamer.bat"
$batContent = @"
@echo off
REM Streamcast audio pipeline - GStreamer (MSYS2/mingw64 build). Edit device ID,
REM multicast address/port, or ptime below as needed.
REM ptime is in nanoseconds - $PtimeNs = $($PtimeNs / 1000000)ms, per Viking support's spec.
REM Device ID is the WASAPI endpoint ID for "CABLE Output (VB-Audio Virtual Cable)" -
REM if VB-Cable is ever reinstalled, re-run: gst-device-monitor-1.0.exe Audio/Source
REM and update the device= value below to match the new ID.

set GST_BIN=$GstBin
set PATH=%GST_BIN%;%PATH%

"%GST_BIN%\gst-launch-1.0.exe" -v ^
  wasapi2src device="$CaptureDeviceId" ^
  ! audioconvert ! audioresample ! audio/x-raw,rate=$SampleRate,channels=$Channels ^
  ! $AudioCodec ^
  ! rtppcmupay min-ptime=$PtimeNs max-ptime=$PtimeNs ^
  ! udpsink host=$MulticastAddress port=$MulticastPort auto-multicast=true ttl-mc=1
"@
Set-Content -Path $runBat -Value $batContent -Encoding ASCII

$existingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existingService) {
    Write-Host "Service '$ServiceName' already exists - removing and recreating."
    & $nssmExe stop $ServiceName confirm | Out-Null
    & $nssmExe remove $ServiceName confirm | Out-Null
}
# Also remove the old ffmpeg-based service if it's still there from a previous install.
$oldService = Get-Service -Name "StreamcastFFmpeg" -ErrorAction SilentlyContinue
if ($oldService) {
    Write-Host "Removing old 'StreamcastFFmpeg' service (replaced by $ServiceName)."
    & $nssmExe stop StreamcastFFmpeg confirm | Out-Null
    & $nssmExe remove StreamcastFFmpeg confirm | Out-Null
}

# Point NSSM straight at the .bat file with NO AppParameters - this sidesteps NSSM's
# own parameter-quoting bug entirely (it silently strips quotes around values with
# spaces/parentheses), since all real config lives inside the .bat file itself,
# which is plain text you can open and edit directly.
& $nssmExe install $ServiceName $runBat
& $nssmExe set $ServiceName AppDirectory $InstallDir
& $nssmExe set $ServiceName Start SERVICE_AUTO_START
& $nssmExe set $ServiceName AppExit Default Restart
& $nssmExe set $ServiceName AppStdout (Join-Path $InstallDir "gstreamer-stdout.log")
& $nssmExe set $ServiceName AppStderr (Join-Path $InstallDir "gstreamer-stderr.log")

# ============================================================================
# 5. Desktop control panel
# ============================================================================
# Deployed to the PUBLIC desktop (C:\Users\Public\Desktop), not
# [Environment]::GetFolderPath("Desktop") - when this script runs via
# automation (e.g. a Proxmox/SSH guest-agent session), that resolves to the
# automation account's own profile desktop, not the real interactive user's
# visible desktop. Public Desktop is visible to whoever actually logs in.
$desktopBat = "C:\Users\Public\Desktop\Streamcast Control.bat"
$controlContent = @"
@echo off
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
title Streamcast Control
:menu
cls
echo Streamcast Audio Pipeline
echo =========================
sc query $ServiceName | find "STATE"
echo.
echo 1. Start
echo 2. Stop
echo 3. Edit pipeline (opens run-gstreamer.bat in Notepad)
echo 4. Restart
echo 5. Exit
echo.
set /p choice="Choose an option: "
if "%choice%"=="1" (net start $ServiceName & pause & goto menu)
if "%choice%"=="2" (net stop $ServiceName & pause & goto menu)
if "%choice%"=="3" (notepad "$runBat" & echo Restart the service for changes to take effect. & pause & goto menu)
if "%choice%"=="4" (net stop $ServiceName & net start $ServiceName & pause & goto menu)
if "%choice%"=="5" exit
goto menu
"@
Set-Content -Path $desktopBat -Value $controlContent -Encoding ASCII

Write-Host ""
Write-Host "================================================================"
Write-Host "Service '$ServiceName' registered (NOT started yet - audio routing isn't set up)."
Write-Host "Desktop control panel created: $desktopBat"
Write-Host ""
Write-Host "REMAINING MANUAL STEPS (cannot be scripted):"
Write-Host "  1. Log into your streaming service in a browser on this machine."
Write-Host "  2. Settings > System > Sound > Volume mixer > set that app/tab's"
Write-Host "     output device to 'CABLE Input (VB-Audio Virtual Cable)'."
Write-Host "  3. Then start the service via the desktop control panel, or:"
Write-Host "       Start-Service $ServiceName"
Write-Host "  4. Configure the horn's multicast paging-source slot (Viking Device"
Write-Host "     Manager or equivalent) to listen on ${MulticastAddress}:${MulticastPort}"
Write-Host "     - use a LOW-priority slot (e.g. Group 9) with Timeout UNCHECKED so"
Write-Host "     paging calls can still interrupt/override the music."
Write-Host "================================================================"

<#
.ADDING ANOTHER HORN
    Multicast is one-to-many by design - this script and its pipeline do NOT need
    to change at all to add more horns. Steps, per additional horn:

    1. Physically connect the horn to a FortiSwitch port on VLAN30 (same subnet as
       the existing horn, 10.48.230.0/24) - set that port's CMDB entry to
       `vlan=vlan30` access mode via the FortiGate REST API, same as the existing
       horn's port.
    2. In that horn's own Viking Device Manager (or equivalent), configure its
       multicast paging-source slot to listen on the SAME address/port as every
       other horn: $MulticastAddress`:$MulticastPort - low-priority slot (e.g.
       Group 9), Timeout unchecked.
    3. Confirm IGMP snooping is enabled on the FortiSwitch (default) so the switch
       replicates the stream only to ports whose horn actually joined the group.
    4. Test: with the pipeline service running, the new horn should play the same
       audio as every other horn on VLAN30, simultaneously, automatically.

    Non-Viking horns (e.g. Algo brand) that support standard multicast paging
    should work the same way - join the same multicast group - but their own
    device config UI/steps will differ from Viking's. Verify against that
    vendor's own docs rather than assuming identical config steps to Viking.

    If a future horn needs to live on a DIFFERENT VLAN/subnet than VLAN30, that is
    a real network change (PIM/multicast routing on the FortiGate between VLANs),
    not something this script or a horn-side config alone can solve - flag it
    separately rather than assuming it'll just work.
#>
