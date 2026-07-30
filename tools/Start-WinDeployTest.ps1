#requires -Version 5.1
<#
.SYNOPSIS
    Gefuehrter Komplett-Assistent fuer den WinDeploy-VM-Test. Fuehrt der Reihe nach durch:
    Preflight -> Win11-ISO (laden/waehlen) -> Konfiguration abfragen -> optional Join-Konto in AD
    anlegen -> Profil schreiben -> bootfaehige Test-ISO bauen -> Proxmox-Anleitung.

    Nutzt die vorhandenen Skripte (Preflight.ps1, Get-Win11Iso.ps1, Build-DeploymentUSB.ps1, Build-Iso.ps1).
    Alle Passwoerter werden interaktiv abgefragt und nie angezeigt/geloggt.

.EXAMPLE
    .\tools\Start-WinDeployTest.ps1
#>
[CmdletBinding()]
param(
    [string]$IsoDir = 'C:\ISOs',
    [string]$OutIso
)

$ErrorActionPreference = 'Stop'
$Tools    = $PSScriptRoot
$RepoRoot = Split-Path -Parent $PSScriptRoot

function Head  { param($t) Write-Host "`n==================== $t ====================" -ForegroundColor Cyan }
function Note  { param($t) Write-Host $t -ForegroundColor Green }
function Warn3 { param($t) Write-Host $t -ForegroundColor Yellow }
function Ask {
    param([string]$Prompt, [string]$Default)
    if ($Default) {
        $a = Read-Host "$Prompt [$Default]"
        if ([string]::IsNullOrWhiteSpace($a)) { return $Default } else { return $a }
    }
    return (Read-Host $Prompt)
}
function YesNo {
    param([string]$Prompt, [bool]$DefaultYes = $true)
    $d = if ($DefaultYes) { 'J' } else { 'N' }
    $a = Read-Host "$Prompt (j/n) [$d]"
    if ([string]::IsNullOrWhiteSpace($a)) { return $DefaultYes }
    return ($a -match '^(?i)(j|y)')
}

Write-Host "`n#############################################################" -ForegroundColor Magenta
Write-Host "#   WinDeploy - Gefuehrter VM-Test-Assistent                #" -ForegroundColor Magenta
Write-Host "#############################################################" -ForegroundColor Magenta

# ---------------------------------------------------------------------------
# 1/7  Preflight (im Kindprozess, damit dessen 'exit' den Assistenten nicht beendet)
# ---------------------------------------------------------------------------
Head "1/7  Abhaengigkeiten (Preflight)"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Tools 'Preflight.ps1')
if ($LASTEXITCODE -ne 0) {
    if (YesNo "Es fehlen Abhaengigkeiten. Jetzt automatisch installieren (ADK + WinPE-Add-on)?") {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Tools 'Preflight.ps1') -Install
        if ($LASTEXITCODE -ne 0) { throw "Preflight weiterhin NICHT bereit. Bitte Ausgabe oben pruefen." }
    } else { throw "Abgebrochen - Abhaengigkeiten fehlen." }
}
Note "Preflight OK."

# ---------------------------------------------------------------------------
# 2/7  Windows-11-ISO
# ---------------------------------------------------------------------------
Head "2/7  Windows-11-ISO (x64)"
$iso = Ask "Pfad zu einem vorhandenen Win11-x64-ISO (leer = automatisch von Microsoft laden)" ""
if ([string]::IsNullOrWhiteSpace($iso) -or -not (Test-Path -LiteralPath $iso)) {
    if ($iso) { Warn3 "Nicht gefunden: $iso" }
    if (YesNo "Offizielles Win11-x64-ISO jetzt von Microsoft laden (mehrere GB)?") {
        $iso = (& (Join-Path $Tools 'Get-Win11Iso.ps1') -OutDir $IsoDir | Select-Object -Last 1)
    } else { throw "Ohne ISO kein Bau moeglich - Abbruch." }
}
if (-not (Test-Path -LiteralPath $iso)) { throw "ISO nicht verfuegbar: $iso" }
Note "ISO: $iso"

# ---------------------------------------------------------------------------
# 3/7  Edition / imageIndex (automatisch erkannt)
# ---------------------------------------------------------------------------
Head "3/7  Windows-Edition (imageIndex)"
$proIdx = $null
$mount = Mount-DiskImage -ImagePath $iso -PassThru; Start-Sleep -Seconds 2
try {
    $drv = ($mount | Get-Volume | Where-Object { $_.DriveLetter }).DriveLetter
    $wim = "$($drv):\sources\install.wim"
    if (-not (Test-Path -LiteralPath $wim)) { $wim = "$($drv):\sources\install.esd" }
    $imgs = Get-WindowsImage -ImagePath $wim
    $imgs | ForEach-Object { Write-Host ("  {0} = {1}" -f $_.ImageIndex, $_.ImageName) }
    $pro = $imgs | Where-Object { $_.ImageName -match 'Pro' -and $_.ImageName -notmatch 'Education|Enterprise|China|Pro N|Pro for' } | Select-Object -First 1
    if ($pro) { $proIdx = $pro.ImageIndex }
} finally { Dismount-DiskImage -ImagePath $iso | Out-Null }
if (-not $proIdx) { $proIdx = 6 }
$imageIndex = [int](Ask "imageIndex der zu installierenden Edition" "$proIdx")

