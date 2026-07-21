#requires -Version 5.1
<#
    Deploy-WinPE.ps1 — läuft in WinPE (via WinPE-PowerShell-Komponente).

    PRIMÄRER Start: winpeshl.ini/startnet in der boot.wim ruft dieses Skript direkt auf
    (siehe lib/Build-UsbMedia.ps1) — unabhängig von der 24H2/25H2-Setup-Engine.
    FALLBACK: autounattend.xml windowsPE RunSynchronous (falls doch über setup.exe gebootet).

    Verantwortlich für den sicherheitskritischen Teil (§5.1):
      1. Medium-/Abbild-Datenträger ausschließen, Ziel FAIL-SAFE wählen (Abbruch statt falscher Wipe)
      2. Idempotenz-Marker prüfen -> kein erneuter Wipe einer bereits installierten Platte
      3. GPT/UEFI-Partitionen anlegen (ESP / MSR / Windows / Recovery)
      4. Windows-Abbild via DISM anwenden
      5. Bootdateien schreiben (bcdboot), autounattend.xml nach Panther, Payload nach C:\Deploy
      6. Marker schreiben, Reboot in das installierte Windows

    Aufruf: Deploy-WinPE.ps1 -MediaRoot <Laufwerk der \deploy-Payload, z.B. D:\>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MediaRoot
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\Deploy.Common.psm1') -Force

function Find-InstallImage {
    foreach ($vol in (Get-Volume | Where-Object { $_.DriveLetter })) {
        foreach ($name in @('install.wim','install.esd','install.swm')) {
            $p = ('{0}:\images\{1}' -f $vol.DriveLetter, $name)
            if (Test-Path -LiteralPath $p) { return $p }
        }
    }
    throw "Kein Windows-Abbild (\images\install.wim/.esd) auf den Datenträgern gefunden."
}

function Get-DiskNumberForLetter {
    param([string]$Letter)
    try {
        $p = Get-Partition -DriveLetter $Letter -ErrorAction Stop
        return [int]$p.DiskNumber
    } catch { return $null }
}

