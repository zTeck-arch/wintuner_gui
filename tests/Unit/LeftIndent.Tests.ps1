# Der linke Einzug ist EINE Entscheidung, nicht drei.
#
# Der Fehler: der Titel in der Kopfzeile sass auf x=21 (16 px im angedockten Kopfbereich plus 5 px
# Fensterinnenabstand), die Symbolspalte der Seitenleiste auf x=30 (10 px mainPanel + 8 px Knopf +
# 12 px Innenabstand). Zwei getrennte Pixelwerte, sichtbar unterschiedlich weit vom Fensterrand.
#
# Gemessen wird hier die Rechnung, nicht das Bild - das Bild misst tests/LayoutProbe.ps1. Diese
# Regel schlaegt an, sobald wieder eine der Zahlen einzeln geaendert wird.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  $script:uiText   = Get-SourcePartText -Part '75-UiState.ps1'
  $script:mainText = Get-SourcePartText -Part '90-Main.ps1'
}

Describe 'Linker Einzug von Kopfzeile und Seitenleiste' {

  It 'definiert die vier Einzugswerte genau einmal, in 75-UiState' {
    $script:uiText | Should -Match '\$script:formPadding\s*=\s*5'
    $script:uiText | Should -Match '\$script:mainPanelIndent\s*=\s*10'
    $script:uiText | Should -Match '\$script:navButtonIndent\s*=\s*8'
    $script:uiText | Should -Match '\$script:navButtonTextPad\s*=\s*12'
  }

  It 'rechnet die Symbolspalte aus diesen Werten (10 + 8 + 12 = 30)' {
    $script:uiText | Should -Match '\$script:navContentIndent\s*=\s*\$script:mainPanelIndent\s*\+\s*\$script:navButtonIndent\s*\+\s*\$script:navButtonTextPad'

    # Dieselbe Rechnung noch einmal hier, damit der erwartete Wert im Test schwarz auf weiss steht.
    $formPadding = 5; $mainPanelIndent = 10; $navButtonIndent = 8; $navButtonTextPad = 12
    ($mainPanelIndent + $navButtonIndent + $navButtonTextPad) | Should -Be 30
    (($mainPanelIndent + $navButtonIndent + $navButtonTextPad) - $formPadding) | Should -Be 25
  }

  It 'setzt den Titel der Kopfzeile aus der Konstante, nicht aus einer eigenen Zahl' {
    $script:uiText | Should -Match '\$appTitleLabel\.Location\s*=\s*New-Object System\.Drawing\.Point\(\(\$script:navContentIndent - \$script:formPadding\)'
    $script:uiText | Should -Not -Match '\$appTitleLabel\.Location\s*=\s*New-Object System\.Drawing\.Point\(16'
  }

  It 'setzt die Menueleiste auf dieselbe Spalte' {
    # Der Wert 14 ist GEMESSEN (Bildschirmkopie des laufenden Fensters): so viel rueckt der
    # ToolStrip seinen ersten Eintrag von sich aus ein. Mit 20 px stand "Extras" links vom Titel.
    $script:uiText | Should -Match '\$script:menuBarOwnIndent\s*=\s*14'
    $script:uiText | Should -Match '\$menuStrip\.Padding = New-Object System\.Windows\.Forms\.Padding\(\(\$script:navContentIndent - \$script:menuBarOwnIndent\)'
  }

  It 'haengt die Hoehe der Kopfzeile und den Anfang des Inhalts zusammen' {
    # Wer eines von beiden einzeln aendert, bekommt entweder einen leeren Streifen unter der
    # Akzentlinie oder Inhalt, der daran klebt.
    $script:uiText | Should -Match '\$script:headerHeight\s*=\s*64'
    $script:uiText | Should -Match '\$script:mainPanelTop\s*=\s*\$script:menuBarHeight \+ \$script:headerHeight \+ 10'
    $script:uiText | Should -Match '\$headerPanel\.Height = \$script:headerHeight'
    $script:uiText | Should -Match '\$mainPanel\.Location = New-Object System\.Drawing\.Point\(\$script:mainPanelIndent, \$script:mainPanelTop\)'
  }

  It 'setzt mainPanel, Nav-Knoepfe und Gruppentitel aus denselben Konstanten' {
    $script:uiText   | Should -Match '\$mainPanel\.Location\s*=\s*New-Object System\.Drawing\.Point\(\$script:mainPanelIndent'
    $script:mainText | Should -Match '\$btn\.Location\s*=\s*New-Object System\.Drawing\.Point\(\$script:navButtonIndent'
    $script:mainText | Should -Match '\$btn\.Padding\s*=\s*New-Object System\.Windows\.Forms\.Padding\(\$script:navButtonTextPad'
    $script:mainText | Should -Match '\$groupLabel\.Location\s*=\s*New-Object System\.Drawing\.Point\(\(\$script:navButtonIndent \+ \$script:navButtonTextPad\)'
  }
}
