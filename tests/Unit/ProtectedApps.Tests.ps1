BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '10-Settings.ps1' -Name @(
    'Test-IsProtectedApp', 'Set-ProtectedAppPatterns',
    'Add-ProtectedAppPattern', 'Remove-ProtectedAppPattern'))))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '70-Runtime.ps1' -Name @(
    'Confirm-ProtectedAppsInRun', 'Split-ProtectedApps', 'Resolve-ProtectedRunChoice'))))

  function New-Candidate {
    param([string]$Name, [bool]$Protected = $false, [string]$From = '1.0', [string]$To = '2.0')
    [pscustomobject]@{ Name = $Name; CurrentVersion = $From; LatestVersion = $To; IsProtected = $Protected }
  }
}

Describe 'Test-IsProtectedApp' {
  It 'trifft einen Eintrag ohne Platzhalter genau' {
    Test-IsProtectedApp -Name 'Zoom Rooms' -Patterns @('Zoom Rooms') | Should -BeTrue
  }

  It 'ignoriert dabei Gross- und Kleinschreibung' {
    Test-IsProtectedApp -Name 'zoom rooms' -Patterns @('Zoom Rooms') | Should -BeTrue
  }

  It 'trifft OHNE Platzhalter nicht auch verwandte Namen' {
    # Das ist der Punkt der Regel: wer "Zoom Rooms" schuetzt, will nicht ungefragt auch
    # "Zoom Workplace" gesperrt bekommen - sonst waere unklar, warum eine Zeile ploetzlich fragt.
    Test-IsProtectedApp -Name 'Zoom Workplace' -Patterns @('Zoom Rooms') | Should -BeFalse
    Test-IsProtectedApp -Name 'Zoom Rooms Client' -Patterns @('Zoom Rooms') | Should -BeFalse
  }

  It 'wertet einen Eintrag MIT Stern als Muster aus' {
    Test-IsProtectedApp -Name 'Splashtop Streamer' -Patterns @('Splashtop*') | Should -BeTrue
    Test-IsProtectedApp -Name 'Splashtop Business' -Patterns @('Splashtop*') | Should -BeTrue
    Test-IsProtectedApp -Name 'TeamViewer Host'    -Patterns @('Splashtop*') | Should -BeFalse
  }

  It 'wertet das Fragezeichen ebenfalls als Platzhalter aus' {
    Test-IsProtectedApp -Name 'Tool v2' -Patterns @('Tool v?') | Should -BeTrue
    Test-IsProtectedApp -Name 'Tool v20' -Patterns @('Tool v?') | Should -BeFalse
  }

  It 'nimmt den ersten passenden Eintrag aus einer laengeren Liste' {
    $list = @('Splashtop*', 'Keeper Password Manager', 'TeamViewer*')
    Test-IsProtectedApp -Name 'TeamViewer Host' -Patterns $list | Should -BeTrue
    Test-IsProtectedApp -Name 'Google Chrome'   -Patterns $list | Should -BeFalse
  }

  It 'schuetzt nichts bei leerer Liste, leerem Namen oder $null' {
    # Der haeufigste Zustand ueberhaupt - eine frische settings.json hat die Liste leer. Ein Fehler
    # hier wuerde entweder alles oder nichts schuetzen, und beides faellt spaet auf.
    Test-IsProtectedApp -Name 'Google Chrome' -Patterns @()   | Should -BeFalse
    Test-IsProtectedApp -Name 'Google Chrome' -Patterns $null | Should -BeFalse
    Test-IsProtectedApp -Name ''  -Patterns @('*')            | Should -BeFalse
    Test-IsProtectedApp -Name $null -Patterns @('*')          | Should -BeFalse
  }

  It 'ueberspringt Leereintraege statt sie als Treffer zu werten' {
    # Ein '' in der Liste als "trifft alles" zu lesen haette JEDE App geschuetzt - der Lauf haette
    # dann bei jeder einzelnen Zeile nachgefragt und die Rueckfrage damit wertlos gemacht.
    Test-IsProtectedApp -Name 'Google Chrome' -Patterns @('', '   ', $null) | Should -BeFalse
  }

  It 'ignoriert Leerzeichen am Rand - in beiden Richtungen' {
    Test-IsProtectedApp -Name '  Zoom Rooms  ' -Patterns @('Zoom Rooms')     | Should -BeTrue
    Test-IsProtectedApp -Name 'Zoom Rooms'     -Patterns @('  Zoom Rooms  ') | Should -BeTrue
  }
}

