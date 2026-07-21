#requires -Version 5.1
<#
    Build-UsbMedia.ps1 — baut aus dem Generator-Output einen bootfähigen WinDeploy-USB.
    Läuft auf dem Techniker-Windows und benötigt das Windows ADK inkl. WinPE-Add-on
    (für die WinPE-PowerShell-Komponente, damit Deploy-WinPE.ps1 in WinPE laufen kann).

    Layout des USB:
      Partition 1 (FAT32, UEFI-bootfähig):  Windows-Setup-Bootdateien + \sources\boot.wim (mit PS)
                                            + autounattend.xml (Root) + \deploy\ (Skripte)
      Partition 2 (NTFS):                    \images\install.wim  (> 4 GB, daher NICHT FAT32, §5.3)

    SICHERHEIT: Der Ziel-USB wird über Get-Disk geprüft (BusType=USB, nicht Boot/System)
    und der Wipe läuft nur nach ausdrücklicher Bestätigung (ShouldProcess).
#>

function Get-AdkWinPeOcPath {
    $candidates = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs",
        "${env:ProgramFiles}\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs"
    )
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    return $null
}

function Add-WinPePowerShell {
    param([Parameter(Mandatory)][string]$MountPath, [Parameter(Mandatory)][string]$OcPath)
    # Reihenfolge = Abhängigkeitsreihenfolge für WinPE-PowerShell
    $pkgs = @('WinPE-WMI','WinPE-NetFX','WinPE-Scripting','WinPE-PowerShell','WinPE-StorageWMI','WinPE-DismCmdlets')
    foreach ($p in $pkgs) {
        $cab = Join-Path $OcPath "$p.cab"
        if (-not (Test-Path -LiteralPath $cab)) { throw "WinPE-Paket fehlt: $cab (ADK WinPE-Add-on installiert?)" }
        Add-WindowsPackage -Path $MountPath -PackagePath $cab -ErrorAction Stop | Out-Null
        $langCab = Join-Path $OcPath "en-us\${p}_en-us.cab"
        if (Test-Path -LiteralPath $langCab) { Add-WindowsPackage -Path $MountPath -PackagePath $langCab | Out-Null }
        Write-Host "[ OK ] WinPE-Komponente hinzugefügt: $p" -ForegroundColor Green
    }
}

