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

### `.Visible` sagt nicht, was Sie meinen
WinForms liefert die **wirksame** Sichtbarkeit: für jedes Kind einer versteckten Sektion ist
`.Visible` gleich `$false` — nachgemessen mit einem Panel, dessen Elternteil auf `Visible = $false`
steht. Wer damit eine Kartenhöhe misst, während ein *anderer* Bereich offen ist, bekommt „kein Kind
sichtbar" und lässt die Karte auf ihren Rand zusammenschrumpfen. Der Zustand eines Aufklappers
gehört deshalb in eine Variable (`$script:advExpanded`), und `Update-StackedCards` bekommt die
ausgeblendeten Steuerelemente über `-Exclude` genannt, statt sie zu erraten.

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

### Ohne `-TimeoutSec` wartet PowerShell 7 für immer
`Invoke-RestMethod` ohne Zeitablauf hat keine Obergrenze. Gemessen am 31.08.2026: von 22
Aufrufstellen trugen **sieben** eine Angabe, **fünfzehn** nicht — und alle laufen auf dem UI-Faden.
Eine Antwort, die nie kommt, war ein eingefrorenes Fenster ohne Abbruchweg; nur das Beenden half.

Graph läuft deshalb über `Invoke-GraphRest` (40-Graph): Zeitablauf (100 s), Wiederholung bei 429 und
5xx mit `Retry-After` (begrenzt auf 45 s), Abbruchprüfung über `$script:cancelBatch`, und eine
Protokollzeile, die sagt **was** gewartet hat. Eine StaticCheck-Regel weist jeden neuen Aufruf ab,
der weder darüber läuft noch `-TimeoutSec` nennt.

Zwei Entscheidungen darin sind Sicherheits- und keine Bequemlichkeitsfragen:

- **Wiederholt wird nur bei einem gelesenen HTTP-Status.** Status 0 heißt „kein Status lesbar":
  Zeitablauf, abgerissene Verbindung, DNS. Genau dann ist unbekannt, ob der Dienst die Anfrage schon
  ausgeführt hat — ein zweiter `POST /mobileApps` legte eine zweite App an. Deshalb `-MaxRetries 0`
  bei allem, was nicht idempotent ist. `POST …/assign` **ist** idempotent (es ersetzt die ganze
  Zuweisungsliste), dort wird wiederholt.
- **Zwei Ebenen Wiederholung multiplizieren sich.** Inventar (`Get-Win32AppsResilient`) und Paketbau
  (`Invoke-PackageBuildWithThrottleRetry`) haben ihre eigene, abgestimmte Schleife; ihre Aufrufe
  gehen mit `-MaxRetries 0` durch den Transport. Sonst wären drei äußere × drei innere Versuche mit
  bis zu 30 s Pause Minuten Wartezeit für eine Liste.

Der eigentliche Anlass: die Zuweisungs-Übergabe schreibt **zwei** Mal (neue App bekommt die
Zuweisungen, dann wird die alte geleert). Scheitert der zweite Schreibvorgang, sind beide Versionen
zugewiesen — der Zustand, den `Move-AppAssignments` als `PARTIALLY applied` protokolliert und den
jemand von Hand aufräumen muss. Die wahrscheinlichste Ursache ist die Drosselung, die zwei schnelle
Schreibvorgänge auslösen, und dagegen half dort vorher nichts.
Tests: `GraphTransport.Tests.ps1` (rein, ohne Netz und ohne Uhr).

### `if (Get-Command X …)` vor einem Aufruf im eigenen Skript schützt vor nichts
Es ist ein Ein-Datei-Skript: die Funktion ist immer definiert. Das Gatter kann also nur eines tun —
eine Umbenennung oder einen Tippfehler in ein stilles „wird übersprungen" verwandeln.

Wo das teuer wird: `Clear-TenantViews` (85-Rows) ist der **eine** Riegel, der beim Anmelden, Trennen
und Abmelden alles wegwirft, was einem bestimmten Kunden gehört — Inventar, Gruppennamen,
Installationsquelle. Jeder dieser vier Aufrufe stand hinter so einem Gatter. Ein übersprungener
Aufruf heißt: Kunde A steht im Fenster von Kunde B. Bei einem MSP-Werkzeug ist das der Unterschied
zwischen „Pilot-Gruppe von Kunde A" und „falsche Organisation".

