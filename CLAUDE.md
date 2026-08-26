> **Diese Datei wird bei jedem Sitzungsstart geladen.** Sie ist absichtlich kurz. Alles, was nur
> manchmal gebraucht wird, steht in [docs/CODEMAP.md](docs/CODEMAP.md) (wo liegt was) und
> [docs/PATTERNS.md](docs/PATTERNS.md) (Fallen dieser Codebasis). Den aktuellen Arbeitsstand und die
> offenen Punkte trägt `HANDOVER.md` (nicht im Repository).

# WinTuner GUI — Arbeitsanweisung

WinForms-Oberfläche in PowerShell 7, die Apps in Microsoft Intune paketiert, bereitstellt und
aktualisiert. Setzt das fremde PowerShell-Modul **WinTuner** (`*-Wt*`-Cmdlets) voraus. Ausgeliefert
wird **eine** Datei: `dist/WinTuner_GUI_ntg.ps1`, zusammengebaut aus `src/*.ps1`.

## Die fünf Regeln

1. **Niemals `dist/` bearbeiten.** Änderungen gehen in `src/NN-*.ps1`; danach neu bauen.
2. **Prüfkette nach JEDER Änderung vollständig laufen lassen** (unten). Kein „das ist zu klein dafür".
3. **Behaupten ist verboten, messen ist Pflicht.** Für alles Sichtbare: rendern und hinsehen
   (`tests/LayoutProbe.ps1`, Wegwerf-Proben nach dem Muster in `docs/PATTERNS.md`).
4. **Jeder behobene Fehler bekommt eine Regressionsprüfung** — Unit-Test in `tests/Unit`, oder eine
   Messung. Jede neue Prüfregel einmal **gegenprüfen**: Fix zurückbauen, Regel muss anschlagen.
5. **Git führt der Benutzer selbst aus.** Befehle geben, nicht committen, nicht pushen.

## Prüfkette

Ein Aufruf, alle sieben Schritte, eine Ergebnistabelle (Exit-Code 0 nur wenn alles grün ist):

```powershell
pwsh -NoProfile -File tests/Invoke-CheckChain.ps1
```

Für Zwischenläufe: `-Skip Layout` spart die 7 Designs (~53 s), `-Only Build,Static` beschränkt auf
zwei Schritte, `-FailFast` bricht beim ersten roten ab, `-ShowOutput` zeigt jede Ausgabe.
Der vollständige Lauf dauert ~2,5 Minuten. Die Einzelbefehle dahinter — nur nötig, wenn ein
Schritt genauer untersucht werden soll:

```powershell
pwsh -NoProfile -File build/Build-SingleFile.ps1
pwsh -NoProfile -File tests/StaticChecks.ps1
pwsh -NoProfile -File tests/SmokeTest.ps1
pwsh -NoProfile -File tests/LayoutProbe.ps1
Invoke-Pester -Path tests/Unit
Invoke-ScriptAnalyzer -Path .\src   -Settings .\PSScriptAnalyzerSettings.psd1 -Recurse
Invoke-ScriptAnalyzer -Path .\tests -Settings .\PSScriptAnalyzerSettings.Tests.psd1 -Recurse
```

Erwartet (gemessen am 26.08.2026, Stand 0.16.0): StaticChecks grün (**309 Funktionen, 965 UI-Keys
je Sprache**), SmokeTest grün, LayoutProbe grün, **523 Pester** grün (1 übersprungen ohne
WinTuner-Modul), Analyzer **0 blockierend** (5 informational in `65-Theme.ps1` sind Altbestand).

Die drei Läufer, die kein Parser ersetzt:

| Läufer | fängt |
|---|---|
| `SmokeTest.ps1` | Ladefehler des gebauten Skripts (falsche Teil-Reihenfolge, Control vor seiner Erzeugung benutzt) |
| `LayoutProbe.ps1` | überlappende Steuerelemente, abgeschnittener Text, zu geringer Kontrast, Karten die beim Scrollen verrutschen — in **allen 7 Designs**, 2 Fenstergrößen |
| `StaticChecks.ps1` | Version/Kopf, UI-Key-Parität EN/DE, `-LiteralPath`-Regeln, `Show-Progress` ohne `Hide-Progress` |