# ---------------------------------------------------------------------------
# 4/7  Konfiguration
# ---------------------------------------------------------------------------
Head "4/7  Konfiguration"
$prefix      = Ask "Computername-Praefix (max 12 Zeichen)" "TEST-"
$lang        = Ask "Sprache/Locale" "de-DE"
$inputLocale = Ask "Tastatur (InputLocale)" "0407:00000407"
$tz          = Ask "Zeitzone" "W. Europe Standard Time"
$laUser      = Ask "Lokaler Admin (Benutzername)" "itadmin"
$laPwSec     = Read-Host -AsSecureString "Lokales Admin-Passwort setzen"
$laPw        = [System.Net.NetworkCredential]::new('', $laPwSec).Password

$domain = Ask "AD-Domaene (FQDN), z.B. mk.local" ""
while ([string]::IsNullOrWhiteSpace($domain)) { $domain = Ask "AD-Domaene (FQDN) - Pflicht" "" }
$dcPath = ($domain -split '\.' | ForEach-Object { "DC=$_" }) -join ','
$nb = $domain.Split('.')[0].ToUpper()

$ou = $null
if (YesNo "Ziel-OU angeben? (nein = Standard-Container 'Computers', einfacher fuer den ersten Test)" $false) {
    $ou = Ask "Ziel-OU (Distinguished Name)" "OU=Test,$dcPath"
}

# ---------------------------------------------------------------------------
# 5/7  Domaenen-Join-Konto (optional in AD anlegen)
# ---------------------------------------------------------------------------
Head "5/7  Domaenen-Join-Konto"
Write-Host "Hinweis: Das Konto muss in AD EXISTIEREN. Standard-Benutzer duerfen per MachineAccountQuota bis zu 10 PCs aufnehmen." -ForegroundColor DarkGray
$joinUser = Ask "Join-Konto (DOMAIN\\user oder user@domain)" "$nb\svc-join"
$joinPwSec = $null

if (YesNo "Dieses Konto JETZT in AD anlegen? (nein = existiert schon)" $false) {
    $sam = if ($joinUser -match '\\') { ($joinUser -split '\\')[1] } elseif ($joinUser -match '@') { ($joinUser -split '@')[0] } else { $joinUser }
    try {
        if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
            Warn3 "RSAT ActiveDirectory-Modul fehlt - installiere (braucht Internet/Windows Update) ..."
            Add-WindowsCapability -Online -Name 'Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0' -ErrorAction Stop | Out-Null
        }
        Import-Module ActiveDirectory -ErrorAction Stop
        $server  = Ask "DC-Hostname/IP (leer = automatisch aus der Domaene)" ""
        $admCred = Get-Credential -Message "Domaenen-Admin zum Anlegen von '$sam'"
        $newPw   = Read-Host -AsSecureString "Passwort fuer das NEUE Konto '$sam' festlegen"

        $common = @{ Credential = $admCred }
        if ($server) { $common.Server = $server }

        # ggf. OU anlegen
        if ($ou) {
            $ouExists = $false
            try { $ouExists = [bool](Get-ADOrganizationalUnit -Identity $ou @common -ErrorAction SilentlyContinue) } catch { }
            if (-not $ouExists -and (YesNo "Ziel-OU '$ou' existiert nicht. Anlegen?")) {
                $ouName = ($ou -split ',')[0] -replace '^OU=', ''
                $ouParent = ($ou -split ',', 2)[1]
                New-ADOrganizationalUnit -Name $ouName -Path $ouParent @common -ProtectedFromAccidentalDeletion:$false
                Note "OU angelegt: $ou"
            }
        }

        $existing = $null
        try { $existing = Get-ADUser -Filter "SamAccountName -eq '$sam'" @common -ErrorAction SilentlyContinue } catch { }
        if ($existing) {
            Warn3 "Konto '$sam' existiert bereits - setze nur das Passwort."
            Set-ADAccountPassword -Identity $existing -NewPassword $newPw -Reset @common
            Enable-ADAccount -Identity $existing @common
        } else {
            New-ADUser -Name $sam -SamAccountName $sam -AccountPassword $newPw -Enabled $true `
                -PasswordNeverExpires $true -UserPrincipalName "$sam@$domain" @common
            Note "Join-Konto '$sam' in AD angelegt."
        }
        $joinPwSec = $newPw
    } catch {
        Warn3 "AD-Anlage fehlgeschlagen: $($_.Exception.Message)"
        Warn3 "Lege das Konto manuell auf dem DC an, z.B.:"
        Write-Host "  New-ADUser -Name '$sam' -SamAccountName '$sam' -AccountPassword (Read-Host -AsSecureString) -Enabled `$true" -ForegroundColor Gray
    }
}

