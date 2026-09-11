#requires -Version 7
# Der macOS-Katalog: was aus Homebrew uebernommen wird und was nicht.
#
# Die Auswahlregel ist die ganze Sicherheit dieses Weges. Nimmt sie einen DMG-Cask mit, laedt die
# Anwendung ein Plattenabbild hoch und nennt es gegenueber Intune ein PKG - die App entsteht, und
# auf dem Geraet passiert nichts. Nimmt sie einen Hash nicht mit, laedt sie ungeprueft.
#
# Gemessen am 11.09.2026 am vollstaendigen Katalog (7712 Casks): 378 PKG, davon 334 mit echtem
# SHA256, 0 mit bundle_short_version. Diese Zahlen stehen als Kommentar in 44-MacOsCatalog.ps1 und
# begruenden dort den Aufbau - der Block ganz unten prueft sie gegen die Wirklichkeit nach, wenn
# eine Netzverbindung da ist.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  # Der ganze Teil: er setzt die Ueberschreibliste, die Adressen und die Grenzwerte als
  # Zuweisungen neben den Funktionen.
  . ([scriptblock]::Create((Get-SourcePartText -Part '44-MacOsCatalog.ps1')))

  # Ein Cask, wie ihn formulae.brew.sh liefert - auf die Felder gekuerzt, die wir lesen.
  function New-Cask {
    param([string]$Token, [string]$Url, [string]$Version = '1.0', [string]$Sha = 'no_check', [string]$Name = '')
    $displayName = if ($Name) { $Name } else { $Token }
    return [pscustomobject]@{
      token = $Token; name = @($displayName); desc = 'a test cask'
      homepage = "https://example.invalid/$Token"; url = $Url; version = $Version; sha256 = $Sha
    }
  }
}

Describe 'Test-IsPkgUrl' {

  It 'erkennt eine gewoehnliche PKG-Adresse' {
    Test-IsPkgUrl -Url 'https://dl.google.com/chrome/mac/universal/stable/gcem/GoogleChrome.pkg' | Should -BeTrue
  }

  It 'erkennt das Format auch, wenn es in der Abfrage steht' {
    # Mozilla nennt das Format als Parameter, nicht als Endung. Eine Pruefung nur auf '.pkg$'
    # haette Firefox stillschweigend aus dem Katalog geworfen.
    Test-IsPkgUrl -Url 'https://download.mozilla.org/?product=firefox-pkg-latest-ssl&os=osx&lang=de' | Should -BeTrue
  }

  It 'verwirft DMG, ZIP und alles andere' {
    # Der wichtigste Fall: ein DMG als PKG hochzuladen ergibt eine App, die Intune anlegt und die
    # auf dem Geraet nichts tut.
    Test-IsPkgUrl -Url 'https://dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg' | Should -BeFalse
    Test-IsPkgUrl -Url 'https://example.invalid/app.zip' | Should -BeFalse
    Test-IsPkgUrl -Url 'https://example.invalid/app.tar.gz' | Should -BeFalse
    Test-IsPkgUrl -Url '' | Should -BeFalse
  }

  It 'laesst sich von einem .pkg mitten im Pfad nicht taeuschen' {
    Test-IsPkgUrl -Url 'https://example.invalid/some.pkg.old/app.dmg' | Should -BeFalse
  }
}

Describe 'Select-MacOsPkgCasks' {

  It 'nimmt nur die PKG-Casks' {
    $casks = @(
      (New-Cask -Token 'zoom'   -Url 'https://example.invalid/Zoom.pkg'  -Sha ('a' * 64))
      (New-Cask -Token 'chrome' -Url 'https://example.invalid/chrome.dmg')
      (New-Cask -Token 'slack'  -Url 'https://example.invalid/slack.zip')
    )
    $sel = Select-MacOsPkgCasks -Casks $casks
    $sel.Count | Should -Be 1
    $sel[0].Token | Should -Be 'zoom'
  }

  It 'uebernimmt einen echten Hash und verwirft no_check' {
    # 'no_check' heisst: die Datei aendert sich unter derselben Adresse. Das als Hash zu fuehren
    # waere eine Pruefung, die immer fehlschlaegt.
    $mitHash = Select-MacOsPkgCasks -Casks @((New-Cask -Token 'a' -Url 'https://x.invalid/a.pkg' -Sha ('b' * 64)))
    $mitHash[0].Sha256 | Should -Be ('b' * 64)
    $ohneHash = Select-MacOsPkgCasks -Casks @((New-Cask -Token 'c' -Url 'https://x.invalid/c.pkg' -Sha 'no_check'))
    $ohneHash[0].Sha256 | Should -Be ''
  }

  It 'ueberspringt einen Cask ohne Token, statt ihn halb zu uebernehmen' {
    $sel = Select-MacOsPkgCasks -Casks @((New-Cask -Token '' -Url 'https://x.invalid/a.pkg'))
    $sel.Count | Should -Be 0
  }

  It 'faellt auf den Token zurueck, wenn der Cask keinen Namen nennt' {
    $cask = [pscustomobject]@{ token = 'nameless'; name = @(); url = 'https://x.invalid/a.pkg'; version = '1'; sha256 = 'no_check' }
    (Select-MacOsPkgCasks -Casks @($cask))[0].Name | Should -Be 'nameless'
  }
}

