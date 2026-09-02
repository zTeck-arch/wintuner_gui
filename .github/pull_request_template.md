<!--
  Diese Vorlage erzwingt nichts - GitHub liest die Kaestchen nicht und blockt keinen Merge.
  Sie stellt die drei Fragen aus CLAUDE.md in dem Moment, in dem man sie ueberspringt.
  Die eingetragenen Zahlen sind der Teil, der spaeter zaehlt: sie halten fest, welcher Stand
  tatsaechlich gemessen wurde.
-->

## Was aendert sich

<!-- Ein bis drei Saetze. Bei einem behobenen Fehler: welcher, und woran man ihn gemerkt hat. -->

## Pruefkette

`pwsh -NoProfile -File tests/Invoke-CheckChain.ps1` — Ergebnis eintragen, nicht behaupten (Regel 2):

- [ ] vollstaendig gelaufen, Exit-Code 0
- [ ] StaticChecks gruen — Funktionen: `___`, UI-Keys je Sprache: `___`
- [ ] SmokeTest gruen
- [ ] LayoutProbe gruen (7 Designs, 2 Fenstergroessen, 2 Sprachen)
- [ ] Pester gruen — `___` Tests, `___` uebersprungen
- [ ] Analyzer — 0 blockierend, `___` informational

<!-- Bei den uebersprungenen Tests dazuschreiben, ob das WinTuner-Modul auf dem Rechner lag:
     ohne Modul sind es 15 und der Modulvertrag ist NICHT geprueft. -->

## Regressionspruefung

<!-- Regel 4: jeder behobene Fehler bekommt eine Pruefung, jede neue Regel wird gegengeprueft
     (Fix zurueckbauen, Regel muss anschlagen). -->

- [ ] Pruefung ergaenzt in `tests/`_______
- [ ] Gegenprobe gemacht — Regel schlaegt ohne den Fix an
- [ ] entfaellt, weil: _______

## Sichtbares

<!-- Regel 3: behaupten ist verboten, messen ist Pflicht. Welche Probe, welches Design? -->

- [ ] gerendert und angesehen: _______
- [ ] entfaellt, keine UI-Aenderung

## Form

- [ ] kein `dist/` im Diff — Aenderungen liegen in `src/NN-*.ps1`
- [ ] CRLF erhalten; BOM erhalten (alle `src/*.ps1` ausser `45-Assignments.ps1`)
- [ ] neue UI-Texte in **beiden** Sprachbloecken in `15-Strings.ps1`
- [ ] `CHANGELOG.md` gepflegt
