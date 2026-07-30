#requires -Version 5.1
<#  Schritt 4: Cleanup (§5.8) - läuft IMMER als letztes.
    WICHTIG (Review-Fund #12/#14): Secrets werden ZUERST und unabänderlich entfernt
    (Invoke-DeploySafeScrub), bevor irgendein Schritt fehlschlagen könnte. Erst danach
    folgen die best-effort-Aufräumarbeiten (Antwortdatei-Reste, Reporting, Task, Payload).  #>

function Invoke-CleanupStep {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Config)

    $adminUser = $null
    if ($Config.localAdmin -and $Config.localAdmin.username) { $adminUser = [string]$Config.localAdmin.username }
    $randomize = $true
    if ($Config.localAdmin -and $Config.localAdmin.PSObject.Properties['randomizePassword']) {
        $randomize = [bool]$Config.localAdmin.randomizePassword
    }

    # 1) ZUERST: Auto-Logon + Klartext-Credentials + Secrets entfernen, Admin-PW randomisieren.
    #    (Unabänderlich, kann durch spätere Fehler nicht mehr übersprungen werden.)
    $scrubUser = $null
    if ($randomize) { $scrubUser = $adminUser }
    Invoke-DeploySafeScrub -LocalAdminUser $scrubUser
    if ($randomize) { Write-DeployLog "Lokales Admin-Passwort randomisiert (Hinweis: Windows LAPS = empfohlene Dauerlösung)." -Level OK -Component cleanup }

    # Verifikation
    $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $rest = @()
    foreach ($n in @('DefaultPassword','AutoLogonCount')) {
        if (Get-ItemProperty -Path $winlogon -Name $n -ErrorAction SilentlyContinue) { $rest += $n }
    }
    if ($rest.Count -gt 0) { Write-DeployLog "WARN: Auto-Logon-Reste noch vorhanden: $($rest -join ', ')" -Level WARN -Component cleanup }
    else { Write-DeployLog "Auto-Logon/Credentials/Secrets entfernt." -Level OK -Component cleanup }

    # 2) Antwortdatei-Reste scrubben
    $scrub = @(
        'C:\Windows\Panther\unattend.xml',
        'C:\Windows\Panther\Unattend\unattend.xml',
        'C:\Windows\System32\Sysprep\unattend.xml',
        'C:\unattend.xml','C:\autounattend.xml','C:\Deploy\autounattend.xml'
    )
    foreach ($f in $scrub) {
        if (Test-Path -LiteralPath $f) { try { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } catch { } }
    }
    Write-DeployLog "Antwortdatei-Reste bereinigt." -Component cleanup

    # 3) Zusammenfassung
    $summary = [pscustomobject]@{
        computerName = $State.computerName
        domain       = $(if ($Config.domainJoin) { $Config.domainJoin.domain } else { $null })
        profile      = "$($Config.profileName) v$($Config.profileVersion)"
        generator    = $Config.generatorVersion
        finishedUtc  = (Get-Date).ToUniversalTime().ToString('o')
        serial       = $(try { (Get-CimInstance Win32_BIOS).SerialNumber } catch { $null })
    }
    try {
        $archive = 'C:\Windows\Temp\WinDeploy'
        New-Item -ItemType Directory -Path $archive -Force | Out-Null
        $summary | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $archive 'summary.json') -Encoding UTF8
        Copy-Item -Path (Join-Path (Get-DeployRoot) 'logs\*') -Destination $archive -Recurse -Force -ErrorAction SilentlyContinue
    } catch { }

    if ($Config.reporting -and $Config.reporting.sharePath) {
        try {
            $dest = Join-Path $Config.reporting.sharePath ("{0}.json" -f $State.computerName)
            $summary | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $dest -Encoding UTF8
            Write-DeployLog "Zusammenfassung auf Share abgelegt: $dest" -Component cleanup
        } catch { Write-DeployLog "Share-Report übersprungen: $($_.Exception.Message)" -Level WARN -Component cleanup }
    }

    # 4) Fortsetzungs-Task entfernen (best-effort - darf Cleanup NICHT abbrechen)
    try { Unregister-DeployResumeTask } catch { Write-DeployLog "Task-Entfernung: $($_.Exception.Message)" -Level WARN -Component cleanup }

    # 5) Rest-Payload verzögert löschen (dieser Prozess läuft noch daraus)
    try {
        $root = Get-DeployRoot
        Write-DeployLog "Payload wird nach dem finalen Logoff aufgeräumt." -Level OK -Component cleanup
        $delArgs = "/c timeout /t 20 >nul & rmdir /s /q `"$root`""
        Start-Process -FilePath 'cmd.exe' -ArgumentList $delArgs -WindowStyle Hidden
    } catch { Write-DeployLog "Payload-Cleanup unvollständig: $($_.Exception.Message)" -Level WARN -Component cleanup }
}