Die Gatter sind dort weg; dass die Liste vollständig **bleibt**, hält eine StaticCheck-Regel: jede
Funktion, die einen Zwischenspeicher leert, muss im Riegel gerufen werden oder in der Regel
ausdrücklich als nicht-tenantbezogen eingetragen sein. Berechtigt bleibt das Gatter nur bei einem
echten Vorwärtsbezug über Teilgrenzen (`Set-ActiveTheme` in Teil 65 ruft eine Funktion aus Teil 75).

Nebenbei gelernt, als die Gegenprüfung zu dieser Regel zuschlug: die erste Fassung suchte den
Funktionsnamen als **Text** im Rumpf des Riegels — und blieb grün, als die Gegenprüfung den Aufruf
auskommentierte. Eine auskommentierte Zeile ist kein Aufruf. Solche Regeln über den Parser stellen.

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

Es sind inzwischen **drei** Runspaces mit je einem Zweck: Paketbau (`$script:pkgRunspace`, geteilt
mit dem Inventar), Vorab-Bau (`$script:prebuildRunspace`) und Upload (`$script:deployRunspace`).
Geteilt werden dürfen sie nicht — während des Uploads baut der Vorab-Bau schon die nächste App, und
genau dieses Nebeneinander ist ihr Sinn. Erzeugt werden alle über `New-PackagingRunspace -Purpose`,
geschlossen werden alle drei beim Beenden (ein offener Runspace hält mit seinem Thread das Beenden
auf).

### Ein Modulaufruf auf dem UI-Faden hat zwei Symptome, nicht eins
Gemeldet am 02.09.2026: das Fenster friert beim Upload ein, **und** die Konsole füllt sich mit
„[ERROR] Write log to PowerShell failed: The WriteObject and WriteError methods cannot be called
from outside … the same thread". Das sieht nach zwei Fehlern aus und ist einer. `Deploy-WtWin32App`
lief auf dem UI-Faden; dann pumpt niemand die Nachrichtenschleife (das Fenster steht), und der
.NET-Logger des Moduls schreibt in den Host **seines** Runspace — auf dem UI-Faden ist das unsere
Konsole, und weil das Modul aus fortgesetzten Aufgaben protokolliert, scheitert jede einzelne Zeile
mit genau dieser Meldung. Beim Paketbau war beides längst weg, aus demselben Grund: eigener
Runspace. Wer also eine Logger-Flut aus dem Modul sieht, sucht nicht nach einem Protokollfehler,
sondern nach einem Modulaufruf auf dem falschen Faden.

Upload **und Löschen** haben dabei eine Sonderregel, die der Paketbau nicht hat: **kein Abbruch,
kein Zeitablauf, kein `$ps.Stop()`**. Beide gehen über `Invoke-WtModuleCallOffThread`
(35-Packaging), wo diese Politik **einmal** steht; die zwei öffentlichen Trichter
(`Invoke-WtDeployOffThread`, `Invoke-WtRemoveWin32App`) halten nur noch ihren Inline-Rückfall, damit
jeder echte Modulaufruf genau einmal im Quelltext steht und eine StaticCheck-Regel ihn über den
Parser finden kann. Ein abgebrochener Paketbau lässt lokale Dateien zurück, ein abgebrochener
Upload eine halb angelegte App und eine abgebrochene Löschung eine App, an der Intune noch
Ablösebeziehungen führt. Der Abbruchknopf wirkt deshalb **zwischen** den Apps.

### Ein Schreibvorgang, der Erfolg meldet, hat nicht unbedingt etwas geändert
Am 03.09.2026 entfernte `updateRelationships` eine Ablösebeziehung, antwortete mit Erfolg — und im
nächsten Durchlauf war die Beziehung wieder da, dreimal hintereinander. Die anschließende Löschung
scheiterte weiter mit derselben Absage, und der Rückbau lief in einen 400er, dessen Grund im
Protokoll fehlte, weil dort nur der Status stand.

Zwei Regeln daraus, beide umgesetzt: bei einer Mutation, von der eine Löschung abhängt, **nachlesen**
statt annehmen (`Remove-SupersededByUnlinking` liest die Beziehungen nach dem Schreiben erneut) — und
bei einem Graph-Fehler **den Antwortkörper protokollieren** (`Get-GraphErrorText`, 40-Graph). „400
(Bad Request)" allein ist keine Diagnose, der Grund steht immer im Körper.

