#requires -Version 5.1
<#
.SYNOPSIS
    WinDeploy-Generator: erzeugt aus einem Kundenprofil eine XML-sichere autounattend.xml,
    verschlüsselt das Join-Passwort und stellt den Deploy-Payload zusammen. Optional wird
    daraus ein bootfähiger USB-Stick gebaut (benötigt Windows ADK + WinPE-Add-on).

.EXAMPLE
    # Nur Payload/Antwortdatei erzeugen (kein USB) — schnell testbar:
    .\Build-DeploymentUSB.ps1 -ProfilePath .\profiles\kunde-example.json -PromptJoinPassword

.EXAMPLE
    # Kompletten USB bauen (ADK nötig):
    .\Build-DeploymentUSB.ps1 -ProfilePath .\profiles\kunde-example.json -PromptJoinPassword `
        -BuildMedia -UsbDisk 3 -InstallWim D:\sources\install.wim -WindowsMediaPath D:\

.NOTES
    Sicherheitskritischer USB-Wipe ist mit -WhatIf/-Confirm abgesichert und prüft BusType=USB.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$ProfilePath,
    [string]$OutputPath,
    [switch]$PromptJoinPassword,

    [switch]$BuildMedia,
    [int]$UsbDisk = -1,
    [string]$InstallWim,
    [string]$WindowsMediaPath,
    [string]$AdkXsd
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$GeneratorVersion = '1.0.0'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---------------------------------------------------------------------------
# Hilfsfunktionen
# ---------------------------------------------------------------------------
function Write-Info { param($m) Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "[ OK ] $m" -ForegroundColor Green }
function Write-Warn2{ param($m) Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Fail       { param($m) throw $m }

function ConvertTo-XmlSafe {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return '' }
    return [System.Security.SecurityElement]::Escape($Value)
}

function Expand-Template {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][hashtable]$Tokens)
    $out = $Text
    foreach ($k in $Tokens.Keys) {
        $out = $out.Replace(('{{' + $k + '}}'), (ConvertTo-XmlSafe ([string]$Tokens[$k])))
    }
    $left = [regex]::Matches($out, '\{\{([A-Za-z0-9_]+)\}\}')
    if ($left.Count -gt 0) {
        $names = ($left | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique) -join ', '
        Fail "Unaufgelöste Platzhalter in der Vorlage: $names"
    }
    return $out
}

function Protect-Secret {
    param([Parameter(Mandatory)][string]$Plain, [Parameter(Mandatory)][string]$KeyPath)
    $key = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($key)
    [System.IO.File]::WriteAllBytes($KeyPath, $key)
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.Key = $key; $aes.GenerateIV(); $aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'
        $enc = $aes.CreateEncryptor()
        $pt = [System.Text.Encoding]::UTF8.GetBytes($Plain)
        $ct = $enc.TransformFinalBlock($pt, 0, $pt.Length)
        $blob = $aes.IV + $ct
        return [Convert]::ToBase64String($blob)
    } finally { $aes.Dispose() }
}

function Test-ProfileSemantics {
    param([Parameter(Mandatory)]$P)
    $errs = @()

    foreach ($req in @('schemaVersion','profileName','profileVersion','windows','locale','naming','localAdmin','domainJoin')) {
        if (-not $P.PSObject.Properties[$req]) { $errs += "Pflichtfeld fehlt: $req" }
    }
    if ($errs.Count) { Fail ("Profil ungültig:`n - " + ($errs -join "`n - ")) }

    if ($P.schemaVersion -ne 1) { $errs += "schemaVersion muss 1 sein." }

    $prefix = [string]$P.naming.prefix
    if ($prefix -notmatch '^[A-Za-z0-9-]+$') { $errs += "naming.prefix enthält ungültige Zeichen." }
    if ($prefix.Length -gt 12) { $errs += "naming.prefix ist zu lang (max 12; NetBIOS-Budget = 15)." }
    if ($prefix.Length -ge 14) { $errs += "naming.prefix lässt keinen Platz für die Seriennummer." }
    if ($prefix.Length -gt 10) { Write-Warn2 "naming.prefix ist lang ($($prefix.Length)) — wenig Platz für eindeutigen Serienteil (15-Zeichen-Grenze)." }

    if ([string]$P.windows.productKey -notmatch '^[A-Z0-9]{5}(-[A-Z0-9]{5}){4}$') { $errs += "windows.productKey hat kein gültiges Format." }
    if ([int]$P.windows.imageIndex -lt 1) { $errs += "windows.imageIndex muss >= 1 sein." }
    if ([string]$P.locale.language -notmatch '^[a-z]{2}-[A-Z]{2}$') { $errs += "locale.language muss wie 'de-DE' aussehen." }
    if (([string]$P.localAdmin.username).Length -gt 20) { $errs += "localAdmin.username zu lang (max 20)." }
    if (-not $P.domainJoin.username) { $errs += "domainJoin.username fehlt (delegiertes Join-Konto)." }
    if ($P.domainJoin.username -match '(?i)administrator$') { Write-Warn2 "domainJoin.username sieht nach Admin-Konto aus — bitte delegiertes, minimal berechtigtes Konto verwenden!" }

    if ($errs.Count) { Fail ("Profil ungültig:`n - " + ($errs -join "`n - ")) }
    Write-Ok "Profil semantisch validiert."
}

function Get-ProfileProp {
    param($Obj, [string]$Name, $Default = $null)
    if ($Obj -and $Obj.PSObject.Properties[$Name]) { return $Obj.$Name }
    return $Default
}

# ---------------------------------------------------------------------------
# 1) Profil laden + validieren
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $ProfilePath)) { Fail "Profil nicht gefunden: $ProfilePath" }
$prof = Get-Content -LiteralPath $ProfilePath -Raw | ConvertFrom-Json
Write-Info "Profil: $($prof.profileName) v$($prof.profileVersion)"
Test-ProfileSemantics -P $prof

# ---------------------------------------------------------------------------
# 2) Ausgabeordner vorbereiten
# ---------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $safeName = ($prof.profileName -replace '[^A-Za-z0-9._-]', '_')
    $OutputPath = Join-Path $ScriptRoot ("out\" + $safeName)
}
$deployDir = Join-Path $OutputPath 'deploy'
$configDir = Join-Path $deployDir 'config'
$imagesDir = Join-Path $OutputPath 'images'
foreach ($d in @($OutputPath, $deployDir, $configDir, $imagesDir)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
Write-Info "Ausgabe: $OutputPath"

# ---------------------------------------------------------------------------
# 3) Join-Passwort ermitteln + verschlüsseln
# ---------------------------------------------------------------------------
$joinPwPlain = $null
if ($PromptJoinPassword) {
    $sec = Read-Host -AsSecureString "Passwort für Join-Konto '$($prof.domainJoin.username)'"
    $joinPwPlain = [System.Net.NetworkCredential]::new('', $sec).Password
} elseif (Get-ProfileProp $prof.domainJoin 'password') {
    $joinPwPlain = [string]$prof.domainJoin.password
    Write-Warn2 "Join-Passwort stammt aus dem Profil (Klartext auf Disk). Besser: -PromptJoinPassword."
} else {
    $sec = Read-Host -AsSecureString "Passwort für Join-Konto '$($prof.domainJoin.username)'"
    $joinPwPlain = [System.Net.NetworkCredential]::new('', $sec).Password
}
if ([string]::IsNullOrEmpty($joinPwPlain)) { Fail "Kein Join-Passwort angegeben." }

$keyPath = Join-Path $configDir 'secret.key'
$joinCipher = Protect-Secret -Plain $joinPwPlain -KeyPath $keyPath
$joinPwPlain = $null
Write-Ok "Join-Passwort verschlüsselt (AES). Hinweis: Schlüssel liegt neben der Chiffre — reale Sicherheit = physische Sicherung + Konto-Rotation (PLAN.md §5.4)."

# ---------------------------------------------------------------------------
# 4) autounattend.xml XML-sicher rendern (§5.2)
# ---------------------------------------------------------------------------
$templatePath = Join-Path $ScriptRoot 'templates\autounattend.template.xml'
$templateText = Get-Content -LiteralPath $templatePath -Raw

$tokens = @{
    Locale            = $prof.locale.language
    InputLocale       = $prof.locale.inputLocale
    TimeZone          = $prof.locale.timeZone
    ProductKey        = $prof.windows.productKey
    RegisteredOwner   = (Get-ProfileProp (Get-ProfileProp $prof 'registration') 'owner' $prof.profileName)
    RegisteredOrg     = (Get-ProfileProp (Get-ProfileProp $prof 'registration') 'organization' $prof.profileName)
    LocalAdminName    = $prof.localAdmin.username
    LocalAdminPassword= $prof.localAdmin.password
    AutoLogonCount    = '5'
}
$rendered = Expand-Template -Text $templateText -Tokens $tokens

# Wohlgeformtheit beweisen (§5.2)
try { [xml]$doc = $rendered } catch { Fail "Gerenderte autounattend.xml ist nicht wohlgeformt: $($_.Exception.Message)" }

# optional gegen ADK-Schema validieren
if ($AdkXsd) {
    if (Test-Path -LiteralPath $AdkXsd) {
        try {
            $settings = New-Object System.Xml.XmlReaderSettings
            $settings.ValidationType = [System.Xml.ValidationType]::Schema
            [void]$settings.Schemas.Add($null, $AdkXsd)
            $reader = [System.Xml.XmlReader]::Create((New-Object System.IO.StringReader($rendered)), $settings)
            while ($reader.Read()) { }
            $reader.Close()
            Write-Ok "autounattend.xml gegen ADK-Schema validiert."
        } catch { Write-Warn2 "ADK-Schema-Validierung meldet: $($_.Exception.Message)" }
    } else { Write-Warn2 "AdkXsd nicht gefunden: $AdkXsd" }
}

# Build-Metadaten als Kommentar einfügen
$stamp = (Get-Date).ToUniversalTime().ToString('u')
$metaComment = "<!-- WinDeploy generiert: profile=$($prof.profileName) v$($prof.profileVersion); generator=$GeneratorVersion; buildUtc=$stamp -->"
$rendered = $rendered -replace '(<unattend[^>]*>)', ("`$1`r`n  " + $metaComment)

