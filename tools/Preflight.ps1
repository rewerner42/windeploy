#requires -Version 5.1
<#
.SYNOPSIS
    WinDeploy-Preflight: prüft (und installiert optional) alle Abhängigkeiten, die zum
    Bauen und Testen von WinDeploy nötig sind - auf dem Windows-Build-/Testrechner.

.DESCRIPTION
    Prüft: Windows-Edition, PowerShell, Adminrechte, CPU-Architektur, Windows ADK +
    WinPE-Add-on (WinPE_OCs), oscdimg (für ISO-Bau), ein Windows-11-Abbild
    (ISO/install.wim inkl. Architektur & Edition-Indizes) und die Hypervisor-Lage.

    Mit -Install werden fehlende Komponenten (ADK + WinPE-Add-on) per winget installiert.

.EXAMPLE
    # Nur prüfen:
    powershell -ExecutionPolicy Bypass -File .\tools\Preflight.ps1

.EXAMPLE
    # Prüfen + fehlende Abhängigkeiten installieren + Abbild inspizieren:
    powershell -ExecutionPolicy Bypass -File .\tools\Preflight.ps1 -Install -IsoPath D:\Win11_25H2.iso

.NOTES
    WICHTIG: WinDeploy zielt auf amd64. Auf Apple-Silicon-Parallels läuft nur ARM64-Windows -
    dann validiert ein VM-Test nur eine ARM64-Variante, nicht die amd64-Zielplattform.
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [string]$IsoPath
)

$ErrorActionPreference = 'Continue'
$script:results = @()
$script:notReady = 0

function Add-Check {
    param([string]$Name, [ValidateSet('OK','WARN','FAIL')][string]$Status, [string]$Detail, [string]$Fix)
    $script:results += [pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail; Fix = $Fix }
    if ($Status -eq 'FAIL') { $script:notReady++ }
    $color = @{ OK='Green'; WARN='Yellow'; FAIL='Red' }[$Status]
    Write-Host ("[{0,-4}] {1,-28} {2}" -f $Status, $Name, $Detail) -ForegroundColor $color
    if ($Fix) { Write-Host ("        -> $Fix") -ForegroundColor DarkGray }
}

Write-Host "`n=================== WinDeploy Preflight ===================`n" -ForegroundColor Cyan

# --- 0) Windows? ---
$onWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or ($PSVersionTable.Platform -eq 'Win32NT')
if (-not $onWindows) {
    Write-Host "Dieses Preflight muss auf WINDOWS laufen (nicht macOS/Linux). Abbruch." -ForegroundColor Red
    exit 2
}

# --- 1) OS / Edition ---
$os = Get-CimInstance Win32_OperatingSystem
Add-Check 'Windows' 'OK' ("{0} (Build {1})" -f $os.Caption, $os.BuildNumber)

# --- 2) PowerShell ---
$ps = $PSVersionTable.PSVersion
Add-Check 'PowerShell' 'OK' "$ps (Ziel-Payload läuft unter Windows PowerShell 5.1)"

# --- 3) Adminrechte ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if ($isAdmin) { Add-Check 'Adminrechte' 'OK' 'als Administrator' }
else { Add-Check 'Adminrechte' 'FAIL' 'keine Adminrechte' 'PowerShell "Als Administrator ausführen" (ADK-Install + DISM + VM brauchen das).' }

# --- 4) CPU-Architektur ---
$arch = $env:PROCESSOR_ARCHITECTURE
if ($arch -eq 'AMD64') {
    Add-Check 'Architektur' 'OK' 'AMD64 (x86-64) - passt zum WinDeploy-Ziel'
} elseif ($arch -eq 'ARM64') {
    Add-Check 'Architektur' 'WARN' 'ARM64 (Apple-Silicon-Parallels?)' 'WinDeploy zielt auf amd64. Ein Test hier validiert nur eine ARM64-Variante, nicht deine amd64-Zielgeräte.'
} else {
    Add-Check 'Architektur' 'WARN' "unbekannt: $arch"
}
$archFolder = if ($arch -eq 'ARM64') { 'arm64' } else { 'amd64' }

# --- 5) winget (für -Install) ---
$winget = Get-Command winget.exe -ErrorAction SilentlyContinue
if ($winget) { Add-Check 'winget' 'OK' 'verfügbar' }
else { Add-Check 'winget' 'WARN' 'nicht gefunden' 'Ohne winget müssen ADK/WinPE-Add-on manuell installiert werden (siehe Fix bei ADK).' }

# --- 6) Windows ADK + WinPE-Add-on ---
$kitsRoot = $null
foreach ($p in @('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots','HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots')) {
    $v = (Get-ItemProperty -Path $p -Name KitsRoot10 -ErrorAction SilentlyContinue).KitsRoot10
    if ($v) { $kitsRoot = $v; break }
}

