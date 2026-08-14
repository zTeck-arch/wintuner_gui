# Changelog

## 0.15.5 – Microsoft Store als eigener Bereich, Gruppen-Favoriten, verständlichere Berichte

**Die Veröffentlichung hat noch nie funktioniert**

- **Kein einziges Release konnte gebaut werden.** Der Workflow setzt nach dem Bauen die Repository-Kennung in die ausgelieferte Datei ein. Das dafür verwendete Suchmuster endete auf `\s*$`; da `\s` auch den Wagenrücklauf einschließt und `$` im Mehrzeilenmodus **vor** dem Zeilenvorschub steht, verschluckte der Treffer das `\r`. Der Ersatztext setzte keines zurück, und genau diese eine Zeile endete danach mit einem nackten `\n`. Seit 0.15.4 laufen die Static Checks bewusst **nach** diesem Eingriff – und lehnten das Ergebnis seitdem jedes Mal ab. Das Muster prüft das Zeilenende jetzt über einen Vorausschau-Ausdruck, ohne es zu verbrauchen. Frühere Releases enthielten dieses nackte `\n` unbemerkt.

**Microsoft Store**

- **Eigener Bereich in der Navigation.** Store-Apps werden direkt in Intune angelegt, es wird nichts paketiert oder hochgeladen – als dritte Karte unter „WinGet-Apps" war das fachlich falsch einsortiert. Der Bereich hat jetzt eine eigene Zuweisungskarte; bisher lieh er sich die Steuerelemente der Nachbarkarte, weshalb der Hinweis „oben unter *Zuweisen an*" auf eine Karte mit ganz anderem Titel zeigte.
- **Die bereitgestellte App bleibt im Blick.** Nach dem Bereitstellen wurde das Suchfeld geleert und die Liste ungefiltert neu geladen, sodass sie auf sämtliche Store-Apps des Tenants aufklappte und die gerade angelegte darin unterging. Jetzt wird nach der Paket-ID gefiltert und die neue App markiert.
- **Keine geliehenen Einstellungen mehr.** Filter, Fristen und Kategorien aus der WinGet-Karte wirkten still auf eine danach bereitgestellte Store-App. Der Bereich hat eigene Felder. Verfügbarkeitsdatum, Übermittlungsoptimierung und Auto-Update werden nicht mehr angeboten – Store-Apps unterstützen sie nicht, was bisher erst hinterher als Warnung erschien.

**Zuweisungen**

- **Gruppen-Favoriten je Kunde.** Häufig gebrauchte Entra-Gruppen lassen sich neben dem Gruppenfeld unter einem Namen speichern und erscheinen anschließend direkt in der Ziel-Auswahlliste. Die Favoriten sind an die Tenant-Domain gebunden: Gruppen eines Kunden tauchen bei einem anderen nie auf. Verfügbar an allen drei Stellen mit Zielauswahl.
- **Ein stiller Datenverlust beim Speichern.** `Save-Settings` serialisierte ohne Tiefenangabe; der Standard von zwei Ebenen hätte jeden Favoriten beim ersten Speichern in die Zeichenkette `System.Collections.Hashtable` verwandelt.

**Berichte und Rückmeldungen**

- **Der Leistungsnachweis zählt Updates statt Objekte.** Gingen mehrere alte Versionen auf dieselbe neue über, stand die App mehrfach untereinander und las sich, als wäre sie mehrfach aktualisiert worden. Jetzt eine Zeile je App und Zielversion, Vorgänger älteste zuerst.
- **„Bewusst behalten" ist kein Fehler mehr.** Die Bereinigung meldete Schutz und Fehler in derselben Zahl. Beides ist getrennt, und wer die Bereinigung selbst anstößt, bekommt je Version den konkreten Grund genannt – samt Hinweis, dass sich diese Versionen von selbst erledigen, sobald die Geräte gewechselt haben.

