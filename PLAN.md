# WinDeploy — Automatisierte Windows-Installation für IT-Support

**Status:** Geprüfter Plan (5 Fach-Agenten + Synthese, Abgleich gegen aktuelle Microsoft-Doku, Juli 2026)
**Verdikt:** Architektur freigegeben — Umsetzung erst nach Einbau der „Must-Fix"-Punkte auf echter Hardware.

---

## 1. Ziel

Ein Techniker steckt einen vorbereiteten USB-Stick in einen PC, bootet davon und geht weg.
Ergebnis ohne weiteres Eingreifen: Datenträger partitioniert, Windows installiert, Standard-Software
installiert, in die Domäne eingebunden, sinnvoll benannt. Pro PC **kein Klick**.

Ein USB-Stick wird **einmal** aus einem Kundenprofil gebaut und dann für **viele** PCs desselben Kunden
wiederverwendet.

---

## 2. Gewählter Ansatz (bestätigt)

**Serverloser USB-Stick: `autounattend.xml` (Windows Setup) + PowerShell-Post-Install, erzeugt aus
wiederverwendbaren JSON-Profilen durch einen PowerShell-Generator.**

Die Absage an die Alternativen wurde bestätigt — und ist sogar stärker als ursprünglich formuliert:

| Alternative | Warum nicht |
|---|---|
| **MDT** | **Offiziell eingestellt (Retired seit 06.01.2026)** — nicht nur „eingefroren". Braucht WDS/PXE-Server. |
| **SCCM / ConfigMgr** | Braucht SQL + Site-Infrastruktur. Overkill für einen kleinen Betrieb. |
| **Windows Autopilot** | Autopilot v2 kann **kein** Hybrid-AD-Join; braucht Entra/Intune + Internet + On-Prem-ODJ-Connector. Passt nicht zu reinem On-Prem-AD. |
| **Golden Image / FFU** | Sinnvoll — aber als **Zusatzmodus** (siehe §8), nicht als Ersatz. |

---

## 3. Architektur / Komponenten

1. **Profil (JSON, pro Kunde)** — Domäne, Ziel-OU, Zeitzone, Sprache/Locale, Software-Liste, Namensschema/Präfix,
   Bypass-Flags. Mit `schemaVersion` und Build-Metadaten.
2. **`autounattend.xml`-Template** — mit Platzhaltern; wird **XML-sicher** befüllt (kein reines Text-Ersetzen!).
3. **Post-Install-Orchestrator (PowerShell)** — zustandsgesteuert, übersteht Reboots; führt Naming, Software,
   Join, Cleanup aus.
4. **Generator `Build-DeploymentUSB.ps1`** — liest Profil, validiert es, rendert `autounattend.xml`, baut den
   USB-Stick (Partitionen + Payload), schreibt ein `manifest.json`.
5. **Secrets-Handling** — dediziertes, minimal berechtigtes Join-Konto; klare Regeln zu Klartext-Credentials.

---

## 4. Ablauf am Ziel-PC (korrigiert — mit reboot-fester State-Machine)

Der reale Ablauf braucht **2–3 Neustarts** (Umbenennen, Join, Installationen). Ein einzelner linearer
`FirstLogonCommands`-Durchlauf verliert alles nach dem Join-Reboot. Deshalb: **ein Orchestrator + Statusdatei**.

```
Boot vom USB
  └─ windowsPE:
       1. Bypass-Registry (LabConfig) setzen  ← VOR der Kompatibilitätsprüfung
       2. Ziel-Datenträger fail-safe wählen (siehe §5.1) → GPT/UEFI-Partitionen → Wipe
       3. Windows-Abbild anwenden
  └─ specialize:
       4. Payload+Skripte nach C:\Deploy kopieren (überlebt USB-Abzug)
       5. Locale/Zeitzone; Orchestrator als RunOnce/Task registrieren
  └─ oobeSystem:
       6. Lokalen Admin anlegen (→ OOBE erreicht Online-Konto-Seite nie) + OOBE-Seiten ausblenden
       7. Auto-Logon (LogonCount minimal)
  └─ Orchestrator (interaktiv als Admin, State: C:\Deploy\state.json):
       Schritt A  Rename-Computer (Name aus §5.6) → Reboot
       Schritt B  Software installieren (MSI/Choco Baseline + winget optional) → ggf. Reboot
       Schritt C  Readiness-Gate (Netz/DNS/Zeit) → Domänenbeitritt → Reboot
       Schritt D  Cleanup: Auto-Logon + alle Credentials + Answer-File-Reste löschen (läuft IMMER)
       Fertig → sichtbare Erfolgs-/Fehlermeldung + Log auf Share
```

