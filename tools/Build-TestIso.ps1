#requires -Version 5.1
<#
.SYNOPSIS
    Baut eine bootfaehige WinDeploy-Test-ISO - OHNE Hyper-V. Fuer Proxmox/VMware/ESXi/echte HW.

.DESCRIPTION
    Laeuft auf dem Windows-Build-Host (ADK + WinPE-Add-on + oscdimg noetig). Fuehrt den Generator
    aus (fragt das Join-Passwort ab), baut daraus via Build-Iso eine UEFI-bootfaehige ISO.
    Diese ISO haengst du dann auf deinem Hypervisor an eine LEERE UEFI-VM und bootest davon.

.EXAMPLE
    .\tools\Build-TestIso.ps1 -ProfilePath .\profiles\test-vm.json -IsoPath C:\ISOs\Win11_..._x64_German.iso -OutIso C:\ISOs\WinDeploy-Test.iso
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProfilePath,
    [Parameter(Mandatory)][string]$IsoPath,                                   # Win11-Quell-ISO
    [string]$OutIso  = (Join-Path (Get-Location).Path 'WinDeploy-Test.iso'),
    [string]$WorkDir = (Join-Path $env:TEMP 'windeploy-build')
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot

if (-not (Test-Path -LiteralPath $IsoPath))     { throw "IsoPath nicht gefunden: $IsoPath" }
if (-not (Test-Path -LiteralPath $ProfilePath)) { throw "ProfilePath nicht gefunden: $ProfilePath" }
if (-not (Test-Path -LiteralPath $WorkDir))     { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }

Write-Host "[INFO] Mounte Quell-ISO $IsoPath ..." -ForegroundColor Cyan
$mounted = Mount-DiskImage -ImagePath $IsoPath -PassThru
Start-Sleep -Seconds 2
$drv = ($mounted | Get-Volume | Where-Object { $_.DriveLetter }).DriveLetter
if (-not $drv) { throw "Konnte gemountetem ISO keinen Laufwerksbuchstaben zuordnen." }
$mediaPath = "$($drv):\"

try {
    $genOut = Join-Path $WorkDir 'gen'
    if (Test-Path -LiteralPath $genOut) { Remove-Item -LiteralPath $genOut -Recurse -Force }
    Write-Host "[INFO] Erzeuge Payload/autounattend (Join-Passwort wird abgefragt) ..." -ForegroundColor Cyan
    & (Join-Path $RepoRoot 'Build-DeploymentUSB.ps1') -ProfilePath $ProfilePath -OutputPath $genOut -PromptJoinPassword
    if (-not (Test-Path -LiteralPath (Join-Path $genOut 'autounattend.xml'))) { throw "Generator lieferte keine autounattend.xml." }

    . (Join-Path $RepoRoot 'lib\Build-Iso.ps1')
    if (Test-Path -LiteralPath $OutIso) { Remove-Item -LiteralPath $OutIso -Force }
    Invoke-BuildIso -OutputPath $genOut -WindowsMediaPath $mediaPath -IsoOutPath $OutIso
}
finally {
    Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue | Out-Null
}

Write-Host ""
Write-Host "[ OK ] Test-ISO fertig: $OutIso" -ForegroundColor Green
Write-Host "Naechste Schritte (Proxmox):" -ForegroundColor Green
Write-Host "  1. ISO auf Proxmox-Storage hochladen (Datacenter > Storage > local > ISO Images > Upload)." -ForegroundColor Green
Write-Host "  2. Neue VM: BIOS=OVMF(UEFI) + EFI-Disk, Maschine q35, leere Disk >=64GB, Netz-Bridge zum Test-DC, diese ISO als CD/DVD." -ForegroundColor Green
Write-Host "  3. VM starten, Konsole (noVNC) oeffnen - der Deploy laeuft automatisch." -ForegroundColor Green