**Kleinere Verbesserungen**

- **Der Update-Suchlauf nach dem Login ist standardmäßig aus.** In großen Tenants durchsuchte er nach jeder Anmeldung jede App. Bereits gespeicherte Einstellungen behalten ihren Wert.
- Hinweis am Benachrichtigungsfeld, dass „unverändert" Intunes eigene Vorgabe bedeutet, und die ist „alle Popup-Benachrichtigungen anzeigen".
- Info-Symbol bei „Inhalt einer vorhandenen App ersetzen", das auch erklärt, wann man es *nicht* nehmen sollte und dass Erkennungsregeln dabei unangetastet bleiben.
- README erklärt jetzt, wie der Anmelde-Zwischenspeicher technisch funktioniert und was er für gemeinsam genutzte Rechner bedeutet.
- Testsuite auf 138 Prüfungen erweitert; der Test-Ambient lädt WinForms, weil auf einem sauberen CI-Runner sonst die Wiederholungslogik der Anmeldung fehlschlug.

## 0.15.4 – Versionsbereinigung funktioniert wieder, Tests, Bestätigungsdialog, Spaltenbeschriftung

**Berechtigungen und Konto**

- **Klar dokumentiert, welche Graph-Berechtigungen wofür gebraucht werden** – je Berechtigung mit Zweck und Angabe, ob lesend oder schreibend. Im README als eigener Abschnitt „Konto und Berechtigungen", in der Anwendung unter Hilfe → „Benötigte Berechtigungen".
- **Empfehlung gegen den globalen Administrator.** Für den Betrieb genügt die eingebaute Intune-Rolle *Application Manager*, für reine Auswertung *Read Only Operator*; empfohlen wird ein dediziertes Administrationskonto mit MFA, dessen Wirkungsbereich sich zusätzlich über Bereichs-Tags einschränken lässt. Dass die einmalige Zustimmung ein Entra-ID-Konto mit entsprechender Berechtigung braucht, der laufende Betrieb aber nicht, steht jetzt ebenfalls dabei.

**Aus einer externen Code-Durchsicht**

- **Der Versionsvergleich widersprach sich selbst.** `Test-IsNewerVersion` nutzte zuerst den `[version]`-Typ, der eine fehlende Komponente als `-1` zählt: `1.2.0` galt damit als neuer als `1.2`, während `Test-VersionsEquivalent` dieselbe Paarung als gleich betrachtete. Beide Funktionen werden im Suchlauf und in der Selbstaktualisierung nebeneinander benutzt; eine App konnte als update-bedürftig gemeldet werden, obwohl sie es nicht war. Es gibt jetzt nur noch einen Vergleichsweg.
- **Der Schutz vor Systemordnern war von der Schreibweise abhängig.** In derselben Zeile trafen zwei Vergleichsarten aufeinander: PowerShells `-eq` ignoriert Groß-/Kleinschreibung, .NETs `String.StartsWith` nicht. `c:\program files\…` passierte die Sperre, `C:\Program Files\…` nicht. Die Prüfung sitzt jetzt in einer eigenen, testbaren Funktion und vergleicht durchgängig ohne Rücksicht auf Schreibweise.
- **Die Gruppensuche kodierte den Suchbegriff nicht für die URL.** Ein Gruppenname mit `&`, `#` oder `%` zerlegte die Abfrage oder hängte eigene Parameter an.
- **Das veröffentlichte Release wurde nie geprüft.** Die Static Checks liefen vor dem Einsetzen der Repository-Kennung, danach nur noch ein Parser-Lauf – das Artefakt, das Anwender herunterladen, hatte die Prüfungen also nie durchlaufen. Sie laufen jetzt danach.
- Eine folgenlose, aber irreführende Verzweigung in der Erkennungsregel entfernt (beide Zweige lieferten `exists`).

**Tests**