if (-not $joinPwSec) {
    $joinPwSec = Read-Host -AsSecureString "Passwort des Join-Kontos '$joinUser'"
}

# ---------------------------------------------------------------------------
# 6/7  Profil schreiben (gitignored: *.local.json - enthaelt lokales Admin-PW)
# ---------------------------------------------------------------------------
Head "6/7  Profil schreiben"
$profileObj = [ordered]@{
    schemaVersion  = 1
    profileName    = 'VM-Test'
    profileVersion = '1.0.0'
    windows        = [ordered]@{ edition = 'Windows 11 Pro'; imageIndex = $imageIndex; productKey = 'VK7JG-NPHTM-C97JM-9MPGT-3V66T' }
    locale         = [ordered]@{ language = $lang; inputLocale = $inputLocale; timeZone = $tz }
    registration   = [ordered]@{ owner = 'Test'; organization = 'Test' }
    disk           = [ordered]@{ minSizeGB = 40; allowMultipleDisks = $false }
    naming         = [ordered]@{ prefix = $prefix }
    localAdmin     = [ordered]@{ username = $laUser; password = $laPw; randomizePassword = $false }
    domainJoin     = [ordered]@{ domain = $domain; username = $joinUser }
    software       = [ordered]@{ msi = @(); choco = @(); winget = @(); rebootIfNeeded = $true }
}
if ($ou) { $profileObj.domainJoin.ouPath = $ou }
$profilePath = Join-Path $RepoRoot 'profiles\test-vm.local.json'   # per .gitignore vom Repo ausgeschlossen
$profileObj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $profilePath -Encoding UTF8
Note "Profil geschrieben: $profilePath  (nicht im Git, enthaelt Klartext-Admin-PW)"

# Zusammenfassung
Write-Host "`n--- Zusammenfassung ---" -ForegroundColor Cyan
Write-Host "  Domaene   : $domain$(if($ou){"  OU: $ou"})"
Write-Host "  Join-User : $joinUser"
Write-Host "  Praefix   : $prefix    imageIndex: $imageIndex    Locale: $lang"
Write-Host "  ISO-Quelle: $iso"
if (-not (YesNo "`nJetzt die Test-ISO bauen?")) { Warn3 "Abgebrochen. Profil bleibt: $profilePath"; return }

# ---------------------------------------------------------------------------
# 7/7  Test-ISO bauen (Join-Passwort direkt durchgereicht)
# ---------------------------------------------------------------------------
Head "7/7  Test-ISO bauen"
if (-not $OutIso) {
    if (-not (Test-Path -LiteralPath $IsoDir)) { New-Item -ItemType Directory -Path $IsoDir -Force | Out-Null }
    $OutIso = Join-Path $IsoDir 'WinDeploy-Test.iso'
}
& (Join-Path $Tools 'Build-TestIso.ps1') -ProfilePath $profilePath -IsoPath $iso -OutIso $OutIso -JoinPassword $joinPwSec

# ---------------------------------------------------------------------------
# Fertig -> Proxmox-Anleitung
# ---------------------------------------------------------------------------
Head "FERTIG"
Note "Test-ISO: $OutIso"
Write-Host ""
Write-Host "Naechste Schritte auf Proxmox:" -ForegroundColor Green
Write-Host "  1. ISO hochladen: Datacenter > Storage > local > ISO Images > Upload ($OutIso)." -ForegroundColor Green
Write-Host "  2. Neue VM: BIOS=OVMF(UEFI) + EFI-Disk, Maschine q35, leere Disk >=64GB," -ForegroundColor Green
Write-Host "     Netz-Bridge die den DC von '$domain' erreicht, diese ISO als CD/DVD, Boot: CD zuerst." -ForegroundColor Green
Write-Host "  3. VM starten, Konsole (noVNC) oeffnen - der Deploy laeuft automatisch (mehrere Reboots)." -ForegroundColor Green
Write-Host "  4. Erfolg: neues Computerobjekt '$prefix...' in AD; im Gast Logs unter C:\Windows\Temp\WinDeploy\." -ForegroundColor Green
