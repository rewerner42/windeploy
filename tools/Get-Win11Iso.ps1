#requires -Version 5.1
<#
.SYNOPSIS
    Laedt automatisch ein offizielles Windows-11-ISO direkt von Microsoft herunter.

.DESCRIPTION
    Nutzt Fido (https://github.com/pbatard/Fido, MIT-Lizenz, vom Rufus-Autor), um die
    zeitlich begrenzten, OFFIZIELLEN Microsoft-Download-Links aufzuloesen, und laedt das
    ISO anschliessend direkt von den Microsoft-Servern. Es werden ausschliesslich
    microsoft.com-URLs akzeptiert. Die Architektur wird automatisch erkannt (x64/arm64).

.EXAMPLE
    .\tools\Get-Win11Iso.ps1
    # laedt ISO passend zur CPU-Architektur nach .\ (Standard: Pro, German, Latest)

.EXAMPLE
    .\tools\Get-Win11Iso.ps1 -Edition Pro -Language English -Arch x64 -OutDir D:\ISOs

.NOTES
    Download ist mehrere GB gross. Ergebnis: Pfad zur ISO (fuer -IsoPath von Preflight/Build).
#>
[CmdletBinding()]
param(
    [ValidateSet('auto','x64','arm64')][string]$Arch = 'auto',
    [string]$Edition = 'Pro',
    [string]$Language = 'German',
    [string]$Release = 'Latest',
    [string]$OutDir = (Get-Location).Path,
    [string]$FidoPath,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072  # TLS 1.2

# --- Architektur bestimmen ---
if ($Arch -eq 'auto') {
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { $Arch = 'arm64' } else { $Arch = 'x64' }
}
Write-Host "[INFO] Zielarchitektur: $Arch  (Host: $env:PROCESSOR_ARCHITECTURE)" -ForegroundColor Cyan
if ($Arch -eq 'arm64') {
    Write-Host "[WARN] ARM64-ISO: WinDeploy zielt eigentlich auf amd64. Nur fuer ARM-Smoketests sinnvoll." -ForegroundColor Yellow
}

# --- Fido beschaffen (offizielles Repo) ---
if (-not $FidoPath -or -not (Test-Path -LiteralPath $FidoPath)) {
    $FidoPath = Join-Path $env:TEMP 'Fido.ps1'
    if ((-not (Test-Path -LiteralPath $FidoPath)) -or $Force) {
        $fidoUrl = 'https://raw.githubusercontent.com/pbatard/Fido/master/Fido.ps1'
        Write-Host "[INFO] Lade Fido von $fidoUrl ..." -ForegroundColor Cyan
        Invoke-WebRequest -Uri $fidoUrl -OutFile $FidoPath -UseBasicParsing
    }
}

# --- Offizielle Microsoft-Download-URL aufloesen ---
# Fido in einem KIND-Prozess starten: Fido ruft bei ungueltigen Werten 'exit 1/3' auf, was
# bei in-process '& $FidoPath' dieses Skript mitbeenden wuerde (gemeinsamer Runspace). Als
# Kindprozess bleibt der Exit isoliert; die Roh-Ausgabe (inkl. Fido-Diagnose) kommt als stdout.
Write-Host "[INFO] Frage offizielle Microsoft-URL ab (Fido, Win 11 / $Edition / $Language / $Arch / $Release) ..." -ForegroundColor Cyan
$fidoArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$FidoPath,
    '-Win','11','-Rel',$Release,'-Ed',$Edition,'-Lang',$Language,'-Arch',$Arch,'-GetUrl')
$raw = & powershell.exe @fidoArgs 2>&1
$fidoExit = $LASTEXITCODE
$url = ($raw | Where-Object { "$_" -match '^https?://' } | Select-Object -Last 1)
if ($fidoExit -ne 0 -or -not $url) {
    Write-Host ($raw | Out-String) -ForegroundColor DarkGray
    throw "Fido konnte keine URL aufloesen (Exit $fidoExit). Pruefe Edition/Language/Arch (Fido listet oben die gueltigen Werte)."
}
$url = ("$url").Trim()

# --- Nur offizielle Microsoft-Server akzeptieren ---
$urlHost = ([Uri]$url).Host
if ($urlHost -notmatch '(?i)\.microsoft\.com$') {
    throw "ABBRUCH: URL-Host '$urlHost' ist kein microsoft.com-Server."
}
Write-Host "[ OK ] Offizielle Download-URL bestaetigt (Host: $urlHost)." -ForegroundColor Green

# --- Zielpfad ---
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$fileName = ("Win11_{0}_{1}_{2}_{3}.iso" -f $Release, $Edition, $Arch, $Language) -replace '\s', '_'
$outFile = Join-Path $OutDir $fileName

# --- Download (BITS bevorzugt, sonst Invoke-WebRequest) ---
Write-Host "[INFO] Lade ISO nach '$outFile' (mehrere GB, kann dauern) ..." -ForegroundColor Cyan
$ok = $false
try {
    Import-Module BitsTransfer -ErrorAction Stop
    Start-BitsTransfer -Source $url -Destination $outFile -DisplayName 'Windows 11 ISO' -ErrorAction Stop
    $ok = $true
} catch {
    Write-Host "[WARN] BITS nicht nutzbar ($($_.Exception.Message)) - nutze WebClient ..." -ForegroundColor Yellow
}
if (-not $ok) {
    # WebClient streamt direkt auf Platte. Invoke-WebRequest puffert in PS 5.1 die gesamte
    # Antwort im RAM (OutOfMemory bei mehreren GB) und der Fortschrittsbalken bremst 10-50x.
    $ProgressPreference = 'SilentlyContinue'
    (New-Object System.Net.WebClient).DownloadFile($url, $outFile)
}

if (-not (Test-Path -LiteralPath $outFile)) { throw "Download fehlgeschlagen: $outFile nicht vorhanden." }
$sizeGB = [math]::Round((Get-Item -LiteralPath $outFile).Length / 1GB, 2)
Write-Host "[ OK ] Fertig: $outFile ($sizeGB GB)" -ForegroundColor Green
Write-Host "Naechster Schritt: .\tools\Preflight.ps1 -Install -IsoPath `"$outFile`"" -ForegroundColor Green
return $outFile