$answerOut = Join-Path $OutputPath 'autounattend.xml'
Set-Content -LiteralPath $answerOut -Value $rendered -Encoding UTF8
Set-Content -LiteralPath (Join-Path $deployDir 'autounattend.xml') -Value $rendered -Encoding UTF8
Write-Ok "autounattend.xml erzeugt."

# ---------------------------------------------------------------------------
# 5) Laufzeit-Konfig (deploy.config.json)
# ---------------------------------------------------------------------------
$runtime = [ordered]@{
    schemaVersion    = 1
    profileName      = $prof.profileName
    profileVersion   = $prof.profileVersion
    generatorVersion = $GeneratorVersion
    buildUtc         = $stamp
    windows          = @{ edition = $prof.windows.edition }
    image            = @{ index = [int]$prof.windows.imageIndex }
    disk             = @{
        minSizeGB          = [int](Get-ProfileProp (Get-ProfileProp $prof 'disk') 'minSizeGB' 60)
        allowMultipleDisks = [bool](Get-ProfileProp (Get-ProfileProp $prof 'disk') 'allowMultipleDisks' $false)
    }
    naming           = @{ prefix = $prof.naming.prefix }
    localAdmin       = @{
        username          = $prof.localAdmin.username
        randomizePassword = [bool](Get-ProfileProp $prof.localAdmin 'randomizePassword' $true)
    }
    domainJoin       = @{
        domain         = $prof.domainJoin.domain
        ouPath         = (Get-ProfileProp $prof.domainJoin 'ouPath' $null)
        username       = $prof.domainJoin.username
        passwordCipher = $joinCipher
    }
    software         = (Get-ProfileProp $prof 'software' @{})
    reporting        = (Get-ProfileProp $prof 'reporting' @{})
}
$runtime | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $configDir 'deploy.config.json') -Encoding UTF8
Write-Ok "deploy.config.json erzeugt."

