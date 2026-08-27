# Fallen und Muster dieser Codebasis

Jede Falle hier ist mindestens einmal zugeschnappt und hat Zeit gekostet. Kurz lesen, bevor an der
Oberfläche oder am Zustand gearbeitet wird. Ergänzt [CLAUDE.md](../CLAUDE.md) und
[CODEMAP.md](CODEMAP.md).

## PowerShell / WinForms

### Ereignisse verlieren die Variablen ihrer Funktion
Ein `Add_Click`-Block, der in einer Funktion erzeugt wird, sieht deren lokale Variablen nur, solange
die Funktion **noch läuft** — bei einem modalen Dialog also, bei einem eingebetteten Bereich nicht.
Danach ist alles `$null` („The property 'Text' cannot be found", „The expression after '&' …").

**`.GetNewClosure()` ist NICHT die Lösung**: die Closure hängt an einem dynamischen Modul, in dem
`$script:` woanders hinzeigt und Skriptfunktionen nur gefunden werden, solange das Skript zufällig
das oberste ist — aus einem anderen Skript heraus meldet jeder Handler „Get-UiString is not
recognized" (gemessen).

**Richtig:** Zustandsbeutel im Skript-Bereich, Handler holt sich alles daraus.
```powershell
$script:appSettingsUi = @{ List = $list; Status = $dlgStatus; … }
$reload.Add_Click({ & $script:appSettingsUi.LoadApps })
```
Ein modaler Dialog sichert den vorherigen Beutel und stellt ihn im `finally` zurück.
Test: `tests/Unit/EmbeddedDialogClosures.Tests.ps1`.

