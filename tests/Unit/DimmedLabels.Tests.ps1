# Eine Beschriftung, die gerade wirkungslos ist, muss LESBAR bleiben.
#
# WinForms zeichnet eine Label mit Enabled = $false immer in SystemColors.GrayText (#6D6D6D) und
# ignoriert dabei jede Farbe des Designs. Auf dem dunklen Kartengrund sind das gemessene 3,56:1 -
# im Bild kaum zu entziffern. Genau dazu kam die Rueckmeldung ("Kulanzzeitraum (Minuten)",
# "Neustart-Countdown vorher anzeigen").
#
# Eine Beschriftung muss ohnehin nicht deaktiviert sein: sie nimmt keine Eingaben an und liegt nicht
# im Tabulator-Weg. Sie wird deshalb gedaempft statt deaktiviert. Hier wird nachgerechnet, dass das
# in JEDEM Design ueber dem Schwellenwert bleibt, und statisch geprueft, dass niemand wieder zu
# Enabled = $false greift.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  Add-Type -AssemblyName System.Windows.Forms, System.Drawing
  # Nur die sieben Designtabellen aus 60-Batch.ps1 - der Rest des Teils ruft beim Laden
  # Get-UiString und Einstellungen auf, die es hier nicht gibt.
  $themeText = ([IO.File]::ReadAllLines((Join-Path (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src') '60-Batch.ps1')) |
    Select-Object -Skip 0)
  $collect = $false
  $themeLines = foreach ($line in $themeText) {
    if ($line -match '^\$script:\w+Theme = @\{') { $collect = $true }
    if ($collect) { $line }
    if ($collect -and $line -match '^\}') { $collect = $false }
  }
  . ([scriptblock]::Create(($themeLines -join "`r`n")))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '65-Theme.ps1' -Name @(
    'Get-DimmedColor', 'Get-CardBackColor', 'Get-LabelDimForeColor', 'Set-LabelDimmed', 'Test-LabelDimmed'))))
  $script:dimmedLabels = @{}

  function Get-Luminance {
    param($Color)
    $parts = @($Color.R, $Color.G, $Color.B) | ForEach-Object {
      $v = $_ / 255.0
      if ($v -le 0.03928) { $v / 12.92 } else { [Math]::Pow((($v + 0.055) / 1.055), 2.4) }
    }
    return 0.2126 * $parts[0] + 0.7152 * $parts[1] + 0.0722 * $parts[2]
  }
  function Get-ContrastRatio {
    param($A, $B)
    $l1 = Get-Luminance $A; $l2 = Get-Luminance $B
    if ($l2 -gt $l1) { $swap = $l1; $l1 = $l2; $l2 = $swap }
    return [Math]::Round((($l1 + 0.05) / ($l2 + 0.05)), 2)
  }
  function New-LabelOnCard {
    param($Theme)
    $card = New-Object System.Windows.Forms.Panel
    $card.BackColor = Get-CardBackColor $Theme
    $label = New-Object System.Windows.Forms.Label
    $label.Text = 'Kulanzzeitraum (Minuten):'
    $card.Controls.Add($label)
    return $label
  }

  $script:allThemes = @{
    Dark = $script:darkTheme; Light = $script:lightTheme; Win98 = $script:win98Theme
    WinXP = $script:winXpTheme; Vista = $script:winVistaTheme; Win7 = $script:win7Theme
    Orange = $script:orangeTheme
  }
}

Describe 'Gedaempfte Beschriftungen' {

  It 'ist in jedem Design lesbar - mindestens 3,5:1 gegen die Karte' {
    foreach ($name in @($script:allThemes.Keys)) {
      $theme = $script:allThemes[$name]
      $script:currentTheme = $theme
      $label = New-LabelOnCard $theme
      Set-LabelDimmed -Label $label -Dimmed $true
      $ratio = Get-ContrastRatio $label.ForeColor $label.Parent.BackColor
      $ratio | Should -BeGreaterThan 3.5 -Because "das Design '$name' waere sonst nicht zu lesen (gemessen $ratio):1"
    }
  }

  It 'ist besser als das GrayText von Windows, das eine deaktivierte Label bekaeme' {
    $script:currentTheme = $script:darkTheme
    $label = New-LabelOnCard $script:darkTheme
    Set-LabelDimmed -Label $label -Dimmed $true
    $dimmed = Get-ContrastRatio $label.ForeColor $label.Parent.BackColor
    $windows = Get-ContrastRatio ([System.Drawing.SystemColors]::GrayText) $label.Parent.BackColor
    $dimmed | Should -BeGreaterThan $windows
  }

  It 'bleibt sichtbar gedaempft - nicht so stark wie normaler Text' {
    $script:currentTheme = $script:darkTheme
    $label = New-LabelOnCard $script:darkTheme
    Set-LabelDimmed -Label $label -Dimmed $true
    $dim = Get-ContrastRatio $label.ForeColor $label.Parent.BackColor
    $normal = Get-ContrastRatio $script:darkTheme.ForeColor $label.Parent.BackColor
    $dim | Should -BeLessThan $normal
  }

  It 'nimmt die Daempfung wieder zurueck' {
    $script:currentTheme = $script:darkTheme
    $label = New-LabelOnCard $script:darkTheme
    Set-LabelDimmed -Label $label -Dimmed $true
    Test-LabelDimmed $label | Should -BeTrue
    Set-LabelDimmed -Label $label -Dimmed $false
    Test-LabelDimmed $label | Should -BeFalse
    $label.ForeColor | Should -Be $script:darkTheme.ForeColor
  }

  It 'laesst die Beschriftung AKTIVIERT - sonst zeichnet WinForms wieder in GrayText' {
    $script:currentTheme = $script:darkTheme
    $label = New-LabelOnCard $script:darkTheme
    Set-LabelDimmed -Label $label -Dimmed $true
    $label.Enabled | Should -BeTrue
  }
}

Describe 'Kein Enabled = $false auf einer Beschriftung im Quelltext' {

  It 'findet keine deaktivierte Label mehr' {
    $srcDir = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src'
    $hits = foreach ($file in (Get-ChildItem -Path $srcDir -Filter '*.ps1')) {
      $lineNumber = 0
      foreach ($line in [IO.File]::ReadAllLines($file.FullName)) {
        $lineNumber++
        # Beschriftungen heissen in dieser Codebasis durchweg "...Label".
        if ($line -match '\$[A-Za-z:.]*Label[A-Za-z]*\.Enabled\s*=') { "$($file.Name):$lineNumber" }
      }
    }
    $hits | Should -BeNullOrEmpty
  }
}
