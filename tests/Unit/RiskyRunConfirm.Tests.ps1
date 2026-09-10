#requires -Version 7
# EINE Rueckfrage fuer alle Befunde eines Laufs.
#
# Bis 0.19.0 standen hier drei nicht wegdrueckbare Dialoge hintereinander (geschuetzte Apps,
# geratene Paket-Id, vorhandene Fassung eines anderen Paketierungstyps). Jeder war fuer sich
# richtig; zusammen erzogen sie zum Durchklicken - und wer 'Rueckfragen ueberspringen' gesetzt hat,
# tut das gerade, weil er klickfrei arbeiten will.
#
# Dazu kam ein echter Fehler: eine App mit geratener Id UND einer neueren Fassung anderen Typs wurde
# ZWEIMAL gefragt, mit denselben drei Knoepfen. Der Fall steht unten als eigene Regressionspruefung.
#
# Der gefaehrlichste Fehler beim Umbau waere still: der Benutzer waehlt "ohne diese", und der Lauf
# rechnet trotzdem mit der alten Liste weiter. Dann baut die Anwendung genau die App, die gerade
# abgewaehlt wurde - ohne Fehlermeldung. Deshalb pruefen die Faelle unten die zurueckgegebene LISTE,
# nicht nur das Ja/Nein.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  # Die ECHTEN Texte, nicht Attrappen: die Vorschau setzt Ueberschriften und Zeilen aus
  # UI-Schluesseln zusammen, und ein Test gegen eine Kopie wuerde einen fehlenden Schluessel nicht
  # bemerken.
  . ([scriptblock]::Create((Get-UiStringsText)))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '70-Runtime.ps1' -Name @(
    'Get-RunRiskFindings', 'Resolve-RiskyRunChoice', 'Get-RunRiskAppLine',
    'Get-RunRiskPreview', 'Confirm-RiskyAppsInRun'))))
  # Die Klassenliste steht als Skriptvariable neben den Funktionen und wird von
  # Get-RunRiskFindings gebraucht.
  $script:runRiskClasses = @('protected', 'fuzzy', 'foreign')

  function New-App {
    param(
      [string]$Name,
      [bool]$Protected = $false,
      [bool]$Fuzzy = $false,
      [bool]$Foreign = $false,
      [string]$From = '1.0',
      [string]$To = '2.0',
      [string]$PackageId = 'Vendor.Product',
      [bool]$ForeignAssigned = $false
    )
    [pscustomobject]@{
      Name                 = $Name
      CurrentVersion       = $From
      LatestVersion        = $To
      IsProtected          = $Protected
      PackageIdFuzzy       = $Fuzzy
      PackageId            = $PackageId
      HasForeignNewer      = $Foreign
      ForeignNewerVersion  = '3.0'
      ForeignNewerType     = 'MSI'
      ForeignNewerAssigned = $ForeignAssigned
    }
  }

  $script:mixed = @(
    (New-App 'Google Chrome'),
    (New-App 'TeamViewer Host' -Protected $true),
    (New-App '7-Zip'),
    (New-App 'Acrobat (netgo)' -Fuzzy $true),
    (New-App 'Notepad++' -Foreign $true)
  )
}