function Invoke-BuildUsbMedia {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][int]$UsbDisk,
        [Parameter(Mandatory)][string]$WindowsMediaPath,
        [Parameter(Mandatory)]$PSCmdlet
    )

    if ($UsbDisk -lt 0) { throw "-UsbDisk (Disk-Nummer aus 'Get-Disk') ist erforderlich für -BuildMedia." }
    if (-not (Test-Path -LiteralPath $WindowsMediaPath)) { throw "-WindowsMediaPath nicht gefunden: $WindowsMediaPath" }
    $srcBoot = Join-Path $WindowsMediaPath 'sources\boot.wim'
    if (-not (Test-Path -LiteralPath $srcBoot)) { throw "boot.wim nicht gefunden unter $WindowsMediaPath\sources (Windows-11-Medium einhängen/extrahieren)." }

    $ocPath = Get-AdkWinPeOcPath
    if (-not $ocPath) { throw "Windows ADK WinPE-Add-on nicht gefunden. Installieren: ADK + 'Windows PE Add-on'." }

    # --- Ziel-USB verifizieren (SICHERHEIT) ---
    $disk = Get-Disk -Number $UsbDisk -ErrorAction Stop
    $sizeGB = [math]::Round($disk.Size/1GB, 0)
    if ($disk.BusType -ne 'USB') { throw "Disk $UsbDisk ist BusType '$($disk.BusType)', kein USB. ABBRUCH." }
    if ($disk.IsBoot -or $disk.IsSystem) { throw "Disk $UsbDisk ist Boot/System-Datenträger. ABBRUCH." }
    if ($sizeGB -gt 512) { throw "Disk $UsbDisk ist $sizeGB GB (> 512) — untypisch für einen USB-Stick. ABBRUCH zur Sicherheit." }

    $target = "USB-Disk $UsbDisk ($($disk.FriendlyName), $sizeGB GB)"
    if (-not $PSCmdlet.ShouldProcess($target, "ALLE DATEN LÖSCHEN und WinDeploy-USB bauen")) {
        Write-Host "Abgebrochen (keine Bestätigung)." -ForegroundColor Yellow
        return
    }

    # --- Partitionieren ---
    Write-Host "[INFO] Partitioniere $target ..." -ForegroundColor Cyan
    Clear-Disk -Number $UsbDisk -RemoveData -RemoveOEM -Confirm:$false
    Initialize-Disk -Number $UsbDisk -PartitionStyle GPT -Confirm:$false -ErrorAction SilentlyContinue

    $bootPart = New-Partition -DiskNumber $UsbDisk -Size 2GB -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
    Format-Volume -Partition $bootPart -FileSystem FAT32 -NewFileSystemLabel 'WDBOOT' -Confirm:$false | Out-Null
    $bootPart | Set-Partition -NewDriveLetter B
    $dataPart = New-Partition -DiskNumber $UsbDisk -UseMaximumSize -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
    Format-Volume -Partition $dataPart -FileSystem NTFS -NewFileSystemLabel 'WDDATA' -Confirm:$false | Out-Null
    $dataPart | Set-Partition -NewDriveLetter Y

    # --- Setup-Bootdateien auf FAT32 (ohne install.wim) ---
    Write-Host "[INFO] Kopiere Windows-Setup-Bootdateien ..." -ForegroundColor Cyan
    robocopy $WindowsMediaPath 'B:\' /E /XF 'install.wim' 'install.esd' /XD 'sources\install' /NFL /NDL /NJH /NJS | Out-Null
    New-Item -ItemType Directory -Path 'B:\sources' -Force | Out-Null

    # --- boot.wim mit PowerShell patchen (Index 2 = Setup-WinPE) ---
    $work = Join-Path $OutputPath 'work'
    $mount = Join-Path $work 'mount'
    New-Item -ItemType Directory -Path $mount -Force | Out-Null
    $workBoot = Join-Path $work 'boot.wim'
    Copy-Item -LiteralPath $srcBoot -Destination $workBoot -Force
    Set-ItemProperty -LiteralPath $workBoot -Name IsReadOnly -Value $false
    try {
        Write-Host "[INFO] Mounte boot.wim (Index 2) und füge WinPE-PowerShell hinzu ..." -ForegroundColor Cyan
        Mount-WindowsImage -ImagePath $workBoot -Index 2 -Path $mount -ErrorAction Stop | Out-Null
        Add-WinPePowerShell -MountPath $mount -OcPath $ocPath
        Dismount-WindowsImage -Path $mount -Save -ErrorAction Stop | Out-Null
    } catch {
        try { Dismount-WindowsImage -Path $mount -Discard -ErrorAction SilentlyContinue | Out-Null } catch { }
        throw
    }
    Copy-Item -LiteralPath $workBoot -Destination 'B:\sources\boot.wim' -Force

    # --- autounattend.xml + Payload auf FAT32 ---
    Copy-Item -LiteralPath (Join-Path $OutputPath 'autounattend.xml') -Destination 'B:\autounattend.xml' -Force
    robocopy (Join-Path $OutputPath 'deploy') 'B:\deploy' /E /NFL /NDL /NJH /NJS | Out-Null

    # --- install.wim auf NTFS (§5.3) ---
    New-Item -ItemType Directory -Path 'Y:\images' -Force | Out-Null
    $img = Get-ChildItem -LiteralPath (Join-Path $OutputPath 'images') -File -ErrorAction SilentlyContinue |
           Where-Object { $_.Extension -in '.wim','.esd','.swm' } | Select-Object -First 1
    if (-not $img) {
        $srcInstall = Join-Path $WindowsMediaPath 'sources\install.wim'
        if (-not (Test-Path $srcInstall)) { $srcInstall = Join-Path $WindowsMediaPath 'sources\install.esd' }
        if (Test-Path $srcInstall) { $img = Get-Item $srcInstall }
    }
    if (-not $img) { throw "Kein install.wim/.esd gefunden (weder in Output\images noch im WindowsMediaPath)." }
    Write-Host "[INFO] Kopiere $($img.Name) auf die NTFS-Partition (kann dauern) ..." -ForegroundColor Cyan
    Copy-Item -LiteralPath $img.FullName -Destination ('Y:\images\' + $img.Name) -Force

    # Arbeitsordner aufräumen
    try { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue } catch { }

    Write-Host "[ OK ] WinDeploy-USB fertig auf Disk $UsbDisk. Vom Ziel-PC (UEFI) booten." -ForegroundColor Green
    Write-Host "       Erinnerung: USB enthält Credentials — physisch sichern." -ForegroundColor Yellow
}
