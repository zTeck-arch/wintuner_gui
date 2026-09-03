# Codekarte — wo liegt was

Nachschlagewerk. Nicht am Stück lesen: über die Tabelle „Wo ändere ich …?" einsteigen, dann gezielt
die genannte Datei öffnen. Ergänzt [CLAUDE.md](../CLAUDE.md) (Regeln, Prüfkette, Fallen).

Stand 02.09.2026 (0.18.0): 21 Teile, ~25 000 Zeilen im gebauten Skript,
357 Funktionen, 1006 UI-Texte je Sprache.

## Aufbau in einem Absatz

`build/Build-SingleFile.ps1` hängt `src/NN-*.ps1` in Nummernreihenfolge zu `dist/WinTuner_GUI_ntg.ps1`
zusammen. **Die Nummer ist die Abhängigkeitsstufe**: Teil 40 darf alles aus 00–35 benutzen, aber
nichts aus 45+ auf oberster Ebene (in Funktionsrümpfen schon — die laufen später). Alles ist ein
einziger Skript-Bereich; es gibt keine Module und keine Klassen. Die Oberfläche ist WinForms mit
absoluten Koordinaten, die zunehmend durch gemessene Layout-Funktionen ersetzt werden.

**Zum Zustand, nachgemessen am 31.08.2026:** es gibt 231 `$script:`-Variablen, aber nur **20
überschreiten vier Dateien** und **vier überschreiten acht** (`settings` 15, `currentTheme` 10,
`isConnected` 9, `currentUserUpn` 8). Die anderen 211 sind faktisch dateilokal und nur deshalb
`$script:`, weil Funktionen sie über den Skript-Bereich teilen müssen. Die frühere Angabe „~130
geteilte Variablen als Architekturschuld" überzeichnete das: das eigentliche Hindernis für
Modularisierung ist nicht der geteilte Zustand, sondern die **oberste Ebene** — 52 % aller Zeilen
(12 558) sind Anweisungen auf Skriptebene, davon 2 585 in `90-Main` (95 % dieser Datei). Dieser Code
ist reihenfolgeabhängig und nur über SmokeTest und LayoutProbe abgedeckt.

## Die Teile