try {
    Write-DeployLog "=== WinPE-Phase gestartet (MediaRoot=$MediaRoot) ===" -Component winpe

    $cfgPath = Join-Path $PSScriptRoot 'config\deploy.config.json'
    $cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json

    # Abbild + dessen Datenträger bestimmen
    $image = Find-InstallImage
    $imageLetter = $image.Substring(0,1)

    # Medium- und Abbild-Datenträger ausschließen (IsBoot ist in WinPE unzuverlässig, Review-Fund #9)
    $excludeDisks = @()
    $mediaLetter = $MediaRoot.Substring(0,1)
    foreach ($lt in @($mediaLetter, $imageLetter)) {
        $dn = Get-DiskNumberForLetter -Letter $lt
        if ($null -ne $dn) { $excludeDisks += $dn }
    }
    $excludeDisks = @($excludeDisks | Select-Object -Unique)

    # Idempotenz: bereits deployt? -> nicht erneut löschen (Review-Fund #7)
    if (Test-DeployAlreadyApplied) {
        Write-DeployLog "WinDeploy-Marker gefunden — diese Platte ist bereits installiert. KEIN erneuter Wipe." -Level WARN -Component winpe
        Write-DeployLog "Setze Firmware-Start auf Windows und starte neu. (Falls Schleife: USB entfernen.)" -Component winpe
        Set-FirmwareBootToWindows
        Start-Sleep -Seconds 5
        & "$env:SystemRoot\System32\wpeutil.exe" reboot
        return
    }

    # 1) Ziel-Datenträger fail-safe wählen
    $allowMulti = [bool]$cfg.disk.allowMultipleDisks
    $minGB      = [int]$cfg.disk.minSizeGB
    if ($minGB -le 0) { $minGB = 60 }
    $disk = Get-TargetInternalDisk -AllowMultiple:$allowMulti -MinSizeGB $minGB -ExcludeDiskNumbers $excludeDisks
    $diskNumber = $disk.Number

    # 2) Partitionieren (GPT/UEFI)
    Write-DeployLog "Bereinige und partitioniere Disk $diskNumber ..." -Component winpe
    Clear-Disk -Number $diskNumber -RemoveData -RemoveOEM -Confirm:$false
    Initialize-Disk -Number $diskNumber -PartitionStyle GPT -Confirm:$false -ErrorAction SilentlyContinue

    # ESP (FAT32, >=260MB)
    $esp = New-Partition -DiskNumber $diskNumber -Size 300MB -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
    Format-Volume -Partition $esp -FileSystem FAT32 -NewFileSystemLabel 'System' -Confirm:$false | Out-Null
    $esp | Set-Partition -NewDriveLetter S

    # MSR (16MB)
    New-Partition -DiskNumber $diskNumber -Size 16MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' | Out-Null

    # Windows-Partition (Rest minus 1GB Recovery + etwas Reserve)
    $reserveRecovery = 1024MB
    $espMsr = 316MB
    $winSize = $disk.Size - $espMsr - $reserveRecovery - 64MB
    $win = New-Partition -DiskNumber $diskNumber -Size $winSize -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
    Format-Volume -Partition $win -FileSystem NTFS -NewFileSystemLabel 'Windows' -Confirm:$false | Out-Null
    $win | Set-Partition -NewDriveLetter W

    # Recovery-Partition (WinRE), korrekte Type-ID + PLATFORM_REQUIRED
    $rec = New-Partition -DiskNumber $diskNumber -UseMaximumSize -GptType '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
    Format-Volume -Partition $rec -FileSystem NTFS -NewFileSystemLabel 'Recovery' -Confirm:$false | Out-Null
    $rec | Set-Partition -NewDriveLetter R
    $dp = @(
        "select disk $diskNumber",
        "select partition $($rec.PartitionNumber)",
        "gpt attributes=0x8000000000000001",
        "exit"
    ) -join "`r`n"
    $dp | diskpart | Out-Null

    Write-DeployLog "Partitionierung abgeschlossen (ESP=S:, Windows=W:, Recovery=R:)." -Level OK -Component winpe

    # 3) Abbild anwenden (DISM)
    $index = [int]$cfg.image.index
    if ($index -le 0) { $index = 1 }
    Write-DeployLog "Wende Abbild an: $image (Index $index) -> W:\ ..." -Component winpe
    if ($image -like '*.swm') {
        $pattern = ($image -replace 'install\.swm$', 'install*.swm')
        Expand-WindowsImage -ImagePath $image -SplitImageFilePattern $pattern -Index $index -ApplyPath 'W:\' | Out-Null
    } else {
        Expand-WindowsImage -ImagePath $image -Index $index -ApplyPath 'W:\' | Out-Null
    }

    # 4) Bootdateien (UEFI)
    Write-DeployLog "Schreibe Bootdateien (bcdboot) ..." -Component winpe
    & "$env:SystemRoot\System32\bcdboot.exe" 'W:\Windows' /s S: /f UEFI | Out-Null

    # WinRE einrichten
    try {
        $reSrc = 'W:\Windows\System32\Recovery\Winre.wim'
        if (Test-Path -LiteralPath $reSrc) {
            New-Item -ItemType Directory -Path 'R:\Recovery\WindowsRE' -Force | Out-Null
            Copy-Item -LiteralPath $reSrc -Destination 'R:\Recovery\WindowsRE\Winre.wim' -Force
            & "$env:SystemRoot\System32\reagentc.exe" /setreimage /path 'R:\Recovery\WindowsRE' /target 'W:\Windows' | Out-Null
        }
    } catch { Write-DeployLog "WinRE-Setup übersprungen: $($_.Exception.Message)" -Level WARN -Component winpe }

    # 5) autounattend.xml in Panther legen (specialize + oobeSystem beim ersten Boot)
    $answer = Join-Path $MediaRoot 'autounattend.xml'
    if (-not (Test-Path -LiteralPath $answer)) { throw "autounattend.xml nicht unter MediaRoot '$MediaRoot' gefunden." }
    New-Item -ItemType Directory -Path 'W:\Windows\Panther' -Force | Out-Null
    Copy-Item -LiteralPath $answer -Destination 'W:\Windows\Panther\unattend.xml' -Force

    # Payload nach W:\Deploy (= C:\Deploy nach Boot). autounattend.xml NICHT mitkopieren
    # (enthält lokales Admin-PW im Klartext, Review-Fund #8).
    Write-DeployLog "Kopiere Payload nach W:\Deploy ..." -Component winpe
    New-Item -ItemType Directory -Path 'W:\Deploy' -Force | Out-Null
    Copy-Item -Path (Join-Path $PSScriptRoot '*') -Destination 'W:\Deploy' -Recurse -Force -Exclude 'images','autounattend.xml'

    # 6) Idempotenz-Marker schreiben, dann Reboot
    $buildUtc = ''
    if ($cfg.PSObject.Properties['buildUtc']) { $buildUtc = [string]$cfg.buildUtc }
    Write-DeployAppliedMarker -WindowsDrive 'W:' -BuildUtc $buildUtc

    Write-DeployLog "=== WinPE-Phase fertig — Neustart in das installierte Windows ===" -Level OK -Component winpe
    Start-Sleep -Seconds 3
    & "$env:SystemRoot\System32\wpeutil.exe" reboot
}
catch {
    Write-DeployLog "WinPE-Phase FEHLGESCHLAGEN: $($_.Exception.Message)" -Level ERROR -Component winpe
    Write-DeployLog $_.ScriptStackTrace -Level ERROR -Component winpe
    Write-Host ""
    Write-Host "  ############################################################" -ForegroundColor Red
    Write-Host "  #  WINDEPLOY ABGEBROCHEN — kein Datenträger wurde verändert #" -ForegroundColor Red
    Write-Host "  #  $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  ############################################################" -ForegroundColor Red
    Write-Host ""
    Start-Sleep -Seconds 3600
    exit 1
}
