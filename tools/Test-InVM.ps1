#requires -Version 5.1
<#
.SYNOPSIS
    Ende-zu-Ende VM-Test fuer WinDeploy: Generator -> bootfaehige ISO -> Hyper-V-Gen2-VM ->
    booten -> Deployment durchlaufen lassen -> via PowerShell Direct verifizieren (PASS/FAIL).

.DESCRIPTION
    Laeuft auf dem Windows-Build-Host (Hyper-V + ADK noetig). Das Join-Passwort wird beim
    Generatorlauf sicher abgefragt (-PromptJoinPassword). Die Verifikation liest im Gast
    C:\Windows\Temp\WinDeploy\summary.json via PowerShell Direct mit dem lokalen Admin.

    WICHTIG: Das Testprofil MUSS localAdmin.randomizePassword = false setzen, sonst ist das
    lokale Admin-Passwort nach dem Deploy geaendert und PowerShell Direct kommt nicht mehr rein.

.EXAMPLE
    .\tools\Test-InVM.ps1 -ProfilePath .\profiles\test-vm.json -IsoPath C:\ISOs\Win11_..._x64_German.iso -SwitchName "Test-AD"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProfilePath,
    [Parameter(Mandatory)][string]$IsoPath,            # Win11-Quell-ISO (von Get-Win11Iso.ps1)
    [string]$SwitchName,                               # Hyper-V-Switch mit Zugang zum Test-DC
    [string]$VMName = 'WinDeploy-Test',
    [int]$MemoryGB = 4,
    [int]$DiskGB = 64,
    [int]$Cpu = 2,
    [string]$WorkDir = (Join-Path $env:TEMP 'windeploy-test'),
    [int]$TimeoutMin = 60,
    [switch]$NoSecureBoot,
    [switch]$KeepExistingVM
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot

function Info { param($m) Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Ok   { param($m) Write-Host "[ OK ] $m" -ForegroundColor Green }
function Warn { param($m) Write-Host "[WARN] $m" -ForegroundColor Yellow }

# --- Vorbedingungen ---
if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) { throw "Hyper-V-PowerShell fehlt. Hyper-V aktivieren (Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All) + Neustart." }
if (-not (Test-Path -LiteralPath $IsoPath)) { throw "IsoPath nicht gefunden: $IsoPath" }
if (-not (Test-Path -LiteralPath $ProfilePath)) { throw "ProfilePath nicht gefunden: $ProfilePath" }
if (-not (Test-Path -LiteralPath $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }

$prof = Get-Content -LiteralPath $ProfilePath -Raw | ConvertFrom-Json
if ($prof.localAdmin.PSObject.Properties['randomizePassword'] -and $prof.localAdmin.randomizePassword) {
    Warn "Profil hat randomizePassword=true. Fuer die PowerShell-Direct-Verifikation bitte auf false setzen (sonst Verify-Timeout trotz erfolgreichem Deploy)."
}

# --- 1) Win11-Quell-ISO mounten ---
Info "Mounte Quell-ISO $IsoPath ..."
$mounted = Mount-DiskImage -ImagePath $IsoPath -PassThru
Start-Sleep -Seconds 2
$mediaDrive = ($mounted | Get-Volume | Where-Object { $_.DriveLetter }).DriveLetter
if (-not $mediaDrive) { throw "Konnte gemountetem ISO keinen Laufwerksbuchstaben zuordnen." }
$mediaPath = "$($mediaDrive):\"

try {
    # --- 2) Generator: Payload + autounattend (Join-Passwort wird abgefragt) ---
    $genOut = Join-Path $WorkDir 'gen'
    if (Test-Path -LiteralPath $genOut) { Remove-Item -LiteralPath $genOut -Recurse -Force }
    Info "Erzeuge Payload/autounattend (Join-Passwort wird abgefragt) ..."
    & (Join-Path $RepoRoot 'Build-DeploymentUSB.ps1') -ProfilePath $ProfilePath -OutputPath $genOut -PromptJoinPassword
    if (-not (Test-Path -LiteralPath (Join-Path $genOut 'autounattend.xml'))) { throw "Generator lieferte keine autounattend.xml." }

    # --- 3) Bootfaehige ISO bauen ---
    . (Join-Path $RepoRoot 'lib\Build-Iso.ps1')
    $isoOut = Join-Path $WorkDir 'WinDeploy-Test.iso'
    if (Test-Path -LiteralPath $isoOut) { Remove-Item -LiteralPath $isoOut -Force }
    Invoke-BuildIso -OutputPath $genOut -WindowsMediaPath $mediaPath -IsoOutPath $isoOut
}
finally {
    Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue | Out-Null
}

# --- 4) Hyper-V-Gen2-VM anlegen ---
if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
    if ($KeepExistingVM) { throw "VM '$VMName' existiert bereits (und -KeepExistingVM gesetzt)." }
    Info "Entferne bestehende VM '$VMName' ..."
    Stop-VM -Name $VMName -TurnOff -Force -ErrorAction SilentlyContinue
    Remove-VM -Name $VMName -Force
}
$vhd = Join-Path $WorkDir "$VMName.vhdx"
if (Test-Path -LiteralPath $vhd) { Remove-Item -LiteralPath $vhd -Force }