| Teil | Zeilen | Inhalt / wichtigste Funktionen |
|---|---|---|
| `00-Bootstrap` | 190 | Startet unter PowerShell 5.1 neu in PS7, prüft/installiert das WinTuner-Modul. `$script:appVersion`, Kopfkommentar `# v0.18.0` (StaticChecks vergleicht beide) |
| `05-Config` | 75 | `$script:githubRepo`, Asset-Namen, `$script:settingsPath`, Datenwurzeln (`Get-AppDataRoot`), **Graph-Transport-Konstanten** (`$script:graphTimeoutSeconds`, `$script:graphRetryStatuses`) |
| `10-Settings` | 600 | Einstellungen laden/speichern (`Load-Settings`, `Save-Settings`, `Get-SettingValue`), Protokollpfad + Löschfrist, Token-Cache (`Remove-TokenCacheFiles`, `Clear-GraphTokenCache`), Datenübernahme (`Copy-LegacyDataFile`, `Get-LegacyDataPath`) |
| `15-Strings` | 2200 | **Alle** UI-Texte. EN-Block zuerst, DE-Block ab ~Zeile 1090. `Get-UiString` liegt in Teil 20 |
| `20-Version` | 580 | `Test-IsNewerVersion`, `Get-UiString`, Selbstupdate: `Test-AppUpdateAvailable`, `Test-SelfUpdateUrlAcceptable`, `Install-SelfUpdateFile`, `Invoke-UpdateCheckFeedback` |
| `25-WinGetData` | 1045 | Inventar + WinGet-Daten. `Get-CachedWin32Apps`, `Get-Win32AppsResilient` (Retry bei Modul-Wettläufen), `Get-Win32AppInventoryViaGraph`, `Get-WingetVersions`, Versions-Cache, lokale Pakete (`Get-LocalPackagePrunePlan`), Zuweisungsziel-Kombis (`Update-AssignTargetCombo`, `Get-SelectedAssignmentTarget`) |
| `30-UpdateTargets` | 665 | Welche App wird wohin aktualisiert: `New-UpdateCandidateModel`, `Find-ExistingUpdateTarget`, `Resolve-DeployedUpdateTarget`, `Measure-AvailableUpdates`, `Get-StringSimilarity` (Jaccard), Store-Auflösung |
| `35-Packaging` | 760 | Paketbau **und Upload** in eigenen Runspaces: `New-PackagingRunspace` (der gemeinsame Erzeuger), `Get-PackageRunspace`, `Invoke-WtPackageBuild`, `Invoke-PackageBuildWithThrottleRetry`, `New-WingetPackageWithFallback`, `Test-PackageFolderUsable`, Vorab-Bau (`Start-PackagePrebuild`, `Get-PrebuildResult`, `Get-PackageBuildKey`), Rückfall (`Get-PackageFallbackVersion`, `Invoke-PackageFallbackBuild`) und **`Invoke-WtModuleCallOffThread`** — der gemeinsame Rumpf für schreibende Modulaufrufe im Hintergrund (`Get-DeployRunspace`, `Close-DeployRunspace`); darauf **`Invoke-WtDeployOffThread`** (der EINE Weg zu `Deploy-WtWin32App`) und das Löschen aus 30-UpdateTargets, dazu `Remove-SupersededByUnlinking` (Abhängen mit Nachlesen und Rückbau) |
| `40-Graph` | 620 | **Der Graph-Transport** (`Invoke-GraphRest`, `Get-GraphRetryPlan`, `Get-ErrorRetryAfterSeconds`, `Get-ErrorHttpStatus`) + Sonden: `Get-GraphCollectionItems`, `Get-AppAssignmentProbe`, `Get-AppInstallationProbe` (zweite Quelle!), `Group-UpdateCandidates` |
| `45-Assignments` | 766 | Zuweisungen schreiben: `Move-AppAssignments`, `Clear-AppAssignments`, `New-AppAssignmentConfiguration`, `Set-AppAssignmentSettings`, `Save-AppScopeSnapshot`, `Enable-AppAutoUpdateChecked` |
| `50-UpdateEngine` | 947 | **`Update-SingleApp`** (der Kern: paketieren → hochladen → Zuweisungen → Aufräumen) und der Leistungsnachweis (`Add-SessionActivity`, `Save-SessionActivity`, `Import-PreviousSessionActivity`, `Get-SessionLeistungstext`) |
| `55-Dialogs` | 1530 | Alle Dialoge. Zwei davon sind auch **Bereiche**: `Show-AppSettingsDialog -HostPanel`, `Show-LeistungstextDialog -HostPanel`. Dazu die generische Zeilen-Anordnung (`Set-AppSettingsRowBlock`, `Get-ControlTextWidth/-Height`) und `Show-GraphScopeConsentDialog` |
| `60-Batch` | 370 | `Invoke-AppUpdateBatch` (Stapellauf über mehrere Apps) + die sieben Design-Tabellen (`$script:darkTheme` …) |
| `65-Theme` | 795 | `Set-GuiTheme`, `New-Card`, `Get-DimmedColor`, `Set-LabelDimmed`, `Get-ScrollOffsetY`, `Add-SettingRow`, `Update-SettingsLayout`, `Update-StackedCards`, `Set-ActiveTheme` |
| `70-Runtime` | 646 | `Write-Log` (+ Mutex, Löschfrist), `Update-Status`, Busy-Sperre (`Test-UiBusy`, `Test-OperationRunning`), aufgeschobene Aktionen, `Get-SanitizedLogText` |
| `75-UiState` | 1360 | Fenster, Kopfzeile, Seitenleiste (`Add-Section`, `Show-Section`), Statuszeile/Protokollbereich, **Fortschrittsanzeige** (`Show-Progress`/`Set-ProgressValue`/`Hide-Progress`), `Show-GroupFavoriteDialog` |
| `80-Views` | 2200 | Bereiche **WinGet-Apps**, **Microsoft Store**, **Lokale Pakete** + `Update-StoreLayout`, `Update-StoreAssignLayout`, `Update-LocalPackagesLayout` |
| `82-TenantApps` | 900 | Bereich **Alle Tenant-Apps**, Zuweisungs-Manager, Entra-Gruppensuche, `Connect-OptionalGraphScope`, `Get-TenantDetectedApps` |
| `83-OwnPackage` | 1995 | Bereich **Eigene Installer** (EXE/MSI, Erkennungsregeln, Sandbox-Test, Inhalt ersetzen) |
| `85-Rows` | 1560 | Bereiche **Updates**, **Erkannte Apps**, **App-Zuweisungseinstellungen**, **Leistungsnachweis**, **Einstellungen** |
| `90-Main` | 2515 | Verdrahtung: alle `Add_Click`-Handler, Seitenleiste bauen, Tooltips, Fensterplatzierung, Smoke-Gate, Start |

## Wo ändere ich …?

| Aufgabe | Datei / Funktion |
|---|---|
| Text ändern oder ergänzen | `15-Strings.ps1` — **beide** Sprachblöcke |
| Neuen Bereich in der Seitenleiste | `Add-Section -Key … -Group start\|deploy\|manage\|local` + Reihenfolge in `$navKeyOrder` (90-Main) + Glyph in `$script:navGlyphs` (75-UiState) + Layout-Funktion in `$script:sectionLayoutFunctions` (75-UiState). StaticChecks hält alle drei Tabellen vollständig |
| Etwas am Update-Lauf | `Update-SingleApp` (50), Stapel drumherum `Invoke-AppUpdateBatch` (60) |
| Zuweisung schreiben/ändern | `45-Assignments.ps1` — nie direkt Graph aufrufen, dort ist die Schreiblogik samt Schutz |
| Neue Graph-Abfrage | **immer über `Invoke-GraphRest`** (40-Graph: Zeitablauf, 429-Wiederholung, Abbruchprüfung) — `Get-GraphCollectionItems` für paginierte Listen. Eine StaticCheck-Regel weist jeden `Invoke-RestMethod` ohne `-TimeoutSec` ab |
| Optionale Berechtigung anfordern | `Connect-OptionalGraphScope -Scope … -TextKey …` (82) |
| Etwas am Aussehen einer Karte | die `Update-*Layout`-Funktion des Bereichs (Liste unten) |
| Design-/Farbfrage | `65-Theme.ps1`, Tabellen in `60-Batch.ps1` |
| Neue Einstellung | Default im `$script:settings`-Block ganz oben in `10-Settings.ps1`, Laden in `Load-Settings`, Zeile auf der Seite über `Add-SettingRow` (85-Rows) |
| Protokollzeile | `Write-Log` (70) — Klartext, englisch, mit Zahlen |