Describe 'Get-RunRiskFindings' {

  It 'sortiert jede App in ihre Klasse und laesst den Rest unangetastet' {
    $f = Get-RunRiskFindings -Apps $script:mixed
    @($f.Protected).Count | Should -Be 1
    @($f.Fuzzy).Count     | Should -Be 1
    @($f.Foreign).Count   | Should -Be 1
    @($f.Rest).Count      | Should -Be 2
    $f.Total | Should -Be 3
    @($f.Rest | ForEach-Object { $_.Name }) | Should -Contain '7-Zip'
  }

  It 'zaehlt eine App mit ZWEI Befunden nur EINMAL - die Doppelfrage von 0.19.0' {
    # Der eigentliche Fehler: Split-FuzzyMatchedApps und Split-ForeignNewerApps schlossen beide nur
    # 'IsProtected' aus, nicht sich gegenseitig. Diese App stand deshalb in beiden Rueckfragen.
    $f = Get-RunRiskFindings -Apps @((New-App 'Chrome' -Fuzzy $true -Foreign $true))
    $f.Total | Should -Be 1
    @($f.Fuzzy).Count   | Should -Be 1
    @($f.Foreign).Count | Should -Be 0
  }

  It 'ordnet nach Gewicht: geschuetzt schlaegt geraten schlaegt fremder Typ' {
    $f = Get-RunRiskFindings -Apps @((New-App 'Alles' -Protected $true -Fuzzy $true -Foreign $true))
    @($f.Protected).Count | Should -Be 1
    @($f.Fuzzy).Count     | Should -Be 0
    @($f.Foreign).Count   | Should -Be 0
    $f.Total | Should -Be 1
  }

  It 'behandelt eine App ohne die Eigenschaften als unauffaellig' {
    # Ein Objekt aus einem aelteren Pfad hat die Merker vielleicht gar nicht - das darf weder
    # werfen noch die App stillschweigend als auffaellig fuehren.
    $f = Get-RunRiskFindings -Apps @([pscustomobject]@{ Name = 'Alt'; CurrentVersion = '1'; LatestVersion = '2' })
    $f.Total | Should -Be 0
    @($f.Rest).Count | Should -Be 1
  }

  It 'vertraegt eine leere Auswahl und Nullwerte darin' {
    (Get-RunRiskFindings -Apps @()).Total | Should -Be 0
    $f = Get-RunRiskFindings -Apps @($null, (New-App 'A' -Protected $true), $null)
    $f.Total | Should -Be 1
  }
}

Describe 'Resolve-RiskyRunChoice' {

  It "'all' laesst die Liste unveraendert" {
    $r = Resolve-RiskyRunChoice -Apps $script:mixed -Choice 'all'
    $r.Proceed | Should -BeTrue
    @($r.Apps).Count | Should -Be 5
    @($r.Skipped).Count | Should -Be 0
    $r.Reason | Should -Be 'all'
  }

  It "'skip' entfernt GENAU die auffaelligen aller drei Klassen" {
    $r = Resolve-RiskyRunChoice -Apps $script:mixed -Choice 'skip'
    $r.Proceed | Should -BeTrue
    @($r.Apps).Count | Should -Be 2
    $names = @($r.Apps | ForEach-Object { $_.Name })
    $names | Should -Not -Contain 'TeamViewer Host'
    $names | Should -Not -Contain 'Acrobat (netgo)'
    $names | Should -Not -Contain 'Notepad++'
    @($r.Skipped).Count | Should -Be 3
    $r.Reason | Should -Be 'skip'
  }

  It "'cancel' laesst nichts laufen" {
    $r = Resolve-RiskyRunChoice -Apps $script:mixed -Choice 'cancel'
    $r.Proceed | Should -BeFalse
    @($r.Apps).Count | Should -Be 0
    $r.Reason | Should -Be 'cancel'
  }

  It "unterscheidet 'nichts mehr uebrig' von 'abgebrochen'" {
    # Waren NUR auffaellige Apps angehakt, bleibt bei 'skip' nichts uebrig. Der Benutzer hat aber
    # gewaehlt - die Meldung darf nicht "abgebrochen" sagen, sonst sucht er den Fehler bei sich.
    $r = Resolve-RiskyRunChoice -Apps @((New-App 'TeamViewer' -Protected $true)) -Choice 'skip'
    $r.Proceed | Should -BeFalse
    $r.Reason | Should -Be 'empty'
    @($r.Skipped).Count | Should -Be 1
  }

  It 'gibt eine Auswahl ganz ohne Befund in jedem Fall durch' {
    $plain = @((New-App 'Chrome'), (New-App '7-Zip'))
    foreach ($choice in @('all', 'skip')) {
      $r = Resolve-RiskyRunChoice -Apps $plain -Choice $choice
      $r.Proceed | Should -BeTrue
      @($r.Apps).Count | Should -Be 2
    }
  }
}

