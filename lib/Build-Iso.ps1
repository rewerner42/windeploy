#requires -Version 5.1
<#
    Build-Iso.ps1 - baut aus dem Generator-Output eine bootfaehige WinDeploy-ISO (fuer VM-Tests).
    Benoetigt Windows ADK (oscdimg + WinPE-Add-on). Reutzt Funktionen aus Build-UsbMedia.ps1
    (Get-AdkWinPeOcPath, Add-WinPePowerShell).

    Im Gegensatz zum USB (2 Partitionen wegen FAT32/4GB) liegt bei der ISO (UDF) alles auf
    EINEM Dateisystem: gepatchte \sources\boot.wim + \deploy\ + autounattend.xml + \sources\install.wim.
#>

. (Join-Path $PSScriptRoot 'Build-UsbMedia.ps1')

function Get-OscdimgPath {
    foreach ($root in @("${env:ProgramFiles(x86)}\Windows Kits\10", "${env:ProgramFiles}\Windows Kits\10")) {
        $p = Join-Path $root 'Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe'
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Invoke-BuildIso {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputPath,       # Generator-Output (deploy\ + autounattend.xml)
        [Parameter(Mandatory)][string]$WindowsMediaPath, # gemountetes Win11-Medium (sources\boot.wim + install.wim)
        [Parameter(Mandatory)][string]$IsoOutPath        # Ziel .iso
    )
    $oscdimg = Get-OscdimgPath
    if (-not $oscdimg) { throw "oscdimg.exe nicht gefunden (ADK Deployment Tools installieren)." }
    $ocPath = Get-AdkWinPeOcPath
    if (-not $ocPath) { throw "ADK WinPE-Add-on nicht gefunden." }
    $srcBoot = Join-Path $WindowsMediaPath 'sources\boot.wim'
    if (-not (Test-Path -LiteralPath $srcBoot)) { throw "boot.wim nicht unter $WindowsMediaPath\sources gefunden." }

    $stage = Join-Path $OutputPath 'iso-stage'
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    New-Item -ItemType Directory -Path $stage -Force | Out-Null

    # 1) Windows-Medium ins Stage kopieren (install.wim bleibt drin -> Find-InstallImage nutzt \sources\)
    Write-Host "[INFO] Kopiere Windows-Medium ins Stage (dauert) ..." -ForegroundColor Cyan
    & robocopy $WindowsMediaPath $stage /E /NFL /NDL /NJH /NJS | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy (Medium) fehlgeschlagen: Code $LASTEXITCODE" }

    # 2) boot.wim (Index 2 = Setup-WinPE) patchen: WinPE-PowerShell + winpeshl-Launcher
    $mount = Join-Path $OutputPath 'iso-mount'
    if (Test-Path -LiteralPath $mount) { Remove-Item -LiteralPath $mount -Recurse -Force }
    New-Item -ItemType Directory -Path $mount -Force | Out-Null
    $stageBoot = Join-Path $stage 'sources\boot.wim'
    Set-ItemProperty -LiteralPath $stageBoot -Name IsReadOnly -Value $false
    try {
        Write-Host "[INFO] Patche boot.wim (WinPE-PowerShell + Startlauncher) ..." -ForegroundColor Cyan
        Mount-WindowsImage -ImagePath $stageBoot -Index 2 -Path $mount -ErrorAction Stop | Out-Null
        Add-WinPePowerShell -MountPath $mount -OcPath $ocPath
        $winpeshl = @(
            '[LaunchApps]',
            '%SYSTEMROOT%\System32\wpeinit.exe',
            '%SYSTEMROOT%\System32\cmd.exe, "/c %SYSTEMDRIVE%\deploy-launch.cmd"'
        ) -join "`r`n"
        Set-Content -LiteralPath (Join-Path $mount 'Windows\System32\winpeshl.ini') -Value $winpeshl -Encoding Ascii
        $launch = '@echo off' + "`r`n" +
            'for %%i in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do if exist %%i:\deploy\Deploy-WinPE.ps1 powershell -NoProfile -ExecutionPolicy Bypass -File %%i:\deploy\Deploy-WinPE.ps1 -MediaRoot %%i:\'
        Set-Content -LiteralPath (Join-Path $mount 'deploy-launch.cmd') -Value $launch -Encoding Ascii
        Dismount-WindowsImage -Path $mount -Save -ErrorAction Stop | Out-Null
    } catch {
        try { Dismount-WindowsImage -Path $mount -Discard -ErrorAction SilentlyContinue | Out-Null } catch { }
        throw
    }

    # 3) Payload + autounattend ins Stage
    Copy-Item -LiteralPath (Join-Path $OutputPath 'autounattend.xml') -Destination (Join-Path $stage 'autounattend.xml') -Force
    Copy-Item -Path (Join-Path $OutputPath 'deploy') -Destination (Join-Path $stage 'deploy') -Recurse -Force

    # 4) oscdimg -> bootfaehige UEFI+BIOS-ISO
    $etfs   = Join-Path $stage 'boot\etfsboot.com'
    $efisys = Join-Path $stage 'efi\microsoft\boot\efisys.bin'
    if (-not (Test-Path -LiteralPath $efisys)) { throw "efisys.bin fehlt im Medium ($efisys) - kein UEFI-Boot moeglich." }
    $bootdata = "2#p0,e,b$etfs#pEF,e,b$efisys"
    Write-Host "[INFO] Erzeuge ISO mit oscdimg ..." -ForegroundColor Cyan
    & $oscdimg -m -o -u2 -udfver102 "-bootdata:$bootdata" $stage $IsoOutPath
    if ($LASTEXITCODE -ne 0) { throw "oscdimg fehlgeschlagen: Code $LASTEXITCODE" }

    Remove-Item -LiteralPath $mount -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "[ OK ] ISO erstellt: $IsoOutPath" -ForegroundColor Green
    return $IsoOutPath
}
