#requires -Version 5.1
<#
    Deploy.Common.psm1 — gemeinsame Hilfsfunktionen für WinDeploy
    Läuft in zwei Kontexten:
      1. WinPE (Windows PowerShell 5.1, via WinPE-PowerShell-Komponente)  -> Deploy-WinPE.ps1
      2. Erstes Admin-Logon des installierten Windows                      -> Invoke-Deploy.ps1
    Daher strikt 5.1-kompatibel (keine PS7-Syntax wie ?: oder ??).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Pfade
# ---------------------------------------------------------------------------
$script:DeployRoot = 'C:\Deploy'
$script:LogDir     = "$script:DeployRoot\logs"
$script:StateFile  = "$script:DeployRoot\state.json"
$script:ConfigFile = "$script:DeployRoot\config\deploy.config.json"

function Get-DeployRoot { return $script:DeployRoot }

function Initialize-DeployPaths {
    foreach ($d in @($script:DeployRoot, $script:LogDir, (Split-Path $script:ConfigFile))) {
        if (-not (Test-Path -LiteralPath $d)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }
    }
}

# ---------------------------------------------------------------------------
# Logging  (Datei + Konsole + best-effort Windows-Eventlog)
# ---------------------------------------------------------------------------
function Write-DeployLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK')][string]$Level = 'INFO',
        [string]$Component = 'deploy'
    )
    $ts   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = '{0} [{1,-5}] [{2}] {3}' -f $ts, $Level, $Component, $Message

    try {
        Initialize-DeployPaths
        $logFile = Join-Path $script:LogDir ('deploy-{0}.log' -f (Get-Date).ToString('yyyyMMdd'))
        Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
    } catch { }

    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'OK'    { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line }
    }

    try {
        $src = 'WinDeploy'
        if (-not [System.Diagnostics.EventLog]::SourceExists($src)) {
            New-EventLog -LogName Application -Source $src -ErrorAction SilentlyContinue
        }
        $entryType = 'Information'
        if ($Level -eq 'WARN')  { $entryType = 'Warning' }
        if ($Level -eq 'ERROR') { $entryType = 'Error' }
        Write-EventLog -LogName Application -Source $src -EntryType $entryType -EventId 9001 -Message $line -ErrorAction SilentlyContinue
    } catch { }
}

# ---------------------------------------------------------------------------
# Konfiguration (vom Generator erzeugt: deploy.config.json)
# ---------------------------------------------------------------------------
function Get-DeployConfig {
    if (-not (Test-Path -LiteralPath $script:ConfigFile)) {
        throw "Konfiguration nicht gefunden: $script:ConfigFile"
    }
    return (Get-Content -LiteralPath $script:ConfigFile -Raw | ConvertFrom-Json)
}

# ---------------------------------------------------------------------------
# State-Machine  (übersteht Reboots)
# ---------------------------------------------------------------------------
function Get-DeployState {
    if (Test-Path -LiteralPath $script:StateFile) {
        try {
            $s = Get-Content -LiteralPath $script:StateFile -Raw | ConvertFrom-Json
            # completed als Array normalisieren (JSON deserialisiert Einzelwerte nicht als Array)
            if (-not $s.PSObject.Properties['completed'] -or $null -eq $s.completed) {
                $s | Add-Member -NotePropertyName completed -NotePropertyValue @() -Force
            } else {
                $s.completed = @($s.completed)
            }
            return $s
        } catch {
            Write-DeployLog "State-Datei defekt, starte neu: $($_.Exception.Message)" -Level WARN
        }
    }
    return [pscustomobject]@{
        schemaVersion = 1
        completed     = @()
        computerName  = $null
        failed        = $false
        failReason    = $null
        startedUtc    = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Set-DeployState {
    param([Parameter(Mandatory)]$State)
    Initialize-DeployPaths
    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:StateFile -Encoding UTF8
}

function Test-DeployStepDone {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Step)
    return (@($State.completed) -contains $Step)
}

function Complete-DeployStep {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Step)
    if (-not (Test-DeployStepDone -State $State -Step $Step)) {
        $State.completed = @($State.completed) + $Step
    }
    Set-DeployState -State $State
}