Describe 'Merge-MacOsCatalogOverrides' {

  It 'ersetzt die Adresse eines vorhandenen Casks und behaelt dessen Version' {
    # Genau der Chrome-Fall: Homebrew kennt die aktuelle Version, zeigt aber auf das DMG.
    $entries = Select-MacOsPkgCasks -Casks @((New-Cask -Token 'x' -Url 'https://x.invalid/x.pkg' -Version '9.9' -Sha ('c' * 64)))
    $merged = Merge-MacOsCatalogOverrides -Entries $entries -Overrides @(
      @{ Token = 'x'; Name = 'X Enterprise'; Url = 'https://vendor.invalid/X.pkg'; Homepage = 'https://vendor.invalid' }
    )
    $merged.Count | Should -Be 1
    $merged[0].Url | Should -Be 'https://vendor.invalid/X.pkg'
    $merged[0].Name | Should -Be 'X Enterprise'
    $merged[0].Version | Should -Be '9.9'
    $merged[0].Source | Should -Be 'override'
  }

  It 'LEERT den Hash beim Ueberschreiben' {
    # Der Hash gehoerte zur Datei von Homebrew. Auf die Datei des Herstellers passt er nicht, und
    # ihn stehen zu lassen hiesse: jeder Download schlaegt mit "Hash stimmt nicht" fehl.
    $entries = Select-MacOsPkgCasks -Casks @((New-Cask -Token 'x' -Url 'https://x.invalid/x.pkg' -Sha ('d' * 64)))
    $merged = Merge-MacOsCatalogOverrides -Entries $entries -Overrides @(
      @{ Token = 'x'; Url = 'https://vendor.invalid/X.pkg' }
    )
    $merged[0].Sha256 | Should -Be ''
  }

  It 'haengt einen Ueberschreibeintrag an, den Homebrew gar nicht kennt' {
    $merged = Merge-MacOsCatalogOverrides -Entries @() -Overrides @(
      @{ Token = 'neu'; Name = 'Neu'; Url = 'https://vendor.invalid/neu.pkg' }
    )
    $merged.Count | Should -Be 1
    $merged[0].Token | Should -Be 'neu'
    $merged[0].Source | Should -Be 'override'
  }

  It 'laesst alles unberuehrt, was nicht in der Liste steht' {
    $entries = Select-MacOsPkgCasks -Casks @(
      (New-Cask -Token 'a' -Url 'https://x.invalid/a.pkg' -Sha ('e' * 64))
      (New-Cask -Token 'b' -Url 'https://x.invalid/b.pkg' -Sha ('f' * 64))
    )
    $merged = Merge-MacOsCatalogOverrides -Entries $entries -Overrides @(@{ Token = 'a'; Url = 'https://v.invalid/a.pkg' })
    ($merged | Where-Object Token -eq 'b').Sha256 | Should -Be ('f' * 64)
    ($merged | Where-Object Token -eq 'b').Source | Should -Be 'homebrew'
  }
}

Describe 'Die mitgelieferte Ueberschreibliste' {

  It 'nennt fuer jeden Eintrag Adresse, Grund und Pruefdatum' {
    # Ein Eintrag ohne geprueftes Datum ist eine Behauptung. Eine tote URL im Katalog ist ein
    # Supportfall, den von aussen niemand erklaeren kann.
    $script:macOsPkgOverrides.Count | Should -BeGreaterThan 0
    foreach ($ov in $script:macOsPkgOverrides) {
      $ov.Token | Should -Not -BeNullOrEmpty
      $ov.Url | Should -Match '^https://'
      $ov.Reason | Should -Not -BeNullOrEmpty
      $ov.Checked | Should -Match '^\d{4}-\d{2}-\d{2}$'
    }
  }

  It 'zeigt mit jeder Adresse wirklich auf ein PKG' {
    foreach ($ov in $script:macOsPkgOverrides) {
      Test-IsPkgUrl -Url ([string]$ov.Url) | Should -BeTrue -Because ("die Ueberschreibadresse von {0} muss ein PKG sein" -f $ov.Token)
    }
  }
}