**Reihenfolge wichtig:** *erst* Software, *dann* Join+Reboot (sonst killt der Join-Reboot die Rest-Installation).

---

## 5. Die kritischen Fallstricke (Must-Fix vor echtem Einsatz)

### 5.1 🔴 KRITISCH — Fail-safe Datenträger-Auswahl (höchste Priorität)
Ein festkodiertes `<DiskID>0</DiskID>` + `WillWipeDisk=true` ist bei USB-Boot **gefährlich**: Die
Enumerierungs-Reihenfolge ändert sich auf NVMe-/Multi-Disk-Maschinen — Disk 0 ist nicht zuverlässig die
interne Ziel-Platte. Ein zweiter interner Datenträger (Daten/Backup) kann **still und unwiderruflich** gelöscht werden.

**Fix:** Kein festes `DiskID`. Stattdessen in windowsPE per `RunSynchronous` (diskpart/PowerShell):
- Filter `BusType != USB` **und** `MediaType = fixed`, Boot-USB explizit ausschließen.
- Genau **eine** interne Platte wählen (nach Modell / größter fixer Disk).
- Gewählte Disk (Nummer + Modell) **loggen, bevor** gelöscht wird.
- **Abbruch ohne Wipe**, wenn 0 oder >1 Kandidaten passen (Weiterlaufen bei 2. Platte nur per Profil-Opt-in).
- `WillShowUI=OnError` auf `DiskConfiguration`/`ImageInstall`.

### 5.2 🔴 KRITISCH — `autounattend.xml` XML-sicher erzeugen (kein String-Replace)
Passwörter/OU/Namen mit `& < > " '` erzeugen bei reinem Token-Ersetzen eine **kaputte** Answer-File
(Setup bricht mitten in der Installation ab) oder erlauben Injection.

**Fix:** Template als `System.Xml.XmlDocument` laden, Knoten per namespace-fähigem XPath
(`urn:schemas-microsoft-com:unattend`) setzen (`node.InnerText`, automatisch escaped). Mindestens jeden Wert
durch `[System.Security.SecurityElement]::Escape()` schicken und das Ergebnis vor dem Schreiben neu parsen
(Wohlgeformtheit beweisen).

### 5.3 🔴 KRITISCH — USB-Medium für `install.wim` > 4 GB
Ein reiner FAT32-Stick (nötig für UEFI-Boot) kann eine 24H2-`install.wim` (> 4 GB) **nicht** aufnehmen —
der Build scheitert still oder bootet nicht.

**Fix:** Dual-Partition-Layout (kleine FAT32-EFI-/Boot-Partition + NTFS-Payload, so wie Rufus intern) **oder**
`DISM /Split-Image` in `.swm` **oder** `install.esd`. `autounattend.xml` ins Wurzelverzeichnis der von Setup
gescannten Partition. Bau mit dem Storage-Modul (`Clear-Disk`/`New-Partition`/`Format-Volume`) + `robocopy`.
USB **immer** über `DiskNumber` + `BusType=USB` + `IsRemovable` identifizieren — **nie** über einen bloßen
Laufwerksbuchstaben (`-Usb E:`).

### 5.4 🔴 KRITISCH — Credential-Modell korrigieren (DPAPI schützt die Medien-Secrets NICHT)
Die Annahme „DPAPI → kein Klartext im Image" ist **falsch**: DPAPI-Blobs sind an User/Maschine gebunden und
auf dem Ziel-PC nicht entschlüsselbar. Setup braucht also den Klartext → landet in `autounattend.xml`
(AutoLogon nur Base64; `UnattendedJoin`-Passwort **gar nicht** verschleiert).

**Fix:**
- DPAPI **nur** für den Profil-Speicher am Techniker-PC nutzen.
- Reusable Domänen-Credentials von den Medien nehmen → entweder **djoin-ODJ-Blobs** (§5.5) **oder** Credentials
  **zur Deploy-Zeit** in einen flüchtigen `SecureString` abfragen.
- Jeder USB mit eingebetteten Credentials ist ein **lebendes Geheimnis**: verschlossen lagern, Join-Konto
  rotieren.