Describe 'Get-RunRiskAppLine' {

  It 'nennt Name und beide Versionen' {
    $line = Get-RunRiskAppLine -App (New-App 'Splashtop Streamer' -Protected $true -From '3.5' -To '3.6')
    $line | Should -Match 'Splashtop Streamer'
    $line | Should -Match '3\.5 -> 3\.6'
  }

  It 'nennt ALLE zutreffenden Gruende, auch wenn die App nur unter dem ernstesten steht' {
    # Sonst entscheidet der Leser auf halber Grundlage: eine geschuetzte App mit geratener Id ist
    # der schlimmste Fall ueberhaupt, aber sie steht in der Klasse 'protected'.
    $line = Get-RunRiskAppLine -App (New-App 'Acrobat (netgo)' -Protected $true -Fuzzy $true -PackageId 'Adobe.Acrobat')
    $line | Should -Match 'Adobe\.Acrobat'
  }

  It 'nennt bei der fremden Fassung Typ, Version und Zuweisung' {
    $line = Get-RunRiskAppLine -App (New-App 'Chrome' -Foreign $true -ForeignAssigned $true)
    $line | Should -Match 'MSI'
    $line | Should -Match '3\.0'
    $line | Should -Match ([regex]::Escape((Get-UiString 'ForeignNewerAssignedTag')))
  }

  It 'haengt an eine unauffaellige App keine Klammer' {
    (Get-RunRiskAppLine -App (New-App 'Chrome')) | Should -Not -Match '\['
  }
}

Describe 'Get-RunRiskPreview' {

  It 'schreibt nur zu den Klassen eine Ueberschrift, die auch Apps haben' {
    $p = Get-RunRiskPreview -Findings (Get-RunRiskFindings -Apps @((New-App 'TeamViewer' -Protected $true)))
    $p | Should -Match 'TeamViewer'
    # Keine Ueberschrift zu einer leeren Klasse und keine Leerzeile am Ende.
    $p | Should -Not -Match 'GUESSED|GERATENEN'
    $p | Should -Be $p.TrimEnd()
  }

  It 'nennt alle drei Klassen, wenn alle drei vorkommen' {
    $p = Get-RunRiskPreview -Findings (Get-RunRiskFindings -Apps $script:mixed)
    $p | Should -Match 'TeamViewer Host'
    $p | Should -Match 'Acrobat \(netgo\)'
    $p | Should -Match 'Notepad\+\+'
  }

  It 'kuerzt eine lange Liste und sagt es' {
    $many = @(1..20 | ForEach-Object { New-App ("App{0}" -f $_) -Protected $true })
    $p = Get-RunRiskPreview -Findings (Get-RunRiskFindings -Apps $many)
    $p | Should -Match '  - \.\.\.'
    @($p -split "`r`n" | Where-Object { $_ -match '^  - App' }).Count | Should -Be 12
  }

  It 'liefert bei einer Auswahl ohne Befund eine leere Vorschau' {
    (Get-RunRiskPreview -Findings (Get-RunRiskFindings -Apps @((New-App 'Chrome')))) | Should -Be ''
  }
}