- **Erste echte Testsuite: 101 Pester-Prüfungen** unter `tests/Unit`, ausgeführt in einem eigenen CI-Auftrag. Abgedeckt sind die Funktionen mit echter Logik: Versionsvergleich, Versionsgruppierung, Installationssonde samt Report-Rückfall, Leistungsnachweis, Sicherungsrotation, Anmelde-Wiederholung, Aufräum-Optionen und Systemordner-Schutz. Jeder in dieser Runde behobene Fehler hat eine Regressionsprüfung bekommen.

- **Der Leistungsnachweis erfasst jetzt auch alles andere.** Bisher zählte er ausschließlich Updates, weshalb eine Sitzung, die acht alte Versionen aufgeräumt hat, „noch keine Apps aktualisiert" meldete. Aufgezeichnet werden nun zusätzlich entfernte alte Versionen, gelöschte abgelöste Apps und Zuweisungsänderungen, jeweils in eigenen Abschnitten mit passender Zusammenfassung. Einträge aus älteren Fassungen ohne Typ werden weiterhin als Update gelesen.
- **Die Anzahl zu behaltender Versionen ist einstellbar.** Statt fest 2 lässt sich in den Einstellungen ein Wert zwischen 1 und 20 wählen. Der Knopf in der Karte der abgelösten Apps, sein Tooltip und die Checkbox übernehmen die Zahl sofort.
- **Der Update-Suchlauf nach dem Login ist jetzt standardmäßig aus.** Die Option „Beim Login nach Updates suchen" gab es schon, war aber voreingestellt aktiv; in großen Tenants durchsucht sie nach jeder Anmeldung jede App und lässt die Oberfläche lange laden. Wer den Automatismus will, aktiviert die Checkbox in den Einstellungen. Bereits gespeicherte Einstellungen behalten ihren bisherigen Wert.
- **Feature-Anfrage per E-Mail entfernt.** Der Menüpunkt, der Dialog und die darin hinterlegten Standard-Empfänger sind vollständig aus der Anwendung verschwunden. Es sind keine Kontaktadressen mehr im Programm enthalten.
- **Deutlicher Hinweis, wann die Versionsbereinigung eine Version stehen lässt.** Tooltip und Info-Text erklären jetzt, dass „neueste N behalten" eine Kandidatenliste ist: Entfernt wird erst, wenn Intune null Zuweisungen **und** null installierte Geräte meldet. Eine noch installierte ältere Version bleibt bewusst erhalten – auch wenn dadurch mehr als N Versionen übrig bleiben – und wird von einem späteren Lauf abgeräumt, sobald die Geräte gewechselt haben.

- **Der Installationszustand wird notfalls aus der Report-API gelesen.** In Tenants, die auf *jede* App-bezogene Navigationseigenschaft mit HTTP 400 antworten – `deviceStatuses`, `userStatuses` und `installSummary`, auf beta wie v1.0, mit und ohne Typ-Cast – blieb der Zustand dauerhaft unbekannt. Da unbekannt jede Löschung blockiert, meldete die Versionsbereinigung Lauf für Lauf „0 entfernt, N behalten" und konnte ihre Aufgabe nie erfüllen. Als dritte Quelle wird jetzt `getAppStatusOverviewReport` abgefragt – dieselbe Quelle, aus der auch das Intune-Portal den App-Installationsstatus zieht. Die Spalte wird über ihren Namen gesucht, und jede unerwartete Antwort ergibt weiterhin „unbekannt", blockiert also die Löschung, statt sie zu erlauben.
- Derselbe Fehler wirkte über die Bereinigung hinaus: Konsolidierungen räumten alte Objekte nie ab, und Updates unzugewiesener Apps wurden ohne Ablöse bereitgestellt.
- **Auch „Value cannot be null" wird bei der Anmeldung wiederholt.** Derselbe Wettlauf im Modul wie „Collection was modified", nur mit anderem Wortlaut; er wurde bisher als harter Fehler gemeldet und zwang zu einem manuellen zweiten Anmeldeversuch.
- Die Abschlusszeile der Versionsbereinigung sprach von „kept back (errors)", obwohl eine korrekt geschützte Version kein Fehler ist.