`Invoke-CheckChain.ps1` prüft selbst nichts — es startet diese Läufer, jeden in einem eigenen
pwsh-Kindprozess (SmokeTest und LayoutProbe rufen `exit` auf und laden WinForms; nacheinander im
selben Prozess wäre die Kette nach dem ersten Schritt tot).

## Harte Formregeln (der Build bricht sonst ab)

- **CRLF** überall. `sed -i` und Python-Skripte zerstören das lautlos → danach nachmessen.
- **BOM:** alle `src/*.ps1` **außer** `65-Theme.ps1` (das hat keins). Beim Bearbeiten erhalten.
- **Einzeilige UI-Strings** in `15-Strings.ps1` vertragen **keine** deutschen Anführungszeichen
  (`„…"` beendet den String). Here-Strings (`@"…"@`) schon. Eine StaticCheck-Regel fängt das.
- **Backticks nie über die Shell setzen.** `` `r`n `` in einem Bash-Heredoc wird zur
  Befehlsersetzung. Solche Texte mit dem Write-/Edit-Werkzeug schreiben.
- Neue UI-Texte immer in **beiden** Sprachblöcken (EN zuerst, DE ab ca. Zeile 1090).

## Wo was liegt (Kurzform)

`src/` ist nach Ladereihenfolge nummeriert; Nummer = Abhängigkeitsstufe.

| Teil | Inhalt |
|---|---|
| `00`–`10` | Bootstrap (PS7-Nachstart), Konfiguration (Repo/Assets/Pfade), Einstellungen + Protokoll |
| `15` | **Alle** UI-Texte, EN und DE |
| `20`–`35` | Versionsvergleich + Selbstupdate, WinGet-Daten, Update-Zielauflösung, Paketierung |
| `40`–`50` | Graph-Aufrufe, Zuweisungen, Update-Motor (`Update-SingleApp`) |
| `55` | Alle Dialoge — auch die zwei, die als **Bereich** eingebettet werden |
| `60`–`70` | Stapellauf, Designs/Karten/Layout-Helfer, Laufzeit (Protokoll, Busy-Sperre, Statuszeile) |
| `75`–`90` | Fenster + Seitenleiste, Bereiche (Views/Rows/TenantApps/OwnPackage), Verdrahtung + Start |

Details, Funktionsnamen und „wo ändere ich X?" → [docs/CODEMAP.md](docs/CODEMAP.md).

## Die Fallen, die am häufigsten zuschnappen

Vollständig mit Begründung in [docs/PATTERNS.md](docs/PATTERNS.md) — hier nur die Kurzliste:

- Ereignisse in einer Funktion, die zurückkehrt, verlieren ihre lokalen Variablen. **Kein
  `.GetNewClosure()`** — Zustandsbeutel im Skript-Bereich (`$script:appSettingsUi`).
- In einem **AutoScroll**-Panel sind Kind-Koordinaten relativ zum Scrollstand → absolute Y-Werte
  über `Get-ScrollOffsetY` korrigieren.
- Eine **deaktivierte Label** zeichnet WinForms immer grau → `Set-LabelDimmed` statt `Enabled=$false`.
- Die Sichtbarkeit der Fortschrittsanzeige **ist** die Busy-Sperre → jedes `Show-Progress` braucht
  ein `Hide-Progress` im selben Handler.
- `[Environment]::GetFolderPath('ApplicationData')` ignoriert `$env:APPDATA` → ein Testlauf des
  gebauten Skripts schreibt ins **echte** Profil.
- Layout aus Pixelkonstanten ist Altbestand; neu geschriebenes Layout misst (`Get-ControlTextWidth`,
  `Set-AppSettingsRowBlock`).

## Sprache und Ton

Code-Kommentare und Dokumentation auf **Deutsch**, Bezeichner und Protokollzeilen auf Englisch (so
ist der Bestand). Kommentare erklären **warum**, nicht was — und nennen den Fehler, den sie
verhindern, wenn es einen gab.
