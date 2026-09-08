#requires -Version 7
# Die geratene Paket-Id: die zweite Rueckfrage, die "Rueckfragen abschalten" nicht wegdrueckt.
#
# Der Fall, um den es geht: eine App in Intune, die niemand als WinTuner-Paket angelegt hat und fuer
# die keine Id hinterlegt ist. Resolve-WingetIdForApp findet keinen exakten Namenstreffer, aber
# einen Aehnlichkeitstreffer (Score >= 80, 15 Punkte Abstand zum Zweiten) - und nimmt ihn. Ist die
# Vermutung falsch, baut der Lauf ein FREMDES Herstellerpaket, loest die vorhandene App damit ab und
# zieht ihre Zuweisungen mit. Bei einer von Hand paketierten App holt das kein zweiter Lauf zurueck.
#
# Mit SuppressChangeConfirmations lief genau dieser Fall bisher ohne einen einzigen Klick durch:
# geschuetzte Apps fragten nach (-AlwaysAsk), die allgemeine Rueckfrage blieb stumm, und eine
# unmarkierte App mit geratener Id fiel durch beide Netze.
#
# Der gefaehrlichste Fehler beim Bau waere still - genau der, den docs/PATTERNS.md fuer diese Kette
# schon dreimal beschreibt (IsUnmanaged, IsProtected, PackageIdFromNotes gingen dort verloren): der
# Merker kommt am Objekt an, aber Group-UpdateCandidates traegt ihn nicht mit, und die Rueckfrage
# kommt deshalb nie. Deshalb prueft dieser Satz die GRUPPIERUNG mit, nicht nur die Rechnung.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '70-Runtime.ps1' -Name @(
    'Split-AppsByFlag', 'Split-FuzzyMatchedApps', 'Resolve-FuzzyRunChoice'))))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '25-WinGetData.ps1' -Name 'New-WingetIdResult')))

  function New-App {
    param([string]$Name, [bool]$Fuzzy = $false, [bool]$Protected = $false, [string]$PackageId = 'Vendor.Product')
    [pscustomobject]@{
      Name = $Name; CurrentVersion = '1.0'; LatestVersion = '2.0'; PackageId = $PackageId
      PackageIdFuzzy = $Fuzzy; IsProtected = $Protected
    }
  }
}

Describe 'New-WingetIdResult' {
  It 'gibt ohne -AsObject weiterhin die reine Id zurueck' {
    # Jeder bestehende Aufrufer von Resolve-WingetIdForApp erwartet einen String. Ein Objekt an
    # dieser Stelle waere in einen Dateinamen oder eine Paket-Id gewandert.
    New-WingetIdResult -Id 'Google.Chrome' -Source 'exact' | Should -Be 'Google.Chrome'
  }
  It 'gibt ohne -AsObject $null zurueck, wenn keine Id gefunden wurde' {
    New-WingetIdResult -Id '' -Source 'none' | Should -BeNullOrEmpty
  }
  It 'gibt mit -AsObject Id UND Herkunft zurueck' {
    $r = New-WingetIdResult -Id 'Google.Chrome' -Source 'fuzzy' -AsObject
    $r.Id | Should -Be 'Google.Chrome'
    $r.Source | Should -Be 'fuzzy'
  }
}