Describe 'Set-ProtectedAppPatterns' {
  It 'trimmt, wirft Leereintraege weg und sortiert' {
    Set-ProtectedAppPatterns -Patterns @('  TeamViewer* ', '', 'Splashtop*', '   ') |
      Should -Be @('Splashtop*', 'TeamViewer*')
  }

  It 'entfernt Doppelte ohne Ruecksicht auf Gross-/Kleinschreibung' {
    @(Set-ProtectedAppPatterns -Patterns @('Splashtop*', 'splashtop*', 'SPLASHTOP*')).Count | Should -Be 1
  }

  It 'kommt mit einer leeren Liste und mit $null aus' {
    @(Set-ProtectedAppPatterns -Patterns @()).Count   | Should -Be 0
    @(Set-ProtectedAppPatterns -Patterns $null).Count | Should -Be 0
  }
}

Describe 'Add-ProtectedAppPattern und Remove-ProtectedAppPattern' {
  It 'fuegt hinzu' {
    Add-ProtectedAppPattern -Patterns @('Splashtop*') -Pattern 'Keeper Password Manager' |
      Should -Be @('Keeper Password Manager', 'Splashtop*')
  }

  It 'legt einen vorhandenen Eintrag nicht ein zweites Mal an' {
    @(Add-ProtectedAppPattern -Patterns @('Splashtop*') -Pattern 'splashtop*').Count | Should -Be 1
  }

  It 'entfernt ohne Ruecksicht auf Gross-/Kleinschreibung' {
    @(Remove-ProtectedAppPattern -Patterns @('Splashtop*', 'TeamViewer*') -Pattern 'SPLASHTOP*') |
      Should -Be @('TeamViewer*')
  }

  It 'laesst die Liste unveraendert, wenn der Eintrag gar nicht drin ist' {
    @(Remove-ProtectedAppPattern -Patterns @('Splashtop*') -Pattern 'Google Chrome') |
      Should -Be @('Splashtop*')
  }

  It 'macht bei leerer Eingabe nichts kaputt' {
    @(Add-ProtectedAppPattern -Patterns @('Splashtop*') -Pattern '   ')    | Should -Be @('Splashtop*')
    @(Remove-ProtectedAppPattern -Patterns @('Splashtop*') -Pattern '')    | Should -Be @('Splashtop*')
  }
}

