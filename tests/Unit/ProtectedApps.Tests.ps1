BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '10-Settings.ps1' -Name @(
    'Test-IsProtectedApp', 'Set-ProtectedAppPatterns',
    'Add-ProtectedAppPattern', 'Remove-ProtectedAppPattern'))))
}
# Die Rueckfrage vor dem Lauf steht seit 0.19.1 nicht mehr hier: sie ist mit den beiden anderen
# nicht wegdrueckbaren Fragen zu EINER zusammengefasst und wird in RiskyRunConfirm.Tests.ps1
# geprueft. Diese Datei prueft nur noch die Werksliste selbst.

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

Describe 'Das Urteil faellt einmal, im Zeilenmodell' {

  It 'setzt IsProtected in New-UpdateCandidateModel und nirgends sonst' {
    # Wuerde jede Anzeigestelle selbst rechnen, koennten Zeilenfarbe und Rueckfrage auseinanderlaufen -
    # die Zeile saehe harmlos aus und der Lauf fragte trotzdem, oder schlimmer: umgekehrt.
    $fn = Get-SourceFunctionText -Part '30-UpdateTargets.ps1' -Name 'New-UpdateCandidateModel'
    $fn | Should -Match 'IsProtected\s+= \[bool\]\(Test-IsProtectedApp -Name \(\[string\]\$App\.Name\) -Patterns \$script:settings\.ProtectedApps\)'
  }
}