Dazu die dritte: eine Absage, die **strukturell** ist, nicht in jedem Lauf wiederholen
(`Test-IsStructuralDeleteRefusal`, `$script:deleteBlockedApps`). Die Grenze ist wichtig — nur
„parent of another app"/„Cannot delete this app" gelten als endgültig; 429, 5xx, 403 und Zeitablauf
**nicht**, sonst schaltet ein einzelner Fehlschlag das Aufräumen für die Sitzung ab. Und der
Merkzettel gehört in den Tenant-Riegel: App-Ids gehören einem Kunden.

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

### Die Marke sagt, WER die App gebaut hat — nicht, ob sie aktualisierbar ist
Deshalb entscheidet sie nicht mehr über den Umfang der Update-Suche. Handgebaute Pakete
sind ebenfalls `.intunewin`-Apps, und die Marke wird im Betrieb auch wieder entfernt — beides ließ
Apps lautlos aus der Suche fallen (im Protokoll vom 28.08.2026: 3 von 13 Win32-Apps geprüft).
`Get-ScanInventory` hängt die unmarkierten Apps an (Schalter `ScanUnmanagedWin32Apps`, Standard an);
**Kachel und Suche müssen dieselbe Liste benutzen**, sonst beantworten sie wieder zwei Fragen mit
demselben Wort. Die Sicherheit liegt nicht am Schalter, sondern an `Resolve-WingetIdForApp`: eine
unmarkierte App bringt **keine** `PackageId` mit, also muss die Id über einen exakten Namen, einen
Treffer ≥ 80 mit 15 Punkten Abstand oder einen `WingetOverrides`-Eintrag kommen. Eine geratene Id
würde das falsche Produkt paketieren und die echte App ablösen — bei einem handgebauten Paket, das
niemand schnell nachbaut, ist das der Totalverlust. Solche Zeilen sind in der Update-Liste orange
und mit `UpdateStateUnmanaged` beschriftet.

Zwei Erweiterungen dazu (28.08.2026, gemessen am Lauf 09:30):

