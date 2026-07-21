#requires -Version 5.1
<#
    Invoke-Deploy.ps1 — Orchestrator (läuft im ersten Admin-Logon des installierten Windows).
    Reboot-feste State-Machine:  Rename -> Software -> Domänenbeitritt -> Cleanup.
    Erststart via FirstLogonCommands; Fortsetzung nach jedem Reboot via geplanten Task
    'WinDeploy-Resume' (läuft interaktiv als lokaler Admin -> winget-Kontext vorhanden, §5.7).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$libPath = Join-Path $PSScriptRoot 'lib\Deploy.Common.psm1'
Import-Module $libPath -Force

# Schritt-Funktionen laden
. (Join-Path $PSScriptRoot 'steps\Set-ComputerNameStep.ps1')
. (Join-Path $PSScriptRoot 'steps\Install-SoftwareStep.ps1')
. (Join-Path $PSScriptRoot 'steps\Join-DomainStep.ps1')
. (Join-Path $PSScriptRoot 'steps\Invoke-CleanupStep.ps1')

function Invoke-Step {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Body
    )
    if (Test-DeployStepDone -State $State -Step $Name) {
        Write-DeployLog "Schritt '$Name' bereits erledigt — überspringe." -Component orch
        return $State
    }
    Write-DeployLog "--- Schritt '$Name' startet ---" -Component orch
    & $Body $State
    Complete-DeployStep -State $State -Step $Name
    Write-DeployLog "--- Schritt '$Name' abgeschlossen ---" -Level OK -Component orch
    return $State
}

try {
    Initialize-DeployPaths
    Write-DeployLog "==================== Invoke-Deploy Start ====================" -Component orch
    $cfg   = Get-DeployConfig
    $state = Get-DeployState

    if ($state.failed) {
        Write-DeployLog "Frühere Ausführung als fehlgeschlagen markiert ($($state.failReason)). Kein automatischer Neuversuch." -Level ERROR -Component orch
        return
    }

    # Fortsetzung über Reboots sicherstellen (idempotent), läuft als lokaler Admin
    Register-DeployResumeTask -UserId $cfg.localAdmin.username

    # 1) Computername setzen -> Reboot, damit AD-Objekt mit finalem Namen entsteht (§5.9)
    if (-not (Test-DeployStepDone -State $state -Step 'rename')) {
        $state = Invoke-Step -State $state -Name 'rename' -Body { param($s) Set-ComputerNameStep -State $s -Config $cfg }
        Write-DeployLog "Neustart nach Umbenennung ..." -Component orch
        Start-Sleep -Seconds 3
        Restart-Computer -Force
        return
    }

    # 2) Software (MSI/Choco-Baseline + optional winget) — VOR dem Join (§5.7)
    if (-not (Test-DeployStepDone -State $state -Step 'software')) {
        $state = Invoke-Step -State $state -Name 'software' -Body { param($s) Install-SoftwareStep -State $s -Config $cfg }
        if ($script:DeployRebootRequested) {
            Write-DeployLog "Neustart nach Softwareinstallation angefordert ..." -Component orch
            Start-Sleep -Seconds 3
            Restart-Computer -Force
            return
        }
    }

    # 3) Domänenbeitritt (mit Readiness-Gate) -> Reboot
    if (-not (Test-DeployStepDone -State $state -Step 'join')) {
        $state = Invoke-Step -State $state -Name 'join' -Body { param($s) Join-DomainStep -State $s -Config $cfg }
        Write-DeployLog "Neustart nach Domänenbeitritt ..." -Component orch
        Start-Sleep -Seconds 3
        Restart-Computer -Force
        return
    }

    # 4) Cleanup (läuft IMMER als letztes — auch Credential-/Auto-Logon-Scrub)
    if (-not (Test-DeployStepDone -State $state -Step 'cleanup')) {
        $state = Invoke-Step -State $state -Name 'cleanup' -Body { param($s) Invoke-CleanupStep -State $s -Config $cfg }
    }

    Write-DeployLog "==================== WinDeploy ABGESCHLOSSEN ====================" -Level OK -Component orch
    try {
        $done = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'WinDeploy-OK.txt'
        Set-Content -LiteralPath $done -Value "WinDeploy erfolgreich abgeschlossen: $($state.computerName)`r`n$((Get-Date).ToString('u'))" -Encoding UTF8
    } catch { }
}
catch {
    $msg = $_.Exception.Message
    Write-DeployLog "Orchestrator abgebrochen: $msg" -Level ERROR -Component orch
    Write-DeployLog $_.ScriptStackTrace -Level ERROR -Component orch

    # Fehlerpfad-Scrub: ein abgebrochener Deploy darf NIE Credentials/Auto-Logon
    # zurücklassen (Review-Fund #14). Best-effort, wirft nie.
    $adminUser = $null
    try { if ($cfg -and $cfg.localAdmin) { $adminUser = $cfg.localAdmin.username } } catch { }
    try { Invoke-DeploySafeScrub -LocalAdminUser $adminUser } catch { }

    try {
        $state = Get-DeployState
        Set-DeployFailure -State $state -Reason $msg
    } catch { Write-DeployLog "Konnte Fehlerstatus nicht speichern: $($_.Exception.Message)" -Level ERROR -Component orch }
}
