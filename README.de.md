# WinTuner GUI

[English](README.md) · **Deutsch**

Eine Windows-Oberfläche zur Verwaltung von WinGet-, Win32- und Microsoft-Store-Apps in Microsoft Intune.

Paketierung, Bereitstellung, Versionsvergleich, Zuweisungen und die kontrollierte Ablösung alter App-Versionen an einer Stelle, mit zweisprachiger Oberfläche (Deutsch und Englisch). Aufgebaut auf dem PowerShell-Modul [WinTuner](https://github.com/svrooij/WinTuner), WinGet und Microsoft Graph.

> [!WARNING]
> **Beta. Nicht für den produktiven Einsatz freigegeben.** Siehe [Projektstatus](#projektstatus).

> [!IMPORTANT]
> Je nach gewählter Aktion verändert WinTuner GUI Apps und Zuweisungen in Microsoft Intune. Pakete, Erkennungsregeln, Anforderungsregeln und Zuweisungen sollten vor dem produktiven Einsatz in einem Test-Tenant oder mit einer Testgruppe geprüft werden.

---

## Inhalt

- [Schnellstart](#schnellstart)
- [Funktionsumfang](#funktionsumfang)
- [Was die einzelnen Bereiche tun](#was-die-einzelnen-bereiche-tun)
- [Sicherheitskonzept](#sicherheitskonzept)
- [Anmeldung und Sitzung](#anmeldung-und-sitzung)
- [Voraussetzungen](#voraussetzungen)
- [Konto und Berechtigungen](#konto-und-berechtigungen)
- [Ein typischer Ablauf](#ein-typischer-ablauf)
- [Erste Kundenumgebung und Dauerbetrieb](#erste-kundenumgebung-und-dauerbetrieb)
- [Grenzen und Verantwortung](#grenzen-und-verantwortung)
- [Projektstatus](#projektstatus)
- [Lizenz und Herkunft](#lizenz-und-herkunft)

---

## Schnellstart

Das Repository muss **nicht** geklont werden. Eine einzige Datei genügt:

```text
WinTuner_GUI_ntg.ps1
```

1. Die Seite [Neueste Version](../../releases/latest) öffnen.
2. Den Bereich **Assets** aufklappen.
3. Ausschließlich **`WinTuner_GUI_ntg.ps1`** herunterladen. Quellcode und die ZIP-Archive von GitHub werden zum Betrieb nicht gebraucht.
4. PowerShell 7 im Downloadordner öffnen und starten:

   ```powershell
   Unblock-File -LiteralPath '.\WinTuner_GUI_ntg.ps1'
   & '.\WinTuner_GUI_ntg.ps1'
   ```

> [!NOTE]
> Windows blockiert aus dem Internet geladene Skripte beim ersten Start. `Unblock-File` entfernt diese Markierung. Alternativ per Rechtsklick auf die Datei, **Eigenschaften**, dann **Zulassen** ankreuzen.

Das zweite Asset, `WinTuner_GUI_ntg.ps1.sha256`, ist optional und dient nur dazu, die Prüfsumme des Downloads zu kontrollieren.

**Fehlende Voraussetzungen werden abgefangen.** Fehlt PowerShell 7, bietet das Skript Installation oder Aktualisierung über WinGet an. Das benötigte Modul `WinTuner` lässt sich nach Bestätigung für den aktuellen Benutzer aus der PowerShell Gallery installieren. Das Modul `Microsoft.Graph` muss vorhanden sein; fehlt es, zeigt die Anwendung den passenden Hinweis.

**Aktualisieren.** Die Anwendung kann beim Start nach neuen Releases sehen und ihre eigene Datei ersetzen; die Suche beim Start lässt sich unter „Einstellungen › Updates dieses Programms" abschalten, dann bleibt der Knopf dort der einzige Weg. Vorher legt sie eine Sicherung neben dem Skript ab (`WinTuner_GUI_ntg.ps1.<Zeitstempel>.backup`) und behält die beiden jüngsten.

---

## Funktionsumfang

**WinGet-Apps suchen und paketieren**
Den öffentlichen WinGet-Katalog durchsuchen, eine Version auswählen und lokal als Intune-Win32-Paket erstellen.

**In Microsoft Intune bereitstellen**
Neue Win32-Apps hochladen und wahlweise als verfügbar, erforderlich oder zur Deinstallation zuweisen. Zielgruppen, Filter, Benachrichtigungen, Fristen und weitere Zuweisungseinstellungen stehen in der Oberfläche zur Verfügung.

**Microsoft-Store-Apps verwalten**
Store-Apps über Namen oder Paket-ID auflösen, im Tenant suchen und bereitstellen. Bereits vorhandene Apps werden erkannt, damit nichts doppelt bereitgestellt wird.

**Bereitgestellte Apps auf Updates prüfen**
Win32-Apps in Intune mit aktuellen WinGet-Versionen vergleichen. Die Ergebnisliste unterscheidet zwischen erforderlichem neuen Upload, Wiederverwendung eines bereits vorhandenen Ziels und offener Nacharbeit.

**Updates kontrolliert ausrollen**
Eine neue Zielversion paketieren oder eine vorhandene wiederverwenden, Zuweisungen übernehmen und Vorgänger über Intune-Supersedence ablösen.

**Alte Versionen sicher bereinigen**
Abgelöste oder ungenutzte App-Objekte ermitteln. Automatisch gelöscht wird erst, nachdem Zuweisungen und erfolgreiche Installationen erneut geprüft wurden. Die risikoreichen Optionen sind standardmäßig aus.

**Eigene Installer paketieren und App-Inhalte ersetzen**
Beliebige EXE- oder MSI-Installer zu einem `.intunewin`-Paket verarbeiten, auch Software, die es in WinGet nicht gibt. Zusätzlich lässt sich der Inhalt einer vorhandenen Intune-App direkt ersetzen: App-ID, Zuweisungen und Historie bleiben unverändert, es entsteht kein zweites App-Objekt und nichts wird abgelöst.

**Erkennungsregel ermitteln**
Bei einer MSI genügt ein Klick, um Produktcode und Version auszulesen. Bei einer EXE wird die Uninstall-Registrierung vor und nach einer Installation verglichen; daraus entsteht eine fertige Intune-Erkennungsregel mit Schlüsselpfad, Wertname und Vergleichswert. Silent-Schalter lassen sich vorher in der Windows Sandbox ausprobieren, ohne den eigenen Rechner zu verändern.

**Alle Apps des Tenants einsehen und zuweisen**
Sämtliche App-Objekte jeden Typs auflisten, auch solche, die diese Oberfläche nicht paketiert (MSI, UWP/MSIX, Microsoft 365 Apps, Weblinks). Zuweisungen werden im Klartext angezeigt und lassen sich verwalten: Gruppen und Ausschlüsse hinzufügen oder entfernen, Absicht festlegen, Benachrichtigungen, Fristen und Neustartverhalten anpassen. Gruppen können optional über ihren Namen gesucht werden.

**Erkannte Software auswerten**
Das Intune-Inventar erkannter Apps laden, die üblichen Treiber- und OEM-Einträge herausfiltern und geeignete Anwendungen WinGet-Paketen zuordnen. Ausgewählte Treffer lassen sich anschließend unter Verwaltung nehmen.

**Lokale Pakete und Favoriten aktuell halten**
Häufig verwendete WinGet-Pakete als Favoriten speichern und optional beim Start prüfen lassen. Fehlende Versionen werden heruntergeladen oder lokal erstellt. **Alle lokalen Apps aktualisieren** prüft den gesamten Paketordner und bringt ihn in einem Durchgang auf Stand, ohne bereits aktuelle Versionen neu zu bauen.

**Tenant-Übersicht und Protokollierung**
Ein Dashboard für verwaltete Apps, verfügbare Updates und abgelöste Versionen. Aktionen und Fehler werden in einem lokalen Wochenprotokoll festgehalten.

**Anpassbare Oberfläche**
Deutsche und englische Oberfläche, mehrere Darstellungsmodi sowie lokal gespeicherte Einstellungen und zuletzt verwendete Anmeldungen.

---

## Was die einzelnen Bereiche tun

| Bereich | Datenquelle | Wirkung |
|---|---|---|
| Dashboard | Microsoft Intune | Nur lesende Übersicht über Apps, Updates und abgelöste Versionen. Die vierte Kachel misst den lokalen Paketordner |
| WinGet-Apps | WinGet und lokaler Paketordner | Sucht Pakete, erstellt sie lokal und lädt sie nach Bestätigung zu Intune hoch. Enthält auch die Favoriten für lokale Pakete: optional beim Start geprüft, und auf Wunsch werden alle gültigen lokalen Pakete aktualisiert |
| Microsoft Store | Microsoft Store und Intune | Durchsucht den Store-Katalog, zeigt Treffer zur Auswahl, stellt nach Bestätigung bereit, dazu eine Übersicht bereits bereitgestellter Store-Apps |
| Updates | Intune, WinGet und WinTuner-Index | Vergleicht Versionen, erstellt oder verwendet eine Ziel-App und übergibt auf Wunsch die Zuweisungen. Enthält auch die Versionsbereinigung, die alte App-Objekte nur löscht, wenn die konfigurierten Sicherheitsbedingungen erfüllt sind |
| Erkannte Apps | Intune-Inventar und WinGet | Ordnet installierte Software möglichen WinGet-Paketen zu. Der Scan selbst ist nur lesend |
| Alle Tenant-Apps | Intune | Listet jedes App-Objekt jeden Typs. Zuweisungen werden gelesen und können geändert werden, was nach Intune schreibt |
| Eigene Installer | Lokale Dateien und Intune | Paketiert beliebige EXE oder MSI lokal zu `.intunewin`. Das Ersetzen des Inhalts einer vorhandenen App schreibt nach Intune |
| Lokale Pakete | WinGet und lokaler Paketordner | Pflegt Paketkopien auf diesem Rechner: gemerkte Pakete prüfen und neuere herunterladen. Legt nichts in Intune an |
| Einstellungen | Lokale Einstellungsdatei und Intune | Paket- und Protokollordner, Sprache, Darstellung, Aufräum-Optionen und gespeicherte Gruppen-Favoriten. Hier wird der Tenant nicht selbst verändert; die Optionen entscheiden, was die anderen Bereiche dürfen |

Die Oberfläche installiert keine Software auf Endgeräten. Sie erstellt und verwaltet App-Objekte und Zuweisungen in Intune; die eigentliche Verteilung und Auswertung übernimmt anschließend Microsoft Intune.

---

## Sicherheitskonzept

- Intune wird erst nach einer bewussten Benutzeraktion verändert.
- Doppelte Uploads derselben Paketversion werden vor der Bereitstellung erkannt und blockiert.
- Vor jeder Bereinigung werden Zuweisungen und gemeldete erfolgreiche Installationen erneut abgefragt.
- Zugewiesene Vorgänger werden nur unter den ausdrücklich aktivierten Bedingungen entfernt.
- Kennwörter, Token und andere Geheimnisse werden weder im Skript noch in der Einstellungsdatei gespeichert. Die Authentifizierung läuft über Microsoft Entra ID und Microsoft Graph.
- Einstellungen, zuletzt verwendete Kontonamen und Protokolle bleiben lokal, im Windows-Benutzerprofil oder neben der Anwendung.
- Pakete entstehen standardmäßig unter `%LOCALAPPDATA%\WinTunerGUI\Packages`. Dieses Verzeichnis gehört dem angemeldeten Benutzer. Ein gemeinsam beschreibbarer Ort wie `C:\Temp` ist bewusst nicht mehr voreingestellt, weil dort jeder Benutzer des Rechners ein fertiges Paket zwischen Erstellung und Upload verändern könnte.
- Das Ändern von Zuweisungen unter **Alle Tenant-Apps** ersetzt immer den vollständigen Zuweisungssatz einer App, denn Microsoft Graph kennt keine Teilaktualisierung. Der Dialog zeigt die zu schreibende Liste vorher an und fragt nach.
- Das Ersetzen des Inhalts einer vorhandenen App verändert **nicht** deren Erkennungs- und Anforderungsregeln. Sie müssen zur neuen Version passen und sind vorher zu prüfen.
- Die Selbstaktualisierung akzeptiert nur Releases mit passendem Skript-Asset, SHA-256-Prüfsumme und plausibler interner Versionsnummer. Vor dem Austausch wird eine Sicherung angelegt. Nach der Bestätigung läuft der Austausch ohne weitere Rückfragen, die beiden jüngsten Sicherungen bleiben erhalten.

### Trennen und Abmelden

| Aktion | Aktuelle Sitzung | Zwischengespeicherte Sitzung | Nächste Anmeldung |
|---|---|---|---|
| **Trennen** | wird beendet | bleibt erhalten | sofort, ohne Rückfrage |
| **Abmelden** | wird beendet | wird gelöscht (der Windows-Anmeldedienst wird umgangen, das Benutzernamenfeld geleert) | echte, interaktive Anmeldung |

**Faustregel:** Kundenwechsel oder gemeinsam genutzter Rechner bedeutet **Abmelden**. Alles andere **Trennen**.

Warum dieser Unterschied wichtig ist, erklärt der folgende Abschnitt.

---

## Anmeldung und Sitzung

Hier steht, warum nach der ersten Anmeldung meist kein Kennwort mehr abgefragt wird, wo diese Sitzung liegt und was das für die Sicherheit bedeutet. Denselben Text gibt es in der Anwendung unter **Hilfe → „Anmeldung und Sitzung erklärt"**.

### Was gespeichert wird und was nicht

Kennwort und MFA werden **nicht** gespeichert. Die Anmeldung läuft über Microsoft Entra ID, das nach erfolgreicher interaktiver Anmeldung zwei Token ausstellt:

- ein **Zugriffstoken**, kurzlebig mit rund einer Stunde Gültigkeit, das bei jedem Graph-Aufruf mitgeht;
- ein **Aktualisierungstoken**, länger gültig, mit dem im Hintergrund ein frisches Zugriffstoken beschafft wird, ohne erneut zu fragen.

Das Aktualisierungstoken ist der schützenswerte Teil. Wer es besitzt, kann daraus neue Zugriffstoken erzeugen, bis es abläuft oder zentral widerrufen wird.

### Wo die Sitzung liegt

Der Zwischenspeicher wird von der darunterliegenden Microsoft Authentication Library (MSAL) verwaltet und liegt im Windows-Benutzerprofil:

```text
%LOCALAPPDATA%\.IdentityService\   (Dateien mg.msal.cache*)
```

Unter Windows verschlüsselt MSAL diesen Zwischenspeicher mit der **Data Protection API (DPAPI)** im Benutzerkontext. Entschlüsseln kann ihn nur **derselbe Windows-Benutzer auf demselben Gerät**. Ein anderer lokaler Benutzer sieht die Datei, kann sie aber nicht lesen. Übertragen auf ein anderes Gerät oder Konto lässt sich der Zwischenspeicher nicht, und er läuft ab. Richtlinien für bedingten Zugriff oder MFA können ihn früher beenden.

### Warum die nächste Verbindung ohne Abfrage klappt

Beim erneuten Verbinden findet MSAL das Aktualisierungstoken und tauscht es still gegen ein neues Zugriffstoken. Zusätzlich kann der Windows-Anmeldedienst (WAM) ein auf dem Gerät bereits angemeldetes Konto wiederverwenden. Deshalb bleibt die Kennwort- und MFA-Abfrage in der Regel aus.

### Was das für die Sicherheit bedeutet

DPAPI schützt die Sitzung gegen *andere Benutzer* des Rechners. Es schützt nicht gegen Code, der **als der angemeldete Benutzer** läuft. Schadsoftware oder ein Skript unter demselben Windows-Konto kann DPAPI genauso aufrufen und das Aktualisierungstoken auslesen.

Bei einem Werkzeug, das Kundentenants verwaltet, ist ein liegengebliebener Zwischenspeicher auf einem geteilten Technikerrechner deshalb potenziell stiller Zugriff auf einen Kundentenant, bis das Token abläuft oder widerrufen wird. Genau darum sollte vor einem Kundenwechsel und auf gemeinsam genutzten Rechnern abgemeldet und nicht nur getrennt werden.

### Zwei Dinge, die leicht übersehen werden

- Der Zwischenspeicher gehört dem Modul `Microsoft.Graph` und ist **gemeinsam**, nicht privat für diese Anwendung. Abmelden beendet deshalb auch die zwischengespeicherte Sitzung **anderer** PowerShell-Werkzeuge desselben Windows-Benutzers.
- Abmelden löscht nur die **lokale** Kopie. Das Aktualisierungstoken bleibt bei Entra ID gültig und ist damit **nicht widerrufen**. Bei echtem Verdacht auf ein kompromittiertes Konto oder Gerät reicht Abmelden nicht: Dann müssen die Sitzungen zusätzlich zentral im Entra-Portal widerrufen werden.

### Wie viele Anmeldeadressen gemerkt werden

Das Auswahlfeld neben dem Adressfeld bietet die zuletzt benutzten Adressen an, die neueste zuerst. Gemerkt werden standardmäßig **15**; alles darüber fällt hinten heraus. Die Liste ist reine Bequemlichkeit — sie schlägt eine Adresse vor, sie hält keine Sitzung offen.

Wer mehr Kunden betreut, setzt `MaxRecentLogins` in der Einstellungsdatei hoch (1 bis 50, alles außerhalb fällt auf 15 zurück):

```text
%APPDATA%\WinTunerGUI\settings.json
```

```powershell
# vorher die Anwendung schliessen - sie schreibt diese Datei beim Beenden
$p = "$env:APPDATA\WinTunerGUI\settings.json"
$s = Get-Content -Raw -LiteralPath $p | ConvertFrom-Json
$s.MaxRecentLogins = 20
$s | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $p -Encoding utf8
```

> [!NOTE]
> In einer länger genutzten Installation kann dort noch `MaxRecentLogins = 8` stehen. Das war in früheren Versionen die Vorgabe, und eine bestehende Einstellungsdatei behält ihren Wert — eine erhöhte Vorgabe gilt nur für neue Installationen. Wenn die Liste bei acht Einträgen stehenbleibt, ist das der Grund.

---

## Voraussetzungen

- Windows 10, Windows 11 oder Windows Server mit grafischer Oberfläche
- PowerShell 7.4 oder neuer
- WinGet / App Installer für WinGet- und Microsoft-Store-Abfragen
- Die PowerShell-Module `WinTuner` und `Microsoft.Graph`
- Eine Microsoft-Intune-Lizenz im **Ziel-Tenant**, der verwaltet werden soll
- Ein in diesem **Ziel-Tenant** zugelassenes Konto mit den unten genannten Berechtigungen
- Internetzugriff auf die Microsoft-, WinGet- und optionalen GitHub-Endpunkte

> [!NOTE]
> Lizenz- und Berechtigungsanforderungen beziehen sich immer auf den gewählten **Ziel-Tenant**. Maßgeblich ist das Konto, mit dem angemeldet wird, und dessen Berechtigungen in genau dem Tenant, dessen Intune-Apps verwaltet werden sollen.

---

## Konto und Berechtigungen

### Ein dediziertes Konto verwenden, keinen globalen Administrator

**Für den Betrieb ist die Rolle „Globaler Administrator" nicht erforderlich, und wir raten davon ab, eine zu verwenden.** Das Werkzeug legt Intune-Apps an, ändert Zuweisungen und löscht App-Objekte. Mehr Rechte vergrößern nur den Schaden, den ein Fehlgriff oder ein kompromittiertes Konto anrichten kann.

Empfohlen wird ein **eigenes Administrationskonto** ausschließlich für diese Aufgabe, mit Multifaktor-Authentifizierung und ohne Postfach- oder Endanwenderfunktion. In Intune genügt die eingebaute Rolle:

| Aufgabe | Passende Intune-Rolle |
|---|---|
| Apps bereitstellen, aktualisieren, zuweisen, löschen | **Application Manager** |
| Nur auswerten, nichts verändern | **Read Only Operator** |

**Application Manager** deckt genau den Funktionsumfang ab: Mobile Apps lesen, anlegen, ändern, zuweisen, löschen und in Beziehung setzen (Ablöse), dazu verwaltete Geräte lesen. Microsoft selbst empfiehlt, für die tägliche Intune-Administration diese Intune-Rollen zu verwenden und Entra-ID-Rollen mit Intune-Zugriff zu meiden, weil die meisten davon als privilegiert gelten.

Der Wirkungsbereich lässt sich über **Bereichs-Tags (Scope Tags)** und Bereichsgruppen weiter einschränken, sodass ein Konto nur bestimmte Apps oder Gerätegruppen verwalten darf.

> [!IMPORTANT]
> Die **einmalige** Zustimmung zu den Microsoft-Graph-Berechtigungen benötigt ein Konto, das sie erteilen darf, zum Beispiel Anwendungsadministrator oder Cloudanwendungsadministrator. Das geschieht einmal je Tenant bei der Ersteinrichtung. Für den laufenden Betrieb genügt danach das Konto mit der Intune-Rolle.

### Microsoft-Graph-Berechtigungen (delegiert)

Die Anmeldung läuft über das Modul `WinTuner` und dessen App-Registrierung und fordert `https://graph.microsoft.com/.default` an, also genau den im Tenant zugestimmten Umfang. Fachlich benötigt die Anwendung:

| Berechtigung | Wofür | Art |
|---|---|---|
| `DeviceManagementApps.ReadWrite.All` | Intune-Apps lesen und schreiben: Bereitstellen, Aktualisieren, Ablösen, Löschen, Zuweisungen und deren Einstellungen, Installationsberichte | Schreibend |
| `DeviceManagementManagedDevices.Read.All` | Das Inventar „Erkannte Apps" (`/deviceManagement/detectedApps`) | Lesend |
| `Group.Read.All` | **Optional.** Nur für die Suche nach Entra-ID-Gruppen *anhand ihres Namens* unter „Alle Tenant-Apps" | Lesend |

`Group.Read.All` wird bei der Anmeldung **bewusst nicht** angefordert. Die Anwendung fragt separat und mit Erklärung danach, erst wenn die Namenssuche tatsächlich benutzt wird. Ohne diese Berechtigung funktioniert alles Übrige unverändert, Gruppen lassen sich über ihre Objekt-ID zuweisen.

Wer die Anwendung **ausschließlich zur Auswertung** einsetzt (Dashboard, Update-Suchlauf, Tenant-Übersicht, erkannte Apps), kommt fachlich mit `DeviceManagementApps.Read.All` statt `.ReadWrite.All` aus. Ein eigener Nur-Lesen-Modus, der beim Anmelden nur diesen Umfang anfordert, ist geplant, aber noch nicht umgesetzt.

Je nach Tenant können zusätzlich Administratorzustimmung, Richtlinien für bedingten Zugriff oder weitere organisatorische Freigaben nötig sein.

---

## Ein typischer Ablauf

1. Mit dem gewünschten Microsoft-365-Tenant verbinden.
2. Neue Apps über WinGet oder den Microsoft Store auswählen, einen eigenen Installer paketieren oder vorhandene Intune-Apps auf Updates prüfen.
3. Paketversion, Zielgruppe, Absicht und erweiterte Zuweisungseinstellungen kontrollieren.
4. Paketierung beziehungsweise Bereitstellung ausdrücklich bestätigen.
5. Ergebnis in Intune und im lokalen Aktivitätsprotokoll prüfen.

Für ein Update gibt es zwei Wege. Die neue Version als eigene App bereitstellen und die alte ablösen (Standard unter **Updates**), oder den Inhalt der vorhandenen App ersetzen (**Eigene Installer**). Der zweite Weg vermeidet mehrere App-Objekte je Produkt, setzt aber voraus, dass die Erkennungsregeln weiterhin passen.

---

## Erste Kundenumgebung und Dauerbetrieb

Das Werkzeug ist auf einen **Dauerzustand** hin gebaut: einmal eingerichtet, hält ein wiederkehrender Lauf die Apps eines Tenants ohne Handarbeit aktuell. Dieser Zustand stellt sich aber nicht von allein beim ersten Lauf ein — eine Umgebung, die bisher nicht über WinTuner beziehungsweise WinGet betreut wurde, braucht **einmal** eine genauere Betrachtung. Danach nie wieder.

### Der Dauerbetrieb: wenige Schalter, und die Ablösung läuft von selbst

Der Regelbetrieb hängt an drei Einstellungen. Zusammen ergeben sie eine geschlossene Kette: neue Version paketieren → hochladen → Vorgänger ablösen → Zuweisung umziehen → alte Version aufräumen. Nichts bleibt liegen, und niemand muss im Portal nacharbeiten.

| Einstellung | Was sie im Dauerbetrieb leistet |
|---|---|
| **Gruppenzuweisung auf die neue Version umziehen (alte Version entziehen)** | Ohne sie tragen nach dem Update **beide** Versionen die Zuweisung, und jemand muss die alte im Portal von Hand entziehen. Das ist der Schalter, der aus „ein Update wurde bereitgestellt" ein „die neue Version ist tatsächlich im Einsatz" macht. |
| **Vorgänger-Version direkt nach einem erfolgreichen Update löschen** *oder* **Nur die neuesten N Versionen je Paket behalten** | Beide räumen die abgelösten App-Objekte weg — die Kachel **Abgelöste Versionen** wächst sonst mit jedem einzelnen Update weiter. Die beiden Optionen schließen einander aus: entweder sofort löschen oder eine Anzahl behalten. Gelöscht wird in beiden Fällen erst, nachdem Zuweisungen und erfolgreiche Installationen erneut geprüft wurden. |
| **Auch Win32-Apps ohne WinTuner-Marke prüfen** | Die Marke im Notizfeld sagt nur, **wer** eine App angelegt hat — nicht, ob es eine neuere Version gibt. Ohne diesen Schalter bleibt alles unsichtbar, was von Hand oder mit einem anderen Werkzeug angelegt wurde, und genau das ist in einer übernommenen Umgebung die Mehrheit. |

Sind diese Schalter gesetzt und die Zuordnungen einmal geprüft, kann ein Lauf über **Alle aktualisieren** ohne einen einzigen Klick durchlaufen (**Rückfragen vor Änderungen in Intune überspringen**). Geschützte Apps fragen weiterhin nach — diese eine Rückfrage lässt sich bewusst nicht wegdrücken.

### Es wird leichter, sobald jede App einmal durch dieses Werkzeug gelaufen ist

Die Zuordnung „welche Intune-App ist welches WinGet-Paket" ist das eine, was dieses Werkzeug nicht verlässlich raten kann. Es muss auch nicht raten, wenn die Antwort aufgeschrieben ist — und sie ist aufgeschrieben, sobald eine App über WinTuner angelegt oder abgelöst wurde: im **Notizfeld** der App in Intune steht dann eine Marke der Form

```
[WinTuner|winget|Google.Chrome]
```

Diese Marke enthält die **Paket-Id**, und sie zu lesen ist eindeutig — kein Namensvergleich, kein Ähnlichkeitswert, keine Mehrdeutigkeit. Die erste Runde ist also die teure, und jede App, die einmal über dieses Werkzeug abgelöst wurde, lässt das Raten endgültig hinter sich. In einer Umgebung, in der jede App einmal durchgelaufen ist, ist die Update-Suche nur noch ein Nachschlagen.

Zwei Folgen, die man kennen sollte:

- **Das Notizfeld in Ruhe lassen.** Wer es im Intune-Portal leert oder überschreibt, wirft die Paket-Id weg. Die App verschwindet damit nicht aus der Suche — sie fällt auf die Zuordnung über den Anzeigenamen zurück (siehe die erste Runde unten), und bleibt die mehrdeutig, steht sie als **gesperrte Zeile** da statt als Update. Wer das Notizfeld für eigene Anmerkungen nutzt, schreibt sie **neben** die Marke, nicht darüber.
- **Eine von Hand geschriebene Notiz zählt auch.** Ein Notizfeld, in dem nur `mit WinGet installiert: Google.Chrome` oder `WinTuner - Zoom.ZoomRooms` steht, wird ebenfalls gelesen, solange die Id wie `Hersteller.Produkt` aussieht. Das ist eine bewusste zweite Chance für Apps, deren Marke irgendwann entfernt wurde. Sie kann eine Id aber immer nur **hinzufügen**: eine so gelesene App bleibt in der Liste der unmarkierten Apps und wird weiter dort geprüft.

Das alles ersetzt den Schalter **Auch Win32-Apps ohne WinTuner-Marke prüfen** nicht — der entscheidet, ob unmarkierte Apps überhaupt angesehen werden. Die Marke entscheidet, wie genau eine angesehene App zugeordnet werden kann.

### Warum die erste Runde anders ist

In einer frisch übernommenen Umgebung stammt **keine** App aus diesem Werkzeug. Daraus folgen vier Dinge, die es später nicht mehr gibt:

- **Es gibt keine Zuordnung zu WinGet.** Weder eine Marke noch eine Paket-Id im Notizfeld; nur einen Anzeigenamen, den jemand frei gewählt hat. Die Zuordnung Name → WinGet-Id ist deshalb der kritische Schritt der ersten Runde. Übernommen wird sie nur bei einem **exakten** Namenstreffer, einem klar dominierenden Treffer oder einer hinterlegten Zuordnung — alles Mehrdeutige wird übersprungen. Eine falsche Id würde das falsche Produkt paketieren und die echte App ablösen.
- **Nicht prüfbare Apps stehen als gesperrte Zeilen in der Liste**, mit Grund („keine WinGet-Id sicher zuzuordnen", „Intune meldet keine Version"). Sie sind nicht anhakbar und werden von einem Lauf ausgelassen. Wo es sinnvoll ist, lässt sich die Id per Rechtsklick → **WinGet-Id zuordnen…** von Hand setzen; der Rest bleibt bewusst stehen.
- **Selbst paketierte Apps sind noch nicht alle bekannt.** Fernwartung, RMM und die gängigen Passwortmanager sind ab Werk geschützt (die vollständige Liste steht unten). **Kundeneigene** Installer kennt niemand außer Ihnen — die gehören in die Schutzliste, **bevor** der erste Lauf startet. Ein Update darauf baut eine neue App aus dem öffentlichen Katalog, löst die selbst gebaute ab und zieht deren Zuweisungen mit; bei einem von Hand gebauten Paket holt das kein zweiter Lauf zurück.
- **Die Ablösung ist beim ersten Mal noch nicht belegt.** Ob die Zuweisung wirklich auf die neue Version übergegangen ist, sieht man erst an einem echten Lauf in diesem Tenant.

### Die Schutzliste: was ab Werk geschützt ist, und wie man daran vorbeikommt

Diese Muster stehen ab dem ersten Start in der Liste, weil ihr Installer etwas in sich trägt, das ein aus dem öffentlichen Katalog gebautes Paket nicht hat: die Zuordnung zu dem, der den Rechner betreut (Mandanten-Id, Kundenschlüssel, eigens erzeugtes Installationspaket), oder eine Richtliniendatei und die SSO-Anbindung.

| Gruppe | Muster |
|---|---|
| Fernwartung und RMM | `TeamViewer*`, `AnyDesk*`, `Splashtop*`, `ScreenConnect*`, `ConnectWise*`, `N-able*`, `N-central*`, `Datto*`, `NinjaOne*`, `NinjaRMM*`, `Atera*`, `Action1*`, `BeyondTrust*`, `Jamf*` |
| Passwortmanager | `Keeper*`, `1Password*`, `Bitwarden*`, `LastPass*`, `KeePass*` |

Ein Ersatz durch die nackte Herstellerfassung installiert dasselbe Produkt „leer": der Rechner meldet sich bei niemandem mehr, und ausgerechnet der Zugang, über den man das reparieren könnte, ist weg.

**Geschützt heißt nicht gesperrt.** Die App bleibt in der Update-Liste sichtbar, bleibt anhakbar und zeigt weiterhin, dass es eine neuere Version gibt. Anders ist nur: ein Lauf fragt bei ihr ausdrücklich nach — und diese Frage kommt auch dann, wenn **Rückfragen vor Änderungen in Intune überspringen** eingeschaltet ist.

Drei Wege daran vorbei, vom kurzlebigsten zum dauerhaftesten:

1. **Für diesen einen Lauf:** die Rückfrage bietet **Alle aktualisieren, auch geschützte** an. Die anderen Knöpfe sind **Ohne die geschützten fortfahren** (der Vorgabeknopf) und Abbrechen. Ein weggeklickter Dialog bedeutet immer Abbruch, nie „alle aktualisieren".
2. **Für diese eine App, dauerhaft:** Rechtsklick auf ihre Zeile in der Update-Liste und den Schutz aufheben. Die Statuszeile bestätigt mit **Schutz aufgehoben: …**.
3. **Für ein ganzes Muster:** **Geschützte Apps…** in der Update-Ansicht, oder dieselbe Liste unter **Einstellungen → Selbst paketierte Apps**. Eintrag auswählen, **Ausgewählten entfernen**. Änderungen wirken sofort und werden sofort gespeichert; der Knopf **Einstellungen speichern** ist dafür nicht zuständig.

Zwei Eigenschaften der Liste, die im Alltag zählen:

- **Ein Muster, das Sie entfernen, kommt nicht zurück.** Das Werkzeug merkt sich, welche Werksmuster es Ihnen einmal angeboten hat — Ihre Entscheidung gilt also über Neustarts hinweg, und ein Muster, das in einer späteren Version dazukommt, erreicht trotzdem eine **bestehende** Installation.
- **Die Liste gilt global, nicht je Kunde.** Eine Liste pro Tenant fängt in jeder neuen Umgebung leer an, und genau dort passiert der Unfall.

Ein Eintrag ohne `*` oder `?` trifft den App-Namen genau; mit Platzhalter gilt er als Muster — `Zoom Rooms` schützt eine App, `Zoom*` alle.

### Empfohlene Reihenfolge für die erste Runde

1. Verbinden und die Update-Suche mit **Auch Win32-Apps ohne WinTuner-Marke prüfen** laufen lassen. Erst dadurch sieht die Liste den tatsächlichen Bestand.
2. Die **gesperrten Zeilen** durchgehen: Grund lesen, wo es eindeutig ist die WinGet-Id zuordnen, sonst stehen lassen. Eine nicht zugeordnete App ist unangenehm, eine falsch zugeordnete ist teuer.
3. **Selbst paketierte Apps schützen**, solange noch nichts läuft.
4. Den ersten Lauf mit **eingeschalteten Rückfragen** und **ausgeschaltetem Aufräumen** starten, und zwar mit zwei oder drei unkritischen Apps — nicht mit allen.
5. In Intune nachsehen: Trägt die neue App die Zuweisungen? Steht der Vorgänger als abgelöst da? Das Aktivitätsprotokoll hält beides fest.
6. **Erst danach** den Dauerbetrieb einschalten: Aufräumen, und wenn gewünscht die Rückfragen abschalten.

> [!IMPORTANT]
> Die risikoreichen Optionen sind aus gutem Grund standardmäßig aus. Sie in einer noch nicht geprüften Umgebung sofort einzuschalten heißt, Löschungen zu automatisieren, bevor irgendjemand gesehen hat, ob die Zuordnungen in diesem Tenant stimmen.

---

## Grenzen und Verantwortung

- Die Paketqualität hängt von den verfügbaren WinGet-Metadaten und Installern ab sowie von den Erkennungs- und Anforderungsregeln, die WinTuner erzeugt.
- Apps ohne verlässliche WinGet-Zuordnung lassen sich nicht automatisch aktualisieren oder verwalten.
- Tenant-spezifische Richtlinien, Filter, Neustartverhalten, Abhängigkeiten und Installationskontexte sind vorher zu prüfen.
- Der Einsatz in produktiven Umgebungen erfolgt auf eigene Verantwortung. Für Auswirkungen durch WinTuner, Microsoft Graph, WinGet-Pakete oder tenant-spezifische Konfigurationen wird keine Gewähr übernommen.
- WinTuner GUI ist kein Microsoft-Produkt und wird weder von Microsoft bereitgestellt noch unterstützt.

---

## Projektstatus

> [!WARNING]
> **Beta.** WinTuner GUI ist nicht als stabil freigegeben. Funktionen, Bedienabläufe und Einstellungen können sich zwischen Versionen ändern, auch ohne Übergangslösung. Für den produktiven Einsatz in Kundenumgebungen ist die Anwendung noch nicht freigegeben.

Was das praktisch bedeutet:

- Jede Aktion, die Intune verändert, zuerst in einem Test-Tenant oder gegen eine Testgruppe ausführen.
- Ergebnisse in Intune und im Aktivitätsprotokoll nachkontrollieren, statt sich auf die Rückmeldung der Oberfläche zu verlassen.
- Versionen sind als Vorabversionen gekennzeichnet. Ein Update kann Verhalten ändern.

Aktuelle Versionen und ihre Prüfsummen stehen auf der [Releases-Seite](../../releases). Fehlerberichte und Verbesserungsvorschläge sind über [GitHub Issues](../../issues) willkommen, gerade während der Beta.

---

## Lizenz und Herkunft

WinTuner GUI steht unter der [GNU General Public License v3.0](LICENSE).

Dies ist ein eigenständiges Projekt. Zur Laufzeit setzt es das PowerShell-Modul [WinTuner](https://github.com/svrooij/WinTuner) von Stephan van Rooij voraus, das ebenfalls unter der GPL-3.0 steht. Das Modul wird nicht mitgeliefert, sondern bei Bedarf aus der PowerShell Gallery installiert. WinTuner GUI wurde bewusst unter dieselbe Lizenz gestellt, damit die enge Kopplung an dieses Modul lizenzrechtlich eindeutig bleibt.

WinGet und Microsoft Graph werden lediglich angesprochen, nicht mitverteilt.

WinTuner GUI ist weder mit Microsoft noch mit dem WinTuner-Projekt verbunden und wird von diesen nicht unterstützt.
