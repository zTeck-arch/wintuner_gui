# Ablösung der WinTuner-Modulabhängigkeit — verschoben

Die erste Fassung dieses Plans sah eine Ablösung innerhalb des PowerShell-Quellbaums vor. Sie ist
überholt.

Die Ablösung findet stattdessen im eigenständigen Projekt **AppForge** (`..\..\AppForge`) statt:
eine C#-Kernbibliothek, die WinTuner GUI in Stufe S2 über ein PowerShell-Binärmodul einbindet. Der
Motortausch passiert dann hier im Quellbaum, aber die Fachlogik entsteht dort.

Vollständige Unterlagen:

| Dokument | Inhalt |
|---|---|
| `..\..\AppForge\docs\01-Funktionsmatrix.md` | die 89 Funktionen dieses Produkts, vollständig inventarisiert |
| `..\..\AppForge\docs\02-Produktvision.md` | Zielbild und warum PowerShell/WinForms dafür nicht trägt |
| `..\..\AppForge\docs\03-Architektur.md` | Zielarchitektur |
| `..\..\AppForge\docs\04-Umsetzungsplan.md` | Stufen S0–S8; **S2 ist die Ablösung in diesem Produkt** |
| `..\..\AppForge\docs\05-Entscheidungen.md` | offene Entscheidungen |

**Was das für dieses Repository bedeutet:** WinTuner GUI bleibt bis Stufe S4 das Produkt im
Einsatz und wird normal gepflegt. Ab S3 keine neuen Funktionen mehr, ab S4 Wartungsmodus.

**Sofort relevant, unabhängig vom Zeitplan:** Das eingesetzte Modul enthält
`WinTuner.Proxy.Client.dll`, die mit `https://proxy.wintuner.app/api` spricht. Ob im normalen
Betrieb Verbindungen dorthin aufgebaut werden, ist ungeprüft — siehe E5 in
`..\..\AppForge\docs\05-Entscheidungen.md`.
