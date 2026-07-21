#requires -Version 5.1
<#
    Deploy-WinPE.ps1 — läuft in WinPE (via WinPE-PowerShell-Komponente).
    Wird aus autounattend.xml (windowsPE-Pass, RunSynchronous) gestartet.

    Verantwortlich für den sicherheitskritischen Teil (§5.1):
      1. Ziel-Datenträger FAIL-SAFE wählen (Abbruch statt falscher Wipe)
      2. GPT/UEFI-Partitionen anlegen (ESP / MSR / Windows / Recovery)
      3. Windows-Abbild via DISM anwenden (install.wim/.esd von der NTFS-Payload)
      4. Bootdateien schreiben (bcdboot)
      5. autounattend.xml + Payload auf die Systemplatte kopieren
      6. Reboot in das installierte Windows

    Aufruf (aus autounattend RunSynchronous, Laufwerksbuchstabe wird gesucht):
      for %i in (C..Z) do if exist %i:\deploy\Deploy-WinPE.ps1 powershell -File %i:\deploy\Deploy-WinPE.ps1 -MediaRoot %i:\
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MediaRoot
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\Deploy.Common.psm1') -Force

function Find-InstallImage {
    # install.wim/.esd liegt auf der NTFS-Payload-Partition unter \images\
    foreach ($vol in (Get-Volume | Where-Object { $_.DriveLetter })) {
        foreach ($name in @('install.wim','install.esd','install.swm')) {
            $p = ('{0}:\images\{1}' -f $vol.DriveLetter, $name)
            if (Test-Path -LiteralPath $p) { return $p }
        }
    }
    throw "Kein Windows-Abbild (\images\install.wim/.esd) auf den Datenträgern gefunden."
}

try {
    Write-DeployLog "=== WinPE-Phase gestartet (MediaRoot=$MediaRoot) ===" -Component winpe

    # Konfig von der Payload lesen (Flags: allowMultipleDisks, edition, imageIndex)
    $cfgPath = Join-Path $PSScriptRoot 'config\deploy.config.json'
    $cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json

    # 1) Ziel-Datenträger fail-safe wählen
    $allowMulti = [bool]$cfg.disk.allowMultipleDisks
    $minGB      = [int]$cfg.disk.minSizeGB
    if ($minGB -le 0) { $minGB = 60 }
    $disk = Get-TargetInternalDisk -AllowMultiple:$allowMulti -MinSizeGB $minGB
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

    # Recovery (1GB, direkt hinter Windows angelegt -> zuerst Windows, dann Recovery)
    # Windows-Partition: Rest minus 1GB Recovery
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
    # Attribut GPT_ATTRIBUTE_PLATFORM_REQUIRED + hidden für WinRE via diskpart
    $dp = @(
        "select disk $diskNumber",
        "select partition $($rec.PartitionNumber)",
        "gpt attributes=0x8000000000000001",
        "exit"
    ) -join "`r`n"
    $dp | diskpart | Out-Null

    Write-DeployLog "Partitionierung abgeschlossen (ESP=S:, Windows=W:, Recovery=R:)." -Level OK -Component winpe

    # 3) Abbild anwenden (DISM)
    $image = Find-InstallImage
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

    # WinRE einrichten (Recovery)
    try {
        $reSrc = 'W:\Windows\System32\Recovery\Winre.wim'
        if (Test-Path -LiteralPath $reSrc) {
            New-Item -ItemType Directory -Path 'R:\Recovery\WindowsRE' -Force | Out-Null
            Copy-Item -LiteralPath $reSrc -Destination 'R:\Recovery\WindowsRE\Winre.wim' -Force
            & "$env:SystemRoot\System32\reagentc.exe" /setreimage /path 'R:\Recovery\WindowsRE' /target 'W:\Windows' | Out-Null
        }
    } catch { Write-DeployLog "WinRE-Setup übersprungen: $($_.Exception.Message)" -Level WARN -Component winpe }

    # 5) autounattend.xml in Panther legen (specialize + oobeSystem laufen beim ersten Boot)
    $answer = Join-Path $MediaRoot 'autounattend.xml'
    if (-not (Test-Path -LiteralPath $answer)) { $answer = Join-Path $PSScriptRoot 'autounattend.xml' }
    New-Item -ItemType Directory -Path 'W:\Windows\Panther' -Force | Out-Null
    Copy-Item -LiteralPath $answer -Destination 'W:\Windows\Panther\unattend.xml' -Force

    # Payload nach W:\Deploy kopieren (= C:\Deploy nach Boot) — überlebt USB-Abzug
    Write-DeployLog "Kopiere Payload nach W:\Deploy ..." -Component winpe
    New-Item -ItemType Directory -Path 'W:\Deploy' -Force | Out-Null
    Copy-Item -Path (Join-Path $PSScriptRoot '*') -Destination 'W:\Deploy' -Recurse -Force -Exclude 'images'

    Write-DeployLog "=== WinPE-Phase fertig — Neustart in das installierte Windows ===" -Level OK -Component winpe
    Start-Sleep -Seconds 3
    & "$env:SystemRoot\System32\wpeutil.exe" reboot
}
catch {
    Write-DeployLog "WinPE-Phase FEHLGESCHLAGEN: $($_.Exception.Message)" -Level ERROR -Component winpe
    Write-DeployLog $_.ScriptStackTrace -Level ERROR -Component winpe
    # Bewusst NICHT automatisch weiter — Techniker soll den Fehler sehen.
    Write-Host ""
    Write-Host "  ############################################################" -ForegroundColor Red
    Write-Host "  #  WINDEPLOY ABGEBROCHEN — kein Datenträger wurde verändert #" -ForegroundColor Red
    Write-Host "  #  $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  ############################################################" -ForegroundColor Red
    Write-Host ""
    Start-Sleep -Seconds 3600
    exit 1
}