Describe 'Confirm-ProtectedAppsInRun' {
  BeforeEach {
    $global:TestLog.Clear()
    $global:ConfirmCalls = 0
    $global:LastConfirmText = ''
    # Standardantwort 'all': das ist der Weg, der dem frueheren "Ja" entspricht.
    $global:ConfirmAnswer = 'all'
    # Gemockt wird der EIGENE Dialog, nicht mehr Confirm-ChangeAction. Dass diese Frage nicht
    # unterdrueckbar ist, ergibt sich seit dem Umbau daraus, dass sie gar nicht mehr durch
    # Confirm-ChangeAction laeuft - geprueft wird das eine Ebene tiefer, in ProtectedRunChoice.Tests.
    Set-Item -Path function:global:Show-ProtectedRunDialog -Value {
      param([int]$Count, [string]$Preview)
      $global:ConfirmCalls++
      $global:LastConfirmText = ((Get-UiString 'ProtectedRunConfirmDialog') -f $Count, $Preview)
      return $global:ConfirmAnswer
    }
    # Der Dialogtext MUSS die beiden Platzhalter behalten, sonst prueft der Test unten nur, dass ein
    # Schluesselname zurueckkommt - und haette auch dann bestanden, wenn die Namen nie im Dialog stehen.
    Set-Item -Path function:global:Get-UiString -Value {
      param([string]$Key)
      if ($Key -eq 'ProtectedRunConfirmDialog') { return "COUNT={0}|LIST={1}" }
      return "UI:$Key"
    }
  }

  AfterAll {
    Remove-Item -Path function:global:Show-ProtectedRunDialog -ErrorAction SilentlyContinue
    Remove-Item -Path function:global:Get-UiString -ErrorAction SilentlyContinue
  }

  It 'fragt gar nicht, wenn keine geschuetzte App dabei ist' {
    # Der Normalfall darf keinen zusaetzlichen Klick kosten, sonst wird die Rueckfrage zur Gewohnheit
    # und damit wirkungslos.
    $r = Confirm-ProtectedAppsInRun -Apps @((New-Candidate -Name 'Google Chrome'))
    $r.Proceed | Should -BeTrue
    @($r.Apps).Count | Should -Be 1
    $global:ConfirmCalls | Should -Be 0
  }

  It 'fragt immer, wenn eine geschuetzte App dabei ist' {
    # Die zentrale Regel dieser Funktion: bei SuppressChangeConfirmations=True darf sie NICHT
    # lautlos werden - also genau bei dem Benutzer, dessen Lauf sonst voellig ohne Rueckfrage
    # startet. Sichergestellt wird das seit dem Umbau dadurch, dass hier ein eigener Dialog steht
    # statt Confirm-ChangeAction.
    [void](Confirm-ProtectedAppsInRun -Apps @((New-Candidate -Name 'Splashtop Streamer' -Protected $true)))
    $global:ConfirmCalls | Should -Be 1
  }

  It 'nennt die betroffenen Apps im Dialog' {
    [void](Confirm-ProtectedAppsInRun -Apps @(
      (New-Candidate -Name 'Google Chrome'),
      (New-Candidate -Name 'Splashtop Streamer' -Protected $true -From '3.5' -To '3.6')))
    $global:LastConfirmText | Should -Match 'Splashtop Streamer'
    $global:LastConfirmText | Should -Match '3\.5 -> 3\.6'
    $global:LastConfirmText | Should -Not -Match 'Google Chrome'
  }

  It 'nennt sie auch namentlich im Protokoll' {
    # "3 geschuetzte Apps" beantwortet im Nachhinein nicht, WELCHE freigegeben wurden - und genau
    # das ist die Frage nach einem Fehlgriff.
    [void](Confirm-ProtectedAppsInRun -Apps @((New-Candidate -Name 'Keeper Password Manager' -Protected $true)))
    ($global:TestLog -join "`n") | Should -Match 'Keeper Password Manager'
  }

  It 'bricht ab, wenn der Benutzer abbricht' {
    $global:ConfirmAnswer = 'cancel'
    $r = Confirm-ProtectedAppsInRun -Apps @((New-Candidate -Name 'Splashtop Streamer' -Protected $true))
    $r.Proceed | Should -BeFalse
    ($global:TestLog -join "`n") | Should -Match 'canceled at the protected-apps confirmation'
  }

  It 'laesst die geschuetzten aus und den Rest laufen' {
    # Der dritte Weg, und der haeufigste reale Fall: zehn Apps angehakt, zwei davon geschuetzt.
    $global:ConfirmAnswer = 'skip'
    $r = Confirm-ProtectedAppsInRun -Apps @(
      (New-Candidate -Name 'Google Chrome'),
      (New-Candidate -Name 'Splashtop Streamer' -Protected $true))
    $r.Proceed | Should -BeTrue
    @($r.Apps).Count | Should -Be 1
    @($r.Apps)[0].Name | Should -Be 'Google Chrome'
    ($global:TestLog -join "`n") | Should -Match 'Protected apps left out of this run'
    # Auch hier namentlich: welche wurden ausgelassen, ist im Nachhinein dieselbe Frage.
    ($global:TestLog -join "`n") | Should -Match 'Splashtop Streamer'
  }

  It 'kommt mit einer leeren Auswahl aus' {
    $r = Confirm-ProtectedAppsInRun -Apps @()
    $r.Proceed | Should -BeTrue
    $global:ConfirmCalls | Should -Be 0
  }
}

Describe 'Der Riegel haengt in beiden Update-Laeufen' {
  BeforeAll { $script:mainText = Get-SourcePartText -Part '90-Main.ps1' }

  It 'sichert den Lauf ueber die markierten Zeilen ab' {
    $script:mainText | Should -Match '\$protectedChoice = Confirm-ProtectedAppsInRun -Apps @\(\$checkedApps\)'
  }

  It 'sichert auch "Alle aktualisieren" ab' {
    # Der Weg, auf dem eine geschuetzte App am ehesten ungesehen mitlaeuft - niemand liest dabei
    # jede Zeile. Nur den markierten Lauf abzusichern haette genau die Luecke gelassen.
    $script:mainText | Should -Match 'Confirm-ProtectedAppsInRun -Apps @\(\$updatedApps\)'
  }

  It 'faellt das Urteil einmal im Zeilenmodell' {
    # Wuerde jede Anzeigestelle selbst rechnen, koennten Zeilenfarbe und Rueckfrage auseinanderlaufen -
    # die Zeile saehe harmlos aus und der Lauf fragte trotzdem, oder schlimmer: umgekehrt.
    $fn = Get-SourceFunctionText -Part '30-UpdateTargets.ps1' -Name 'New-UpdateCandidateModel'
    $fn | Should -Match 'IsProtected\s+= \[bool\]\(Test-IsProtectedApp -Name \(\[string\]\$App\.Name\) -Patterns \$script:settings\.ProtectedApps\)'
  }
}
