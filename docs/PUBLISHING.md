# WinTuner GUI auf GitHub veröffentlichen

Diese Anleitung richtet einen öffentlichen GitHub-Releasekanal ein, über den die GUI beim Start nach einer neueren stabilen Version sucht und nach Bestätigung ein geprüftes Update installiert.

## 1. Was benötigt wird

- ein GitHub-Konto
- Berechtigung, ein öffentliches Repository anzulegen
- Git für Windows oder GitHub Desktop
- dieses vollständige Repository-Paket
- ein Repository-Name, zum Beispiel `WinTuner-GUI`

Nicht benötigt und niemals weiterzugeben sind GitHub-Passwort, Personal Access Token, Microsoft-Anmeldedaten oder Tenant-Geheimnisse. GitHub akzeptiert für Git-Operationen kein Kontopasswort mehr; Git Credential Manager beziehungsweise GitHub Desktop öffnet den sicheren Browser-Login.

## 2. Sicherheitsentscheidung vorab

Der eingebaute Updater ruft die öffentliche GitHub-Release-API ohne eingebettetes Token ab. Das Repository muss deshalb öffentlich erreichbar sein. Wenn der Quelltext nicht öffentlich sein darf, muss ein separates öffentliches Distributions-Repository nur mit dem freizugebenden Skript verwendet werden. Kundenlogs, `settings.json`, Tenant-IDs, Pakete und Zugangsdaten gehören niemals in das Repository.

## 3. Repository im Browser anlegen

1. Auf <https://github.com/new> gehen.
2. Owner auswählen.
3. Repository-Namen festlegen, beispielsweise `WinTuner-GUI`.
4. Sichtbarkeit **Public** wählen.
5. README, `.gitignore` und Lizenz beim Anlegen nicht automatisch erzeugen; diese Dateien kommen aus dem Paket.
6. `Create repository` wählen.
7. Die angezeigte HTTPS-URL kopieren, zum Beispiel `https://github.com/FIRMA/WinTuner-GUI.git`.