## Layout-Funktionen (eine je Bereich)

**Die Zuordnung steht in `$script:sectionLayoutFunctions` (75-UiState) — an einer Stelle.** Wer eine
neue Layout-Funktion schreibt, trägt sie dort ein und ist fertig; die drei Aufrufer lesen alle daraus:

- `Update-SectionLayout -Key <bereich>` — ordnet **einen** Bereich neu an. Benutzt von `Show-Section`
  (Betreten), `$form.Add_Resize` (Fenstergröße, nur der **sichtbare** Bereich) und der Layout-Probe.
- `Update-AllSectionLayouts` — alle Bereiche. Nur `Set-ActiveTheme` (65) benutzt das: eine andere
  Schriftart ändert die Zeilenhöhe überall, und ein Designwechsel kostet einen Klick statt dutzender
  Ereignisse je Sekunde.

Die elf Einträge: `updates`, `tenant`, `store`, `winget`, `discovered`, `ownpackage`,
`localpackages`, `appsettings`, `workrecord`, `customerdata`, `settings`. `dashboard` hat keine
eigene Funktion — seine Kacheln hängen an `Update-CardWidths`.

Nicht bereichsgebunden und weiter einzeln gerufen: `Update-BottomLayout`, `Update-HeaderLayout`,
`Update-CardWidths` (75) · `Update-StackedCards`, `Add-SettingRow` (65) · `Update-StoreAssignLayout`
(80, aus `Update-StoreLayout`) · `Update-AppSettingsEditorLayout`, `Update-WorkRecordLayout` (55,
die zwei eingebetteten Editoren).

## Bereiche und ihre Gruppen

`dashboard` (start) · `winget`, `store`, `ownpackage` (deploy) · `updates`, `tenant`, `discovered`,
`appsettings` (manage) · `localpackages`, `workrecord`, `settings` (local)

## Zustand, den man kennen muss

| Variable | Bedeutung |
|---|---|
| `$script:isConnected`, `$script:currentUserUpn` | Tenant-Sitzung; die UPN-Domäne ist der Schlüssel für Kundendaten (Gruppen-Favoriten, gemerkte Zustimmungen) |
| `$script:settings` | die geladene Einstellungsdatei; **wird beim Schließen geschrieben** |
| `$script:sessionActivity` / `$script:previousSessionActivity` | Leistungsnachweis dieser / der letzten Sitzung |
| `$script:progressLabel` + `$script:progressTotal/Current` | Fortschrittsanzeige = **Busy-Sperre** |
| `$script:packagingBusy` | zweite Busy-Quelle (kurzes Fenster beim Paketbau) |
| `$script:appSettingsUi`, `$script:workRecordUi` | Zustandsbeutel der zwei eingebetteten Editoren |
| `$script:sections` | Liste aller Bereiche (Key, Panel, Label, Group, NavButton) |
| `$script:currentTheme`, `$script:availableThemes` | aktives Design |

## Tests

`tests/StaticChecks.ps1` (Regeln gegen das gebaute Skript) · `tests/SmokeTest.ps1` (startet es) ·
`tests/LayoutProbe.ps1` (misst die Oberfläche) · `tests/Unit/*.Tests.ps1` (Pester; laden Funktionen
über `Get-SourceFunctionText` aus `src/`, siehe `tests/Unit/TestHelpers.ps1`).

Eine Funktion wird testbar, indem man sie **rein** hält (keine Steuerelemente anfassen) und aus dem
Handler herauslöst — das ist der Grund, warum es Funktionen wie `Get-ExclusionsWithoutInclude` oder
`Get-LocalPackagePrunePlan` überhaupt gibt.

## Externe Abhängigkeiten

- **WinTuner-Modul** (fremd, GPL-3.0): `Connect-WtWinTuner`, `Get-WtWin32Apps`, `New-WtWingetPackage`,
  `Deploy-WtWin32App`, `Get-WtToken`, `Search-WtWinGetPackage`, `Remove-WtWin32App`.
  Vertragstest: `tests/Unit/ModuleContract.Tests.ps1`. Parametersemantik: Filter sind
  `Nullable[bool]`, das Inventar ist **nicht** paginiert (deshalb `Get-Win32AppInventoryViaGraph`).
- **Microsoft.Graph.Authentication** nur für die optionalen Berechtigungen (`Connect-MgGraph`,
  `Invoke-MgGraphRequest`). Alles andere läuft über `Get-WtToken` + `Invoke-RestMethod`.
- **winget.exe** für Katalogsuche und lokale Installation.
