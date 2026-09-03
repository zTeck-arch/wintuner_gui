#requires -Version 7
# Geschuetzte Apps in einem Lauf: drei Wege statt Ja/Nein.
#
# Der Fall, um den es geht: zehn Apps angehakt, zwei davon geschuetzt und uebersehen. Mit einer
# Ja/Nein-Frage heisst Nein "abbrechen, die zwei suchen, abwaehlen, von vorn" - und wer das dreimal
# gemacht hat, klickt beim vierten Mal Ja. Eine Rueckfrage, die den naheliegenden Ausgang nicht
# anbietet, erzieht zum Wegklicken.
#
# Der gefaehrlichste Fehler beim Umbau waere still: der Benutzer waehlt "ohne die geschuetzten",
# und der Lauf rechnet trotzdem mit der alten Liste weiter. Dann baut die Anwendung genau die App,
# die gerade abgewaehlt wurde - ohne Fehlermeldung, ohne Protokollzeile, und zurueckholen laesst es
# sich bei einem handgebauten Paket nicht. Deshalb pruefen die Faelle unten die zurueckgegebene
# LISTE, nicht nur das Ja/Nein.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '70-Runtime.ps1' -Name @(
    'Split-ProtectedApps', 'Resolve-ProtectedRunChoice'))))

  function New-App {
    param([string]$Name, [bool]$Protected = $false)
    [pscustomobject]@{ Name = $Name; CurrentVersion = '1.0'; LatestVersion = '2.0'; IsProtected = $Protected }
  }

  $script:mixed = @(
    (New-App 'Google Chrome'),
    (New-App 'TeamViewer Host' -Protected $true),
    (New-App '7-Zip'),
    (New-App 'Splashtop Streamer' -Protected $true)
  )
}

Describe 'Split-ProtectedApps' {

  It 'trennt geschuetzte von uebrigen Apps' {
    $s = Split-ProtectedApps -Apps $script:mixed
    @($s.Protected).Count | Should -Be 2
    @($s.Unprotected).Count | Should -Be 2
    @($s.Protected | ForEach-Object { $_.Name }) | Should -Contain 'TeamViewer Host'
    @($s.Unprotected | ForEach-Object { $_.Name }) | Should -Contain '7-Zip'
  }

  It 'vertraegt eine leere Auswahl und Nullwerte darin' {
    $s = Split-ProtectedApps -Apps @()
    @($s.Protected).Count | Should -Be 0
    $s2 = Split-ProtectedApps -Apps @($null, (New-App 'Chrome'), $null)
    @($s2.Unprotected).Count | Should -Be 1
  }

  It 'behandelt eine App ohne die Eigenschaft als NICHT geschuetzt' {
    # Ein Objekt aus einem aelteren Pfad hat IsProtected vielleicht gar nicht - das darf keine
    # Ausnahme werfen und die App nicht stillschweigend schuetzen.
    $s = Split-ProtectedApps -Apps @([pscustomobject]@{ Name = 'Alt'; CurrentVersion = '1'; LatestVersion = '2' })
    @($s.Unprotected).Count | Should -Be 1
    @($s.Protected).Count | Should -Be 0
  }
}

