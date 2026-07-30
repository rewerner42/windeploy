#requires -Version 5.1
<#  Schritt 3: Domänenbeitritt mit Readiness-Gate (§5.5 / §5.10).
    - Netzwerk/DHCP abwarten
    - Zeit gegen DC synchronisieren (Kerberos-Skew)
    - DNS-SRV der Domäne prüfen
    - Add-Computer mit Retry (läuft in Windows PowerShell 5.1)  #>

function Wait-DeployNetwork {
    param([int]$TimeoutSec = 300)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $cfg = Get-NetIPConfiguration -ErrorAction SilentlyContinue |
               Where-Object { $_.IPv4Address -and $_.IPv4DefaultGateway }
        if ($cfg) {
            Write-DeployLog "Netzwerk bereit (GW $($cfg[0].IPv4DefaultGateway.NextHop))." -Level OK -Component join
            return $true
        }
        Start-Sleep -Seconds 5
    }
    return $false
}

function Test-DomainDnsReady {
    param([Parameter(Mandatory)][string]$Domain, [int]$TimeoutSec = 120)
    $srv = "_ldap._tcp.dc._msdcs.$Domain"
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $rec = Resolve-DnsName -Name $srv -Type SRV -ErrorAction Stop
            if ($rec) { Write-DeployLog "DNS-SRV der Domäne auflösbar ($srv)." -Level OK -Component join; return $true }
        } catch { }
        Start-Sleep -Seconds 5
    }
    return $false
}

function Join-DomainStep {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Config)

    $dj = $Config.domainJoin
    if (-not $dj -or -not $dj.domain) { throw "Kein domainJoin.domain im Profil konfiguriert." }
    $domain = [string]$dj.domain
    $ou     = $null
    if ($dj.ouPath) { $ou = [string]$dj.ouPath }

    # Bereits Mitglied?
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    if ($cs.PartOfDomain -and $cs.Domain -eq $domain) {
        Write-DeployLog "Bereits Mitglied von '$domain' - überspringe Beitritt." -Level OK -Component join
        return
    }

    if (-not (Wait-DeployNetwork -TimeoutSec 300)) { throw "Kein Netzwerk/Gateway innerhalb des Timeouts - Beitritt nicht möglich." }

    # Zeit synchronisieren (Kerberos toleriert max. 5 min Skew)
    try { & w32tm /resync /force 2>&1 | Out-Null } catch { }
    try { Start-Service w32time -ErrorAction SilentlyContinue; & w32tm /resync 2>&1 | Out-Null } catch { }

    if (-not (Test-DomainDnsReady -Domain $domain -TimeoutSec 120)) {
        Write-DeployLog "DNS-SRV für '$domain' nicht auflösbar (evtl. Nicht-AD-DNS via DHCP). Versuche Beitritt trotzdem." -Level WARN -Component join
    }

    # Anmeldedaten (eingebettet, AES-obfuskiert - realer Schutz = physische Sicherung, §5.4)
    $keyPath = Join-Path (Get-DeployRoot) 'config\secret.key'
    $pwPlain = Unprotect-DeploySecret -CipherBase64 $dj.passwordCipher -KeyPath $keyPath
    $secure  = ConvertTo-SecureString $pwPlain -AsPlainText -Force
    $cred    = New-Object System.Management.Automation.PSCredential($dj.username, $secure)
    $pwPlain = $null

    $maxTry = 3
    for ($i = 1; $i -le $maxTry; $i++) {
        try {
            Write-DeployLog "Domänenbeitritt Versuch $i/$maxTry -> '$domain'$(if($ou){" OU '$ou'"})" -Component join
            if ($ou) {
                Add-Computer -DomainName $domain -OUPath $ou -Credential $cred -Force -ErrorAction Stop
            } else {
                Add-Computer -DomainName $domain -Credential $cred -Force -ErrorAction Stop
            }
            Write-DeployLog "Domänenbeitritt erfolgreich." -Level OK -Component join
            return
        } catch {
            Write-DeployLog "Beitritt Versuch $i fehlgeschlagen: $($_.Exception.Message)" -Level WARN -Component join
            if ($i -eq $maxTry) { throw "Domänenbeitritt nach $maxTry Versuchen fehlgeschlagen: $($_.Exception.Message)" }
            Start-Sleep -Seconds 20
        }
    }
}