### 5.5 🟠 HOCH — Domänenbeitritt: EINE Methode, djoin-Konflikt auflösen
Der Plan beschreibt zwei sich widersprechende Wege (`UnattendedJoin` in specialize **und** `Add-Computer`
im Post-Install). `UnattendedJoin` in specialize ist fragil (Netzwerk oft noch nicht oben).

**Fix:** Für das serverlose Modell **`Add-Computer`** im Post-Install (mit Netz-Wait + Retry) wählen.
- Wichtig: `Add-Computer` gibt es **nur in Windows PowerShell 5.1** → explizit `powershell.exe` aufrufen (oder
  `netdom`/`djoin`/CIM `JoinDomainOrWorkGroup`), damit ein pwsh-Runner den Join nicht still bricht.
- Credential-freier Weg via `djoin.exe /provision`: dessen Blobs sind **pro Computer, einmalig, namensgebunden**
  → passen **nicht** zu „ein wiederverwendbarer USB + Name aus Seriennummer". Realistische Auflösung:
  Blobs vorab per bekannter Seriennummer auf einer Domänen-Station batchweise erzeugen, **oder** einen kleinen
  Provisioning-Helfer zur Deploy-Zeit gegen AD laufen lassen. (Bewusste Abwägung nötig, siehe §9.)

### 5.6 🟠 HOCH — Windows-11-24H2/25H2-Bypässe korrekt umsetzen
„Per Answer-File umgehen" hat **keinen** Mechanismus; OOBE-Flags allein deaktivieren die Kompatibilitätsprüfung nicht.

- **Hardware (TPM/SecureBoot/RAM/CPU/Storage):** windowsPE `RunSynchronous` `reg add`
  `HKLM\SYSTEM\Setup\LabConfig` mit DWORDs `BypassTPMCheck`/`BypassSecureBootCheck`/`BypassRAMCheck`/
  `BypassStorageCheck`/`BypassCPUCheck = 1`, **vor** der Disk-Config einsortiert. **Pro Profil opt-in**
  (Hinweis: umgangene Hardware ist offiziell nicht unterstützt und ggf. von Feature-Updates ausgeschlossen).
- **MS-Konto:** **nicht** auf `bypassnro.cmd` (entfernt ~Build 26200.5516, März 2025) oder `ms-cxh:localonly`
  (in 25H2 Build 26220.6772 gepatcht) verlassen. Stattdessen echten `LocalAccount` in `Administrators` (oobeSystem)
  + vollständiger `OOBE`-Hide-Block (`HideOnlineAccountScreens`, `HideEULAPage`, `HideWirelessSetupInOOBE`,
  `ProtectYourPC=3`) → OOBE erreicht die Online-Konto-Seite nie. `specialize`-`BypassNRO`-Reg-Add nur als Fallback.

### 5.7 🟠 HOCH — winget deterministisch machen (hinter Readiness-Gate)
App-Installer registriert sich beim ersten Logon **asynchron** → `FirstLogonCommands` feuern oft, **bevor**
winget funktioniert → Software-Schritt läuft still ins Leere.

**Fix:**
- `DesktopAppInstaller` + `VCLibs` + `UI.Xaml` per `Add-AppxProvisionedPackage` vorab bereitstellen (auf USB)
  und/oder `Repair-WinGetPackageManager -AllUsers`.
- Import erst nach `winget --version`-Retry-Schleife; `winget.exe` über den WindowsApps-Pfad auflösen.
- **Flag-Bugs:** `--silent` ist bei `winget import` **ungültig** (gehört zu `install`); korrekt ist
  `--accept-source-agreements` (kein `--source-agreement`).
- `--scope machine` erzwingen (oder MSI/Choco), damit Apps das Löschen des Wegwerf-Admin-Profils überleben.
- winget **nur** im interaktiven Admin-Logon, **nie** SYSTEM/`SetupComplete`/specialize.
- **Silent MSI + Chocolatey = garantierte Baseline** (Choco ist die einzige Engine, die aus der SYSTEM-/Skript-
  Phase und offline funktioniert). `winget import` = opportunistisch für Community-Apps.

