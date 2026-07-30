# WinDeploy

**Serverlose, unbeaufsichtigte Windows-Installation für IT-Support.**
USB rein → booten → weggehen. WinDeploy installiert Windows 11 (25H2 Pro) vollautomatisch,
spielt Standard-Software auf, tritt der Domäne bei und benennt den PC – gesteuert über
wiederverwendbare **Kundenprofile**. Ein USB-Stick wird **einmal** gebaut und für **viele** PCs
desselben Kunden genutzt. Kein Server (WDS/PXE/Intune) nötig.

> ⚠️ **Status:** Der Code ist statisch geprüft und getestet (Syntax, Namenslogik, XML-Sicherheit,
> AES-Roundtrip, Generator end-to-end). Der Windows-**Laufzeitpfad** (WinPE-Apply, Domänenbeitritt,
> Reboot-Kette) muss vor dem Produktiveinsatz **in einer VM** durchgespielt werden – siehe
> [Testen](#testen). Hintergrund & Design-Entscheidungen: **[PLAN.md](PLAN.md)**.

> 🚀 **Schnellster VM-Test (ein Befehl):** `.\tools\Start-WinDeployTest.ps1` — geführter Assistent:
> prüft/installiert Abhängigkeiten, lädt bei Bedarf das Win11-ISO, fragt alle Eingaben ab, legt auf
> Wunsch das Join-Konto in AD an, baut die bootfähige Test-ISO und zeigt die Proxmox-Schritte.

---

## Inhalt

1. [Wie es funktioniert](#wie-es-funktioniert)
2. [Voraussetzungen](#voraussetzungen)
3. [Active Directory vorbereiten](#active-directory-vorbereiten)
4. [Konfigurieren – das Profil](#konfigurieren--das-profil)
5. [Benutzen – USB bauen & deployen](#benutzen--usb-bauen--deployen)
6. [Sicherheit](#sicherheit)
7. [Fehlersuche](#fehlersuche)
8. [Testen](#testen)
9. [Projektaufbau](#projektaufbau)

---

## Wie es funktioniert

```
┌─ USB einmal bauen (Techniker-PC) ──────────────────────────────┐
│ Profil (JSON)  ──►  Build-DeploymentUSB.ps1  ──►  bootfähiger USB │
│                     • autounattend.xml (XML-sicher gerendert)     │
│                     • Join-Passwort AES-verschlüsselt             │
│                     • Payload-Skripte + install.wim               │
└──────────────────────────────────────────────────────────────────┘
                                │
┌─ Am Ziel-PC (UEFI-Boot vom USB) ───────────────────────────────┐
│ WinPE:  Bypass-Reg → FAIL-SAFE Disk-Auswahl → GPT-Partitionen    │
│         → DISM-Apply → Reboot                                     │
│ 1. Logon (Orchestrator, übersteht Reboots):                      │
│    ① Umbenennen (Name aus Seriennummer) → Reboot                 │
│    ② Software (MSI/Choco-Baseline + winget optional)             │
│    ③ Domänenbeitritt (Netz/DNS/Zeit-Check) → Reboot              │
│    ④ Cleanup: Auto-Logon + Credentials entfernen, Admin-PW neu   │
└──────────────────────────────────────────────────────────────────┘
```

> **Robuster WinPE-Start:** `Deploy-WinPE.ps1` wird über einen in die `boot.wim` injizierten
> Startlauncher (`winpeshl.ini`) **direkt** gestartet – nicht über `setup.exe`. Grund: Die
> Setup-Engine von Windows 11 24H2/25H2 ignoriert `windowsPE`-Antwortdatei-Trigger auf Stock-Medien.
> Ein Idempotenz-Marker verhindert, dass ein erneuter USB-Boot die frisch installierte Platte löscht.

---

## Voraussetzungen

**Techniker-PC (baut den USB):**
- Windows 10/11 mit Windows PowerShell 5.1 (integriert).
- **Windows ADK** + **Windows PE Add-on** – nur für den USB-Bau (`-BuildMedia`).
  [ADK-Download](https://learn.microsoft.com/windows-hardware/get-started/adk-install)
- Windows-11-25H2-ISO (gemountet oder entpackt; enthält `sources\boot.wim` und `sources\install.wim`).
  Kein ISO? Automatisch laden: `.\tools\Get-Win11Iso.ps1` (holt das offizielle ISO direkt von
  Microsoft, arch-erkennend x64/arm64, via [Fido](https://github.com/pbatard/Fido)).
- USB-Stick ≥ 16 GB.

**Abhängigkeiten prüfen/installieren:** `.\tools\Preflight.ps1 -Install -IsoPath <Win11.iso>` prüft
alles (Architektur, ADK, WinPE-Add-on, oscdimg, ISO-Editionen) und installiert Fehlendes per winget.

**Umgebung:**
- On-Prem Active Directory mit erreichbarem DC am Einsatzort (DHCP + AD-DNS).
- Ein **delegiertes Join-Konto** (kein Domänen-Admin) – siehe nächster Abschnitt.

---

## Active Directory vorbereiten

Einmalig pro Domäne (Best Practice, siehe [PLAN.md §6](PLAN.md)):

1. **Dediziertes Join-Konto** anlegen, z. B. `svc-domainjoin`. Interaktive/Remote-Anmeldung verweigern.
2. **Ziel-OU** anlegen, z. B. `OU=Arbeitsplaetze,…`.
3. Dem Konto auf **dieser OU** nur delegieren: *Computerobjekte erstellen* (+ *Kennwort zurücksetzen* /
   *DNS-Hostname schreiben*, falls vorhandene Objekte wiederverwendet werden).
4. Domänenweit `ms-DS-MachineAccountQuota = 0` setzen (verhindert stillen Fallback auf Nutzerkonten).
5. Optional **Windows LAPS** einführen (empfohlene Dauerlösung für das lokale Admin-Passwort).

---

## Konfigurieren – das Profil

Ein Profil ist eine JSON-Datei unter `profiles/`. Kopiere
[`profiles/kunde-example.json`](profiles/kunde-example.json) und passe sie an. Validiert wird gegen
[`profiles/profile.schema.json`](profiles/profile.schema.json).

| Feld | Bedeutung | Beispiel |
|---|---|---|
| `profileName`, `profileVersion` | Name/Version (landen in Manifest & Logs) | `"Muster GmbH - Standard"`, `"1.0.0"` |
| `windows.edition` | Nur Doku | `"Windows 11 Pro"` |
| `windows.imageIndex` | Index in `install.wim` (Pro = oft 6; mit `dism /Get-WimInfo /WimFile:install.wim` prüfen) | `6` |
| `windows.productKey` | Generischer Editions-Key (kein Aktivierungskey nötig) | `"VK7JG-NPHTM-C97JM-9MPGT-3V66T"` |
| `locale.language` | System-/Anzeigesprache | `"de-DE"` |
| `locale.inputLocale` | Tastaturlayout | `"0407:00000407"` (DE) |
| `locale.timeZone` | Zeitzone | `"W. Europe Standard Time"` |
| `naming.prefix` | Namenspräfix (max 12; NetBIOS-Grenze = 15 gesamt) | `"MUS-"` |
| `localAdmin.username` | Lokaler Admin (Erstanmeldung) | `"itadmin"` |
| `localAdmin.password` | Erst-Passwort (wird nach Setup randomisiert) | `"ChangeMe!23"` |
| `localAdmin.randomizePassword` | Admin-PW am Ende neu setzen | `true` |
| `domainJoin.domain` | AD-Domäne (FQDN) | `"corp.muster-gmbh.de"` |
| `domainJoin.ouPath` | Ziel-OU (Distinguished Name) | `"OU=Arbeitsplaetze,DC=corp,DC=muster-gmbh,DC=de"` |
| `domainJoin.username` | **Delegiertes** Join-Konto | `"corp\\svc-domainjoin"` |
| `disk.minSizeGB` | Mindestgröße interner Zielplatte | `60` |
| `disk.allowMultipleDisks` | Bei mehreren internen Platten die größte wählen (sonst Abbruch) | `false` |
| `software.msi[]` | Offline-MSI: `{name,path,args}` – Datei unter `payload/software/` ablegen | `{"name":"7-Zip","path":"7z.msi"}` |
| `software.choco[]` | Chocolatey-Pakete: `{name,id}` | `{"name":"Chrome","id":"googlechrome"}` |
| `software.winget[]` | winget (optional, online): `{name,id}` | `{"name":"PowerToys","id":"Microsoft.PowerToys"}` |
| `reporting.sharePath` | UNC-Pfad für Abschluss-Report (optional) | `"\\\\srv\\deploy$"` |

> Das **Join-Passwort** gehört **nicht** ins Profil – es wird beim Bauen sicher abgefragt
> (`-PromptJoinPassword`). Ein `domainJoin.password` im Profil ist nur für Tests und wird gewarnt.

---

## Benutzen – USB bauen & deployen

### 1. Payload/Antwortdatei erzeugen (schnell, ohne ADK – zum Prüfen)

```powershell
.\Build-DeploymentUSB.ps1 -ProfilePath .\profiles\meinkunde.json -PromptJoinPassword
```
Ergebnis unter `.\out\<Profilname>\`: `autounattend.xml`, `deploy\` (Skripte + verschlüsselte Config).

### 2. Bootfähigen USB bauen (mit ADK)

Ziel-Disk-Nummer zuerst ermitteln:
```powershell
Get-Disk        # Nummer des USB-Sticks merken (BusType = USB)
```
Dann bauen (der Wipe fragt nach Bestätigung und prüft, dass es wirklich ein USB ist):
```powershell
.\Build-DeploymentUSB.ps1 -ProfilePath .\profiles\meinkunde.json -PromptJoinPassword `
    -BuildMedia -UsbDisk 3 -WindowsMediaPath D:\ -InstallWim D:\sources\install.wim
```

### 3. Am Ziel-PC deployen

1. USB einstecken, im UEFI-Bootmenü vom Stick booten.
2. Warten – **kein Klick nötig**. Es folgen 2–3 automatische Neustarts.
3. **Fertig**, wenn auf dem Desktop `WinDeploy-OK.txt` liegt und der PC in der Domäne ist.

---

## Sicherheit

- Der USB trägt ein **eingebettetes, delegiertes Join-Konto** (AES-obfuskiert). Das ist **kein**
  kryptographischer Schutz – realer Schutz = minimal berechtigtes Konto + **physische Sicherung des
  USB** + **Passwort-Rotation**. ([PLAN.md §5.4/§10](PLAN.md))
- Das Domänen-Passwort steht **nicht** in der `autounattend.xml`.
- Lokales Admin-Passwort wird nach dem Beitritt randomisiert (LAPS empfohlen).
- `.gitignore` hält Secrets (`*.key`), Abbilder (`*.wim`) und den `out/`-Ordner aus dem Repo.

---

## Fehlersuche

| Symptom | Ursache / Blick |
|---|---|
| `DEPLOY-FAILED.txt` + rotes Hintergrundbild | Ein Schritt schlug fehl – Logs in `C:\Windows\Temp\WinDeploy\` |
| Abbruch in WinPE („kein Datenträger" / „mehrere Datenträger") | Fail-safe Schutz (§5.1): 0 oder >1 interne Platten. Zweite Platte entfernen oder `allowMultipleDisks` setzen |
| winget-Pakete fehlen, Rest ok | winget war im Setup-Kontext nicht bereit – MSI/Choco-Baseline greift trotzdem |
| Domänenbeitritt schlägt fehl | Netz/DNS/Zeit am Standort prüfen (AD-DNS via DHCP? Uhr korrekt?) |
| Laufende Logs live | `Get-Content C:\Deploy\logs\deploy-*.log -Wait` |

---

## Testen

```powershell
# Namenslogik (Pester)
Invoke-Pester .\tests\ConvertTo-SafeComputerName.Tests.ps1
```
**Vor dem ersten Kundeneinsatz:** kompletten Ablauf in einer **Hyper-V-Gen2-VM** durchspielen
(WinPE-Apply, Partitionierung, Beitritt, Reboots). Siehe [PLAN.md §9, Phase 0](PLAN.md).

---

## Projektaufbau

```
Build-DeploymentUSB.ps1              Generator (Einstiegspunkt)
templates/autounattend.template.xml  Antwortdatei-Vorlage (Platzhalter XML-sicher ersetzt)
profiles/  profile.schema.json       Profil-Schema
           kunde-example.json        Beispielprofil
lib/Build-UsbMedia.ps1               USB-Bau (ADK, sicherheitsgeprüft)
payload/                             wird nach C:\Deploy auf dem Ziel kopiert
  Deploy-WinPE.ps1                   WinPE: Disk-Auswahl + Partition + DISM-Apply
  Invoke-Deploy.ps1                  Orchestrator (reboot-feste State-Machine)
  lib/Deploy.Common.psm1             Logging, State, Namensbildung, Disk, Secrets
  steps/                             Rename / Software / DomainJoin / Cleanup
  software/                          MSI-Baseline hier ablegen
tests/                               Pester-Tests
PLAN.md                              Geprüfter Gesamtplan (mit §-Referenzen)
```

---

*Erstellt mit [Claude Code](https://claude.com/claude-code). Beiträge/Feedback willkommen.*