Describe 'Confirm-RiskyAppsInRun' {
  BeforeEach {
    $global:TestLog.Clear()
    $global:ConfirmCalls = 0
    $global:LastConfirmCount = 0
    $global:LastConfirmPreview = ''
    # Standardantwort 'all': der Weg, der dem frueheren "Ja" entspricht.
    $global:ConfirmAnswer = 'all'
    # Gemockt wird der EIGENE Dialog, nicht Confirm-ChangeAction. Dass diese Frage nicht
    # unterdrueckbar ist, ergibt sich daraus, dass sie gar nicht durch Confirm-ChangeAction laeuft -
    # geprueft wird das unten in der Verdrahtung.
    Set-Item -Path function:global:Show-RiskyRunDialog -Value {
      param([int]$Count, [string]$Preview)
      $global:ConfirmCalls++
      $global:LastConfirmCount = $Count
      $global:LastConfirmPreview = $Preview
      return $global:ConfirmAnswer
    }
  }

  AfterAll {
    Remove-Item -Path function:global:Show-RiskyRunDialog -ErrorAction SilentlyContinue
  }

  It 'fragt gar nicht, wenn kein Befund dabei ist' {
    # Der Normalfall darf keinen zusaetzlichen Klick kosten, sonst wird die Rueckfrage zur Gewohnheit
    # und damit wirkungslos.
    $r = Confirm-RiskyAppsInRun -Apps @((New-App 'Google Chrome'))
    $r.Proceed | Should -BeTrue
    @($r.Apps).Count | Should -Be 1
    $r.Reason | Should -Be 'none'
    $global:ConfirmCalls | Should -Be 0
  }

  It 'fragt bei drei Befundarten trotzdem nur EIN Mal' {
    # Das ist der Zweck des Umbaus: vorher waren das drei Dialoge hintereinander.
    [void](Confirm-RiskyAppsInRun -Apps $script:mixed)
    $global:ConfirmCalls | Should -Be 1
    $global:LastConfirmCount | Should -Be 3
  }

  It 'fragt eine App mit zwei Befunden nur EIN Mal' {
    [void](Confirm-RiskyAppsInRun -Apps @((New-App 'Chrome' -Fuzzy $true -Foreign $true)))
    $global:ConfirmCalls | Should -Be 1
    $global:LastConfirmCount | Should -Be 1
  }

  It 'nennt die betroffenen Apps in der Vorschau und die unauffaelligen nicht' {
    [void](Confirm-RiskyAppsInRun -Apps @(
      (New-App 'Google Chrome'),
      (New-App 'Splashtop Streamer' -Protected $true -From '3.5' -To '3.6')))
    $global:LastConfirmPreview | Should -Match 'Splashtop Streamer'
    $global:LastConfirmPreview | Should -Match '3\.5 -> 3\.6'
    $global:LastConfirmPreview | Should -Not -Match 'Google Chrome'
  }

  It 'nennt sie namentlich im Protokoll, je Klasse' {
    # "3 auffaellige Apps" beantwortet im Nachhinein nicht, WELCHE freigegeben wurden - und genau
    # das ist die Frage nach einem Fehlgriff.
    [void](Confirm-RiskyAppsInRun -Apps @(
      (New-App 'Keeper Password Manager' -Protected $true),
      (New-App 'Acrobat (netgo)' -Fuzzy $true),
      (New-App 'Notepad++' -Foreign $true)))
    $log = ($global:TestLog -join "`n")
    $log | Should -Match 'protected \(self-packaged\).*Keeper Password Manager'
    $log | Should -Match 'guessed from the display name.*Acrobat'
    $log | Should -Match 'another packaging type.*Notepad'
  }

  It 'sagt im Protokoll, dass die Unterdrueckungseinstellung hier nicht gilt' {
    [void](Confirm-RiskyAppsInRun -Apps @((New-App 'TeamViewer' -Protected $true)))
    ($global:TestLog -join "`n") | Should -Match 'regardless of the suppression setting'
  }

  It 'bricht ab, wenn der Benutzer abbricht' {
    $global:ConfirmAnswer = 'cancel'
    $r = Confirm-RiskyAppsInRun -Apps @((New-App 'Splashtop Streamer' -Protected $true))
    $r.Proceed | Should -BeFalse
    ($global:TestLog -join "`n") | Should -Match 'canceled at the findings confirmation'
  }

  It 'laesst die auffaelligen aus und den Rest laufen' {
    $global:ConfirmAnswer = 'skip'
    $r = Confirm-RiskyAppsInRun -Apps @(
      (New-App 'Google Chrome'),
      (New-App 'Splashtop Streamer' -Protected $true),
      (New-App 'Acrobat (netgo)' -Fuzzy $true))
    $r.Proceed | Should -BeTrue
    @($r.Apps).Count | Should -Be 1
    @($r.Apps)[0].Name | Should -Be 'Google Chrome'
    $log = ($global:TestLog -join "`n")
    $log | Should -Match 'Left out of this run'
    $log | Should -Match 'Splashtop Streamer'
    $log | Should -Match 'Acrobat'
  }

  It 'meldet den Sonderfall, in dem nach dem Auslassen nichts uebrig bleibt' {
    $global:ConfirmAnswer = 'skip'
    $r = Confirm-RiskyAppsInRun -Apps @((New-App 'TeamViewer' -Protected $true))
    $r.Proceed | Should -BeFalse
    $r.Reason | Should -Be 'empty'
    ($global:TestLog -join "`n") | Should -Match 'nothing was built or uploaded'
  }

  It 'kommt mit einer leeren Auswahl aus' {
    $r = Confirm-RiskyAppsInRun -Apps @()
    $r.Proceed | Should -BeTrue
    $global:ConfirmCalls | Should -Be 0
  }
}