- **Die Versionsbereinigung zählte App-Objekte doppelt.** Sie liest die aktive und die abgelöste Bestandsliste und hängte beide ohne Abgleich aneinander. Liefert das Modul dieselbe App in beiden Listen – was vorkommt, kurz nachdem eine Ablöse angelegt wurde –, belegte dieser Doppeleintrag einen der „neueste N behalten"-Plätze und schob eine Version, die hätte bleiben sollen, in die Löschliste. Es wird jetzt über die GraphId entdoppelt.
- **Übersprungene Objekte werden einzeln protokolliert.** Wird ein App-Objekt aus dem aktiven Suchlauf ausgeschlossen, weil dieselbe GraphId bereits als abgelöst gemeldet wird, stand bisher nur eine Anzahl im Protokoll. Jetzt steht dort Name, Version und GraphId – genau diese Objekte sind für den Suchlauf auch als *wiederverwendbares Ziel* unsichtbar.

- **Der Bestätigungsdialog beschreibt jetzt die tatsächliche Konfiguration.** Bisher gab es zwei feste Absätze, gesteuert von einer einzigen Option. Ob die Zuweisungen auf die neue Version umziehen und ob danach ältere Versionen entfernt werden – beides verändert den Tenant – stand nicht darin. Der Hinweis wird nun aus allen drei wirksamen Einstellungen zusammengesetzt, inklusive der eingestellten Anzahl zu behaltender Versionen.
- **Spalte „Ziel in Intune" heißt jetzt „Zielversion".** „Ziel" wurde wiederholt als Zuweisungsziel gelesen, also als Aussage darüber, ob eine App zugewiesen ist. Die Spalte beantwortet aber, ob die Version, auf die aktualisiert wird, in Intune bereits als App existiert. Die Werte „neu anzulegen" und „bereits vorhanden" bleiben unverändert.

## 0.15.3 – Die Selbstaktualisierung hat noch nie funktioniert

- **Kein Speichern-Dialog mehr beim Aktualisieren.** Konnte der Pfad des laufenden Skripts nicht ermittelt werden, öffnete sich ein „Speichern unter"-Dialog – der die Frage an den Benutzer weiterreichte und obendrein nur eine Kopie anlegte, statt das laufende Skript zu ersetzen. Nach der Bestätigung läuft der Austausch jetzt ohne weitere Rückfrage durch; ist der Pfad unbekannt, wird das klar gemeldet.
- **Sicherungen werden rotiert.** Die Sicherung heißt jetzt `<Skript>.<Zeitstempel>.backup`, sodass sich auf eine bekannte Version zurückgehen lässt. Die beiden jüngsten bleiben erhalten, ältere werden beim nächsten Update entfernt – einschließlich der einzelnen `.backup`-Datei früherer Versionen. Schlägt das Löschen fehl, wird das protokolliert und das Update trotzdem abgeschlossen.

- **Die Update-Prüfung meldete immer „aktuell", unabhängig davon, was auf GitHub liegt.** Sie lief über einen `BackgroundWorker`; ein solcher Thread hat keinen PowerShell-Runspace, weshalb der übergebene Scriptblock überhaupt nicht ausgeführt wurde – nicht einmal sein eigenes `try/catch`. Der Aufrufer bekam `$null` zurück, und der Code deutete das als „kein Update verfügbar". Erkennbar war es nur an der Anzeige `GitHub version: vunknown`. Die Prüfung läuft jetzt wie jede andere lange Operation auf dem UI-Thread.
- **Ein Ergebnis ohne Version gilt nicht mehr als „aktuell".** Fehlt die Versionsangabe, wird das als fehlgeschlagene Prüfung gemeldet. Vorher war eine dauerhaft kaputte Prüfung nicht von „du bist auf dem neuesten Stand" zu unterscheiden.
- **`Invoke-AsyncOperation` entfernt.** Der Helfer war die Ursache und hatte nach der Umstellung keinen Aufrufer mehr; 25 Kommentare, die eine Umstellung *auf* ihn empfahlen, wurden korrigiert. Dieselbe Ursache hatte seinerzeit die leeren Dashboard-Kacheln.