- **Die lose Notiz-Id.** Nicht jede Notiz trägt die geklammerte Marke; oft steht dort, was ein
  Mensch geschrieben hat („WinGet: Google.Chrome"). `Get-LoosePackageIdFromNotes` liest das,
  `Test-IsPlausiblePackageId` zieht die Grenze (Hersteller.Produkt, mindestens ein Buchstabe, keine
  Version, kein Dateiname). Die lose Lesart gilt **nicht** als Marke — sonst fiele die App aus dem
  markierten Inventar *und* aus der Unmarkiert-Liste und wäre gar nicht mehr geprüft. Sie kann eine
  Id nur hinzufügen, nie eine App entfernen.
- **Was nicht geprüft werden konnte, gehört in die Liste.** Ohne zuordenbare Id (Keeper, Harmony
  SASE, Teams Machine-Wide Installer) oder ohne `displayVersion` in Intune (Steam) stand eine App
  vorher nur im Protokoll — im Fenster sah der Tenant sauberer aus als er war. Jetzt ist sie eine
  **gesperrte Zeile** (`BlockedReason`, rot, nicht anhakbar, vom Lauf übersprungen) mit
  Rechtsklick → `UpdateCtxAssignId`, der einen `WingetOverrides`-Eintrag schreibt und neu sucht.

### Ein Gruppenobjekt verliert jeden Merker, den es nicht ausdrücklich mitnimmt
Die Zeilen der Update-Liste werden aus dem Ergebnis von `Group-UpdateCandidates` gebaut, nicht aus
den Kandidaten. Was dort nicht wieder eingesetzt wird, ist für die Anzeige verschwunden:
`IsUnmanaged`, `IsProtected` und `PackageIdFromNotes` fehlten, also blieb die orange Warnung „nicht
von WinTuner gebaut" unsichtbar, obwohl `New-UpdateRow` sie kannte — im Lauf vom 28.08.2026 bei
**jeder** der vier angezeigten Zeilen. Zweite Falle derselben Stelle: der Gruppenschlüssel ist
`PackageId|LatestVersion`, und beide sind bei einer gesperrten Zeile leer — ohne den eigenen
`blocked|GraphId`-Zweig fielen alle nicht prüfbaren Apps zu **einer** Zeile zusammen.
Regressionsprüfung: `BlockedUpdateRows.Tests.ps1`.

### Eine Rückfrage, die „Rückfragen abschalten" nicht abschalten darf
`Confirm-ProtectedAppsInRun` ruft `Confirm-ChangeAction` **mit `-AlwaysAsk`**. Ohne das Wort wäre
der Riegel genau bei dem Benutzer stumm, der ihn am dringendsten braucht: wer
`SuppressChangeConfirmations` gesetzt hat, startet den Lauf sonst völlig ohne Nachfrage. Der
Normalfall kostet trotzdem keinen Klick — ohne geschützte App kehrt die Funktion sofort mit `$true`
zurück. Beide Update-Wege müssen den Riegel haben, „Alle aktualisieren" ist der gefährlichere: dort
liest niemand jede Zeile. Das Urteil `IsProtected` fällt **einmal** in `New-UpdateCandidateModel` —
rechnete jede Anzeigestelle selbst, könnten Zeilenfarbe und Rückfrage auseinanderlaufen.

### Zwei Schreiber auf eine Liste vertragen sich nicht
Die Schutzliste wird an zwei Stellen gepflegt (Rechtsklick in der Update-Liste, Karte in den
Einstellungen). Beide schreiben **sofort** und rufen `Save-Settings` — bewusst anders als die Haken
derselben Seite, die erst „Einstellungen speichern" braucht. Ein Sofort-Schreiber neben einem
Speichern-Schreiber überschreibt sich gegenseitig, und ein Schutz, der erst nach einem Klick an
anderer Stelle gilt, ist genau dann keiner, wenn man ihn braucht. Der Hinweis über der Liste sagt es.

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

### Einen Zwischenspeicher einmal je Schleife schreiben, nicht einmal je Element
`Save-VersionDiskCache` stand **in** `Get-WingetVersions` und war dort die einzige Aufrufstelle. Eine
Update-Suche über 100 Apps schrieb damit 100 Mal die ganze Tabelle: je Paket ein
`Select-LiveVersionCacheEntries` über bis zu 2000 Einträge, ein `ConvertTo-Json` darüber und eine
vollständige Datei — auf dem UI-Faden, zwischen zwei Netzabfragen.

Jetzt setzt `Get-WingetVersions` nur `$script:diskCacheDirty`, und `Save-PendingVersionDiskCache`
schreibt einmal: am Ende der Update-Suche (im `finally`, damit auch ein Abbruch behält was er schon
weiß), nach dem Dashboard-Vollscan und beim Schließen. Schlimmster Fall bei einem Abschuss der
Anwendung: eine Suche ist einmal langsamer — dieselbe Risikoklasse wie die Einstellungen, die auch
erst beim Beenden geschrieben werden. Eine StaticCheck-Regel hält den Schreibvorgang aus der
Schleife heraus; Test: `VersionCacheFlush.Tests.ps1`.

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

### Die Zuordnung Bereich → Layout-Funktion steht an EINER Stelle
`$script:sectionLayoutFunctions` (75-UiState). `Update-SectionLayout -Key x` ordnet einen Bereich neu
an, `Update-AllSectionLayouts` alle.

Vorher stand dieselbe Zuordnung vier Mal da, und die vier Fassungen waren **nachweislich
verschieden**: `Show-Section` kannte zehn Bereiche (ohne `settings`), `$form.Add_Resize` neun
(ohne `settings` und `ownpackage`) und rief sie **ohne Rücksicht auf den sichtbaren Bereich**,
`Set-ActiveTheme` elf, und die Layout-Probe eine vierte Liste aus sechs Namen — unter dem Kommentar
„dieselben Aufrufe, die ein Fenster-Resize auslöst". Zwei Folgen, beide erst durch das Zusammenlegen
sichtbar geworden:

- **Zwei Bereiche ordneten sich beim Ziehen am Fensterrand gar nicht neu an** („Einstellungen",
  „Eigene Installer"). Aufgefallen war das nie, weil `Show-Section` sie beim Betreten anordnet.
- **Jedes Resize-Ereignis rechnete zehn unsichtbare Bereiche mit.** Gemessen am 31.08.2026 im
  laufenden Fenster: 15–19 ms je Ereignis vorher, 1,1–6,0 ms nachher. WinForms feuert das Ereignis
  während eines Ziehvorgangs dutzende Mal je Sekunde, und jede Layout-Funktion vermisst Text über
  `TextRenderer::MeasureText`.

Die Probe ruft jetzt dieselbe Funktion wie das Fenster — ein Nachbau des Produktionspfads findet
Fehler des Nachbaus (so geschehen beim Dialog „Geschützte Apps").
Tests: `SectionLayoutTable.Tests.ps1`, dazu eine StaticCheck-Regel gegen Tippfehler in der Tabelle.

### Ein neuer Bereich braucht zwei Einträge, die niemand vermisst
`Add-Section` allein genügt nicht: `$navKeyOrder` (90-Main) bestimmt die Reihenfolge, `$navGlyphs`
(75-UiState) das Symbol. Wer dort fehlt, landet **hinten in seiner Gruppe und ohne Symbol** — mit
Absicht so gebaut, damit ein neuer Bereich nie verschwindet, aber eben auch ohne jede Fehlermeldung.
Beim Bereich „Kundendaten" ist genau das passiert; gesehen hat es erst eine Bildschirmkopie.
Seither hält eine StaticCheck-Regel beide Tabellen vollständig.

### Zeilenfarben in Listen hängen am Design
Eine feste Farbe kann nicht beides: gemessen gegen die Listenfläche (dunkel `38,38,38`, die sechs
hellen weiß) erreichte das frühere `DarkOrange` auf hellem Grund **2,33 : 1**. `Get-RowAlertColor`
(65-Theme) liefert je Design ein Paar für `protected` / `warn` / `blocked` (gemessen 4,4 – 6,7 : 1).
Weil die Farbe damit vom Design abhängt, muss ein Designwechsel die **Zeilen** neu einfärben —
`Set-GuiTheme` färbt nur die Liste, nicht ihre Einträge; das erledigt `Update-UpdateListRows`.
Und: eine Zeile bekommt **eine** Farbe, am Ende einmal gesetzt. Vorher überschrieb jede folgende
Regel ihr Orange über das Rot der geschützten App — die Kennzeichnung verschwand genau dann, wenn
zusätzlich etwas unklar war.

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
- **Eine Ausnahme nach Typ statt nach Geometrie ist ein blinder Fleck.** Die Überlappungsprüfung
  übersprang jedes Paar, an dem ein `Panel` beteiligt war — begründet mit „Wirte enthalten ihre
  Kinder". Der Gedanke stimmt, die Umsetzung nicht: `New-RoundedInput` liefert für **jedes**
  gerundete Eingabefeld ein Panel, also war jedes Paar *Beschriftung gegen Eingabefeld* von der
  Prüfung ausgenommen — genau die Form von Befund, um derer willen die Probe existiert. Gemessen am
  02.09.2026 lag `Installer-Argumente:` in **allen sieben Designs und beiden Sprachen** 4–11 px auf
  seinem Feld, und die Probe blieb grün. Gefragt wird jetzt nach der Geometrie (`Test-LayoutNested`:
  deckt einer den anderen **vollständig** ab?), und auch diese Regel prüft sich bei jedem Lauf
  selbst. **Die Lehre ist allgemein:** wer eine Prüfung an einem Typ vorbeiführt, nimmt sie für
  alles heraus, was zufällig diesen Typ hat — und merkt es nie, weil das Ergebnis grün ist. Der
  gesamte Restbestand war übrigens sauber: die verschärfte Regel fand **einen** echten Fall.

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

- **CRLF** überall, **BOM** in allen `src/*.ps1` außer `45-Assignments.ps1` (bis zum 31.08.2026 stand
  hier `65-Theme.ps1`; nachgemessen ist es `45-Assignments.ps1`). In `tests/` ist beides gemischter
  Bestand und wird von nichts erzwungen — der Build prüft nur `src/`.
- Einzeilige UI-Strings vertragen keine deutschen Anführungszeichen; Here-Strings schon.
- Backticks (`` `r`n ``) nie über eine Bash-Heredoc setzen — Write-/Edit-Werkzeug benutzen.
- Kommentare erklären **warum** und nennen den Fehler, den sie verhindern.
- Das Repository liegt in OneDrive: „Deletion of directory failed"-Prompts bei Branch-Wechseln immer
  mit `n` beantworten.
