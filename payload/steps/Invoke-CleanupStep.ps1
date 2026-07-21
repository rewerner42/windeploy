#requires -Version 5.1
<#  Schritt 4: Cleanup (§5.8) — läuft IMMER als letztes.
    - Auto-Logon + Klartext-Credentials aus der Registry entfernen
    - Antwortdatei-Reste (Panther) scrubben
    - lokales Admin-Passwort randomisieren (LAPS-Ersatz, §5.8)
    - Fortsetzungs-Task entfernen
    - Zusammenfassung erzeugen, optional auf Share pushen
    - Payload (inkl. Secrets) löschen  #>

function Invoke-CleanupStep {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Config)

    $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

    # 1) Auto-Logon / Klartext-Credentials entfernen
    foreach ($n in @('AutoAdminLogon','DefaultPassword','DefaultUserName','DefaultDomainName','AutoLogonCount')) {
        try { Remove-ItemProperty -Path $winlogon -Name $n -ErrorAction SilentlyContinue } catch { }
    }
    Set-ItemProperty -Path $winlogon -Name 'AutoAdminLogon' -Value '0' -ErrorAction SilentlyContinue

    # Verifikation
    $rest = @()
    foreach ($n in @('DefaultPassword','AutoLogonCount')) {
        if (Get-ItemProperty -Path $winlogon -Name $n -ErrorAction SilentlyContinue) { $rest += $n }
    }
    if ($rest.Count -gt 0) { Write-DeployLog "WARN: Auto-Logon-Reste noch vorhanden: $($rest -join ', ')" -Level WARN -Component cleanup }
    else { Write-DeployLog "Auto-Logon/Credentials aus Registry entfernt." -Level OK -Component cleanup }

    # 2) Antwortdatei-Reste scrubben
    $scrub = @(
        'C:\Windows\Panther\unattend.xml',
        'C:\Windows\Panther\Unattend\unattend.xml',
        'C:\Windows\System32\Sysprep\unattend.xml',
        'C:\unattend.xml','C:\autounattend.xml'
    )
    foreach ($f in $scrub) {
        if (Test-Path -LiteralPath $f) { try { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } catch { } }
    }
    Write-DeployLog "Antwortdatei-Reste bereinigt." -Component cleanup

    # 3) Lokales Admin-Passwort randomisieren (statt flottenweitem Einheitspasswort, §5.8)
    $randomize = $true
    if ($Config.localAdmin -and $Config.localAdmin.PSObject.Properties['randomizePassword']) {
        $randomize = [bool]$Config.localAdmin.randomizePassword
    }
    if ($randomize -and $Config.localAdmin -and $Config.localAdmin.username) {
        try {
            Add-Type -AssemblyName System.Web
            $newPw = [System.Web.Security.Membership]::GeneratePassword(20, 5)
            $sec = ConvertTo-SecureString $newPw -AsPlainText -Force
            Set-LocalUser -Name $Config.localAdmin.username -Password $sec -ErrorAction Stop
            $newPw = $null
            Write-DeployLog "Lokales Admin-Passwort randomisiert (Hinweis: Windows LAPS ist die empfohlene Dauerlösung)." -Level OK -Component cleanup
        } catch {
            Write-DeployLog "Konnte Admin-Passwort nicht randomisieren: $($_.Exception.Message)" -Level WARN -Component cleanup
        }
    }

    # 4) Zusammenfassung
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

    # optional: Summary auf Share pushen (best effort)
    if ($Config.reporting -and $Config.reporting.sharePath) {
        try {
            $dest = Join-Path $Config.reporting.sharePath ("{0}.json" -f $State.computerName)
            $summary | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $dest -Encoding UTF8
            Write-DeployLog "Zusammenfassung auf Share abgelegt: $dest" -Component cleanup
        } catch { Write-DeployLog "Share-Report übersprungen: $($_.Exception.Message)" -Level WARN -Component cleanup }
    }

    # 5) Fortsetzungs-Task entfernen
    Unregister-DeployResumeTask

    # 6) Payload inkl. Secrets löschen (Schlüsseldatei + Konfig mit Chiffre!)
    try {
        $root = Get-DeployRoot
        # Erst die Secrets gezielt schreddern
        foreach ($sf in @((Join-Path $root 'config\secret.key'), (Join-Path $root 'config\deploy.config.json'))) {
            if (Test-Path -LiteralPath $sf) { Remove-Item -LiteralPath $sf -Force -ErrorAction SilentlyContinue }
        }
        Write-DeployLog "Secrets entfernt. Payload wird nach dem finalen Logoff aufgeräumt." -Level OK -Component cleanup
        # Selbstlöschung des restlichen C:\Deploy verzögert (dieser Prozess läuft noch daraus)
        $self = "cmd.exe"
        $delArgs = "/c timeout /t 20 >nul & rmdir /s /q `"$root`""
        Start-Process -FilePath $self -ArgumentList $delArgs -WindowStyle Hidden
    } catch { Write-DeployLog "Payload-Cleanup unvollständig: $($_.Exception.Message)" -Level WARN -Component cleanup }
}