### 5.8 🟠 HOCH — Auto-Logon-Teardown vollständig + kein flottenweiter Einheits-Admin
Das AutoLogon-Passwort steht **im Klartext** in `Winlogon\DefaultPassword` und bleibt nach `AutoAdminLogon=0`
liegen; Answer-File-Secrets sind nur Base64 und liegen zusätzlich unter `C:\Windows\Panther`.

**Fix:** Verifiziertes Final-Cleanup: `AutoAdminLogon`/`DefaultPassword`/`DefaultUserName`/`DefaultDomainName`
löschen; `LogonCount` = N-1 (bekannter +1-Effekt); `C:\Windows\Panther\unattend.xml`, `\Panther\Unattend\`,
`C:\unattend.xml` und die Deploy-Skripte/Logs scrubben; **vor** dem letzten Reboot bestätigen, dass keine
Credential-Strings mehr da sind. Zusätzlich: **kein** identisches lokales Admin-Passwort auf jeder Maschine —
pro PC randomisieren oder direkt nach Join **Windows LAPS** übernehmen lassen.

### 5.9 🟠 HOCH — Computername härten
`Win32_BIOS.SerialNumber` ist oft Platzhalter („To Be Filled By O.E.M.", „Default string", Nullen/FFs) oder
enthält Leerzeichen/ungültige Zeichen; Präfix+Serial kann die **15-Zeichen-NetBIOS-Grenze** sprengen,
Trunkierung kann kollidieren → die versprochene Eindeutigkeit ist nicht garantiert.

**Fix:** Sanitisieren (Großschreibung; `\ / : * ? " < > | .` und Leerzeichen entfernen; führenden/schließenden
Bindestrich und rein-numerisch ablehnen); Platzhalter-Serials erkennen → MAC-/Zufalls-Suffix; 15-Zeichen-Budget
schon bei der Profil-Validierung erzwingen; Best-Effort-AD-Kollisionscheck. Reihenfolge
`Rename-Computer` → Reboot → `Add-Computer`, damit das AD-Objekt gleich mit dem finalen Namen entsteht.
Unit-Tests über pathologische/VM-GUID-Serials.

### 5.10 🟡 MITTEL — Readiness-Gate vor Join + Verifikation danach
Generisches „Netz-Wait" reicht nicht. Vor dem Join: aktive NIC + DHCP-Lease abwarten; Zeit synchronisieren
(`w32tm /resync` gegen DC — Kerberos lehnt Skew > 5 min ab, häufig bei leerer CMOS/frischen Boards); prüfen,
dass DNS die Domänen-SRV-Records auflöst (`_ldap._tcp.dc._msdcs.<domain>`) über einen AD-fähigen Resolver
(ein per DHCP zugewiesener Public-Resolver bricht den Join still). Alt-/Stale-Computerobjekte behandeln
(`Get-ADComputer`-Vorabcheck oder `djoin /reuse`). Abschluss mit `Test-ComputerSecureChannel` + OU-Bestätigung.

### 5.11 🟡 MITTEL — Build-Zeit-Validierung
Fehler tauchen sonst erst am Ziel mitten in der Installation auf (langsamste Rückmeldung). Generierte
`autounattend.xml` gegen die ADK-`unattend.xsd` validieren (+ `processorArchitecture=amd64`, Datei im
USB-Root, `AcceptEula=true`, Edition-`ProductKey`/`ImageInstall`-Index gegen die `install.wim` der Ziel-ISO).
JSON-Profil mit `Test-Json`-Schema prüfen (Pflichtfelder, OU-DN wohlgeformt, gültige Locale/Zeitzone, Präfix
im 15-Zeichen-Budget).

---

## 6. Weitere bestätigte Detail-Empfehlungen

- **Partitionen fix im Template:** ESP FAT32 ≥ 260 MB, MSR 16 MB, NTFS-Windows, Recovery ≥ 1 GB **direkt nach**
  Windows mit korrekter Type-ID (`DE94BBA4-06D1-4D40-A16A-BFD50179D6AC`) und `PLATFORM_REQUIRED`-Attribut
  (24H2-WinRE ist größer — zu kleine Recovery-Partition bricht WinRE-Servicing).
- **Locale-Komponenten:** `Microsoft-Windows-International-Core-WinPE` in windowsPE **und**
  `Microsoft-Windows-International-Core` in specialize/oobeSystem (sonst falsches Tastatur-/System-Locale).