Describe 'Resolve-ProtectedRunChoice' {

  It "'all' laesst die Liste unveraendert" {
    $r = Resolve-ProtectedRunChoice -Apps $script:mixed -Choice 'all'
    $r.Proceed | Should -BeTrue
    @($r.Apps).Count | Should -Be 4
    @($r.Skipped).Count | Should -Be 0
    $r.Reason | Should -Be 'all'
  }

  It "'skip' entfernt GENAU die geschuetzten und laesst den Rest laufen" {
    $r = Resolve-ProtectedRunChoice -Apps $script:mixed -Choice 'skip'
    $r.Proceed | Should -BeTrue
    @($r.Apps).Count | Should -Be 2
    @($r.Apps | ForEach-Object { $_.Name }) | Should -Not -Contain 'TeamViewer Host'
    @($r.Apps | ForEach-Object { $_.Name }) | Should -Not -Contain 'Splashtop Streamer'
    @($r.Skipped).Count | Should -Be 2
    $r.Reason | Should -Be 'skip'
  }

  It "'cancel' laesst nichts laufen" {
    $r = Resolve-ProtectedRunChoice -Apps $script:mixed -Choice 'cancel'
    $r.Proceed | Should -BeFalse
    @($r.Apps).Count | Should -Be 0
    $r.Reason | Should -Be 'cancel'
  }

  It "unterscheidet 'nichts mehr uebrig' von 'abgebrochen'" {
    # Waren NUR geschuetzte Apps angehakt, bleibt bei 'skip' nichts uebrig. Der Benutzer hat aber
    # gewaehlt - die Meldung darf nicht "abgebrochen" sagen, sonst sucht er den Fehler bei sich.
    $r = Resolve-ProtectedRunChoice -Apps @((New-App 'TeamViewer' -Protected $true)) -Choice 'skip'
    $r.Proceed | Should -BeFalse
    $r.Reason | Should -Be 'empty'
    @($r.Skipped).Count | Should -Be 1
  }

  It 'gibt bei einer Auswahl ganz ohne geschuetzte Apps alles durch' {
    $plain = @((New-App 'Chrome'), (New-App '7-Zip'))
    foreach ($choice in @('all', 'skip')) {
      $r = Resolve-ProtectedRunChoice -Apps $plain -Choice $choice
      $r.Proceed | Should -BeTrue
      @($r.Apps).Count | Should -Be 2
    }
  }
}

Describe 'Verdrahtung: der Lauf rechnet mit der Liste AUS DEM ERGEBNIS' {

  It 'setzt beide Aufrufstellen auf die zurueckgegebene Liste um' {
    # Ohne diese Zuweisung waere der ganze Umbau wirkungslos - und zwar lautlos.
    $main = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\..\src\90-Main.ps1')
    $main | Should -Match '\$checkedApps = @\(\$protectedChoice\.Apps\)'
    $main | Should -Match '\$updatedApps = @\(\$protectedChoice\.Apps\)'
    ([regex]::Matches($main, 'Confirm-ProtectedAppsInRun')).Count | Should -Be 2
  }

  It 'meldet die ausgelassenen Apps in der Statuszeile' {
    $main = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\..\src\90-Main.ps1')
    ([regex]::Matches($main, 'ProtectedRunSkippedStatus')).Count | Should -Be 2
    ([regex]::Matches($main, 'ProtectedRunNothingLeftStatus')).Count | Should -Be 2
  }

  It 'geht NICHT durch Confirm-ChangeAction - diese Frage ist nicht abschaltbar' {
    # Nur die Code-Zeilen ansehen: der Name steht weiterhin im Kommentar, der erklaert, WARUM hier
    # ein eigener Dialog steht. Ein Test, der einen Kommentar fuer einen Aufruf haelt, zwingt dazu,
    # die Begruendung zu loeschen, um gruen zu werden - das ist der falsche Anreiz.
    $fn = Get-SourceFunctionText -Part '70-Runtime.ps1' -Name 'Confirm-ProtectedAppsInRun'
    $code = @($fn -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    $code | Should -Not -Match 'Confirm-ChangeAction'
    $code | Should -Match 'Show-ProtectedRunDialog'
  }

  It 'macht Abbrechen zum Escape-Weg, nicht "alles aktualisieren"' {
    # Escape und das Fensterkreuz duerfen nie die folgenreichste Wahl bedeuten.
    $dlg = Get-SourceFunctionText -Part '55-Dialogs.ps1' -Name 'Show-ProtectedRunDialog'
    $dlg | Should -Match '\$dlg\.CancelButton = \$cancelButton'
    $dlg | Should -Match "protectedRunChoice = 'cancel'"
  }

  It 'laesst die Wahl nur gelten, wenn ein Knopf gedrueckt wurde' {
    # Jeder andere Ausgang - Escape, Fensterkreuz, ein Close() von aussen - ist ein Abbruch. Die
    # Merkervariable allein reicht dafuer nicht: in einem Probelauf, in dem der Dialog auf anderem
    # Weg geschlossen wurde, kam einmal 'skip' zurueck.
    $dlg = Get-SourceFunctionText -Part '55-Dialogs.ps1' -Name 'Show-ProtectedRunDialog'
    $dlg | Should -Match '\$result = \$dlg\.ShowDialog\(\)'
    $dlg | Should -Match "if \(\`$result -ne \[System\.Windows\.Forms\.DialogResult\]::OK\) \{ return 'cancel' \}"
  }
}
