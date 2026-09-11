#requires -Version 7
# Der Vertrag um den Zustandsbeutel des App-Einstellungen-Editors.
#
# Der Editor baut seine Steuerelemente an zwei Stellen - den Rahmen samt App-Liste in
# Show-AppSettingsDialog, die 25 Zuweisungseinstellungen in Add-AppSettingsAssignmentControls - und
# legt beides in EINEN Beutel im Skript-Bereich ($script:appSettingsUi). Jedes Ereignis und die
# gesamte Anordnung lesen nur aus diesem Beutel; lokale Variablen sind nach dem Aufbau weg
# (siehe docs/PATTERNS.md).
#
# Damit haengt alles an einer Menge von Namen, die nirgends deklariert ist. Genau daran ist der
# Umbau am 10.09.2026 gescheitert: eine Textersetzung traf zwei Stellen und loeschte den
# return-Block des Erbauers. Er gab danach NICHTS zurueck, 22 Eintraege fehlten im Beutel, und die
# Anordnung liess die Steuerelemente auf ihren Konstruktionspositionen liegen - drei Ueberlappungen
# in zwei Sprachen. Kein Parserfehler, kein Test rot: gefunden hat es allein die Layout-Probe, und
# die braucht knapp zwei Minuten.
#
# Diese Pruefung stellt denselben Fehler in Millisekunden fest: liest die Anordnung einen Namen,
# den niemand in den Beutel legt, ist das ein Befund.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient

  $script:builder = Get-SourceFunctionText -Part '55-Dialogs.ps1' -Name 'Add-AppSettingsAssignmentControls'
  $script:dialog  = Get-SourceFunctionText -Part '55-Dialogs.ps1' -Name 'Show-AppSettingsDialog'
  $script:layout  = Get-SourceFunctionText -Part '55-Dialogs.ps1' -Name 'Update-AppSettingsEditorLayout'

  # Was der Erbauer zurueckgibt: die Schluessel seines return-Blocks.
  $script:builderKeys = @(
    [regex]::Matches($script:builder, '(?m)^\s{4}(?<k>[A-Za-z]\w*) = \$\w+\s*$') |
      ForEach-Object { $_.Groups['k'].Value } | Sort-Object -Unique)

  # Was der Dialog selbst in den Beutel legt: die Schluessel seines Hashtable-Literals.
  $script:dialogKeys = @(
    [regex]::Matches($script:dialog, '(?m)^\s{4}(?<k>[A-Za-z]\w*)\s+= ') |
      ForEach-Object { $_.Groups['k'].Value } | Sort-Object -Unique)

  # Was die Anordnung liest.
  $script:layoutKeys = @(
    [regex]::Matches($script:layout, '\$ui\.(?<k>[A-Za-z]\w*)') |
      ForEach-Object { $_.Groups['k'].Value } | Sort-Object -Unique)
}

Describe 'Add-AppSettingsAssignmentControls' {

  It 'gibt ueberhaupt etwas zurueck' {
    # Der Fehler vom 10.09.2026 in seiner einfachsten Form: der return-Block war leer.
    $script:builder | Should -Match 'return @\{'
    @($script:builderKeys).Count | Should -BeGreaterThan 15
  }

  It 'gibt jedes Steuerelement zurueck, das es erzeugt' {
    # Ein erzeugtes, dem Dialog hinzugefuegtes, aber nicht zurueckgegebenes Steuerelement liegt fuer
    # immer auf seiner Konstruktionsposition: sichtbar, aber von der Anordnung nie angefasst.
    $added = @([regex]::Matches($script:builder, '\$Dialog\.Controls\.Add\(\$(?<v>\w+)\)') |
      ForEach-Object { $_.Groups['v'].Value } | Sort-Object -Unique)
    @($added).Count | Should -BeGreaterThan 15
    $returned = @([regex]::Matches($script:builder, '(?m)^\s{4}[A-Za-z]\w* = \$(?<v>\w+)\s*$') |
      ForEach-Object { $_.Groups['v'].Value })
    foreach ($v in $added) {
      $returned | Should -Contain $v -Because "`$$v wird dem Dialog hinzugefuegt, aber nicht zurueckgegeben"
    }
  }

  It 'baut die Steuerelemente in das uebergebene Elternobjekt, nicht in ein eigenes Fenster' {
    # Der Editor ist auch ein EINGEBETTETER Bereich. Ein eigenes New-Object Form hier waere ein
    # zweites Fenster mitten in der Seitenleiste.
    $script:builder | Should -Not -Match 'New-Object System\.Windows\.Forms\.Form'
    $script:builder | Should -Match '\[Parameter\(Mandatory\)\]\[object\]\$Dialog'
  }
}

Describe 'Der Beutel deckt, was die Anordnung liest' {

  It 'legt jeden von der Anordnung gelesenen Namen auch hinein' {
    # DIE Pruefung dieser Datei. Ein Name, den die Anordnung liest und niemand fuellt, ist $null -
    # und $null.Left = 12 wirft nicht, es passiert einfach nichts.
    #
    # Nicht geprueft werden reine Zustandsfelder (AllApps, CheckedIds, ...): die liest die Anordnung
    # ohnehin nicht. Was sie liest, muss ein Steuerelement sein.
    $known = @($script:builderKeys) + @($script:dialogKeys)
    $missing = @($script:layoutKeys | Where-Object { $known -notcontains $_ })
    $missing -join ', ' | Should -Be '' -Because 'diese Namen liest die Anordnung, aber niemand legt sie in den Beutel'
  }

  It 'ordnet jedes zurueckgegebene Steuerelement auch wirklich an' {
    # Die Gegenrichtung: ein Steuerelement, das der Erbauer liefert und die Anordnung nie anfasst,
    # behaelt seine Konstruktionsposition. Im eingebetteten Bereich ist das genau der Fehler, den
    # die Layout-Probe als Ueberlappung meldet.
    $unplaced = @($script:builderKeys | Where-Object { $script:layoutKeys -notcontains $_ })
    $unplaced -join ', ' | Should -Be '' -Because 'diese Steuerelemente werden gebaut, aber nie angeordnet'
  }

  It 'fuehrt die Zuweisungseinstellungen aus dem Erbauer und nicht mehr im Dialog' {
    # Sonst stehen sie doppelt im Beutel, und welche Ausgabe gewinnt, entscheidet die Reihenfolge.
    $doppelt = @($script:builderKeys | Where-Object { $script:dialogKeys -contains $_ })
    $doppelt -join ', ' | Should -Be ''
  }

  It 'uebernimmt das Ergebnis des Erbauers in den Beutel' {
    $script:dialog | Should -Match '\$assignmentControls = Add-AppSettingsAssignmentControls -Dialog \$dlg'
    $script:dialog | Should -Match 'foreach \(\$key in \$assignmentControls\.Keys\) \{ \$script:appSettingsUi\[\$key\] = \$assignmentControls\[\$key\] \}'
  }
}