Die Lizenzfrage ist seit 0.14.0 geklärt: WinTuner GUI steht unter der GPL-3.0 (siehe `LICENSE`). Grund ist das vorausgesetzte Modul [WinTuner](https://github.com/svrooij/WinTuner), das ebenfalls unter der GPL-3.0 steht und im selben PowerShell-Prozess geladen wird. Der Lizenzkopf im Quellcode und der Abschnitt „Lizenz und Herkunft“ in der README müssen dazu passen.

## 4. Erstes Hochladen mit Git

PowerShell 7 im entpackten Ordner öffnen. Vor `git init` unbedingt kontrollieren:

```powershell
Get-Location
Get-ChildItem -Force
```

`Get-Location` muss den entpackten WinTuner-Ordner zeigen – niemals `C:\Windows\System32` und möglichst auch nicht den übergeordneten Ordner `Projekte`, der weitere Dateien enthalten kann.

Falls `git init` versehentlich bereits in `C:\Windows\System32` ausgeführt wurde, eine PowerShell **als Administrator** öffnen und ausschließlich die dadurch erzeugten Git-Metadaten entfernen:

```powershell
Test-Path -LiteralPath 'C:\Windows\System32\.git'
Remove-Item -LiteralPath 'C:\Windows\System32\.git' -Recurse -Force
```

`Remove-Item` nur ausführen, wenn `Test-Path` den Wert `True` ausgibt und die `.git`-Struktur tatsächlich durch den versehentlichen Befehl entstanden ist. `System32` nicht als `safe.directory` eintragen.

Danach in den entpackten Ordner wechseln und dort nochmals `Get-Location` prüfen, zum Beispiel:

```powershell
Set-Location -LiteralPath 'C:\Pfad\zum\WinTuner-GUI-Repository'
Get-Location
Get-ChildItem -Force
```

Erst dort ausführen:

```powershell
git init
git branch -M main
git add .
git status
git commit -m "Release 0.13.9"
git remote add origin https://github.com/FIRMA/WinTuner-GUI.git
git push -u origin main
```

`FIRMA/WinTuner-GUI` durch den echten Owner und Repository-Namen ersetzen. Vor `git commit` bei `git status` prüfen, dass keine Logs, Backups, Einstellungen, Pakete oder Kundendaten enthalten sind.

Alternativ kann GitHub Desktop verwendet werden: `Add existing repository` beziehungsweise `Create a repository from existing files`, Ordner auswählen, committen und `Publish repository` mit öffentlicher Sichtbarkeit wählen.

## 5. GitHub Actions freigeben

1. Repository öffnen und den Tab `Actions` aufrufen.
2. Workflows aktivieren, falls GitHub danach fragt.
3. Unter `Settings > Actions > General` prüfen, dass Actions erlaubt sind.
4. In Organisationen mit strengen Regeln muss der Workflow Schreibzugriff auf `Contents` erhalten. Die Datei `release.yml` fordert bereits `contents: write` an; eine übergeordnete Organisationsrichtlinie kann dies trotzdem blockieren.
5. Unter `Actions` muss `Validate PowerShell` nach dem Push grün sein.

## 6. Erstes Release und Updatekanal erzeugen

```powershell
git tag -a v0.13.9 -m "WinTuner GUI 0.13.9"
git push origin v0.13.9
```

Der Tag startet `Publish release`. Der Workflow:

1. verlangt das Tagformat `vMAJOR.MINOR.PATCH`,
2. vergleicht `v0.13.9` mit `$script:appVersion = "0.13.9"`,
3. parst das vollständige PowerShell-Skript,
4. setzt im Release-Asset automatisch `owner/repository`,
5. erzeugt `WinTuner_GUI_ntg.ps1.sha256`,
6. veröffentlicht beide Dateien als stabiles GitHub-Release.

Nach erfolgreichem Workflow unter `Releases` das Asset `WinTuner_GUI_ntg.ps1` herunterladen. **Diese Release-Datei** an Admin-PCs verteilen; sie enthält bereits die richtige Repository-URL. Die Quelldatei im Git-Repository darf weiterhin einen leeren Wert besitzen.

## 7. Automatische Updates testen

1. Release-Asset öffnen und kontrollieren, dass die Zeile `$script:githubRepo = "OWNER/REPOSITORY"` den echten Wert enthält.
2. Skript auf einem Test-PC starten.
3. Unter Einstellungen `Auf GitHub nach einer neueren Version ...` verwenden; bei gleicher Version muss „aktuell“ erscheinen.
4. Für einen End-to-End-Test eine neue Testversion erstellen, beispielsweise 0.13.10, und als `v0.13.10` veröffentlichen.
5. Die installierte 0.13.9 erneut starten. Die Prüfung läuft automatisch beim GUI-Start und bietet 0.13.10 an.
6. Nach Bestätigung werden Skript und SHA-256 geladen, Hash und interne Version geprüft und die laufende Datei ersetzt.
7. Die GUI schließt sich. Skript manuell neu starten.
8. Die vorherige Datei liegt daneben als `.backup`.

Für die Updateprüfung müssen `api.github.com`, `github.com` und GitHub-Release-Downloads über Firewall beziehungsweise Proxy erreichbar sein.

## 8. Jede weitere Version veröffentlichen

1. Änderungen ausschließlich in den Quellteilen unter `src/` einarbeiten. Die ausgelieferte
   Einzeldatei unter `dist/` wird erzeugt und nie von Hand bearbeitet.
2. Kopfzeile (Zeile 2) und `$script:appVersion` auf dieselbe neue Version setzen — beide
   stehen in `src/00-Bootstrap.ps1`. Die Static Checks brechen ab, wenn sie voneinander
   abweichen.
3. `CHANGELOG.md` ergänzen.
4. Lokal bauen und prüfen — der Build parst das Ergebnis bereits selbst:

```powershell
pwsh -File .\build\Build-SingleFile.ps1
pwsh -File .\tests\StaticChecks.ps1
```

5. Commit und Push (`dist/` ist bewusst nicht im Repository, die Pipeline baut selbst):

```powershell
git add src CHANGELOG.md
git commit -m "Release 0.13.10"
git push origin main
```

6. Erst wenn `Validate PowerShell` grün ist, Tag pushen:

```powershell
git tag -a v0.13.10 -m "WinTuner GUI 0.13.10"
git push origin v0.13.10
```

Ein bereits veröffentlichtes Tag nicht nachträglich verschieben oder wiederverwenden. Fehler mit einer neuen Patchversion korrigieren, zum Beispiel 0.13.10 auf 0.13.11.

## 9. Fehlerbehebung

- **Workflow meldet Versionsabweichung:** Tag und `$script:appVersion` stimmen nicht exakt überein.
- **Release wird nicht erstellt:** Unter `Actions` den fehlgeschlagenen Schritt öffnen; häufig blockiert eine Organisationsrichtlinie `contents: write`.
- **GUI meldet nur manuellen Download:** Eines der beiden exakt benannten Assets fehlt.
- **Updateprüfung schlägt fehl:** GitHub-Domains, Proxy, TLS-Inspection und Systemzeit prüfen.
- **Hash-Abweichung:** Release nicht verwenden; Assets neu aus einem vertrauenswürdigen Commit veröffentlichen und eine neue Version vergeben.
- **Austausch der Datei scheitert:** Schreibrechte, Virenschutz/EDR und OneDrive-Dateisperre prüfen. Die `.backup`-Datei bleibt erhalten.
- **Privates Repository:** Der tokenlose Updater kann private Releases nicht lesen. Keine Tokens im Skript hinterlegen; stattdessen öffentliches Distributions-Repository oder einen intern authentifizierten Updatekanal entwerfen.