Info "Erstelle VM '$VMName' (Gen2, $MemoryGB GB RAM, $DiskGB GB Disk, $Cpu vCPU) ..."
$vm = New-VM -Name $VMName -Generation 2 -MemoryStartupBytes ($MemoryGB * 1GB) -NewVHDPath $vhd -NewVHDSizeBytes ($DiskGB * 1GB)
Set-VM -Name $VMName -ProcessorCount $Cpu -AutomaticCheckpointsEnabled $false
if ($SwitchName) { Connect-VMNetworkAdapter -VMName $VMName -SwitchName $SwitchName }
else { Warn "Kein -SwitchName: die VM hat kein Netz -> Domaenenbeitritt schlaegt fehl." }

Add-VMDvdDrive -VMName $VMName -Path $isoOut
$dvd = Get-VMDvdDrive -VMName $VMName
Set-VMFirmware -VMName $VMName -FirstBootDevice $dvd
if ($NoSecureBoot) {
    Set-VMFirmware -VMName $VMName -EnableSecureBoot Off
    Warn "Secure Boot deaktiviert (Testmodus)."
} else {
    Set-VMFirmware -VMName $VMName -EnableSecureBoot On -SecureBootTemplate 'MicrosoftWindows'
}

Info "Starte VM und oeffne Konsole ..."
Start-VM -Name $VMName
Start-Process 'vmconnect.exe' -ArgumentList 'localhost', $VMName -ErrorAction SilentlyContinue

# --- 5) Verifikation via PowerShell Direct (lokaler Admin aus Profil) ---
$laUser = [string]$prof.localAdmin.username
$laPw   = [string]$prof.localAdmin.password
$cred   = New-Object System.Management.Automation.PSCredential(".\$laUser", (ConvertTo-SecureString $laPw -AsPlainText -Force))

Info "Warte auf Deploy-Abschluss (bis $TimeoutMin min, pruefe alle 30 s via PowerShell Direct) ..."
$deadline = (Get-Date).AddMinutes($TimeoutMin)
$summary = $null
$failMarker = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 30
    try {
        $res = Invoke-Command -VMName $VMName -Credential $cred -ErrorAction Stop -ScriptBlock {
            $s = 'C:\Windows\Temp\WinDeploy\summary.json'
            $f = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'DEPLOY-FAILED.txt'
            [pscustomobject]@{
                Summary = if (Test-Path $s) { Get-Content $s -Raw } else { $null }
                Failed  = (Test-Path $f)
                Computer = $env:COMPUTERNAME
                Domain   = (Get-CimInstance Win32_ComputerSystem).Domain
            }
        }
        if ($res.Summary) { $summary = $res.Summary; break }
        if ($res.Failed)  { $failMarker = $true; break }
        Info "Gast erreichbar ($($res.Computer) / $($res.Domain)) - Deploy laeuft noch ..."
    } catch {
        # Gast noch in WinPE/Reboot/Setup - normal, weiter warten
    }
}

Write-Host "`n==================== ERGEBNIS ====================" -ForegroundColor Cyan
if ($summary) {
    Ok "PASS - Deployment abgeschlossen:"
    Write-Host $summary
} elseif ($failMarker) {
    Write-Host "[FAIL] DEPLOY-FAILED-Marker im Gast. Konsole/Logs pruefen: im Gast C:\Windows\Temp\WinDeploy\ bzw. C:\Deploy\logs\" -ForegroundColor Red
} else {
    Write-Host "[TIMEOUT] Kein Ergebnis in $TimeoutMin min. Konsole (vmconnect) ansehen; Logs im Gast unter C:\Deploy\logs\ / C:\Windows\Temp\WinDeploy\." -ForegroundColor Red
}
Write-Host "VM '$VMName' bleibt zur Analyse bestehen. Entfernen: Remove-VM -Name '$VMName' -Force; Remove-Item '$vhd' -Force" -ForegroundColor DarkGray