## 0.15.2 – Laufzeit des Update-Laufs, blockierender Hintergrund-Dialog, Anmeldung

- **Kein automatischer Suchlauf mehr nach einem Update.** Nach jedem Durchlauf wurde der Tenant komplett neu eingelesen und für jedes Paket erneut WinGet befragt – rund 10–15 Sekunden ungefragtes Warten. Die Zeilen erfolgreich aktualisierter Apps verschwinden weiterhin sofort aus der Liste; eine erneute Prüfung startet nur noch „Updates suchen“.
- **Blockierender Dialog hinter dem Fenster behoben.** Die automatische Versionsbereinigung stieß am Ende eine Ansichtsaktualisierung an, während der Fortschrittsbalken noch lief. Das lief in die „Es läuft bereits ein Vorgang“-Sperre und öffnete einen modalen Dialog – meist hinter dem Hauptfenster, wo er den Durchlauf anhielt, bis ihn jemand fand (in einem Lauf 58 Sekunden).
- **Versionsbereinigung funktioniert in Tenants, deren `deviceStatuses` mit HTTP 400 antwortet.** Dort blieb der Installationszustand dauerhaft „unbekannt“, und weil unbekannt jede Löschung blockiert, wurde nie eine alte Version entfernt – „0 entfernt, N behalten“, Lauf für Lauf. Als Rückfallebene wird jetzt `installSummary` abgefragt; erst wenn auch das scheitert, bleibt der Zustand unbekannt.
- **Doppelte Abfragen entfernt.** Bei der Konsolidierung auf ein vorhandenes Ziel wurden Zuweisungs- und Installationszustand zweimal hintereinander abgefragt, obwohl dazwischen nichts verändert wurde.
- **Anmeldung übersteht kurzlebige Fehler.** Die erste Intune-Abfrage nach dem Login scheiterte gelegentlich mit „Collection was modified“ – ein Wettlauf im Modul, kein Anmeldeproblem – und wurde als Authentifizierungsfehler gemeldet. Solche Fehler (auch Drosselung, 503/504) werden jetzt bis zu dreimal wiederholt. Eine fehlende Berechtigung scheitert weiterhin sofort.
- **Zeiten im Protokoll getrennt.** Upload und das anschließende Auflösen der neuen App werden einzeln gemessen, damit ein langsamer Lauf zuzuordnen ist.

## 0.15.1 – Schutz vor unbeabsichtigtem Löschen der Vorgängerversion

- **Vorgänger wird nur noch gelöscht, wenn die neue Version nachweislich zugewiesen ist.** Bisher genügte als Nachweis, dass die alte App keine Zuweisung mehr hat – das trifft auch zu, wenn die Übergabe stillschweigend fehlgeschlagen ist. Jetzt wird die neue App direkt abgefragt (mit Wiederholungen, weil Intune kurz nach dem Zuweisen verzögert antwortet); ohne bestätigte Zuweisung bleibt die alte Version stehen. Gilt für die Ablöse nach einem Upload ebenso wie für die Konsolidierung auf ein bereits vorhandenes Ziel.
- **Die beiden Aufräum-Optionen schließen sich jetzt technisch aus.** „Auch zugewiesene alte App-Version nach erfolgreichem Update entfernen“ und „nur die neuesten N Versionen behalten“ konnten gleichzeitig aktiv sein; die erste läuft im Update, die zweite erst danach – dadurch wurde der Vorgänger gelöscht, obwohl die zweite Option ihn behalten sollte. Das Anhaken der einen schaltet die andere ab, und eine bereits gespeicherte Kombination wird beim Start zugunsten der nicht-löschenden Option aufgelöst und einmalig erklärt.