Describe 'Die Marke im Notizfeld' {

  It 'schreibt und liest denselben Wert' {
    $marker = New-MacOsAppMarker -CaskToken 'google-chrome' -Version '153.0.8010.37'
    $back = Read-MacOsAppMarker -Notes ("Irgendein Text. {0} Und noch mehr." -f $marker)
    $back.Token | Should -Be 'google-chrome'
    $back.Version | Should -Be '153.0.8010.37'
  }

  It 'gibt null zurueck, wo keine Marke steht' {
    Read-MacOsAppMarker -Notes 'nur Text' | Should -BeNullOrEmpty
    Read-MacOsAppMarker -Notes '' | Should -BeNullOrEmpty
  }

  It 'wird NICHT von der WinGet-Markenlesung erfasst' {
    # Sonst hielte Get-PackageIdFromNotes (Teil 25) eine macOS-App fuer eine WinTuner-Win32-App.
    # Geprueft gegen genau das Muster, das dort steht.
    $marker = New-MacOsAppMarker -CaskToken 'zoom' -Version '7.1.5'
    $marker | Should -Not -Match '\[(?:WinTuner|WingetIntune)\|'
    $marker | Should -Not -Match '(?i)\b(?:WinTuner|WingetIntune|WinGet)\b'
  }
}

Describe 'Test-MacOsUpdateNeeded' {

  It 'meldet Bedarf bei unterschiedlicher Version' {
    Test-MacOsUpdateNeeded -DeployedVersion '1.0' -CatalogVersion '1.1' | Should -BeTrue
  }

  It 'meldet keinen Bedarf bei gleicher Version' {
    Test-MacOsUpdateNeeded -DeployedVersion '1.0' -CatalogVersion '1.0' | Should -BeFalse
    Test-MacOsUpdateNeeded -DeployedVersion ' 1.0 ' -CatalogVersion '1.0' | Should -BeFalse
  }

  It 'meldet KEINEN Bedarf, wenn eine der beiden Seiten unbekannt ist' {
    # Unbekannt heisst behalten. Ein Update auf Verdacht ersetzt den Inhalt einer produktiven App
    # durch etwas, das vielleicht dasselbe ist - und der Fehler faellt erst auf den Geraeten auf.
    Test-MacOsUpdateNeeded -DeployedVersion '' -CatalogVersion '1.1' | Should -BeFalse
    Test-MacOsUpdateNeeded -DeployedVersion '1.0' -CatalogVersion '' | Should -BeFalse
  }
}

Describe 'Find-DeployedMacOsApp' {

  BeforeAll {
    $script:tenant = @(
      @{ Id = 'aaa'; DisplayName = 'Google Chrome'; CaskToken = 'google-chrome'; CaskVersion = '152.0.1'; BundleVersion = '152.0.1' }
      @{ Id = 'bbb'; DisplayName = 'Zoom';         CaskToken = 'zoom';          CaskVersion = '7.1.5';   BundleVersion = '7.1.5' }
      @{ Id = 'ccc'; DisplayName = 'Von Hand angelegt'; CaskToken = ''; CaskVersion = ''; BundleVersion = '1.0' }
    )
  }

  It 'findet die App ueber die Marke' {
    (Find-DeployedMacOsApp -TenantApps $script:tenant -CaskToken 'zoom').Id | Should -Be 'bbb'
  }

  It 'findet nichts, wenn die Marke fehlt' {
    Find-DeployedMacOsApp -TenantApps $script:tenant -CaskToken 'firefox' | Should -BeNullOrEmpty
  }

  It 'greift NICHT auf den Anzeigenamen zurueck' {
    # Der Name kann im Portal geaendert worden sein, und die Marke ist die einzige verlaessliche
    # Zuordnung. Waere der Name die Rueckfalloption, aktualisierte ein Lauf irgendeine App, die
    # zufaellig so heisst.
    $umbenannt = @(@{ Id = 'ddd'; DisplayName = 'zoom'; CaskToken = ''; CaskVersion = ''; BundleVersion = '1' })
    Find-DeployedMacOsApp -TenantApps $umbenannt -CaskToken 'zoom' | Should -BeNullOrEmpty
  }

  It 'ignoriert Apps ohne Marke, statt die erstbeste zu nehmen' {
    Find-DeployedMacOsApp -TenantApps $script:tenant -CaskToken '' | Should -BeNullOrEmpty
  }

  It 'arbeitet mit einem leeren Inventar' {
    Find-DeployedMacOsApp -TenantApps @() -CaskToken 'zoom' | Should -BeNullOrEmpty
  }

  It 'spielt mit Test-MacOsUpdateNeeded zusammen, wie der Handler es benutzt' {
    # Der ganze Entscheidungsweg in einem Fall: App gefunden, Katalog neuer -> ersetzen.
    $app = Find-DeployedMacOsApp -TenantApps $script:tenant -CaskToken 'google-chrome'
    $app | Should -Not -BeNullOrEmpty
    Test-MacOsUpdateNeeded -DeployedVersion $app.CaskVersion -CatalogVersion '153.0.8010.37' | Should -BeTrue
    Test-MacOsUpdateNeeded -DeployedVersion $app.CaskVersion -CatalogVersion '152.0.1' | Should -BeFalse
  }
}

