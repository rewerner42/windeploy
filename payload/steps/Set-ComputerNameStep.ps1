#requires -Version 5.1
<#  Schritt 1: Computername aus BIOS-Seriennummer bilden und setzen (§5.9).  #>

function Set-ComputerNameStep {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Config)

    $prefix = 'PC'
    if ($Config.naming -and $Config.naming.prefix) { $prefix = [string]$Config.naming.prefix }

    # BIOS-Seriennummer (häufig Platzhalter -> Fallback in ConvertTo-SafeComputerName)
    $serial = $null
    try { $serial = (Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop).SerialNumber } catch { }
    Write-DeployLog "BIOS-Seriennummer: '$serial'" -Component name

    # Fallback-Suffix aus erster physischer MAC ableiten
    $fallback = $null
    try {
        $mac = (Get-NetAdapter -Physical -ErrorAction Stop |
                Where-Object { $_.MacAddress } |
                Sort-Object InterfaceIndex | Select-Object -First 1).MacAddress
        if ($mac) { $fallback = ($mac -replace '[^0-9A-Fa-f]', '') }
    } catch { }
    if ([string]::IsNullOrWhiteSpace($fallback)) { $fallback = (New-DeployRandomSuffix -Length 6) }

    $name = ConvertTo-SafeComputerName -Serial $serial -Prefix $prefix -FallbackSuffix $fallback
    Write-DeployLog "Neuer Computername: $name" -Level OK -Component name

    if ($env:COMPUTERNAME -eq $name) {
        Write-DeployLog "Computername ist bereits '$name' - nichts zu tun." -Component name
    } else {
        Rename-Computer -NewName $name -Force -ErrorAction Stop
    }
    $State.computerName = $name
    Set-DeployState -State $State
}