## 0.15.0 – Erste öffentliche Beta

Erste als Beta gekennzeichnete Veröffentlichung. Funktionen und Bedienabläufe können sich zwischen Versionen noch ändern; für den produktiven Einsatz ist die Anwendung nicht freigegeben.

**Funktionsumfang**

- **WinGet-Apps** suchen, Version wählen, lokal als Intune-Win32-Paket erstellen und nach Bestätigung bereitstellen – einschließlich Zielgruppe, Intent, Filtern, Benachrichtigungen und Fristen.
- **Microsoft-Store-Apps** über den Store-Katalog suchen, aus den Treffern auswählen und bereitstellen. Bereits im Tenant vorhandene Store-Apps werden angezeigt, um Doppelbereitstellungen zu vermeiden.
- **Updates** vorhandener Intune-Apps gegen WinGet und den WinTuner-Index prüfen. Die Ergebnisliste trennt erforderliche Uploads von reiner Nacharbeit und weist Konflikte wie doppelt vorhandene Versionen aus, statt sie stillschweigend auszulassen.
- **Alle Tenant-Apps** einsehen – jedes App-Objekt jeden Typs, auch solche, die diese Oberfläche nicht paketiert. Zuweisungen werden im Klartext angezeigt und lassen sich verwalten: Gruppen und Ausschlüsse hinzufügen oder entfernen, Absicht festlegen, Bereitstellungseinstellungen ändern. Gruppen können optional über ihren Namen gesucht werden.
- **Eigene Installer** paketieren: beliebige EXE- oder MSI-Installer zu einem `.intunewin`-Paket verarbeiten, auch Software, die es in WinGet nicht gibt.
- **Erkennungsregel ermitteln**: MSI-Produktcode direkt auslesen, oder die Uninstall-Registrierung vor und nach einer Installation vergleichen und daraus eine fertige Intune-Erkennungsregel ableiten. Silent-Schalter lassen sich in der Windows Sandbox testen, ohne den eigenen Rechner zu verändern.
- **Inhalt vorhandener Apps ersetzen**, statt eine zweite App anzulegen und die alte abzulösen. App-ID, Zuweisungen und Historie bleiben erhalten.
- **Erkannte Software** aus dem Intune-Inventar auswerten und WinGet-Paketen zuordnen.
- **Alte App-Versionen bereinigen** – nur nach erneuter Prüfung von Zuweisungen und gemeldeten Installationen; risikoreiche Optionen sind standardmäßig aus.
- **Lokale Pakete und Favoriten** pflegen, optional automatisch beim Start prüfen.
- Deutsche und englische Oberfläche, mehrere Darstellungsmodi, wöchentliche Aktivitätsprotokolle.

**Sicherheit**

- Pakete werden unter `%LOCALAPPDATA%\WinTunerGUI\Packages` erstellt. Ein gemeinsam beschreibbarer Ablageort ist bewusst nicht voreingestellt, damit ein fertiges Paket zwischen Erstellung und Upload nicht von anderen Benutzern des Rechners verändert werden kann.
- Jede Änderung an Intune erfordert eine ausdrückliche Bestätigung; das Ändern von Zuweisungen zeigt vorher die vollständige Liste, die geschrieben wird.
- Keine Kennwörter, Token oder Zugangsdaten im Skript oder in der Einstellungsdatei. Die Anmeldung läuft über Microsoft Entra ID.
- Die Selbstaktualisierung akzeptiert nur Releases mit passendem Asset, SHA-256-Prüfsumme und plausibler Versionsnummer und legt vorher eine Sicherung an.