function Set-DeployFailure {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Reason)
    $State.failed     = $true
    $State.failReason = $Reason
    Set-DeployState -State $State
    Write-DeployLog "DEPLOY FAILED: $Reason" -Level ERROR

    # Sichtbarer Fehlermarker: rotes Desktop-Hintergrundbild + Textdatei
    try {
        $marker = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'DEPLOY-FAILED.txt'
        Set-Content -LiteralPath $marker -Value "WinDeploy fehlgeschlagen:`r`n$Reason`r`nDetails: $script:LogDir" -Encoding UTF8
    } catch { }
    try {
        Set-ItemProperty -Path 'HKCU:\Control Panel\Colors' -Name Background -Value '150 20 20' -ErrorAction SilentlyContinue
    } catch { }
}

# ---------------------------------------------------------------------------
# Computername aus Seriennummer bilden  (NetBIOS-sicher, §5.9)
# Reine Funktion -> per Pester getestet.
# ---------------------------------------------------------------------------
function ConvertTo-SafeComputerName {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Serial,
        [Parameter(Mandatory)][string]$Prefix,
        [string]$FallbackSuffix
    )
    $maxLen = 15
    $placeholders = @(
        'TO BE FILLED BY O.E.M.','DEFAULT STRING','SYSTEM SERIAL NUMBER',
        'NOT APPLICABLE','NOT SPECIFIED','NONE','INVALID','O.E.M.','OEM',
        'CHASSIS SERIAL NUMBER','BASE BOARD SERIAL NUMBER','SERIAL NUMBER'
    )

    # Präfix säubern (nur A-Z0-9 und -)
    $p = ($Prefix.ToUpperInvariant() -replace '[^A-Z0-9-]', '')
    if ([string]::IsNullOrWhiteSpace($p)) { $p = 'PC' }

    $raw = ''
    if ($null -ne $Serial) { $raw = $Serial.Trim().ToUpperInvariant() }

    $isPlaceholder =
        [string]::IsNullOrWhiteSpace($raw) -or
        ($placeholders -contains $raw) -or
        ($raw -match '^0+$') -or
        ($raw -match '^F+$')

    $s = ''
    if (-not $isPlaceholder) {
        $s = ($raw -replace '[^A-Z0-9]', '')
        if ([string]::IsNullOrWhiteSpace($s) -or $s.Length -lt 3) { $isPlaceholder = $true }
    }

    if ($isPlaceholder) {
        if ([string]::IsNullOrWhiteSpace($FallbackSuffix)) {
            throw "Seriennummer '$Serial' ist Platzhalter/ungültig und es wurde kein -FallbackSuffix angegeben."
        }
        $s = ($FallbackSuffix.ToUpperInvariant() -replace '[^A-Z0-9]', '')
        if ([string]::IsNullOrWhiteSpace($s)) { throw "FallbackSuffix '$FallbackSuffix' ergibt keinen gültigen Wert." }
    }

    # Budget für den Serien-/Suffix-Teil
    if ($p.Length -ge $maxLen) { $p = $p.Substring(0, $maxLen - 1) }
    $budget = $maxLen - $p.Length
    if ($s.Length -gt $budget) {
        # eindeutigsten Teil (Ende) behalten
        $s = $s.Substring($s.Length - $budget, $budget)
    }

    $name = ($p + $s).Trim('-')
    if ([string]::IsNullOrWhiteSpace($name)) { throw "Konnte keinen gültigen Computernamen bilden." }
    if ($name -match '^[0-9]+$') { $name = 'P' + $name }          # nicht rein numerisch
    if ($name.Length -gt $maxLen) { $name = $name.Substring(0, $maxLen) }
    $name = $name.Trim('-')
    if ([string]::IsNullOrWhiteSpace($name)) { throw "Computername nach Bereinigung leer." }
    return $name
}

function New-DeployRandomSuffix {
    param([int]$Length = 6)
    $chars = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ'   # ohne 0/O/1/I zur Verwechslungsvermeidung
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $Length; $i++) {
        [void]$sb.Append($chars[(Get-Random -Minimum 0 -Maximum $chars.Length)])
    }
    return $sb.ToString()
}