Describe 'Resolve-WingetIdForApp: die Herkunft der Id' {
  # Die Regeln selbst bleiben unveraendert - geprueft wird, dass jeder der Ausstiege seine Herkunft
  # richtig benennt. Eine als 'exact' gemeldete Vermutung waere schlimmer als keine Meldung.
  BeforeAll {
    . ([scriptblock]::Create((Get-SourceFunctionText -Part '25-WinGetData.ps1' -Name 'Resolve-WingetIdForApp')))
    # Get-StringSimilarity liegt in 30-UpdateTargets, nicht neben dem Aufrufer - und der echte Rumpf
    # gehoert hierher: der Score entscheidet, ob 'fuzzy' ueberhaupt greift. Eine Attrappe wuerde die
    # Schwelle (>= 80, 15 Punkte Abstand) am Test vorbei bestaetigen.
    . ([scriptblock]::Create((Get-SourceFunctionText -Part '30-UpdateTargets.ps1' -Name 'Get-StringSimilarity')))
    function Write-Log { param([string]$Message) }
    $script:settings = @{ WingetOverrides = @{} }
    # Attrappen fuer die zwei Modulaufrufe. Der Test darf nichts suchen und nichts aufloesen -
    # geprueft wird die Entscheidung, nicht das Modul.
    $script:fakeResults = @()
    $script:fakeMarkerId = ''
    function Resolve-WtWingetId {
      param($AppOrResult)
      if ($AppOrResult -and $AppOrResult.PSObject.Properties['FakeId']) { return [string]$AppOrResult.FakeId }
      return $script:fakeMarkerId
    }
    function Search-WtWinGetPackage { param($SearchQuery) return @($script:fakeResults) }
  }

  BeforeEach {
    $script:settings = @{ WingetOverrides = @{} }
    $script:fakeResults = @()
    $script:fakeMarkerId = ''
  }

  It 'nennt einen Override "override"' {
    $script:settings.WingetOverrides = @{ 'Acrobat Reader DC (netgo)' = 'Adobe.Acrobat.Reader.64-bit' }
    $r = Resolve-WingetIdForApp -App ([pscustomobject]@{ Name = 'Acrobat Reader DC (netgo)' }) -Detailed
    $r.Source | Should -Be 'override'
    $r.Id | Should -Be 'Adobe.Acrobat.Reader.64-bit'
  }

  It 'nennt eine Id aus der App selbst "marker"' {
    $script:fakeMarkerId = 'Google.Chrome'
    $r = Resolve-WingetIdForApp -App ([pscustomobject]@{ Name = 'Google Chrome' }) -Detailed
    $r.Source | Should -Be 'marker'
  }

  It 'nennt einen exakten Namenstreffer "exact"' {
    $script:fakeResults = @([pscustomobject]@{ Name = 'Google Chrome'; FakeId = 'Google.Chrome' })
    $r = Resolve-WingetIdForApp -App ([pscustomobject]@{ Name = 'Google Chrome' }) -Detailed
    $r.Source | Should -Be 'exact'
    $r.Id | Should -Be 'Google.Chrome'
  }

  It 'nennt einen Aehnlichkeitstreffer "fuzzy" - der Fall, um den es geht' {
    # Kein exakter Name, ein klar fuehrender Kandidat: genau die Lage, in der die Anwendung raet.
    $script:fakeResults = @(
      [pscustomobject]@{ Name = 'Adobe Acrobat Reader DC'; FakeId = 'Adobe.Acrobat.Reader.64-bit' },
      [pscustomobject]@{ Name = 'Total Commander'; FakeId = 'Ghisler.TotalCommander' }
    )
    $r = Resolve-WingetIdForApp -App ([pscustomobject]@{ Name = 'Adobe Acrobat Reader DC (netgo)' }) -Detailed
    $r.Source | Should -Be 'fuzzy'
    $r.Id | Should -Be 'Adobe.Acrobat.Reader.64-bit'
  }

  It 'nennt "none", wenn kein Treffer sicher genug ist' {
    # Zwei aehnlich gute Kandidaten: unter 15 Punkten Abstand raet die Anwendung NICHT.
    $script:fakeResults = @(
      [pscustomobject]@{ Name = 'Acrobat Reader DD'; FakeId = 'A.One' },
      [pscustomobject]@{ Name = 'Acrobat Reader DE'; FakeId = 'A.Two' }
    )
    $r = Resolve-WingetIdForApp -App ([pscustomobject]@{ Name = 'Acrobat Reader DC' }) -Detailed
    $r.Source | Should -Be 'none'
    $r.Id | Should -BeNullOrEmpty
  }

  It 'liefert ohne -Detailed unveraendert einen String' {
    $script:fakeResults = @([pscustomobject]@{ Name = 'Google Chrome'; FakeId = 'Google.Chrome' })
    $id = Resolve-WingetIdForApp -App ([pscustomobject]@{ Name = 'Google Chrome' })
    $id | Should -BeOfType ([string])
    $id | Should -Be 'Google.Chrome'
  }
}