Describe 'Gegen den echten Homebrew-Katalog' -Tag 'Network' {
  # Netzabhaengig, deshalb ueberspringt sich der Block, statt die Kette wegen einer fehlenden
  # Verbindung rot zu machen. Er prueft die Zahlen nach, die den Aufbau von 44-MacOsCatalog.ps1
  # begruenden - wenn Homebrew sich grundlegend aendert, soll das hier auffallen und nicht erst
  # beim Kunden.

  BeforeAll {
    # Die ABLEITUNGEN werden hier gerechnet, nicht das Rohfeld durchgereicht.
    #
    # Der erste Entwurf legte das Cask-Array in $script: ab und liess die Pruefungen darauf
    # arbeiten. Dabei kam ein Array MIT EINEM ELEMENT an, das seinerseits das eigentliche Array
    # war: .Count sagte 1, waehrend "| Where-Object { $_.token -eq ... }" dank der
    # Eigenschaftsentfaltung von PowerShell trotzdem etwas fand. Die Chrome-Pruefung wurde dadurch
    # gruen, OHNE etwas geprueft zu haben - der schlimmste Zustand, den ein Test haben kann.
    # Zahlen koennen sich nicht so verstecken.
    $script:liveOk = $false
    $script:liveCount = 0
    $script:livePkgCount = 0
    $script:liveChromeIsPkg = $null
    $script:livePkgByToken = @{}
    try {
      $fetched = Invoke-RestMethod -Uri 'https://formulae.brew.sh/api/cask.json' -Method GET -TimeoutSec 180 -ErrorAction Stop
      $casks = [object[]]$fetched
      $script:liveCount = $casks.Length
      if ($script:liveCount -gt 1) {
        $script:liveOk = $true
        $pkg = Select-MacOsPkgCasks -Casks $casks
        $script:livePkgCount = $pkg.Length
        foreach ($e in $pkg) { $script:livePkgByToken[[string]$e.Token] = $e }
        foreach ($c in $casks) {
          if ([string]$c.token -eq 'google-chrome') { $script:liveChromeIsPkg = (Test-IsPkgUrl -Url ([string]$c.url)) }
        }
      }
    } catch {
      $script:liveOk = $false
    }
  }

  It 'liefert einen Katalog in der erwarteten Groessenordnung' {
    if (-not $script:liveOk) { Set-ItResult -Skipped -Because 'keine Netzverbindung zu formulae.brew.sh'; return }
    $script:liveCount | Should -BeGreaterThan 5000
  }

  It 'enthaelt weiterhin eine brauchbare Zahl an PKG-Casks' {
    if (-not $script:liveOk) { Set-ItResult -Skipped -Because 'keine Netzverbindung zu formulae.brew.sh'; return }
    # Am 11.09.2026 waren es 378. Faellt das deutlich, taugt der Katalog als Quelle nicht mehr.
    $script:livePkgCount | Should -BeGreaterThan 200
  }

  It 'fuehrt Google Chrome weiterhin als DMG - der Grund fuer die Ueberschreibliste' {
    if (-not $script:liveOk) { Set-ItResult -Skipped -Because 'keine Netzverbindung zu formulae.brew.sh'; return }
    # Sollte Homebrew eines Tages auf das Enterprise-PKG zeigen, faellt der Ueberschreibeintrag
    # weg - und dieser Test sagt es.
    $script:liveChromeIsPkg | Should -Not -BeNullOrEmpty -Because 'google-chrome muss im Katalog stehen'
    $script:liveChromeIsPkg | Should -BeFalse -Because 'sonst ist die Ueberschreibliste fuer Chrome ueberfluessig geworden'
  }

  It 'liefert fuer die Microsoft-Familie PKG MIT Hash' {
    if (-not $script:liveOk) { Set-ItResult -Skipped -Because 'keine Netzverbindung zu formulae.brew.sh'; return }
    # Diese Apps sind der Grund, warum Homebrew als Quelle ueberhaupt taugt.
    foreach ($token in @('microsoft-teams', 'onedrive', 'zoom')) {
      $script:livePkgByToken.ContainsKey($token) | Should -BeTrue -Because ("{0} soll als PKG im Katalog stehen" -f $token)
      $script:livePkgByToken[$token].Sha256 | Should -Not -BeNullOrEmpty -Because ("{0} soll einen echten Hash mitbringen" -f $token)
    }
  }
}
