# WinTuner GUI

> [!WARNING]
> **Beta – noch nicht für den produktiven Einsatz freigegeben.** Siehe [Projektstatus](#projektstatus).

WinTuner GUI ist eine Windows-Oberfläche für die zentrale Verwaltung von WinGet-, Win32- und Microsoft-Store-Apps in Microsoft Intune. Die Anwendung bündelt Paketierung, Bereitstellung, Versionsvergleich, Zuweisungen und die kontrollierte Ablösung älterer App-Versionen in einer deutsch- und englischsprachigen Oberfläche.

Die Lösung basiert auf dem PowerShell-Modul [WinTuner](https://github.com/svrooij/WinTuner), WinGet und Microsoft Graph. Sie richtet sich an Administratorinnen und Administratoren, die wiederkehrende Aufgaben rund um Intune-Apps nachvollziehbar und mit zusätzlichen Sicherheitsprüfungen ausführen möchten.

> [!IMPORTANT]
> WinTuner GUI verändert je nach gewählter Aktion Apps und Zuweisungen in Microsoft Intune. Pakete, Erkennungs- und Anforderungsregeln sowie Zuweisungen sollten vor dem produktiven Einsatz in einem Test-Tenant oder mit einer Testgruppe geprüft werden.

## Download und Verwendung

Für die Nutzung muss **nicht das vollständige Repository** heruntergeladen oder geklont werden. Benötigt wird ausschließlich die fertige Datei:

```text
WinTuner_GUI_ntg.ps1
```

So geht die Installation:

1. Die Seite [Neueste GitHub-Version](../../releases/latest) öffnen.
2. Den Bereich **Assets** aufklappen.
3. Ausschließlich **`WinTuner_GUI_ntg.ps1`** herunterladen. Das Repository, den Quellcode und die ZIP-Dateien von GitHub werden für die Nutzung nicht benötigt.
4. PowerShell 7 im Downloadordner öffnen und das Skript starten:
(Hinweis, beim ersten öffnen musst du entweder via Powershell das Skript zulassen oder per Rechtsklick -> Eigenschaften -> Zulassen)

   ```powershell
   Unblock-File -LiteralPath '.\WinTuner_GUI_ntg.ps1'
   & '.\WinTuner_GUI_ntg.ps1'
   ```

Die ebenfalls angebotene Datei `WinTuner_GUI_ntg.ps1.sha256` ist optional und dient nur dazu, die Prüfsumme des Downloads zu kontrollieren. Die übrigen Repository-Dateien werden ausschließlich für Entwicklung, Prüfung und Veröffentlichung benötigt.

> **Wichtig für Versionen bis einschließlich 0.15.2:** In diesen Versionen war die eingebaute Update-Prüfung defekt. Sie meldete immer „kein Update verfügbar" (erkennbar an der Anzeige `GitHub version: vunknown`), unabhängig davon, was tatsächlich veröffentlicht war. Wer eine dieser Versionen einsetzt, wird **nicht** automatisch auf eine neuere hingewiesen und muss die Datei einmalig von Hand über die oben beschriebenen Schritte ersetzen. Ab 0.15.3 funktioniert die Prüfung; anschließende Aktualisierungen laufen wieder über die Anwendung selbst.

Beim Ersetzen legt die Anwendung eine Sicherung der bisherigen Datei neben dem Skript ab (`WinTuner_GUI_ntg.ps1.<Zeitstempel>.backup`). Die beiden jüngsten Sicherungen bleiben erhalten, ältere werden beim nächsten Update automatisch entfernt.

Vor dem ersten Einsatz müssen lediglich die unter [Voraussetzungen](#voraussetzungen) genannten System-, Lizenz- und Berechtigungsanforderungen erfüllt sein. Fehlt PowerShell 7, bietet das Skript eine Installation beziehungsweise Aktualisierung über WinGet an. Das benötigte PowerShell-Modul `WinTuner` kann nach Bestätigung für den aktuellen Benutzer aus der PowerShell Gallery installiert werden. Das Modul `Microsoft.Graph` muss verfügbar sein; falls es fehlt, zeigt die Anwendung den passenden Installationshinweis an.

## Funktionsumfang

- **WinGet-Apps suchen und paketieren**
  Pakete im öffentlichen WinGet-Katalog suchen, verfügbare Versionen auswählen und lokal als Intune-Win32-Paket erstellen.

- **Apps in Microsoft Intune bereitstellen**
  Neue Win32-Apps hochladen und optional als verfügbar, erforderlich oder zur Deinstallation zuweisen. Zielgruppen, Filter, Benachrichtigungen, Fristen und weitere Zuweisungseinstellungen lassen sich in der Oberfläche festlegen.

- **Microsoft-Store-Apps verwalten**
  Store-Apps anhand ihres Namens oder ihrer Paket-ID auflösen, im Tenant suchen und bereitstellen. Bereits vorhandene Apps werden erkannt, um doppelte Bereitstellungen zu vermeiden.

- **Vorhandene Apps auf Updates prüfen**
  In Intune bereitgestellte Win32-Apps mit aktuellen WinGet-Versionen vergleichen. Die Ergebnisliste unterscheidet zwischen einem erforderlichen neuen Upload, der Wiederverwendung eines bereits vorhandenen Ziels und noch offener Nacharbeit.

- **Updates kontrolliert ausrollen**
  Neue Zielversionen paketieren oder vorhandene Zielversionen wiederverwenden, Zuweisungen übernehmen und Vorgängerversionen über Intune-Supersedence ablösen.

- **Alte App-Versionen sicher bereinigen**
  Abgelöste oder nicht mehr benötigte Apps ermitteln. Eine automatische Löschung erfolgt nur nach erneuter Prüfung von Zuweisungen und erfolgreichen Installationen; risikoreiche Bereinigungsoptionen sind standardmäßig deaktiviert.

- **Eigene Installer paketieren und Inhalte ersetzen**
  Beliebige EXE- oder MSI-Installer zu einem `.intunewin`-Paket verarbeiten – auch Software, die es in WinGet nicht gibt. Zusätzlich lässt sich der Inhalt einer bereits vorhandenen Intune-App direkt ersetzen: App-ID, Zuweisungen und Historie bleiben erhalten, es entsteht kein zweites App-Objekt und keine Ablösung.

- **Erkennungsregel ermitteln**
  Bei einer MSI genügt ein Klick: Produktcode und Version werden direkt ausgelesen. Bei einer EXE wird die Uninstall-Registrierung vor und nach einer Installation verglichen; daraus entsteht eine fertig formulierte Intune-Erkennungsregel mit Schlüsselpfad, Wertname und Vergleichswert. Silent-Schalter lassen sich vorab in der Windows Sandbox testen, ohne den eigenen Rechner zu verändern.

- **Alle Apps des Tenants einsehen und zuweisen**
  Sämtliche App-Objekte des Intune-Tenants auflisten – auch Typen, die diese Oberfläche nicht paketiert (MSI, UWP/MSIX, Microsoft 365 Apps, Weblinks). Zuweisungen einer App werden im Klartext angezeigt und lassen sich verwalten: Gruppen und Ausschlüsse hinzufügen oder entfernen, Absicht festlegen sowie Benachrichtigungen, Fristen und Neustartverhalten anpassen. Gruppen können optional über ihren Namen gesucht werden.

- **Erkannte Software auswerten**
  Das Intune-Inventar erkannter Apps laden, typische Treiber- und OEM-Einträge filtern und geeignete Anwendungen WinGet-Paketen zuordnen. Ausgewählte Treffer können anschließend unter Verwaltung genommen werden.

- **Lokale Pakete und Favoriten automatisch pflegen**
  Häufig verwendete WinGet-Pakete als Favoriten speichern und beim Start der Anwendung optional automatisch auf Updates prüfen. Fehlende aktuelle Versionen werden heruntergeladen beziehungsweise lokal erstellt. Mit „Alle lokalen Apps aktualisieren“ lässt sich außerdem der gesamte gewählte Paketordner prüfen und gesammelt auf den aktuellen Stand bringen; bereits vorhandene aktuelle Versionen werden nicht erneut erstellt.

- **Tenant-Übersicht und Protokollierung**
  Dashboard für verwaltete Apps, verfügbare Updates und abgelöste Versionen. Aktionen und Fehler werden in einem lokalen Wochenprotokoll nachvollziehbar festgehalten.

- **Anpassbare Oberfläche**
  Deutsche und englische Benutzeroberfläche, mehrere Darstellungsmodi sowie lokal gespeicherte Einstellungen und zuletzt verwendete Anmeldungen.

## Funktionsweise

| Bereich | Datenquelle | Wirkung |
| --- | --- | --- |
| Dashboard | Microsoft Intune | Nur lesende Übersicht über Apps, Updates und abgelöste Versionen |
| WinGet-Apps | WinGet und lokaler Paketordner | Sucht Pakete, erstellt lokale Pakete und lädt sie nach Bestätigung zu Intune hoch |
| Updates | Intune, WinGet und WinTuner-Index | Vergleicht Versionen, erstellt oder verwendet eine Ziel-App und übergibt auf Wunsch Zuweisungen |
| Lokale App-Pflege | WinGet und lokaler Paketordner | Prüft Favoriten optional beim Programmstart und aktualisiert auf Wunsch alle gültigen lokalen App-Pakete |
| Erkannte Apps | Intune-Inventar und WinGet | Ordnet installierte Software möglichen WinGet-Paketen zu; der Scan selbst ist schreibgeschützt |
| Microsoft Store | Microsoft Store und Intune | Durchsucht den Store-Katalog, zeigt Treffer zur Auswahl und stellt die gewählte App nach Bestätigung bereit; zusätzlich Übersicht der bereits bereitgestellten Store-Apps |
| Alle Tenant-Apps | Intune | Listet alle App-Objekte jeden Typs. Zuweisungen werden gelesen und können geändert werden – dies schreibt nach Intune |
| Eigene Installer | Lokale Dateien und Intune | Paketiert beliebige EXE-/MSI-Installer lokal zu `.intunewin`. Das Ersetzen des Inhalts einer vorhandenen App schreibt nach Intune |
| Bereinigung | Intune | Prüft alte App-Objekte und löscht sie nur, wenn die konfigurierten Sicherheitsbedingungen erfüllt sind |

Die GUI installiert Software nicht direkt auf Endgeräten. Sie erstellt und verwaltet App-Objekte sowie Zuweisungen in Intune; die eigentliche Verteilung und Auswertung erfolgt anschließend durch Microsoft Intune.

## Sicherheitskonzept

- Änderungen an Intune werden erst nach einer bewussten Benutzeraktion ausgeführt.
- Doppelte Uploads derselben Paketversion werden vor der Bereitstellung geprüft und blockiert.
- Vor einer Bereinigung werden Zuweisungen und gemeldete erfolgreiche Installationen erneut abgefragt.
- Zugewiesene Vorgänger werden nur unter den ausdrücklich aktivierten Bedingungen entfernt.
- Kennwörter, Token und andere geheime Anmeldedaten werden weder im Skript noch in der Einstellungsdatei gespeichert. Die Authentifizierung erfolgt über Microsoft Entra ID und Microsoft Graph.
- **Trennen / Disconnect** beendet nur die aktuell aktive Graph-Verbindung. Der von Microsoft bereitgestellte Sitzungskontext bleibt im Windows-Benutzerprofil zwischengespeichert. Dadurch kann die nächste Verbindung mit demselben Konto in der Regel ohne erneute Eingabe von Kennwort oder MFA hergestellt werden.
- **Abmelden / Logout** beendet die Verbindung vollständig und entfernt zusätzlich den lokal zwischengespeicherten Graph-Sitzungskontext. Erst danach ist bei der nächsten Verbindung wieder eine neue interaktive Anmeldung erforderlich. Vor einem Wechsel zu einem anderen Kunden beziehungsweise Tenant und auf gemeinsam genutzten Rechnern sollte deshalb immer **Abmelden** verwendet werden.
- Wie dieser Zwischenspeicher technisch funktioniert und was er für gemeinsam genutzte Rechner bedeutet, ist in [Anmeldung und Sitzung: wie der Zwischenspeicher funktioniert](#anmeldung-und-sitzung-wie-der-zwischenspeicher-funktioniert) im Detail beschrieben.
- Einstellungen, zuletzt verwendete Kontonamen und Protokolle bleiben lokal im Windows-Benutzerprofil beziehungsweise im Anwendungsverzeichnis.
- Pakete werden standardmäßig unter `%LOCALAPPDATA%\WinTunerGUI\Packages` erstellt. Dieses Verzeichnis gehört dem angemeldeten Benutzer. Ein gemeinsam beschreibbarer Ablageort wie `C:\Temp` ist bewusst nicht mehr voreingestellt, weil dort jeder Benutzer des Rechners ein fertiges Paket zwischen Erstellung und Upload verändern könnte.
- Das Ändern von Zuweisungen unter **Alle Tenant-Apps** ersetzt immer den vollständigen Zuweisungssatz einer App – Microsoft Graph kennt keine Teilaktualisierung. Der Dialog zeigt die zu schreibende Liste vorher an und fragt ausdrücklich nach.
- Das Ersetzen des Inhalts einer vorhandenen App verändert **nicht** deren Erkennungs- und Anforderungsregeln. Diese müssen zur neuen Version passen und sind vorab zu prüfen.
- Die integrierte Selbstaktualisierung akzeptiert nur Releases mit passendem Skriptasset, SHA-256-Prüfsumme und plausibler interner Versionsnummer; vor dem Austausch wird eine Sicherung angelegt. Nach der Bestätigung läuft der Austausch ohne weitere Rückfragen; die beiden jüngsten Sicherungen bleiben erhalten.

### Anmeldung und Sitzung: wie der Zwischenspeicher funktioniert

Dieser Abschnitt erklärt, warum nach der ersten Anmeldung meist kein Kennwort mehr abgefragt wird, wo diese Sitzung liegt und was das für die Sicherheit bedeutet. Dieselbe Erklärung ist in der Anwendung unter **Hilfe → „Anmeldung & Sitzung erklärt…"** erreichbar.

**Was bei der Anmeldung gespeichert wird — und was nicht.**
Kennwort und MFA werden **nicht** gespeichert. Die Anmeldung läuft über Microsoft Entra ID, das nach erfolgreicher, interaktiver Anmeldung zwei Token ausstellt:

- ein **Zugriffstoken** (Access Token) — kurzlebig, rund eine Stunde gültig, wird bei jedem Graph-Aufruf mitgeschickt;
- ein **Aktualisierungstoken** (Refresh Token) — längere Gültigkeit, dient dazu, im Hintergrund ohne erneute Benutzerinteraktion ein frisches Zugriffstoken zu beschaffen.

Das Aktualisierungstoken ist der eigentlich schützenswerte Teil: Wer es besitzt, kann daraus so lange neue Zugriffstoken erzeugen, bis es abläuft oder zentral widerrufen wird.

**Wo die Sitzung liegt.**
Der Zwischenspeicher wird von der darunterliegenden Microsoft Authentication Library (MSAL) verwaltet und liegt im Windows-Benutzerprofil unter:

```text
%LOCALAPPDATA%\.IdentityService\   (Dateien mg.msal.cache*)
```

Auf Windows verschlüsselt MSAL diesen Cache mit der **Data Protection API (DPAPI)** im Benutzerkontext. Entschlüsseln kann ihn nur **derselbe Windows-Benutzer auf demselben Gerät**; ein anderer lokaler Benutzer kann die Datei zwar sehen, aber nicht lesen. Der Zwischenspeicher lässt sich damit nicht auf ein anderes Gerät oder Konto übertragen und läuft ab — Richtlinien für bedingten Zugriff oder MFA können ihn früher beenden.

**Warum das nächste Verbinden ohne Abfrage klappt.**
Beim erneuten Verbinden findet MSAL das Aktualisierungstoken im Cache und löst still ein neues Zugriffstoken ein. Zusätzlich kann der Windows-Anmeldedienst (WAM) ein auf dem Gerät bereits angemeldetes Konto wiederverwenden. Deshalb entfällt die erneute Kennwort- und MFA-Abfrage in der Regel.

**Was das für die Sicherheit bedeutet.**
DPAPI schützt die Sitzung gegen *andere Benutzer* des Rechners — nicht gegen Code, der **im Kontext des angemeldeten Benutzers selbst** läuft. Schadsoftware oder ein Skript, das als derselbe Windows-Benutzer läuft, kann DPAPI genauso aufrufen und das Aktualisierungstoken auslesen. Bei einem Werkzeug, das Kundentenants verwaltet, ist ein liegengebliebener Zwischenspeicher auf einem geteilten Technikerrechner daher potenziell stiller Zugriff auf einen Kundentenant, bis das Token abläuft oder widerrufen wird. Genau darum gilt: **vor einem Kunden- beziehungsweise Tenant-Wechsel und auf gemeinsam genutzten Rechnern immer „Abmelden", nicht nur „Trennen".**

**Trennen vs. Abmelden — präzise.**

| Aktion | Aktuelle Sitzung | Zwischenspeicher | Nächste Anmeldung |
|---|---|---|---|
| **Trennen / Disconnect** | wird beendet | bleibt erhalten | sofort, ohne Rückfrage |
| **Abmelden / Logout** | wird beendet | wird gelöscht (WAM wird umgangen, Benutzernamenfeld geleert) | echte, interaktive Anmeldung |

**Zwei Dinge, die man leicht übersieht:**

- Der Zwischenspeicher ist der **gemeinsame** des Moduls `Microsoft.Graph`, kein eigener dieser Anwendung. „Abmelden" beendet deshalb auch die zwischengespeicherte Sitzung **anderer** PowerShell-Werkzeuge desselben Windows-Benutzers, die sich darüber anmelden.
- „Abmelden" löscht nur die **lokale** Kopie. Das Aktualisierungstoken bleibt serverseitig bei Entra ID gültig und ist damit **nicht widerrufen**. Bei echtem Verdacht auf Kompromittierung eines Kontos oder Geräts reicht „Abmelden" nicht — dann müssen die Sitzungen zusätzlich zentral im Entra-Portal widerrufen werden („Revoke sessions").

**Faustregel:** Kundenwechsel oder gemeinsam genutzter Rechner → **Abmelden**. Alles andere → **Trennen**.

## Voraussetzungen

- Windows 10 oder Windows 11 beziehungsweise Windows Server mit grafischer Oberfläche
- PowerShell 7.4 oder neuer
- WinGet / App Installer für WinGet- und Microsoft-Store-Abfragen
- PowerShell-Module `WinTuner` und `Microsoft.Graph`
- Microsoft-Intune-Lizenz im **Ziel-Tenant**, der mit WinTuner GUI verwaltet werden soll
- Ein für diesen **Ziel-Tenant** zugelassenes Konto mit den unten aufgeführten Berechtigungen
- Internetzugriff auf die verwendeten Microsoft-, WinGet- und optionalen GitHub-Endpunkte

> [!NOTE]
> Die Lizenz- und Berechtigungsanforderungen beziehen sich auf den jeweils ausgewählten **Ziel-Tenant**. Maßgeblich ist also das zur Anmeldung verwendete Konto und dessen Berechtigungen in genau dem Tenant, dessen Intune-Apps verwaltet werden sollen.

## Konto und Berechtigungen

### Empfehlung: dediziertes Konto, kein globaler Administrator

**Für den Betrieb dieser Anwendung ist die Rolle „Globaler Administrator" nicht erforderlich, und wir empfehlen ausdrücklich, sie nicht dafür zu verwenden.** Das Werkzeug legt Intune-Apps an, ändert Zuweisungen und löscht App-Objekte — mehr Rechte als dafür nötig vergrößern nur den Schaden, den ein Fehlgriff oder ein kompromittiertes Konto anrichten kann.

Empfohlen wird ein **eigenes Administrationskonto**, das ausschließlich für diese Aufgabe verwendet wird, mit Multifaktor-Authentifizierung und ohne Postfach- oder Endanwenderfunktion. Als Berechtigung genügt in Intune die eingebaute Rolle:

| Aufgabe | Passende Intune-Rolle |
|---|---|
| Apps bereitstellen, aktualisieren, zuweisen, löschen | **Application Manager** |
| Nur auswerten, nichts verändern | **Read Only Operator** |

Die Rolle **Application Manager** deckt genau den Funktionsumfang ab: Mobile Apps lesen, anlegen, ändern, zuweisen, löschen und in Beziehung setzen (Ablöse) sowie verwaltete Geräte lesen. Microsoft selbst empfiehlt, für die tägliche Intune-Administration diese Intune-Rollen zu verwenden und Entra-ID-Rollen mit Intune-Zugriff zu meiden, weil die meisten davon als privilegiert gelten.

Zusätzlich lässt sich der Wirkungsbereich über **Bereichs-Tags (Scope Tags)** und Bereichsgruppen einschränken, sodass ein Konto nur bestimmte Apps oder Gerätegruppen verwalten darf.

> [!IMPORTANT]
> Für die **einmalige** Zustimmung zu den Microsoft-Graph-Berechtigungen wird ein Konto mit ausreichender Entra-ID-Berechtigung benötigt (z. B. Anwendungsadministrator oder Cloudanwendungsadministrator). Das ist ein einmaliger Vorgang bei der Ersteinrichtung im jeweiligen Tenant — für den laufenden Betrieb reicht danach das Konto mit der Intune-Rolle.

### Benötigte Microsoft-Graph-Berechtigungen (delegiert)

Die Anmeldung erfolgt über das PowerShell-Modul `WinTuner` und dessen App-Registrierung; angefordert wird `https://graph.microsoft.com/.default`, also genau der Berechtigungsumfang, dem im Tenant zugestimmt wurde. Fachlich benötigt die Anwendung:

| Berechtigung | Wofür | Art |
|---|---|---|
| `DeviceManagementApps.ReadWrite.All` | Intune-Apps lesen und schreiben: Bereitstellen, Aktualisieren, Ablösen, Löschen, Zuweisungen und Zuweisungseinstellungen, Installationsberichte | Schreibend |
| `DeviceManagementManagedDevices.Read.All` | Inventar „Erkannte Apps" (`/deviceManagement/detectedApps`) | Lesend |
| `Group.Read.All` | **Optional.** Nur für die Suche nach Entra-ID-Gruppen *anhand ihres Namens* unter „Alle Tenant-Apps" | Lesend |

`Group.Read.All` wird bei der Anmeldung **bewusst nicht** angefordert. Erst wenn die Namenssuche tatsächlich benutzt wird, fragt die Anwendung danach — und erklärt vorher, worum es geht. Ohne diese Berechtigung funktioniert alles Übrige unverändert; Gruppen lassen sich dann über ihre Objekt-ID zuweisen.

Wer die Anwendung **ausschließlich zur Auswertung** einsetzt (Dashboard, Update-Suchlauf, Tenant-Übersicht, erkannte Apps), kommt fachlich mit `DeviceManagementApps.Read.All` statt `.ReadWrite.All` aus. Ein eigener Nur-Lesen-Modus, der beim Anmelden nur diesen Umfang anfordert, ist geplant, aber noch nicht umgesetzt.

Je nach Tenant können zusätzlich Administratorzustimmung, Conditional-Access-Richtlinien oder weitere organisatorische Freigaben erforderlich sein.

> [!NOTE]
> **„Abmelden" wirkt über diese Anwendung hinaus.** Dabei wird der zwischengespeicherte Anmeldetoken unter `%LOCALAPPDATA%\.IdentityService` gelöscht. Das ist der **gemeinsame** Zwischenspeicher des Moduls `Microsoft.Graph` und nicht ein eigener dieser Anwendung — andere PowerShell-Werkzeuge desselben Windows-Benutzers, die sich darüber anmelden, verlieren ihre zwischengespeicherte Sitzung ebenfalls. „Trennen" lässt den Zwischenspeicher unangetastet.

## Typischer Ablauf

1. Mit dem gewünschten Microsoft-365-Tenant verbinden.
2. Neue Apps über WinGet oder den Microsoft Store auswählen, einen eigenen Installer paketieren – oder vorhandene Intune-Apps auf Updates prüfen.
3. Paketversion, Zielgruppe, Intent und erweiterte Zuweisungseinstellungen kontrollieren.
4. Paketierung beziehungsweise Bereitstellung ausdrücklich bestätigen.
5. Ergebnis in Intune und im lokalen Aktivitätsprotokoll prüfen.

Für ein Update stehen zwei Wege zur Verfügung: die neue Version als eigene App bereitstellen und die alte ablösen (Standard unter **Updates**), oder den Inhalt der vorhandenen App ersetzen (**Eigene Installer**). Der zweite Weg vermeidet mehrere App-Objekte pro Produkt, setzt aber voraus, dass die Erkennungsregeln weiterhin passen.

## Grenzen und Verantwortung

- Die Qualität eines Pakets hängt von den verfügbaren WinGet-Metadaten, Installern sowie den durch WinTuner erzeugten Erkennungs- und Anforderungsregeln ab.
- Apps ohne sichere WinGet-Zuordnung können nicht automatisch aktualisiert oder verwaltet werden.
- Tenant-spezifische Richtlinien, Filter, Neustartverhalten, Abhängigkeiten und Installationskontexte müssen vorab geprüft werden.
- Die Nutzung in produktiven Umgebungen erfolgt auf eigene Verantwortung. Es wird keine Gewähr für Auswirkungen durch WinTuner, Microsoft Graph, WinGet-Pakete oder tenant-spezifische Konfigurationen übernommen.
- WinTuner GUI ist kein Microsoft-Produkt und wird nicht von Microsoft bereitgestellt oder unterstützt.

## Projektstatus

> [!WARNING]
> **Beta.** WinTuner GUI ist noch nicht als stabil freigegeben. Funktionen, Bedienabläufe und Einstellungen können sich zwischen Versionen ändern, auch ohne Übergangslösung. Für den produktiven Einsatz in Kundenumgebungen ist die Anwendung noch nicht freigegeben.

Was das praktisch bedeutet:

- Jede Aktion, die Intune verändert, sollte zuerst in einem Test-Tenant oder gegen eine Testgruppe ausgeführt werden.
- Ergebnisse in Intune und im Aktivitätsprotokoll nachkontrollieren, statt sich auf die Rückmeldung der Oberfläche zu verlassen.
- Versionen sind als Vorabversionen gekennzeichnet; ein Update kann Verhalten ändern.

Aktuelle Versionen und die zugehörigen Prüfsummen stehen unter [GitHub Releases](../../releases). Fehlerberichte und Verbesserungsvorschläge können über die [GitHub Issues](../../issues) eingereicht werden — gerade in der Beta-Phase sind sie ausdrücklich erwünscht.


## Lizenz und Herkunft

WinTuner GUI steht unter der [GNU General Public License v3.0](LICENSE).

Die Anwendung ist eine eigenständige Entwicklung. Sie setzt zur Laufzeit das PowerShell-Modul [WinTuner](https://github.com/svrooij/WinTuner) von Stephan van Rooij voraus, das ebenfalls unter der GPL-3.0 steht. Das Modul wird nicht mitgeliefert, sondern bei Bedarf aus der PowerShell Gallery installiert. WinTuner GUI wurde bewusst unter dieselbe Lizenz gestellt, damit die enge Kopplung an dieses Modul lizenzrechtlich eindeutig bleibt.

WinGet und Microsoft Graph werden lediglich angesprochen.

WinTuner GUI ist weder mit Microsoft noch mit dem WinTuner-Projekt verbunden und wird von diesen nicht unterstützt.