### AutoScroll-Panels rechnen relativ
In einem gescrollten Panel sind Kind-Koordinaten **relativ zum Scrollstand**: `Karte.Top = 48`
landet bei 400 px Scrollweg in Wahrheit auf 448. Beim Zurückscrollen steht oben ein leerer Block.
Absolute Y-Werte deshalb über `Get-ScrollOffsetY $panel` korrigieren; relative Angaben („unter die
Karte darüber") sind unbedenklich. Auslöser sind Neuanordnungen im gescrollten Zustand: Resize,
Designwechsel, erneutes Öffnen des Bereichs (die Scrollposition bleibt erhalten).
Messung: `LayoutProbe` meldet `LAYOUT-SCROLLSHIFT`.

### Eine deaktivierte Beschriftung ist unlesbar
WinForms zeichnet `Label` mit `Enabled = $false` **immer** in `SystemColors.GrayText` (#6D6D6D) und
ignoriert ForeColor — auf dunklem Grund 3,56 : 1. Statt zu deaktivieren: `Set-LabelDimmed -Label X
-Dimmed $true` (65-Theme). Für Eingabeelemente (Kästchen, Zahlenfelder) bleibt Windows' Darstellung —
die müssen wirklich gesperrt sein. Tests: `DimmedLabels.Tests.ps1`, `LAYOUT-CONTRAST` in der Probe.

### `@($liste)[0]` auf einer `List[object]`
wirft „Argument types do not match". In einer Funktion mit `catch { Write-LogDebug }` fällt das
nirgends auf — außer im gerenderten Bild (sieben Karten lagen übereinander). Elemente lieber in
einer Schleife holen.

### Weitere Kleinigkeiten
- `$args` ist automatisch und darf in einem Handler nicht zugewiesen werden.
- Befehlsaufruf in einem Methodenaufruf braucht eigene Klammern: `$list.Add((Get-UiString 'X'))`.
- `Sort-Object -Property @{Expression={…}}` läuft in eigenem Scope und sieht Skriptfunktionen nicht.
- Eine leere `List` ist **falsy** (`-not $liste` ist wahr) → explizit `$null -eq` prüfen.
- `[Environment]::GetFolderPath('ApplicationData')` ignoriert `$env:APPDATA`: ein Testlauf des
  gebauten Skripts schreibt ins **echte** Profil. Vor Experimenten prüfen, ob die Anwendung läuft.
- Die Fenstergröße wird an zwei Stellen gesetzt; die in `90-Main.ps1` läuft zuletzt und gewinnt.
- Fensterlage immer aus `Screen.PrimaryScreen.WorkingArea` rechnen, nie `CenterScreen` — das
  zentriert über die Taskleiste hinweg.

## Zustand und Sperren

### Die Fortschrittsanzeige IST die Busy-Sperre
`Test-OperationRunning` liest ihre Sichtbarkeit. Ein `Show-Progress` ohne erreichbares
`Hide-Progress` lässt die Anwendung dauerhaft „beschäftigt" aussehen: jeder weitere Klick wird
abgewiesen oder in die Warteschlange gelegt. **Immer** ins `finally`. StaticChecks prüft das;
Ausnahme nur mit dem Kommentar-Marker `progress-restored-elsewhere`.

### Fortschritt als Text, nicht als Balken
`Show-Progress -Total n` / `Set-ProgressValue <erledigt>` / `Hide-Progress`. Gerechnet wird aus
**erledigten** Schritten und abgerundet — 100 % erst, wenn wirklich alles durch ist. Ohne bekannte
Stückzahl: `Show-Progress` ohne `-Total`.

### Ein Lauf wird gestoppt, nicht abgeschossen
`Request-RunCancel` setzt `$script:cancelBatch`; abgefragt wird der Merker nur an Stellen, an denen
nichts halb erledigt zurückbleibt: zwischen zwei Apps (`Invoke-AppUpdateBatch`), im Paketbau und in
den Wiederholungspausen (`35-Packaging`), in der Update-Suche. Ein laufender **Upload** nach Intune
wird nie unterbrochen. Der Abbruch-Knopf erscheint nur bei `Show-Progress -Cancellable` — wer den
Schalter setzt, muss den Merker in seiner Schleife abfragen (ein Test in `ProgressText.Tests.ps1`
erzwingt das; ein Knopf, der nichts tut, war der Grund, warum es den alten nicht mehr gab).

### Trennen während eines Laufs wird zurückgestellt
`Test-DeferWhileRunning` (90-Main): stoppt den Lauf und legt die Trennung über
`Add-DeferredAction` ab, statt die Sitzung mitten im Lauf wegzuziehen. Zusätzlich bricht der
Stapellauf ab, wenn `$script:isConnected` beim nächsten App-Wechsel falsch ist — sonst paketiert er
munter gegen einen Tenant, der nicht mehr da ist (genau so gemeldet).

### Ein Runspace, eine Pipeline
Paketbau und Inventar-Abfrage teilen sich `$script:pkgRunspace`. Beide pumpen die
Nachrichtenschleife, also kann ein Klick eine zweite Nutzung auslösen → „a pipeline is already
running". Wer den Runspace besetzt findet (`$script:pkgRunspaceInUse` / `$script:packagingBusy`),
arbeitet **inline** weiter statt zu warten oder zu scheitern.

### Das Protokoll muss sagen, WIE die Anwendung eingestellt ist
`Get-SettingsSnapshotLines` (10-Settings) liefert die Zeilen, `90-Main` schreibt sie beim Start und
`85-Rows` nach dem Speichern. Rein und getestet, weil die eigentliche Regel eine inhaltliche ist:
Pfade und Haken vollständig, von kundenbezogenen Listen nur die **Anzahl** — ein Protokoll wandert
in Tickets.

### „Keine Apps" heißt fast nie „keine Apps"
Das Modul (und `Get-Win32AppInventoryViaGraph`) listen ausschließlich `win32LobApp`-Objekte mit der
`[WinTuner|`-Marke im Notizfeld — nur die tragen eine WinGet-Paket-Id. Ein Tenant voller handgebauter
Apps ist für diese Sicht leer, und das muss die Meldung sagen (`NoWinTunerAppsStatus`), sonst
widerspricht die Oberfläche dem Intune-Portal. Der Weg für alles andere ist „Alle Tenant-Apps".

### Der untere Bereich ändert seine Höhe nie
Protokollkasten fest auf 120 px, Fortschrittstext und Abbruch-Knopf in der Zeile des
Protokoll-Umschalters. Eine Oberfläche, die während eines Laufs 122 px Inhalt wegnimmt und danach
zurückgibt, verliert die Verlässlichkeit, die man beim Arbeiten braucht — so gemeldet.

### Erst fragen, was in diesem Tenant überhaupt antwortet
`Get-AppInstallationProbe` hat drei Quellen (deviceStatuses → installSummary → Statusbericht). Viele
Tenants antworten auf die ersten zwei mit HTTP 400, also kostete jede Sonde drei Anfragen und 5–8 s.
`$script:installProbeSource` merkt sich die Quelle, die geantwortet hat, und fragt sie zuerst — die
Regeln bleiben: eine Null muss von einer zweiten Quelle bestätigt sein, unbekannt blockiert jedes
Löschen. Beim Tenant-Wechsel wieder offen (`Clear-InstallProbeSource`).

### Dieselbe Frage nicht zweimal stellen
`Get-FreshLatestPackageVersion` kostet zwei Netzabfragen und 1–3 s. Dashboard-Kachel und
automatische Update-Suche stellten sie beim Anmelden beide, Sekunden auseinander. Fünf Minuten
Zwischenspeicher (`Clear-LatestVersionCache` beim Tenant-Wechsel), `-Force` für den Weg, den der
Benutzer selbst anstößt.

### Unbeaufsichtigte Läufe warten kürzer
Der automatische Favoritenlauf hält die Busy-Sperre und blockiert damit die Anmeldung samt
Update-Suche. `-ThrottleRetries 1` statt 3: eine 429-Sperre kostet dort 5 s statt 50. Von Hand
angestoßen bleibt es bei drei Versuchen — dort wartet jemand bewusst.

### Eine Frage, die die Einstellung nicht schluckt
`Confirm-ChangeAction -AlwaysAsk` für Änderungen an der **Reichweite** einer App (wer sie bekommt).
„Rückfragen abschalten" ist für die eigene Routine gedacht, nicht für Zuweisungen.

### Eine leere Antwort ist keine Antwort
Der Modul-Wettlauf („Collection was modified") kommt auch **ohne Ausnahme**: als leere Liste. Deshalb
liest `Get-Win32AppsResilient` eine leere Antwort einmal gegen (`-MaxRetries 0` schaltet das ab, für
Aufrufer mit eigener Warteschleife), `Get-CachedWin32Apps` schreibt keine leere Liste über ein
gefülltes Inventar desselben Kunden, und `Test-InventoryContradiction` erkennt die unmögliche
Kombination „0 aktive, aber n abgelöste". Im Zweifel keine Zahl behaupten: Kachel „—",
`LoadAppsFailedStatus`, Cache verwerfen.

### Der Nachweis hängt an der Domäne, nicht am Konto — und nicht an `currentUserUpn`
`Add-SessionActivity` stempelt `$script:activityTenantUpn` (bei der Anmeldung gesetzt, erst beim
**Abmelden** geleert), nicht `$script:currentUserUpn` — das ist nach „Trennen" leer, und Einträge
mit leerem Tenant sind im Nachweis unauffindbar. Gefiltert wird über `Get-ActivityTenantDomain`:
das zweite Admin-Konto desselben Kunden muss denselben Nachweis sehen. Einträge ohne Tenant werden
getrennt und ausdrücklich benannt angehängt, nie stillschweigend zugeordnet — der Text geht in ein
Kundenticket.

### Das Dashboard lädt nur, wenn es einen Grund hat
Drei Tenant-Abfragen je Besuch waren das kurze Einfrieren beim Navigieren. Geladen wird bei der
Anmeldung, wenn `$script:dashboardStale` gesetzt ist, und auf Knopfdruck. Den Merker setzt
`Add-SessionActivity` — die eine Stelle, die jeder schreibende Weg durchläuft. Wer die Zahlen
zwischenspeichert, muss den **Stand** anzeigen (`Update-DashboardFreshness`); eine stumm veraltete
Zahl ist schlimmer als eine langsame.

### Gruppen-GUIDs werden aufgelöst, aber nie um jeden Preis
`Get-EntraGroupLabel` gibt den Namen oder die GUID zurück, nie leer. Reihenfolge: Favorit dieses
Kunden → Token der Anwendung → bereits erteilte Graph-Zustimmung. Aus einer **Schleife** heraus
darf nie ein Zustimmungsdialog aufgehen, und nach dem ersten 403 wird die Abfrage für die Sitzung
abgeschaltet (`$script:entraGroupLookupOff`) — sonst läuft eine Liste mit 300 Apps 300 Mal in
denselben Fehler. Namen und Fehlschläge gelten je Tenant: `Clear-EntraGroupNameCache` beim Wechsel.

### Kundendaten hängen an der Tenant-Domäne
Gruppen-Favoriten, gemerkte Zustimmungen, Kundennamen: Schlüssel ist die Domäne aus
`$script:currentUserUpn`. Bei einem MSP-Werkzeug ist das der Unterschied zwischen „Pilot-Gruppe von
Kunde A" und „falsche Organisation".

## Oberfläche

### Layout messen statt zählen
Neue Anordnungen rechnen aus dem Inhalt: `Get-ControlTextWidth`, `Get-ControlTextHeight`,
`Set-AppSettingsRowBlock` (Zeilen aus Zellen, gemeinsame Beschriftungsspalte, optional zweispaltig),
`Update-StackedCards` (Kartenhöhe aus dem tiefsten Kind). Handgezählte Höhen stimmen für **eine**
Schriftart — und jedes Retro-Design wechselt sie.

### Der linke Einzug kommt aus einer Rechnung
`$script:formPadding` (5), `$script:mainPanelIndent` (10), `$script:navButtonIndent` (8),
`$script:navButtonTextPad` (12) → `$script:navContentIndent` = 30, die Symbolspalte der
Seitenleiste. Der Titel der Kopfzeile sitzt auf `navContentIndent - formPadding` (die Kopfzeile ist
angedockt, also im Fenster-Innenabstand). Wer eine dieser Zahlen einzeln ändert, verschiebt Titel
und Leiste gegeneinander — genau das war der sichtbare Versatz von 9 px. `LeftIndent.Tests.ps1`
hält die Rechnung fest.

### Eine Karte, deren Höhe vom Inhalt abhängt, muss nach dem Füllen neu vermessen werden
`Get-SupersededCardHeight` rechnet aus der Zeilenzahl — aber `Update-SupersededListState` musste
`Update-UpdatesLayout` erst aufrufen, damit das ankommt. Ohne diesen Aufruf behielt die Karte die
Höhe des Leerzustands, und von sechs Einträgen waren zwei zu sehen. Zeilenhöhe nie unterschätzen:
`ItemHeight` einer `CheckedListBox` ist beim Aufbau kleiner als das, was sie später zeichnet
(18 px Untergrenze plus 4 px für den Rahmen — gemessen, nicht geschätzt).

### Die erste Fenstergröße kommt vom Bildschirm
`Get-InitialWindowSize` (75-UiState) ist die eine Rechnung: gespeicherte Größe > 80 % der
Arbeitsfläche > Entwurfsgröße, begrenzt auf [Minimum .. Arbeitsfläche − 8]. Alle drei Grenzen waren
schon einmal falsch (Fenster unter der Taskleiste, vierte Kachel abgeschnitten, gespeicherte Größe
unter dem Minimum). Deshalb rein und getestet, nicht inline im Startcode.

### Eine Layout-Funktion muss an drei Stellen aufgerufen werden
`Show-Section`, `$form.Add_Resize`, `Set-ActiveTheme`. Fehlt die dritte, behält der Bereich nach
einem Designwechsel die Geometrie der alten Schriftart, bis man ihn verlässt und neu öffnet.

### Leere Listen tragen den Verbindungszustand
`Set-ListEmptyText -Label X -NormalKey 'Y'` schreibt „Nicht verbunden…", solange keine Sitzung
besteht — auch schon beim Aufbau, nicht erst bei der Anmeldung.

## Werkzeuge zum Messen

`tests/LayoutProbe.ps1` deckt Überlappung, abgeschnittenen Text, Kontrast und Scroll-Sprung ab.
Für alles andere: eine **Wegwerf-Probe** nach diesem Muster (30 Zeilen, in den Scratchpad, nicht ins
Repo):

```powershell
$text = [IO.File]::ReadAllText('dist\WinTuner_GUI_ntg.ps1')
$gate = "if (`$env:WINTUNER_SMOKE -eq '1') {"      # das Smoke-Gate in 90-Main
$inject = @'
if ($env:MEINE_PROBE -eq '1') {
  $script:legacySettingsCopied = $null; $script:settingsCorruptBackupPath = $null
  $script:cleanupConflictResolved = $false          # sonst hängt der Lauf in einem Startdialog
  $form.Size = New-Object System.Drawing.Size(1146, 854); $form.Show()
  Show-Section 'appsettings'; [System.Windows.Forms.Application]::DoEvents()
  # … messen, DrawToBitmap speichern, Write-Host …
  [Environment]::Exit(0)
}
'@
[IO.File]::WriteAllText($copy, $text.Replace($gate, $inject + $gate), (New-Object Text.UTF8Encoding($true)))
```
`APPDATA`/`LOCALAPPDATA` vorher auf einen Sandbox-Ordner setzen — sonst schreibt der Lauf ins echte
Profil.

## Prüfläufe ohne Benutzer (CI)

- **Kein modaler Dialog im Startpfad.** Alles, was auf der obersten Ebene vor dem Smoke-Tor
  (`90-Main.ps1`) steht, läuft bei jedem Start — auch bei einem unbeaufsichtigten. Eine MessageBox
  dort wartet auf einen Klick, den auf dem CI-Läufer niemand macht: der Smoke-Test lief nach 180 s
  in seinen Zeitablauf. Ausgelöst hat es der Zweig „Modul-Import fehlgeschlagen", der auf dem
  Läufer **immer** genommen wird, weil dort kein WinTuner-Modul installiert ist — auf dem
  Entwicklungsrechner ist es da, also sah es dort nie jemand. Startmeldungen deshalb über
  `Show-StartupDialog` (70-Runtime); eine StaticCheck-Regel hält die Stelle frei.
- **Es gibt zwei unbeaufsichtigte Läufer, nicht einen.** `SmokeTest` setzt `WINTUNER_SMOKE`,
  `LayoutProbe` setzt `WINTUNER_LAYOUT` und schiebt sich vor das Smoke-Tor. Wer nur die erste
  Kennung abfragt, hat den Dialog nur zur Hälfte stillgestellt — die Layout-Probe lief danach
  weiter in ihren Zeitablauf (240 s). Beide Kennungen stehen in `Test-UnattendedRun` (70-Runtime);
  ein neuer Prüfkopf braucht dort eine Zeile und sonst nichts.
- **Der Entwicklungsrechner hat mehr installiert als der Läufer.** Was nur da ist, weil man selbst
  es einmal installiert hat (WinTuner-Modul, Pester-Fassung), ist im Zweifel eine unbewiesene
  Annahme. Nachstellen lässt sich der Modulfall, indem der Modulordner kurz umbenannt wird.

## Was ein Prüflauf sieht — und was er bisher nicht sah

- **Die Kapselung des Profils wirkte nicht.** `[Environment]::GetFolderPath('ApplicationData')`
  liest den bekannten Ordner von Windows und **ignoriert `$env:APPDATA`**. SmokeTest und LayoutProbe
  setzten genau diese Variable und hielten sich für gekapselt — gemessen am 26.08.2026 lasen und
  schrieben sie das **echte** Profil des Entwicklers. Zwei Folgen: ein Prüflauf konnte die
  Einstellungen des Benutzers anfassen, und der **Erstlauf-Zustand** (frisches Profil = jeder
  CI-Läufer, und jeder neue Benutzer) wurde nie geprüft. Umgelenkt wird jetzt über
  `$env:WINTUNER_DATA_DIR`, gebündelt in `Get-AppDataRoot`/`Get-LocalAppDataRoot`.
- **Was nur der eigene Rechner hat, ist eine unbewiesene Annahme** — nicht nur installierte Module,
  auch der eigene Profilstand. Die Layout-Probe hat dadurch jahrelang **nur Deutsch** gemessen,
  obwohl `Language = "en"` die Vorgabe für jeden neuen Benutzer ist. Sie läuft jetzt über beide
  Sprachen, mit ausdrücklich vorgelegter Einstellung statt „was hier gerade eingestellt ist".
- **`Add_Shown` ist Startpfad.** Diese Handler laufen, sobald das Fenster gezeigt wird, und die
  Layout-Probe zeigt es. Fünf von ihnen öffnen über `BeginInvoke` eine modale MessageBox (Erstlauf-
  Hinweis, beschädigte Einstellungen, übernommene Altdaten, Optionskonflikt, Update-Suche). Dass
  keiner zuschlug, lag an Einstellungen, die auf einem eingerichteten Profil gesetzt sind — auf
  einem frischen nicht. Jeder braucht `if (Test-UnattendedRun) { return }`.
- **Eine Toleranz muss gegengeprüft werden.** Die Überlappungsprüfung meldet erst ab 8 px in
  **beiden** Richtungen: eine AutoSize-Beschriftung ist rundherum ~3 px größer als ihre Glyphen, und
  auf frischem Profil kamen so 7–17 optisch einwandfreie Meldungen zusammen (nachgesehen in einer
  Bildschirmkopie). Damit die Toleranz nicht unbemerkt zu groß wird, prüft die Probe bei **jedem
  Lauf** sechs Fälle gegen: die drei echten Befunde aus ihrer Geschichte müssen anschlagen, die
  Rand-Bleeds nicht.

## Pester 5: Discovery und Run sind zwei Phasen

- **`-ForEach` und `-Skip` werden in der DISCOVERY ausgewertet, `BeforeAll` läuft erst danach.**
  Eine Tabelle, die `BeforeAll` füllt, ist für `-ForEach` also leer — die Prüfungen werden zu
  **null** Tests und die Datei meldet grün, ohne etwas geprüft zu haben (so lief der Modulvertrag
  bis 0.16.0). Daten für `-ForEach`/`-Skip` gehören in `BeforeDiscovery`.
- **Nichts in Discovery oder `BeforeAll` darf fliegen.** Ein Fehler dort nimmt die ganze Datei mit
  und meldet nur „Container failed" — ohne die Zeile, an der es lag.
- **Im Gesamtlauf überschatten die Attrappen der anderen Testdateien echte Cmdlets.** Mehrere
  Dateien definieren globale `Get-Wt*`-Attrappen; wer das echte Modul prüfen will, muss
  `Get-Command -Module WinTuner` schreiben. Sonst ist die Datei allein grün und im Verbund rot.
- Eine Typprüfung über `.FullName` schlägt bei generischen Typen immer fehl (voll qualifizierter
  Name samt Assembly und .NET-Fassung) — `.ToString()` liefert die stabile Kurzform.

## Form

- **CRLF** überall, **BOM** in allen `src/*.ps1` außer `65-Theme.ps1`.
- Einzeilige UI-Strings vertragen keine deutschen Anführungszeichen; Here-Strings schon.
- Backticks (`` `r`n ``) nie über eine Bash-Heredoc setzen — Write-/Edit-Werkzeug benutzen.
- Kommentare erklären **warum** und nennen den Fehler, den sie verhindern.
- Das Repository liegt in OneDrive: „Deletion of directory failed"-Prompts bei Branch-Wechseln immer
  mit `n` beantworten.