Describe 'New-UpdateCandidateModel: PackageIdFuzzy' {
  BeforeAll {
    . ([scriptblock]::Create((Get-SourceFunctionText -Part '30-UpdateTargets.ps1' -Name 'New-UpdateCandidateModel')))
    function Test-IsProtectedApp { param([string]$Name, $Patterns) return $false }
    $script:settings = @{ ProtectedApps = @() }
  }

  It 'setzt den Merker NUR bei einer geratenen Id' {
    foreach ($source in @('override', 'marker', 'exact', 'none', '')) {
      $m = New-UpdateCandidateModel -App ([pscustomobject]@{ Name = 'A'; CurrentVersion = '1'; GraphId = 'g' }) `
        -LatestVersion '2' -PackageId 'X.Y' -PackageIdSource $source
      $m.PackageIdFuzzy | Should -BeFalse -Because "'$source' ist keine geratene Id"
    }
    $m = New-UpdateCandidateModel -App ([pscustomobject]@{ Name = 'A'; CurrentVersion = '1'; GraphId = 'g' }) `
      -LatestVersion '2' -PackageId 'X.Y' -PackageIdSource 'fuzzy'
    $m.PackageIdFuzzy | Should -BeTrue
    $m.PackageIdSource | Should -Be 'fuzzy'
  }

  It 'behandelt eine fehlende Angabe als NICHT geraten' {
    # Eine erfundene Warnung ist schlimmer als keine: sie erzieht zum Wegklicken.
    $m = New-UpdateCandidateModel -App ([pscustomobject]@{ Name = 'A'; CurrentVersion = '1'; GraphId = 'g' }) `
      -LatestVersion '2' -PackageId 'X.Y'
    $m.PackageIdFuzzy | Should -BeFalse
  }
}

Describe 'Split-FuzzyMatchedApps' {
  It 'trennt geratene von uebrigen Apps' {
    $split = Split-FuzzyMatchedApps -Apps @((New-App 'Chrome'), (New-App 'Acrobat (netgo)' -Fuzzy $true), (New-App '7-Zip'))
    @($split.Fuzzy).Count | Should -Be 1
    @($split.Fuzzy)[0].Name | Should -Be 'Acrobat (netgo)'
    @($split.Rest).Count | Should -Be 2
  }

  It 'laesst eine GESCHUETZTE App aus - fuer die ist die Frage schon gestellt' {
    # Sonst kaemen zwei Dialoge fuer dieselbe App, und der zweite brachte kein neues Urteil.
    $split = Split-FuzzyMatchedApps -Apps @((New-App 'TeamViewer' -Fuzzy $true -Protected $true))
    @($split.Fuzzy).Count | Should -Be 0
    @($split.Rest).Count | Should -Be 1
  }

  It 'behandelt eine App ohne die Eigenschaft als NICHT geraten' {
    $plain = [pscustomobject]@{ Name = 'Chrome'; CurrentVersion = '1'; LatestVersion = '2' }
    @((Split-FuzzyMatchedApps -Apps @($plain)).Fuzzy).Count | Should -Be 0
  }

  It 'vertraegt eine leere Auswahl und Nullwerte darin' {
    @((Split-FuzzyMatchedApps -Apps @()).Fuzzy).Count | Should -Be 0
    @((Split-FuzzyMatchedApps -Apps @($null, (New-App 'A' -Fuzzy $true))).Fuzzy).Count | Should -Be 1
  }
}

Describe 'Resolve-FuzzyRunChoice' {
  BeforeAll {
    $script:mixed = @((New-App 'Chrome'), (New-App 'Acrobat (netgo)' -Fuzzy $true), (New-App '7-Zip'))
  }

  It "'all' laesst die Liste unveraendert" {
    $r = Resolve-FuzzyRunChoice -Apps $script:mixed -Choice 'all'
    $r.Proceed | Should -BeTrue
    @($r.Apps).Count | Should -Be 3
    @($r.Skipped).Count | Should -Be 0
  }

  It "'skip' entfernt GENAU die geratenen und laesst den Rest laufen" {
    # Der stille Fehler, den dieser Fall verhindert: der Benutzer waehlt "ohne die geratenen", und
    # der Lauf rechnet trotzdem mit der alten Liste weiter - dann baut er genau das Paket, das
    # gerade abgewaehlt wurde.
    $r = Resolve-FuzzyRunChoice -Apps $script:mixed -Choice 'skip'
    $r.Proceed | Should -BeTrue
    @($r.Apps).Count | Should -Be 2
    @($r.Apps | Where-Object { $_.PackageIdFuzzy }).Count | Should -Be 0
    @($r.Skipped).Count | Should -Be 1
  }

  It "'cancel' laesst nichts laufen" {
    $r = Resolve-FuzzyRunChoice -Apps $script:mixed -Choice 'cancel'
    $r.Proceed | Should -BeFalse
    @($r.Apps).Count | Should -Be 0
  }

  It "unterscheidet 'nichts mehr uebrig' von 'abgebrochen'" {
    # Waren AUSSCHLIESSLICH geratene Apps angehakt, ist "skip" kein Abbruch durch den Benutzer -
    # er hat gewaehlt, es gab nur nichts mehr zu tun. Die Meldung darf nicht wie ein Fehler klingen.
    $r = Resolve-FuzzyRunChoice -Apps @((New-App 'Acrobat (netgo)' -Fuzzy $true)) -Choice 'skip'
    $r.Proceed | Should -BeFalse
    $r.Reason | Should -Be 'empty'
    @($r.Skipped).Count | Should -Be 1
  }
}

Describe 'Group-UpdateCandidates traegt den Merker mit' {
  BeforeAll {
    . ([scriptblock]::Create((Get-SourceFunctionText -Part '40-Graph.ps1' -Name 'Group-UpdateCandidates')))
    . ([scriptblock]::Create((Get-SourceFunctionText -Part '20-Version.ps1' -Name @(
      'Test-IsNewerVersion', 'Get-ComparableVersionParts'))))
    function Write-Log { param([string]$Message) }
    function Get-AppAssignmentScopeProbe {
      param([string]$AppId, [string]$AppName)
      return @{ Succeeded = $true; Signature = '<none>'; Summary = 'no assignment' }
    }
    function New-Member2 {
      param([string]$Name, [string]$Version, [bool]$Fuzzy)
      [pscustomobject]@{
        Name = $Name; CurrentVersion = $Version; LatestVersion = '3.0'; GraphId = ('g-' + $Version)
        PackageId = 'Vendor.Product'; PackageIdFuzzy = $Fuzzy; PackageIdSource = $(if ($Fuzzy) { 'fuzzy' } else { 'exact' })
      }
    }
  }

  It 'meldet die Gruppe als geraten, sobald EIN Vorgaenger geraten ist' {
    # Die Gruppe wird zu EINEM Ziel zusammengefasst. Ginge der Merker hier verloren, kaeme die
    # Rueckfrage nie - genau die Falle, in die IsUnmanaged, IsProtected und PackageIdFromNotes an
    # dieser Stelle schon gefallen sind.
    $groups = @(Group-UpdateCandidates -Candidates @((New-Member2 -Name 'App' -Version '1.0' -Fuzzy $false), (New-Member2 -Name 'App' -Version '2.0' -Fuzzy $true)))
    @($groups).Count | Should -Be 1
    $groups[0].PackageIdFuzzy | Should -BeTrue
  }

  It 'meldet eine Gruppe ohne geratene Vorgaenger als nicht geraten' {
    $groups = @(Group-UpdateCandidates -Candidates @((New-Member2 -Name 'App' -Version '1.0' -Fuzzy $false), (New-Member2 -Name 'App' -Version '2.0' -Fuzzy $false)))
    $groups[0].PackageIdFuzzy | Should -BeFalse
  }
}

Describe 'Verdrahtung: die Rueckfrage haengt in BEIDEN Laeufen' {
  BeforeAll { $script:main = Get-SourcePartText -Part '90-Main.ps1' }

  It 'fragt in "Ausgewaehlte aktualisieren" UND in "Alle aktualisieren"' {
    ([regex]::Matches($script:main, 'Confirm-FuzzyMatchedAppsInRun')).Count | Should -Be 2
  }

  It 'rechnet mit der Liste AUS DEM ERGEBNIS weiter' {
    # Ohne diese Zuweisung waere der ganze Riegel wirkungslos - und zwar lautlos.
    $script:main | Should -Match '\$checkedApps = @\(\$fuzzyChoice\.Apps\)'
    $script:main | Should -Match '\$updatedApps = @\(\$fuzzyChoice\.Apps\)'
  }

  It 'meldet die ausgelassenen Apps in der Statuszeile' {
    ([regex]::Matches($script:main, 'FuzzyRunSkippedStatus')).Count | Should -Be 2
    ([regex]::Matches($script:main, 'FuzzyRunNothingLeftStatus')).Count | Should -Be 2
  }

  It 'geht NICHT durch Confirm-ChangeAction - diese Frage ist nicht abschaltbar' {
    # Der Kern des Auftrags: SuppressChangeConfirmations darf diese Frage nicht wegdruecken.
    # Nur Code-Zeilen ansehen, damit die Begruendung im Kommentar stehen bleiben darf.
    $fn = Get-SourceFunctionText -Part '70-Runtime.ps1' -Name 'Confirm-FuzzyMatchedAppsInRun'
    $code = @($fn -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    $code | Should -Not -Match 'Confirm-ChangeAction'
    $code | Should -Not -Match 'Test-ChangeConfirmationsSuppressed'
    $code | Should -Match 'Show-ProtectedRunDialog'
  }

  It 'nennt die geratene Id im Dialog und im Protokoll' {
    # "3 Apps mit geratener Id" beantwortet die eine Frage nicht, die zaehlt: WELCHES Paket haette
    # er genommen? Ohne die Id ist die Rueckfrage nicht entscheidbar.
    $fn = Get-SourceFunctionText -Part '70-Runtime.ps1' -Name 'Confirm-FuzzyMatchedAppsInRun'
    $fn | Should -Match '\$_\.PackageId'
    $fn | Should -Match 'Write-Log'
  }

  It 'zeigt es auch in der Zeile, vor dem Haken' {
    $rows = Get-SourceFunctionText -Part '85-Rows.ps1' -Name 'New-UpdateRow'
    $rows | Should -Match 'PackageIdFuzzy'
    $rows | Should -Match 'UpdateStateFuzzyId'
  }

  It 'hat jeden neuen Text in BEIDEN Sprachbloecken' {
    # Die Paritaet aller Schluessel prueft StaticChecks; hier geht es um diese sieben - ein Text,
    # der nur auf Englisch existiert, faellt im deutschen Fenster als leerer Dialog auf.
    $strings = Get-SourcePartText -Part '15-Strings.ps1'
    foreach ($key in @('FuzzyRunConfirmTitle', 'FuzzyRunConfirmDialog', 'FuzzyRunSkipButton',
                       'FuzzyRunAllButton', 'FuzzyRunSkippedStatus', 'FuzzyRunNothingLeftStatus',
                       'UpdateStateFuzzyId')) {
      ([regex]::Matches($strings, ("(?m)^\s*{0}\s*=" -f [regex]::Escape($key)))).Count |
        Should -Be 2 -Because "$key muss einmal in EN und einmal in DE stehen"
    }
  }

  It 'nennt in beiden Sprachen, dass die Frage nicht abschaltbar ist' {
    # Wer die Rueckfragen abgeschaltet hat und trotzdem gefragt wird, soll im Dialog lesen, warum -
    # sonst sieht es wie ein Fehler der Einstellung aus.
    . ([scriptblock]::Create((Get-UiStringsText)))
    $script:uiLanguage = 'en'
    (Get-UiString 'FuzzyRunConfirmDialog') | Should -Match 'switched off'
    $script:uiLanguage = 'de'
    (Get-UiString 'FuzzyRunConfirmDialog') | Should -Match 'abgeschaltet'
  }
}