# ---------------------------------------------------------------------------
# 6) Payload zusammenstellen (Skripte, lib, steps, software)
# ---------------------------------------------------------------------------
$srcPayload = Join-Path $ScriptRoot 'payload'
foreach ($item in @('Deploy-WinPE.ps1','Invoke-Deploy.ps1','lib','steps')) {
    Copy-Item -Path (Join-Path $srcPayload $item) -Destination $deployDir -Recurse -Force
}
# Software-Dateien (MSI-Baseline) mitnehmen, Beispiel-Liste weglassen
$swSrc = Join-Path $srcPayload 'software'
$swDst = Join-Path $deployDir 'software'
if (-not (Test-Path $swDst)) { New-Item -ItemType Directory -Path $swDst -Force | Out-Null }
Get-ChildItem -LiteralPath $swSrc -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne 'packages.example.json' } |
    ForEach-Object { Copy-Item $_.FullName -Destination $swDst -Force }
Write-Ok "Payload zusammengestellt."

# ---------------------------------------------------------------------------
# 7) install.wim ablegen (falls angegeben)
# ---------------------------------------------------------------------------
if ($InstallWim) {
    if (-not (Test-Path -LiteralPath $InstallWim)) { Fail "InstallWim nicht gefunden: $InstallWim" }
    Copy-Item -LiteralPath $InstallWim -Destination (Join-Path $imagesDir (Split-Path $InstallWim -Leaf)) -Force
    Write-Ok "Windows-Abbild nach images\ kopiert."
} else {
    Write-Warn2 "Kein -InstallWim angegeben. Lege install.wim/.esd manuell unter '$imagesDir' ab (bzw. auf die NTFS-Payload-Partition \images\)."
}

# ---------------------------------------------------------------------------
# 8) Manifest
# ---------------------------------------------------------------------------
$manifest = [ordered]@{
    profileName      = $prof.profileName
    profileVersion   = $prof.profileVersion
    generatorVersion = $GeneratorVersion
    buildUtc         = $stamp
    windows          = $prof.windows.edition
    imageIndex       = [int]$prof.windows.imageIndex
    domain           = $prof.domainJoin.domain
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputPath 'manifest.json') -Encoding UTF8

Write-Ok "Fertig. Ausgabe unter: $OutputPath"
Write-Host ""
Write-Host "  ACHTUNG: '$configDir' enthält secret.key + verschlüsseltes Join-Passwort." -ForegroundColor Yellow
Write-Host "           Ordner/USB physisch sichern; Join-Konto regelmäßig rotieren." -ForegroundColor Yellow
Write-Host ""

# ---------------------------------------------------------------------------
# 9) Optional: bootfähigen USB bauen  (benötigt ADK + WinPE-Add-on)
# ---------------------------------------------------------------------------
if ($BuildMedia) {
    . (Join-Path $ScriptRoot 'lib\Build-UsbMedia.ps1')
    Invoke-BuildUsbMedia -OutputPath $OutputPath -UsbDisk $UsbDisk -WindowsMediaPath $WindowsMediaPath -PSCmdlet $PSCmdlet
}
