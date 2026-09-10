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
  # Die Rueckfrage selbst steht seit 0.19.1 nicht mehr hier: sie ist mit den beiden anderen nicht
  # wegdrueckbaren Fragen zu EINER zusammengefasst (RiskyRunConfirm.Tests.ps1). Diese Datei prueft
  # den Weg DORTHIN - woher die Id stammt, ob der Merker gesetzt und durch die Gruppierung
  # getragen wird.
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '70-Runtime.ps1' -Name @(
    'Get-RunRiskFindings'))))
  $script:runRiskClasses = @('protected', 'fuzzy', 'foreign')
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

Describe 'Die Einordnung sieht den Merker' {

  It 'fuehrt eine App mit geratener Id als Befund' {
    $f = Get-RunRiskFindings -Apps @((New-App 'Chrome'), (New-App 'Acrobat (netgo)' -Fuzzy $true), (New-App '7-Zip'))
    @($f.Fuzzy).Count | Should -Be 1
    @($f.Fuzzy)[0].Name | Should -Be 'Acrobat (netgo)'
    @($f.Rest).Count | Should -Be 2
  }

  It 'fragt eine GESCHUETZTE App mit geratener Id nicht zweimal' {
    # Sonst stuende dieselbe App zweimal in der Liste, und die zweite Zeile brachte kein neues
    # Urteil. Sie steht unter dem ernsteren Grund - genannt wird die geratene Id trotzdem.
    $f = Get-RunRiskFindings -Apps @((New-App 'TeamViewer' -Fuzzy $true -Protected $true))
    $f.Total | Should -Be 1
    @($f.Fuzzy).Count | Should -Be 0
    @($f.Protected).Count | Should -Be 1
  }

  It 'behandelt eine App ohne die Eigenschaft als NICHT geraten' {
    $plain = [pscustomobject]@{ Name = 'Chrome'; CurrentVersion = '1'; LatestVersion = '2' }
    (Get-RunRiskFindings -Apps @($plain)).Total | Should -Be 0
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

Describe 'Verdrahtung: die geratene Id kommt bis in die Rueckfrage' {

  It 'nennt die geratene Id in der Vorschau der Rueckfrage' {
    # "3 Apps mit geratener Id" beantwortet die eine Frage nicht, die zaehlt: WELCHES Paket haette
    # er genommen? Ohne die Id ist die Rueckfrage nicht entscheidbar.
    $fn = Get-SourceFunctionText -Part '70-Runtime.ps1' -Name 'Get-RunRiskAppLine'
    $fn | Should -Match '\$App\.PackageId'
    $fn | Should -Match 'RiskyRunNoteGuessedId'
  }

  It 'zeigt es auch in der Zeile, vor dem Haken' {
    $rows = Get-SourceFunctionText -Part '85-Rows.ps1' -Name 'New-UpdateRow'
    $rows | Should -Match 'PackageIdFuzzy'
    $rows | Should -Match 'UpdateStateFuzzyId'
  }

  It 'hat den Zeilentext in BEIDEN Sprachbloecken' {
    $strings = Get-SourcePartText -Part '15-Strings.ps1'
    foreach ($key in @('UpdateStateFuzzyId', 'RiskyRunNoteGuessedId', 'RiskyRunHeadGuessed')) {
      ([regex]::Matches($strings, ("(?m)^\s*{0}\s*=" -f [regex]::Escape($key)))).Count |
        Should -Be 2 -Because "$key muss einmal in EN und einmal in DE stehen"
    }
  }
}
