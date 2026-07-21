#requires -Version 5.1
<#  Schritt 2: Software (§5.7 / §7).
    Baseline garantiert: MSI (offline, C:\Deploy\software) + Chocolatey.
    Optional: winget (readiness-gated, --scope machine).
    Ergebnis pro App wird strukturiert protokolliert.  #>

function Install-MsiPackage {
    param([Parameter(Mandatory)][string]$Path, [string]$Arguments = '/qn /norestart')
    if (-not (Test-Path -LiteralPath $Path)) { throw "MSI nicht gefunden: $Path" }
    $args = "/i `"$Path`" $Arguments"
    $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList $args -Wait -PassThru
    return $p.ExitCode
}

function Test-WingetReady {
    param([int]$TimeoutSec = 300)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
        if ($cmd) {
            try { & winget.exe --version | Out-Null; if ($LASTEXITCODE -eq 0) { return $true } } catch { }
        }
        # App Installer für alle Benutzer bereitstellen versuchen
        try {
            $wapath = Get-ChildItem "$env:ProgramFiles\WindowsApps" -Filter 'Microsoft.DesktopAppInstaller_*' -Directory -ErrorAction SilentlyContinue |
                      Sort-Object Name -Descending | Select-Object -First 1
            if ($wapath) { $env:Path = "$($wapath.FullName);$env:Path" }
        } catch { }
        Start-Sleep -Seconds 10
    }
    return $false
}

function Install-SoftwareStep {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Config)

    $script:DeployRebootRequested = $false
    $results = @()
    $sw = $Config.software

    if (-not $sw) { Write-DeployLog "Keine Software im Profil definiert." -Component sw; return }

    # --- MSI (offline-Baseline) ---
    if ($sw.msi) {
        foreach ($m in @($sw.msi)) {
            $name = $m.name
            try {
                $path = $m.path
                if ($path -notmatch '^[A-Za-z]:\\') { $path = Join-Path (Join-Path (Get-DeployRoot) 'software') $path }
                # Silent-Defaults IMMER behalten, Profil-Args nur ANHÄNGEN (Review-Fund #11)
                $argline = '/qn /norestart'
                if ($m.args) { $argline = $argline + ' ' + [string]$m.args }
                $code = Install-MsiPackage -Path $path -Arguments $argline
                if ($code -eq 0 -or $code -eq 1641 -or $code -eq 3010) {
                    if ($code -eq 3010 -or $code -eq 1641) { $script:DeployRebootRequested = $true }
                    Write-DeployLog "MSI OK: $name (Exit $code)" -Level OK -Component sw
                    $results += [pscustomobject]@{ engine='msi'; name=$name; ok=$true; code=$code }
                } else {
                    Write-DeployLog "MSI FEHLER: $name (Exit $code)" -Level ERROR -Component sw
                    $results += [pscustomobject]@{ engine='msi'; name=$name; ok=$false; code=$code }
                }
            } catch {
                Write-DeployLog "MSI FEHLER: $name — $($_.Exception.Message)" -Level ERROR -Component sw
                $results += [pscustomobject]@{ engine='msi'; name=$name; ok=$false; code=$null }
            }
        }
    }

    # --- Chocolatey (funktioniert auch skript-/offline-nah) ---
    if ($sw.choco) {
        if (-not (Get-Command choco.exe -ErrorAction SilentlyContinue)) {
            try {
                Write-DeployLog "Installiere Chocolatey ..." -Component sw
                Set-ExecutionPolicy Bypass -Scope Process -Force
                [System.Net.ServicePointManager]::SecurityProtocol = 3072
                Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
                $env:Path = "$env:ProgramData\chocolatey\bin;$env:Path"
            } catch {
                Write-DeployLog "Chocolatey-Bootstrap fehlgeschlagen: $($_.Exception.Message)" -Level WARN -Component sw
            }
        }
        foreach ($c in @($sw.choco)) {
            $id = $c.id; $name = $c.name
            try {
                # Args als echtes Argument-Array (Review-Fund #15): mehrteilige Werte
                # wie "--version 1.2.3" würden als ein Token sonst fehlschlagen.
                $cargs = @('install', $id, '-y', '--no-progress')
                if ($c.args) { $cargs += ([string]$c.args -split '\s+' | Where-Object { $_ -ne '' }) }
                & choco.exe @cargs 2>&1 | Out-Null
                $code = $LASTEXITCODE
                if ($code -eq 0 -or $code -eq 3010) {
                    if ($code -eq 3010) { $script:DeployRebootRequested = $true }
                    Write-DeployLog "choco OK: $name ($id, Exit $code)" -Level OK -Component sw
                    $results += [pscustomobject]@{ engine='choco'; name=$name; ok=$true; code=$code }
                } else {
                    Write-DeployLog "choco FEHLER: $name ($id, Exit $code)" -Level ERROR -Component sw
                    $results += [pscustomobject]@{ engine='choco'; name=$name; ok=$false; code=$code }
                }
            } catch {
                Write-DeployLog "choco FEHLER: $name — $($_.Exception.Message)" -Level ERROR -Component sw
                $results += [pscustomobject]@{ engine='choco'; name=$name; ok=$false; code=$null }
            }
        }
    }

    # --- winget (optional, readiness-gated) ---
    if ($sw.winget -and @($sw.winget).Count -gt 0) {
        if (Test-WingetReady -TimeoutSec 300) {
            foreach ($w in @($sw.winget)) {
                $id = $w.id; $name = $w.name
                try {
                    & winget.exe install --id $id --exact --silent --scope machine `
                        --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 | Out-Null
                    $code = $LASTEXITCODE
                    if ($code -eq 0) {
                        Write-DeployLog "winget OK: $name ($id)" -Level OK -Component sw
                        $results += [pscustomobject]@{ engine='winget'; name=$name; ok=$true; code=$code }
                    } else {
                        Write-DeployLog "winget PROBLEM: $name ($id, Exit $code) — übersprungen." -Level WARN -Component sw
                        $results += [pscustomobject]@{ engine='winget'; name=$name; ok=$false; code=$code }
                    }
                } catch {
                    Write-DeployLog "winget FEHLER: $name — $($_.Exception.Message)" -Level WARN -Component sw
                    $results += [pscustomobject]@{ engine='winget'; name=$name; ok=$false; code=$null }
                }
            }
        } else {
            Write-DeployLog "winget wurde nicht rechtzeitig verfügbar — winget-Pakete übersprungen (MSI/Choco-Baseline bleibt gültig)." -Level WARN -Component sw
        }
    }

    # Ergebnisse ablegen
    try {
        $summ = Join-Path (Get-DeployRoot) 'logs\software-results.json'
        $results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $summ -Encoding UTF8
    } catch { }

    $fail = @($results | Where-Object { -not $_.ok })
    Write-DeployLog ("Software fertig: {0} OK, {1} Fehler." -f (@($results).Count - $fail.Count), $fail.Count) -Component sw
}