- **Treiber:** Standard = In-Box + Windows Update. **Keine** universelle Treiber-Injektion für gemischte
  Hardware. Kleine modell-basierte Treiber-Bibliothek (`Win32_ComputerSystemProduct`) nur für
  (a) WinPE-Storage-Controller (Intel VMD/RST — der eigentliche „No disk found"-Blocker, in `boot.wim` injizieren)
  und (b) Modelle, wo Windows Update kritische Treiber verpasst. Runbook-Notiz: SATA auf AHCI, wo VMD nicht gepflegt.
- **Kein GUI** — Config-Datei + CLI. `schemaVersion` je Profil; Profilname+Version, Generator-Version und
  Build-Zeitstempel als XML-Kommentar in der Answer-File, in `manifest.json` auf dem USB **und** in jeder Log-Zeile
  → jede Maschine ist auf ihren exakten Build zurückführbar. `-WhatIf`/Dry-Run + Hyper-V-Gen2-VM-Smoketest
  (ISO via `oscdimg`).
- **Fleet-Betrieb:** BitLocker-Policy (24H2 kann Geräteverschlüsselung in OOBE auto-aktivieren und den
  Recovery-Key mit lokalem/AD-Konto ggf. **nirgends** hinterlegen → vor Join unterdrücken oder Keys nach AD
  eskalieren); Aktivierungs-Check (OEM/OA3 vs. KMS/MAK); `summary.json` best-effort auf einen Share für Inventar.
- **Join-Konto härten:** dediziertes Join-only-Servicekonto (nie Domain Admin), nur „Create Computer Objects"
  auf der Ziel-OU delegiert (+ Reset Password / DNS-Hostname / SPN für Objekt-Reuse), interaktiver/Remote-Logon
  verweigert, **`ms-DS-MachineAccountQuota = 0`** domänenweit (sonst stiller Fallback auf user-eigene
  Maschinenkonten — bekannter Eskalationspfad).

---

## 7. Software-Modell (2-Engine)

1. **Baseline (garantiert):** Silent-MSI + Chocolatey. Funktioniert offline und aus der Skript-/SYSTEM-Phase.
2. **Optional:** `winget import` (readiness-gated, `--scope machine`) für Community-Apps.
3. **USB-lokaler Paket-Cache** mit Online-Fallback → First-Boot-Installs hängen nicht am Netz vor dem Join.
4. Jede Installation in einem **idempotenten Runner** mit Exit-Code-Auswertung (MSI 0/1641/**3010**=Erfolg,
   3010=Reboot nötig), Retry mit Backoff, Prereqs (Runtimes/Treiber) zuerst, **eine strukturierte Pass/Fail-Zeile
   pro App** + `Start-Transcript`.

---

## 8. Sekundärmodus: Golden Image / FFU (empfohlen ergänzen)

Für Chargen **identischer** Maschinen (Schwelle ~5–10 Stück): einmal ein gepatchtes, vor-appliziertes Image
(custom `install.wim` oder **FFU**) erstellen und per DISM/FFU anwenden — I/O-gebundene **Minuten** statt pro PC
volles OOBE + winget + Windows Update. Braucht weiterhin keinen Server. `autounattend` bleibt der flexible
Primärpfad für gemischte/Einzel-Hardware. Beides teilt sich denselben USB.

---

## 9. Umsetzung in Phasen

- **Phase 0 — Test-Rig:** Hyper-V-Gen2-VM + `oscdimg`-ISO-Build, damit jede Iteration in Minuten testbar ist.
- **Phase 1 — MVP (sicher):** Generator + XML-sicheres Template (§5.2) + **fail-safe Disk-Auswahl (§5.1)** +
  Dual-Partition-USB (§5.3) + lokaler Admin + MSI/Choco-Baseline. Join zunächst manuell testen.
- **Phase 2 — Zero-Touch-Kern:** Orchestrator-State-Machine (§4) + Naming (§5.9) + Readiness-Gate + `Add-Computer`
  (§5.5/§5.10) + vollständiges Credential-Cleanup (§5.8) + Logging.
- **Phase 3 — Härtung & Skalierung:** winget-Readiness (§5.7), Build-Zeit-Validierung (§5.11), Treiber-Bibliothek,
  Multi-Kunden-Profile, LAPS/BitLocker/Aktivierung, optional Golden-Image-Modus (§8).

---

## 10. Offene Entscheidungen / Restrisiken

- **Credentials auf Medien:** Ohne vollständigen Umstieg auf **djoin-ODJ-Blobs** trägt die Answer-File auf dem USB
  wiederherstellbare lokale-Admin- (ggf. Join-)Credentials — unabhängig von jeder Build-Zeit-Verschlüsselung.
  Kein Rotations-/Revocation-Konzept bisher. **→ Entscheidung nötig:** eingebettete Creds + verschlossene Lagerung
  + Rotation, *oder* Deploy-Zeit-Abfrage, *oder* djoin-Blobs.
- **djoin vs. wiederverwendbarer USB:** „Null Vorbereitung + ein reusable USB + Name aus Seriennummer + keine Creds
  auf Medien" sind **nicht gleichzeitig** erfüllbar. Eine dieser Eigenschaften muss bewusst geopfert werden.
- **Bypass-Haltbarkeit:** Microsoft verschärft die TPM/SecureBoot/OOBE-Tricks laufend zwischen Builds.
  LabConfig-Keys + Answer-File-Local-Account sind aktuell korrekt, können aber regressen → Erkennung/Fallback einbauen.
- **Naming-Kollisionen** bei VM-/Duplicate-Serials + 15-Zeichen-Trunkierung bleiben ein Restrisiko im großen Maßstab.
- **Feld-Netzwerke:** Nicht-AD-DHCP-Resolver, gesperrte/metered Netze oder falsche RTC verursachen weiterhin
  Fehler, die die Gates nur mildern.
- **Image-Aktualität:** Alte ISO → langer Windows-Update-Lauf pro PC + wachsende Sicherheitslücke → ISO/Golden-Image
  in Kadenz (z. B. monatlich) neu servicen.

---

---

## Nachtrag: Code-Review-Fixes (2026-07-21)

Nach der Implementierung wurde der Code von 4 Fach-Agenten adversarial geprüft (40 Funde, 20 verifiziert,
**15 bestätigt**). Die wichtigsten eingearbeiteten Korrekturen:

- **🔴 KRITISCH – WinPE-Trigger:** Der ganze Ablauf hing an `windowsPE`-`RunSynchronous`. Die 24H2/25H2-Setup-
  Engine (setuphost/SetupPrep) **ignoriert** das auf Stock-Medien → PC landet still im interaktiven Setup.
  **Fix:** `winpeshl.ini` in die `boot.wim` injizieren, `Deploy-WinPE.ps1` direkt starten (wie MDT LiteTouch);
  RunSynchronous bleibt nur als Fallback.
- **🟠 Re-Wipe-Schleife:** erneuter USB-Boot löschte die frische Installation. **Fix:** Idempotenz-Marker +
  Firmware-BootNext.
- **🟠 Disk-Auswahl:** `IsBoot` ist in WinPE unzuverlässig. **Fix:** Medium-/Abbild-Datenträger explizit per
  Disk-Nummer ausschließen.
- **🟠 Credentials auf Fehlerpfad:** ein abgebrochener Deploy ließ Secrets/Auto-Logon liegen. **Fix:**
  `Invoke-DeploySafeScrub` läuft jetzt auch im `catch` und **zuerst** im Cleanup (unabänderlich).
- **🟠 Klartext-Antwortdatei** gelangte nach `C:\Deploy`. **Fix:** nicht mehr mitkopiert + Scrub-Liste erweitert.
- **🟠 USB-Bau:** hartkodierte Laufwerksbuchstaben `B:/Y:` → dynamisch; robocopy-Exit-Codes werden geprüft.
- **🟠 Software:** MSI-Silent-Args gingen bei eigenen Args verloren → jetzt angehängt; Choco-Args als Array.
- **🟠 Fortsetzungs-Task** startete auf Akku nicht → Battery-Settings gesetzt.
- **🟠 Generator:** fehlende Pflichtfelder → sauberer Abbruch statt Absturz; Metadaten-Kommentar ohne
  `-replace`-Backreference-Injection + erneute Wohlgeformt-Prüfung.

---

*Erstellt und geprüft am 2026-07-21. Prüfung: 5 Fach-Agenten (Windows-Setup, Domänenbeitritt/Sicherheit,
Softwareverteilung, Tool-Architektur, Ansatz-Auswahl) + Synthese; Implementierung anschließend von 4 Agenten
adversarial code-reviewed (15 bestätigte Funde eingearbeitet). Abgleich gegen aktuelle Microsoft-Doku.*
