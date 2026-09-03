# Der Fortschritt wird als Prozenttext angezeigt, nicht mehr als Balken.
#
# Der Balken war eine Behauptung: Paketieren und Hochladen laufen auf dem UI-Thread, waehrend eines
# Uploads pumpt niemand die Nachrichtenschleife - der Marquee stand still, der fortlaufende Balken
# blieb minutenlang auf demselben Wert. Beides las sich wie ein Absturz.
#
# Geprueft wird hier vor allem die Rechnung, die dabei leicht falsch wird: Prozent kommt aus
# ERLEDIGTEN Schritten und wird abgerundet, damit nie 100 % dasteht, solange noch etwas laeuft.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  Add-Type -AssemblyName System.Windows.Forms, System.Drawing
  . ([scriptblock]::Create((Get-UiStringsText)))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '75-UiState.ps1' -Name @(
    'Update-ProgressDisplay', 'Show-Progress', 'Set-ProgressValue', 'Hide-Progress', 'Test-ProgressVisible',
    'Request-RunCancel'))))
  # Request-RunCancel stoppt seit 0.18.0 auch den Vorab-Bau des naechsten Pakets.
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '35-Packaging.ps1' -Name 'Stop-PackagePrebuild')))

  $script:progressLabel = New-Object System.Windows.Forms.Label
  $script:progressLabel.Visible = $false
  $script:progressTotal = 0
  $script:progressCurrent = 0
}

Describe 'Fortschrittsanzeige als Text' {

  It 'zeigt beim Start eines Laufs 0 %' {
    Show-Progress -Total 11
    Test-ProgressVisible | Should -BeTrue
    $script:progressLabel.Text | Should -BeLike '*0 %*'
    $script:progressLabel.Text | Should -BeLike '*11*'
  }

  It 'rechnet Prozent aus erledigten Schritten' {
    Show-Progress -Total 4
    Set-ProgressValue 1
    $script:progressLabel.Text | Should -BeLike '*25 %*'
    Set-ProgressValue 3
    $script:progressLabel.Text | Should -BeLike '*75 %*'
  }

  It 'rundet ab - 10 von 11 sind 90 %, nicht 100 %' {
    Show-Progress -Total 11
    Set-ProgressValue 10
    $script:progressLabel.Text | Should -BeLike '*90 %*'
    $script:progressLabel.Text | Should -Not -BeLike '*100 %*'
  }

  It 'erreicht 100 % erst beim letzten Schritt' {
    Show-Progress -Total 11
    Set-ProgressValue 11
    $script:progressLabel.Text | Should -BeLike '*100 %*'
  }

  It 'begrenzt einen zu hohen Wert auf die Gesamtzahl' {
    Show-Progress -Total 3
    Set-ProgressValue 99
    $script:progressLabel.Text | Should -BeLike '*100 %*'
    $script:progressLabel.Text | Should -BeLike '*3*'
  }

  It 'sagt ohne bekannte Stueckzahl nur, dass etwas laeuft - ohne Prozentzahl' {
    Show-Progress
    Test-ProgressVisible | Should -BeTrue
    $script:progressLabel.Text | Should -Be (Get-UiString 'ProgressRunningText')
    $script:progressLabel.Text | Should -Not -BeLike '*%*'
  }

  It 'blendet am Ende aus und laesst keinen alten Text stehen' {
    Show-Progress -Total 5
    Set-ProgressValue 2
    Hide-Progress
    Test-ProgressVisible | Should -BeFalse
    $script:progressLabel.Text | Should -Be ''
  }
}

Describe 'Kein Balken mehr im Quelltext' {

  It 'verwendet nirgends mehr eine ProgressBar fuer den Lauf-Fortschritt' {
    $hits = foreach ($part in (Get-ChildItem -Path (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src') -Filter '*.ps1')) {
      $text = [IO.File]::ReadAllText($part.FullName)
      if ($text -match '\$script:progressBar') { $part.Name }
    }
    $hits | Should -BeNullOrEmpty
  }
}

# Der Abbruch-Knopf darf nur dort erscheinen, wo der Merker auch abgefragt wird. Ein Knopf, der
# nichts tut, war der Grund, warum es den alten Knopf nicht mehr gab - diese Regel haelt den neuen
# ehrlich.
Describe 'Abbruch-Knopf' {

  BeforeEach {
    $script:cancelRunButton = New-Object System.Windows.Forms.Button
    $script:cancelRunButton.Visible = $false
    $script:cancelBatch = $false
  }

  It 'bleibt verborgen, wenn der Aufrufer keinen Abbruch anbietet' {
    Show-Progress -Total 3
    $script:cancelRunButton.Visible | Should -BeFalse
  }

  It 'erscheint bei -Cancellable und verschwindet mit der Anzeige' {
    Show-Progress -Total 3 -Cancellable
    $script:cancelRunButton.Visible | Should -BeTrue
    $script:cancelRunButton.Enabled | Should -BeTrue
    Hide-Progress
    $script:cancelRunButton.Visible | Should -BeFalse
  }

  It 'setzt beim Anfordern den Merker und sperrt den zweiten Klick' {
    Show-Progress -Total 3 -Cancellable
    Request-RunCancel -Reason 'test'
    $script:cancelBatch | Should -BeTrue
    $script:cancelRunButton.Enabled | Should -BeFalse
    $script:cancelRunButton.Visible | Should -BeTrue   # der Lauf laeuft noch
  }

  It 'wird von jedem Teil, der -Cancellable anbietet, auch abgefragt' {
    $srcDir = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src'
    $offenders = foreach ($part in (Get-ChildItem -Path $srcDir -Filter '*.ps1')) {
      $text = [IO.File]::ReadAllText($part.FullName)
      if ($text -match 'Show-Progress[^\r\n]*-Cancellable' -and $text -notmatch '\$script:cancelBatch') {
        $part.Name
      }
    }
    $offenders | Should -BeNullOrEmpty
  }
}
