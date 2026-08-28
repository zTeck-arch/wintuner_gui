# Codekarte — wo liegt was

Nachschlagewerk. Nicht am Stück lesen: über die Tabelle „Wo ändere ich …?" einsteigen, dann gezielt
die genannte Datei öffnen. Ergänzt [CLAUDE.md](../CLAUDE.md) (Regeln, Prüfkette, Fallen).

Stand 0.17.0: 21 Teile, ~23 600 Zeilen im gebauten Skript, 328 Funktionen, 994 UI-Texte je Sprache.

## Aufbau in einem Absatz

`build/Build-SingleFile.ps1` hängt `src/NN-*.ps1` in Nummernreihenfolge zu `dist/WinTuner_GUI_ntg.ps1`
zusammen. **Die Nummer ist die Abhängigkeitsstufe**: Teil 40 darf alles aus 00–35 benutzen, aber
nichts aus 45+ auf oberster Ebene (in Funktionsrümpfen schon — die laufen später). Alles ist ein
einziger Skript-Bereich; es gibt keine Module und keine Klassen. Der Zustand liegt in
`$script:`-Variablen (~130 Stück), die Oberfläche ist WinForms mit absoluten Koordinaten, die
zunehmend durch gemessene Layout-Funktionen ersetzt werden.

## Die Teile

| Teil | Zeilen | Inhalt / wichtigste Funktionen |
|---|---|---|
| `00-Bootstrap` | 190 | Startet unter PowerShell 5.1 neu in PS7, prüft/installiert das WinTuner-Modul. `$script:appVersion`, Kopfkommentar `# v0.17.0` (StaticChecks vergleicht beide) |
| `05-Config` | 33 | `$script:githubRepo`, Asset-Namen, `$script:settingsPath` |
| `10-Settings` | 600 | Einstellungen laden/speichern (`Load-Settings`, `Save-Settings`, `Get-SettingValue`), Protokollpfad + Löschfrist, Token-Cache (`Remove-TokenCacheFiles`, `Clear-GraphTokenCache`), Datenübernahme (`Copy-LegacyDataFile`, `Get-LegacyDataPath`) |
| `15-Strings` | 2200 | **Alle** UI-Texte. EN-Block zuerst, DE-Block ab ~Zeile 1090. `Get-UiString` liegt in Teil 20 |
| `20-Version` | 580 | `Test-IsNewerVersion`, `Get-UiString`, Selbstupdate: `Test-AppUpdateAvailable`, `Test-SelfUpdateUrlAcceptable`, `Install-SelfUpdateFile`, `Invoke-UpdateCheckFeedback` |
| `25-WinGetData` | 1045 | Inventar + WinGet-Daten. `Get-CachedWin32Apps`, `Get-Win32AppsResilient` (Retry bei Modul-Wettläufen), `Get-Win32AppInventoryViaGraph`, `Get-WingetVersions`, Versions-Cache, lokale Pakete (`Get-LocalPackagePrunePlan`), Zuweisungsziel-Kombis (`Update-AssignTargetCombo`, `Get-SelectedAssignmentTarget`) |
| `30-UpdateTargets` | 665 | Welche App wird wohin aktualisiert: `New-UpdateCandidateModel`, `Find-ExistingUpdateTarget`, `Resolve-DeployedUpdateTarget`, `Measure-AvailableUpdates`, `Get-StringSimilarity` (Jaccard), Store-Auflösung |
| `35-Packaging` | 380 | Paketbau im eigenen Runspace: `Get-PackageRunspace`, `Invoke-WtPackageBuild`, `Invoke-PackageBuildWithThrottleRetry`, `New-WingetPackageWithFallback`, `Test-PackageFolderUsable` |
| `40-Graph` | 490 | Rohe Graph-Aufrufe + Sonden: `Get-GraphCollectionItems`, `Get-AppAssignmentProbe`, `Get-AppInstallationProbe` (zweite Quelle!), `Group-UpdateCandidates` |
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
| Neuen Bereich in der Seitenleiste | `Add-Section -Key … -Group start\|deploy\|manage\|local` + Glyph in `$script:navGlyphs` (75-UiState) + Layout-Aufruf in `Show-Section` |
| Etwas am Update-Lauf | `Update-SingleApp` (50), Stapel drumherum `Invoke-AppUpdateBatch` (60) |
| Zuweisung schreiben/ändern | `45-Assignments.ps1` — nie direkt Graph aufrufen, dort ist die Schreiblogik samt Schutz |
| Neue Graph-Abfrage | `40-Graph.ps1` (`Get-GraphCollectionItems` paginiert) oder `82-TenantApps.ps1` |
| Optionale Berechtigung anfordern | `Connect-OptionalGraphScope -Scope … -TextKey …` (82) |
| Etwas am Aussehen einer Karte | die `Update-*Layout`-Funktion des Bereichs (Liste unten) |
| Design-/Farbfrage | `65-Theme.ps1`, Tabellen in `60-Batch.ps1` |
| Neue Einstellung | Default im `$script:settings`-Block ganz oben in `10-Settings.ps1`, Laden in `Load-Settings`, Zeile auf der Seite über `Add-SettingRow` (85-Rows) |
| Protokollzeile | `Write-Log` (70) — Klartext, englisch, mit Zahlen |

## Layout-Funktionen (eine je Bereich)

`Update-BottomLayout`, `Update-HeaderLayout` (75) · `Update-SettingsLayout`, `Update-StackedCards`
(65) · `Update-StoreLayout`, `Update-StoreAssignLayout`, `Update-LocalPackagesLayout` (80) ·
`Update-TenantAppsLayout` (82) · `Update-OwnPackageLayout` (83) · `Update-UpdatesLayout`,
`Update-AppSettingsLayout`, `Update-WorkRecordSectionLayout` (85) · `Update-AppSettingsEditorLayout`,
`Update-WorkRecordLayout` (55).

Aufgerufen werden sie an **drei** Stellen — wer eine neue schreibt, muss alle drei bedienen:
`Show-Section` (75), `$form.Add_Resize` (75) und `Set-ActiveTheme` (65, Schriftwechsel).

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