function Install-Adk {
    if (-not $isAdmin) { Write-Host "  Adminrechte fehlen - Installation übersprungen." -ForegroundColor Yellow; return }
    # ADK selbst: winget funktioniert.
    if ($winget) {
        Write-Host "  Installiere Windows ADK (winget) ..." -ForegroundColor Cyan
        & winget install --id Microsoft.WindowsADK -e --accept-source-agreements --accept-package-agreements --disable-interactivity
    } else {
        Write-Host "  winget fehlt - ADK bitte manuell installieren (https://learn.microsoft.com/windows-hardware/get-started/adk-install)." -ForegroundColor Yellow
    }
    # WinPE-Add-on: das winget-Paket ist bekannt kaputt (404/'nicht gefunden', winget-pkgs #253458).
    # Daher direkter Microsoft-Download des adkwinpesetup.exe (passend zu ADK 10.1.26100.2454, Win11 25H2/24H2 x64).
    Write-Host "  Installiere Windows PE Add-on (direkter Microsoft-Download) ..." -ForegroundColor Cyan
    $peUrl = 'https://go.microsoft.com/fwlink/?linkid=2289981'
    $peExe = Join-Path $env:TEMP 'adkwinpesetup.exe'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $peUrl -OutFile $peExe -UseBasicParsing
        Write-Host "  Starte adkwinpesetup.exe (still) ..." -ForegroundColor Cyan
        $p = Start-Process -FilePath $peExe -ArgumentList '/quiet','/features','OptionId.WindowsPreinstallationEnvironment','/norestart' -Wait -PassThru
        if ($p.ExitCode -ne 0) { Write-Host "  adkwinpesetup Exitcode $($p.ExitCode)" -ForegroundColor Yellow }
    } catch {
        Write-Host "  WinPE-Add-on-Download/-Install fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

$winpeOc = $null; $oscdimg = $null
if ($kitsRoot) {
    $winpeOc = Join-Path $kitsRoot ("Assessment and Deployment Kit\Windows Preinstallation Environment\{0}\WinPE_OCs" -f $archFolder)
    $oscdimg = Join-Path $kitsRoot ("Assessment and Deployment Kit\Deployment Tools\{0}\Oscdimg\oscdimg.exe" -f $archFolder)
}

$adkFixHint = 'Dieses Skript mit -Install ausführen (installiert ADK via winget + WinPE-Add-on per direktem MS-Download, da das winget-Add-on-Paket kaputt ist). Manuell: WinPE-Add-on von https://go.microsoft.com/fwlink/?linkid=2289981'

if ($Install -and -not ($winpeOc -and (Test-Path $winpeOc))) { Install-Adk
    # nach Installation Pfade neu bestimmen
    foreach ($p in @('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots','HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots')) {
        $v = (Get-ItemProperty -Path $p -Name KitsRoot10 -ErrorAction SilentlyContinue).KitsRoot10
        if ($v) { $kitsRoot = $v; break }
    }
    if ($kitsRoot) {
        $winpeOc = Join-Path $kitsRoot ("Assessment and Deployment Kit\Windows Preinstallation Environment\{0}\WinPE_OCs" -f $archFolder)
        $oscdimg = Join-Path $kitsRoot ("Assessment and Deployment Kit\Deployment Tools\{0}\Oscdimg\oscdimg.exe" -f $archFolder)
    }
}

if ($kitsRoot) { Add-Check 'ADK-Root' 'OK' $kitsRoot }
else { Add-Check 'ADK-Root' 'FAIL' 'Windows ADK nicht gefunden' $adkFixHint }

if ($winpeOc -and (Test-Path $winpeOc)) {
    $psCab = Join-Path $winpeOc 'WinPE-PowerShell.cab'
    if (Test-Path $psCab) { Add-Check "WinPE-Add-on ($archFolder)" 'OK' 'WinPE_OCs inkl. WinPE-PowerShell vorhanden' }
    else { Add-Check "WinPE-Add-on ($archFolder)" 'FAIL' 'WinPE_OCs da, aber WinPE-PowerShell.cab fehlt' $adkFixHint }
} else {
    Add-Check "WinPE-Add-on ($archFolder)" 'FAIL' 'WinPE-Add-on nicht gefunden' $adkFixHint
}

if ($oscdimg -and (Test-Path $oscdimg)) { Add-Check 'oscdimg (ISO-Bau)' 'OK' $oscdimg }
else { Add-Check 'oscdimg (ISO-Bau)' 'WARN' 'nicht gefunden (Teil der ADK Deployment Tools)' 'Wird für den ISO-Bau gebraucht - kommt mit dem ADK.' }

# --- 7) Windows-11-Abbild ---
function Get-ImageInfoSafe {
    param([string]$Wim)
    try {
        $imgs = Get-WindowsImage -ImagePath $Wim -ErrorAction Stop
        $first = $imgs | Select-Object -First 1
        $arch = 'n/a'
        try { $arch = (Get-WindowsImage -ImagePath $Wim -Index $first.ImageIndex -ErrorAction Stop).Architecture } catch {}
        return [pscustomobject]@{ Count=$imgs.Count; Editions=($imgs | ForEach-Object { "$($_.ImageIndex)=$($_.ImageName)" }); Arch=$arch }
    } catch { return $null }
}

$wim = $null; $mounted = $null
if ($IsoPath) {
    if (-not (Test-Path -LiteralPath $IsoPath)) { Add-Check 'Windows-Abbild' 'FAIL' "IsoPath nicht gefunden: $IsoPath" }
    elseif ($IsoPath -match '\.iso$') {
        try {
            $mounted = Mount-DiskImage -ImagePath $IsoPath -PassThru -ErrorAction Stop
            $drv = ($mounted | Get-Volume).DriveLetter
            foreach ($n in 'install.wim','install.esd') { $c = "$($drv):\sources\$n"; if (Test-Path $c) { $wim = $c; break } }
        } catch { Add-Check 'Windows-Abbild' 'WARN' "ISO konnte nicht gemountet werden: $($_.Exception.Message)" }
    } elseif ($IsoPath -match '\.(wim|esd)$') { $wim = $IsoPath }
}

if ($wim) {
    $info = Get-ImageInfoSafe -Wim $wim
    if ($info) {
        $archMap = @{ 0='x86'; 5='ARM'; 9='amd64'; 12='ARM64' }
        $imgArch = if ($archMap.ContainsKey([int]$info.Arch)) { $archMap[[int]$info.Arch] } else { "$($info.Arch)" }
        $st = 'OK'
        $note = ''
        if ($imgArch -eq 'ARM64' -and $arch -eq 'AMD64') { $st='WARN'; $note=' (ARM64-Abbild auf amd64-Host!)' }
        if ($imgArch -eq 'amd64' -and $arch -eq 'ARM64') { $st='WARN'; $note=' (amd64-Abbild lässt sich auf ARM-Parallels nicht booten)' }
        Add-Check 'Windows-Abbild' $st ("$wim | Arch=$imgArch$note")
        Write-Host "        Editionen/Indizes:" -ForegroundColor DarkGray
        $info.Editions | ForEach-Object { Write-Host "          $_" -ForegroundColor DarkGray }
    } else { Add-Check 'Windows-Abbild' 'WARN' "install.wim/.esd nicht lesbar: $wim" }
} elseif (-not $IsoPath) {
    Add-Check 'Windows-Abbild' 'WARN' 'kein -IsoPath angegeben' 'Mit -IsoPath <Win11.iso|install.wim> prüfen (liefert Editionen/imageIndex + Architektur).'
}
if ($mounted) { try { Dismount-DiskImage -ImagePath $IsoPath | Out-Null } catch {} }

# --- 8) Hypervisor-Lage (nur Info) ---
try {
    $hv = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction SilentlyContinue
    if ($hv -and $hv.State -eq 'Enabled') { Add-Check 'Hyper-V' 'OK' 'aktiviert (für amd64-VM-Test nutzbar)' }
    else { Add-Check 'Hyper-V' 'WARN' 'nicht aktiviert' 'Für einen amd64-VM-Test: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All (oder Parallels/VMware nutzen).' }
} catch { Add-Check 'Hyper-V' 'WARN' 'Status unbekannt' }

# --- Fazit ---
Write-Host "`n=================== Ergebnis ===================" -ForegroundColor Cyan
$fails = @($script:results | Where-Object { $_.Status -eq 'FAIL' })
$warns = @($script:results | Where-Object { $_.Status -eq 'WARN' })
if ($fails.Count -eq 0) {
    Write-Host "BEREIT zum Bauen." -ForegroundColor Green
    Write-Host "Nächster Schritt: .\Build-DeploymentUSB.ps1 -ProfilePath .\profiles\<deins>.json -PromptJoinPassword -BuildMedia ..." -ForegroundColor Green
} else {
    Write-Host ("NICHT bereit - {0} kritische Punkte offen:" -f $fails.Count) -ForegroundColor Red
    $fails | ForEach-Object { Write-Host ("  - {0}: {1}" -f $_.Name, $_.Detail) -ForegroundColor Red }
    Write-Host "Tipp: dieses Skript mit -Install erneut ausführen, um ADK/WinPE-Add-on automatisch zu installieren." -ForegroundColor Yellow
}
if ($warns.Count -gt 0) { Write-Host ("({0} Hinweise/Warnungen beachten.)" -f $warns.Count) -ForegroundColor Yellow }
Write-Host ""
exit ([int]($fails.Count -gt 0))