Describe 'Verdrahtung: der Lauf rechnet mit der Liste AUS DEM ERGEBNIS' {
  BeforeAll { $script:main = Get-SourcePartText -Part '90-Main.ps1' }

  It 'haengt in BEIDEN Laeufen - und nur noch einmal je Lauf' {
    # Der Weg, auf dem eine auffaellige App am ehesten ungesehen mitlaeuft, ist "Alle
    # aktualisieren": niemand liest dabei jede Zeile.
    $script:main | Should -Match '\$riskChoice = Confirm-RiskyAppsInRun -Apps @\(\$checkedApps\)'
    $script:main | Should -Match '\$riskChoice = Confirm-RiskyAppsInRun -Apps @\(\$updatedApps\)'
    ([regex]::Matches($script:main, 'Confirm-RiskyAppsInRun')).Count | Should -Be 2
  }

  It 'setzt beide Aufrufstellen auf die zurueckgegebene Liste um' {
    # Ohne diese Zuweisung waere der ganze Umbau wirkungslos - und zwar lautlos.
    $script:main | Should -Match '\$checkedApps = @\(\$riskChoice\.Apps\)'
    $script:main | Should -Match '\$updatedApps = @\(\$riskChoice\.Apps\)'
  }

  It 'meldet die ausgelassenen Apps in der Statuszeile' {
    ([regex]::Matches($script:main, 'RiskyRunSkippedStatus')).Count | Should -Be 2
    ([regex]::Matches($script:main, 'RiskyRunNothingLeftStatus')).Count | Should -Be 2
  }

  It 'hat die drei alten Rueckfragen wirklich abgeloest, nicht nur ergaenzt' {
    # Sonst stuenden vier Dialoge statt drei - genau das Gegenteil des Umbaus.
    $runtime = Get-SourcePartText -Part '70-Runtime.ps1'
    foreach ($old in @('Confirm-ProtectedAppsInRun', 'Confirm-FuzzyMatchedAppsInRun',
                       'Confirm-ForeignNewerAppsInRun', 'Show-ProtectedRunDialog')) {
      $script:main | Should -Not -Match ([regex]::Escape($old))
      $runtime | Should -Not -Match ([regex]::Escape($old))
    }
  }

  It 'geht NICHT durch Confirm-ChangeAction - diese Frage ist nicht abschaltbar' {
    # Nur die Code-Zeilen ansehen: der Name steht weiterhin im Kommentar, der erklaert, WARUM hier
    # ein eigener Dialog steht. Ein Test, der einen Kommentar fuer einen Aufruf haelt, zwingt dazu,
    # die Begruendung zu loeschen, um gruen zu werden - das ist der falsche Anreiz.
    $fn = Get-SourceFunctionText -Part '70-Runtime.ps1' -Name 'Confirm-RiskyAppsInRun'
    $code = @($fn -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    $code | Should -Not -Match 'Confirm-ChangeAction'
    $code | Should -Not -Match 'Test-ChangeConfirmationsSuppressed'
    $code | Should -Match 'Show-RiskyRunDialog'
  }

  It 'macht Abbrechen zum Escape-Weg, nicht "alles bearbeiten"' {
    # Escape und das Fensterkreuz duerfen nie die folgenreichste Wahl bedeuten.
    $dlg = Get-SourceFunctionText -Part '55-Dialogs.ps1' -Name 'Show-RiskyRunDialog'
    $dlg | Should -Match '\$dlg\.CancelButton = \$cancelButton'
    $dlg | Should -Match "riskyRunChoice = 'cancel'"
  }

  It 'laesst die Wahl nur gelten, wenn ein Knopf gedrueckt wurde' {
    # Jeder andere Ausgang - Escape, Fensterkreuz, ein Close() von aussen - ist ein Abbruch. Die
    # Merkervariable allein reicht dafuer nicht: in einem Probelauf, in dem der Dialog auf anderem
    # Weg geschlossen wurde, kam einmal 'skip' zurueck.
    $dlg = Get-SourceFunctionText -Part '55-Dialogs.ps1' -Name 'Show-RiskyRunDialog'
    $dlg | Should -Match '\$result = \$dlg\.ShowDialog\(\)'
    $dlg | Should -Match "if \(\`$result -ne \[System\.Windows\.Forms\.DialogResult\]::OK\) \{ return 'cancel' \}"
  }
}

Describe 'Texte' {
  BeforeAll { $script:strings = Get-SourcePartText -Part '15-Strings.ps1' }

  It 'hat jeden neuen Schluessel in BEIDEN Sprachbloecken' {
    foreach ($key in @('RiskyRunConfirmTitle', 'RiskyRunConfirmDialog', 'RiskyRunSkipButton',
                       'RiskyRunAllButton', 'RiskyRunHeadProtected', 'RiskyRunHeadGuessed',
                       'RiskyRunHeadForeign', 'RiskyRunNoteGuessedId', 'RiskyRunNoteForeign',
                       'RiskyRunSkippedStatus', 'RiskyRunNothingLeftStatus')) {
      ([regex]::Matches($script:strings, ('(?m)^\s+{0} = ' -f [regex]::Escape($key)))).Count |
        Should -Be 2 -Because "$key muss in EN und DE stehen"
    }
  }

  It 'hat die Schluessel der drei abgeloesten Rueckfragen entfernt' {
    # Tote UI-Schluessel meldet StaticChecks ohnehin; hier steht der Fall namentlich, damit klar
    # ist, dass das Loeschen Absicht war und nicht vergessen wurde.
    foreach ($key in @('ProtectedRunConfirmDialog', 'FuzzyRunConfirmDialog', 'ForeignNewerRunConfirmDialog',
                       'ProtectedRunSkippedStatus', 'FuzzyRunSkippedStatus', 'ForeignNewerRunSkippedStatus')) {
      $script:strings | Should -Not -Match ([regex]::Escape($key))
    }
  }

  It 'sagt in beiden Sprachen, dass die Frage nicht abschaltbar ist' {
    $script:uiLanguage = 'en'
    (Get-UiString 'RiskyRunConfirmDialog') | Should -Match 'switched off'
    $script:uiLanguage = 'de'
    (Get-UiString 'RiskyRunConfirmDialog') | Should -Match 'abgeschaltet'
  }

  It 'nennt in jeder Ueberschrift die Zahl der betroffenen Apps' {
    # Ohne {0} stuende dort eine Ueberschrift ohne Anzahl - und -f wuerde den Wert stillschweigend
    # verschlucken.
    foreach ($key in @('RiskyRunHeadProtected', 'RiskyRunHeadGuessed', 'RiskyRunHeadForeign')) {
      foreach ($lang in @('en', 'de')) {
        $script:uiLanguage = $lang
        (Get-UiString $key) | Should -Match '\{0\}' -Because "$key braucht {0} in $lang"
      }
    }
  }
}