# ---------------------------------------------------------------------------
# Fail-safe Ziel-Datenträger-Auswahl  (§5.1 — die wichtigste Sicherheitsfunktion)
# Läuft in WinPE.  Bricht bewusst ab, statt den falschen Datenträger zu löschen.
# ---------------------------------------------------------------------------
function Get-TargetInternalDisk {
    [CmdletBinding()]
    param(
        [switch]$AllowMultiple,     # per-Profil-Opt-in: bei mehreren internen Platten die größte wählen
        [int]$MinSizeGB = 32
    )
    $excludedBus = @('USB','SD','MMC','1394','Fibre Channel','iSCSI','Virtual')  # Virtual nur in echtem WinPE relevant
    $all = @(Get-Disk | Sort-Object Number)

    Write-DeployLog ("Gefundene Datenträger: {0}" -f $all.Count) -Component disk
    foreach ($d in $all) {
        Write-DeployLog ("  Disk {0}: Bus={1} Size={2}GB Model='{3}' Boot={4} System={5}" -f `
            $d.Number, $d.BusType, [math]::Round($d.Size/1GB,0), $d.FriendlyName, $d.IsBoot, $d.IsSystem) -Component disk
    }

    $candidates = @($all | Where-Object {
        ($excludedBus -notcontains [string]$_.BusType) -and
        ($_.Size -ge ($MinSizeGB * 1GB)) -and
        (-not $_.IsBoot)      # das gebootete WinPE-Medium ausschließen
    })

    if ($candidates.Count -eq 0) {
        throw "Kein interner Ziel-Datenträger gefunden (>= $MinSizeGB GB, Bus != USB). ABBRUCH — es wird nichts gelöscht."
    }
    if ($candidates.Count -gt 1) {
        $list = ($candidates | ForEach-Object { "Disk $($_.Number) ($($_.BusType), $([math]::Round($_.Size/1GB,0))GB, '$($_.FriendlyName)')" }) -join '; '
        if (-not $AllowMultiple) {
            throw "Mehrere interne Datenträger gefunden [$list]. ABBRUCH zur Sicherheit — es wird nichts gelöscht. (Profil-Flag allowMultipleDisks setzen, um die größte zu wählen.)"
        }
        Write-DeployLog "WARNUNG: mehrere interne Datenträger [$list] — allowMultipleDisks aktiv, wähle die größte." -Level WARN -Component disk
        return ($candidates | Sort-Object Size -Descending | Select-Object -First 1)
    }
    $target = $candidates[0]
    Write-DeployLog ("Ziel-Datenträger: Disk {0} ({1}, {2}GB, '{3}')" -f $target.Number, $target.BusType, [math]::Round($target.Size/1GB,0), $target.FriendlyName) -Level OK -Component disk
    return $target
}

# ---------------------------------------------------------------------------
# Fortsetzungs-Task über Reboots hinweg
# ---------------------------------------------------------------------------
function Register-DeployResumeTask {
    param(
        [string]$ScriptPath = (Join-Path $script:DeployRoot 'Invoke-Deploy.ps1'),
        [string]$UserId            # lokaler Admin -> interaktiver Kontext für winget (§5.7)
    )
    $taskName = 'WinDeploy-Resume'
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { return }
    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    if (-not [string]::IsNullOrWhiteSpace($UserId)) {
        $principal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType Interactive -RunLevel Highest
        $who = $UserId
    } else {
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $who = 'SYSTEM'
    }
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
    Write-DeployLog "Fortsetzungs-Task '$taskName' registriert (User=$who)." -Component task
}

function Unregister-DeployResumeTask {
    $taskName = 'WinDeploy-Resume'
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-DeployLog "Fortsetzungs-Task '$taskName' entfernt." -Component task
    }
}

# ---------------------------------------------------------------------------
# Secret-Handling  (AES + Schlüsseldatei = Obfuskation, KEIN echter Schutz)
# Der reale Schutz ist: minimal berechtigtes Join-Konto, physische Sicherung
# des USB, Rotation.  Siehe PLAN.md §5.4.
# ---------------------------------------------------------------------------
function Unprotect-DeploySecret {
    param(
        [Parameter(Mandatory)][string]$CipherBase64,
        [Parameter(Mandatory)][string]$KeyPath
    )
    $key = [System.IO.File]::ReadAllBytes($KeyPath)          # 32 Byte
    $blob = [Convert]::FromBase64String($CipherBase64)
    $iv  = $blob[0..15]
    $ct  = $blob[16..($blob.Length-1)]
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.Key = $key; $aes.IV = $iv; $aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'
        $dec = $aes.CreateDecryptor()
        $plain = $dec.TransformFinalBlock($ct, 0, $ct.Length)
        return [System.Text.Encoding]::UTF8.GetString($plain)
    } finally { $aes.Dispose() }
}

Export-ModuleMember -Function `
    Get-DeployRoot, Initialize-DeployPaths, Write-DeployLog, Get-DeployConfig, `
    Get-DeployState, Set-DeployState, Test-DeployStepDone, Complete-DeployStep, Set-DeployFailure, `
    ConvertTo-SafeComputerName, New-DeployRandomSuffix, Get-TargetInternalDisk, `
    Register-DeployResumeTask, Unregister-DeployResumeTask, Unprotect-DeploySecret
