# Sucht Steuerelemente, die sich ueberlappen - in JEDEM Bereich, bei mehreren Fenstergroessen.
#
# Warum das eine eigene Pruefung ist: die Anordnung dieser Oberflaeche entsteht zur Laufzeit. Karten
# wachsen mit dem Fenster, Beschriftungen wachsen mit der Schriftart, und jedes Retro-Design bringt
# eine andere Schriftart mit. Ein Parser sieht davon nichts, ein Unit-Test auch nicht. Gefunden
# wurden so unter anderem:
#   - "Auto-Update abgeloester Versionen:" (376 px breit) lag ueber seiner Auswahlliste bei x=240 -
#     die Liste war im Bild schlicht nicht vorhanden.
#   - "Neustart-Countdown vorher anzeigen (Minuten):" lag ueber seinem Eingabefeld.
#   - In "Alle Tenant-Apps" lag der Hinweistext MITTEN in der Knopfreihe, das Detailfeld ueber dem
#     dritten Knopf (der beim Vergroessern nicht mitwanderte) und die Beschriftung im Detailfeld.
#
# Zusaetzlich wird gemeldet, wenn ein Bereich bei grossem Fenster hoeher ist als sein sichtbarer
# Ausschnitt: dann muss gescrollt werden, obwohl Platz da ist. Das ist ein HINWEIS, kein Fehler -
# "Eigene Installer" und "Einstellungen" sind absichtlich lange, scrollende Seiten.
#
# Laeuft wie der Smoke-Test in einem KINDPROZESS gegen das gebaute Skript.
[CmdletBinding()]
param(
  [string]$ScriptPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist/WinTuner_GUI_ntg.ps1'),
  [int]$TimeoutSeconds = 240,
  # Klein genug fuer ein 720p-Notebook, gross genug fuer einen normalen Arbeitsplatz.
  [string[]]$Sizes = @('1146x854', '1920x1080'),
  # BEIDE Sprachen, ausdruecklich gesetzt.
  #
  # Vorher richtete sich der Lauf nach dem Profil des Rechners, auf dem er gestartet wurde - und
  # weil die Umlenkung des Profils nicht wirkte (GetFolderPath ignoriert APPDATA), war das das
  # ECHTE Profil des Entwicklers: gemessen wurde immer nur Deutsch. Englisch ist die Vorgabe fuer
  # jeden neuen Benutzer (Language = "en" in 10-Settings) und wurde damit nie angesehen.
  [string[]]$Languages = @('en', 'de')
)

$ErrorActionPreference = 'Stop'
$path = (Resolve-Path -LiteralPath $ScriptPath).Path

$probeBody = @'
if ($env:WINTUNER_LAYOUT -eq '1') {
  # Startdialoge stillstellen erledigt die Anwendung selbst: jeder Add_Shown-Handler, der eine
  # MessageBox oeffnen kann, kehrt bei Test-UnattendedRun sofort zurueck (WINTUNER_LAYOUT ist
  # gesetzt). Vorher standen hier drei Zuweisungen, die je EINEN bekannten Dialog entschaerften -
  # ein vierter Dialog waere daran vorbeigelaufen, und genau so ist der Lauf einmal gehangen.
  $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
  $form.Size = New-Object System.Drawing.Size([int]$env:WINTUNER_LAYOUT_W, [int]$env:WINTUNER_LAYOUT_H)
  $form.Show()

  # Ueberlappung MIT Toleranz - und die Toleranz ist gemessen, nicht geraten.
  #
  # Eine AutoSize-Beschriftung ist breiter und hoeher als ihre Glyphen: WinForms legt rundherum
  # etwa 3 px Innenabstand. Zwei solche Kaesten beruehren sich daher schon, wenn optisch nichts
  # kollidiert. Beim ersten Lauf auf einem FRISCHEN Profil (siehe unten, das wurde vorher nie
  # gemessen) kamen so 7 bis 17 Meldungen zusammen: Ueberschrift/Unterzeile im Dashboard 6 px,
  # Kachelzahl/Beschriftung 5 px, "Zu behaltende Versionen je Paket:" gegen sein Zahlenfeld 1 px.
  # Nachgesehen in einer Bildschirmkopie: alles einwandfrei lesbar, kein Element verdeckt.
  #
  # Gemeldet wird deshalb erst, wenn sich die Kaesten in BEIDEN Richtungen um mehr als die Toleranz
  # schneiden. Das ist genau die Form der Befunde, um derer willen diese Probe existiert - eine
  # Beschriftung, die auf ihrem Eingabefeld liegt, deckt es auf ganzer Hoehe UND ueber viele Pixel
  # Breite ab (die drei Faelle im Kopf dieser Datei: 128 px, 168 px, 210 px). Ein Rand-Bleed von
  # 1-8 px hat immer in genau EINER Richtung fast nichts.
  $script:overlapTolerance = 8
  function Get-LayoutIntersection {
    param($A, $B)
    $w = [Math]::Min($A.Right, $B.Right) - [Math]::Max($A.Left, $B.Left)
    $h = [Math]::Min($A.Bottom, $B.Bottom) - [Math]::Max($A.Top, $B.Top)
    return @{ Width = $w; Height = $h }
  }
  function Test-LayoutRects {
    param($A, $B)
    $i = Get-LayoutIntersection -A $A -B $B
    return (($i.Width -gt $script:overlapTolerance) -and ($i.Height -gt $script:overlapTolerance))
  }

  # Gegenprobe der Toleranz, bei JEDEM Lauf. Eine Regel, die nie angeschlagen hat, ist keine Regel -
  # und eine Toleranz, die zu gross gerutscht ist, macht die ganze Probe wertlos, ohne rot zu werden.
  # Die drei "muss anschlagen"-Faelle sind die echten Befunde aus dem Kopf dieser Datei.
  $toleranceCases = @(
    @{ Name = 'Beschriftung 376 px auf ihrer Auswahlliste';  A = @{Left=0;   Top=100; Right=376; Bottom=125}; B = @{Left=240; Top=98;  Right=490; Bottom=128}; Expect = $true }
    @{ Name = 'Beschriftung auf ihrem Eingabefeld';          A = @{Left=14;  Top=40;  Right=310; Bottom=65};  B = @{Left=142; Top=38;  Right=392; Bottom=68};  Expect = $true }
    @{ Name = 'Hinweistext mitten in der Knopfreihe';        A = @{Left=14;  Top=8;   Right=566; Bottom=73};  B = @{Left=14;  Top=32;  Right=224; Bottom=55};  Expect = $true }
    @{ Name = 'Ueberschrift/Unterzeile, 6 px Rand-Bleed';    A = @{Left=16;  Top=12;  Right=156; Bottom=52};  B = @{Left=18;  Top=46;  Right=145; Bottom=71};  Expect = $false }
    @{ Name = 'Beschriftung/Zahlenfeld, 1 px Rand-Bleed';    A = @{Left=0;   Top=5;   Right=237; Bottom=30};  B = @{Left=236; Top=1;   Right=296; Bottom=28};  Expect = $false }
    @{ Name = 'nebeneinander, kein Kontakt';                 A = @{Left=0;   Top=0;   Right=100; Bottom=25};  B = @{Left=120; Top=0;   Right=220; Bottom=25};  Expect = $false }
  )
  foreach ($case in $toleranceCases) {
    $got = Test-LayoutRects $case.A $case.B
    if ($got -ne $case.Expect) {
      Write-Host ("LAYOUT-SELFTEST FAILED: '{0}' erwartet {1}, gemessen {2}" -f $case.Name, $case.Expect, $got)
      exit 3
    }
  }
  function Test-LayoutContainer {
    param($C)
    # Wirte (Karten, Rundungs-Panels) enthalten ihre Kinder - das ist keine Ueberlappung.
    return ($C -is [System.Windows.Forms.Panel] -or $C -is [System.Windows.Forms.GroupBox] -or
            $C -is [System.Windows.Forms.TableLayoutPanel] -or $C -is [System.Windows.Forms.FlowLayoutPanel])
  }
  function Get-LayoutDesc {
    param($C)
    $label = if ($C.Text) { ([string]$C.Text) -replace "`r`n", ' ' } else { $C.GetType().Name }
    if ($label.Length -gt 40) { $label = $label.Substring(0, 40) + '...' }
    return ("{0} '{1}' [{2},{3} {4}x{5}]" -f $C.GetType().Name, $label, $C.Left, $C.Top, $C.Width, $C.Height)
  }
  function Test-LayoutPanel {
    param($Panel, [string]$Path)
    $found = 0
    $kids = @($Panel.Controls | Where-Object { $_.Visible })
    for ($i = 0; $i -lt $kids.Count; $i++) {
      for ($j = $i + 1; $j -lt $kids.Count; $j++) {
        $a = $kids[$i]; $b = $kids[$j]
        if ((Test-LayoutContainer $a) -or (Test-LayoutContainer $b)) { continue }
        if (Test-LayoutRects $a.Bounds $b.Bounds) {
          Write-Host ("LAYOUT-OVERLAP {0}: {1}  <>  {2}" -f $Path, (Get-LayoutDesc $a), (Get-LayoutDesc $b))
          $found++
        }
      }
    }
    foreach ($k in $kids) { if ($k.Controls.Count -gt 0) { $found += Test-LayoutPanel $k ($Path + '/' + $k.GetType().Name) } }
    return $found
  }

  # Eine Neuanordnung, die laeuft waehrend der Bereich GESCROLLT ist, darf nichts verschieben.
  # In einem AutoScroll-Panel sind Kind-Koordinaten relativ zum gescrollten Ursprung: "Karte.Top =
  # 48" landet dann in Wahrheit auf 48 + Scrollweg. Beim Zurueckscrollen stand oben ein leerer
  # Block und alle Karten hingen zu tief - gemeldet aus der Einstellungsseite, reproduziert hier.
  function Test-LayoutScrollShift {
    param($Section)
    $panel = $Section.Panel
    if (-not $panel.AutoScroll) { return 0 }
    $cards = @($panel.Controls | Where-Object { $_.Visible -and [string]$_.Tag -eq 'card' })
    if ($cards.Count -eq 0) { return 0 }
    $before = @($cards | ForEach-Object { $_.Top })
    $panel.AutoScrollPosition = New-Object System.Drawing.Point(0, 300)
    [System.Windows.Forms.Application]::DoEvents()
    if ($panel.AutoScrollPosition.Y -eq 0) { return 0 }   # passt ohnehin ohne Bildlaufleiste
    # Dieselben Aufrufe, die ein Fenster-Resize ausloest.
    foreach ($fn in @('Update-CardWidths', 'Update-SettingsLayout', 'Update-StoreLayout',
                      'Update-LocalPackagesLayout', 'Update-OwnPackageLayout', 'Update-TenantAppsLayout')) {
      if (Get-Command $fn -ErrorAction SilentlyContinue) { try { & $fn } catch { } }
    }
    [System.Windows.Forms.Application]::DoEvents()
    $panel.AutoScrollPosition = New-Object System.Drawing.Point(0, 0)
    [System.Windows.Forms.Application]::DoEvents()
    $after = @($cards | ForEach-Object { $_.Top })
    $shifted = 0
    for ($i = 0; $i -lt $before.Count; $i++) {
      if ([Math]::Abs($after[$i] - $before[$i]) -gt 2) {
        Write-Host ("LAYOUT-SCROLLSHIFT {0}: Karte {1} stand auf {2}px, nach Neuanordnung im gescrollten Zustand auf {3}px" -f $Section.Key, $i, $before[$i], $after[$i])
        $shifted++
      }
    }
    return $shifted
  }

  # --- Lesbarkeit: Beschriftung gegen ihren tatsaechlichen Hintergrund, in JEDEM Design ----------
  #
  # WinForms zeichnet eine Label mit Enabled=$false in SystemColors.GrayText und ignoriert jede
  # Designfarbe: auf dunklem Grund waren "Kulanzzeitraum (Minuten)" und "Neustart-Countdown vorher
  # anzeigen" praktisch unlesbar. Seitdem werden solche Beschriftungen gedaempft statt deaktiviert -
  # und hier wird nachgemessen, dass das in allen sieben Designs reicht.
  function Get-Luminance {
    param($C)
    $vals = @($C.R, $C.G, $C.B) | ForEach-Object {
      $v = $_ / 255.0
      if ($v -le 0.03928) { $v / 12.92 } else { [Math]::Pow((($v + 0.055) / 1.055), 2.4) }
    }
    return 0.2126 * $vals[0] + 0.7152 * $vals[1] + 0.0722 * $vals[2]
  }
  function Get-ContrastRatio {
    param($A, $B)
    $l1 = Get-Luminance $A; $l2 = Get-Luminance $B
    if ($l2 -gt $l1) { $t = $l1; $l1 = $l2; $l2 = $t }
    return [Math]::Round((($l1 + 0.05) / ($l2 + 0.05)), 2)
  }
  function Get-EffectiveBackColor {
    param($Control)
    $c = $Control
    while ($c) {
      if ($c.BackColor.A -ne 0) { return $c.BackColor }
      $c = $c.Parent
    }
    return [System.Drawing.SystemColors]::Control
  }
  function Test-LabelContrast {
    param($Panel, [string]$Path, [string]$ThemeName, [double]$Minimum = 3.0)
    $found = 0
    foreach ($c in $Panel.Controls) {
      if (-not $c.Visible) { continue }
      if ($c -is [System.Windows.Forms.Label]) {
        $ratio = Get-ContrastRatio $c.ForeColor (Get-EffectiveBackColor $c.Parent)
        if ($ratio -lt $Minimum) {
          $text = ([string]$c.Text) -replace "`r`n", ' '
          if ($text.Length -gt 40) { $text = $text.Substring(0, 40) + '...' }
          Write-Host ("LAYOUT-CONTRAST {0}/{1}: '{2}' {3}:1" -f $ThemeName, $Path, $text, $ratio)
          $found++
        }
      }
      if ($c.Controls.Count -gt 0) { $found += Test-LabelContrast $c ($Path + '/' + $c.GetType().Name) $ThemeName $Minimum }
    }
    return $found
  }

  # --- Abgeschnittener Text ----------------------------------------------------------------------
  #
  # Ein Knopf, dessen Beschriftung breiter ist als er selbst, zeigt "Bei Tenant anmeld..." - und das
  # passiert bei jeder neuen Sprache und bei jedem Design mit breiterer Schrift neu. Bei umbrechenden
  # Beschriftungen ist die HOEHE das Mass: braucht der Text mehr Zeilen als das Steuerelement hoch
  # ist, fehlt die letzte.
  function Test-TextFits {
    param($Panel, [string]$Path, [string]$ThemeName)
    $found = 0
    foreach ($c in $Panel.Controls) {
      if (-not $c.Visible -or [string]::IsNullOrWhiteSpace([string]$c.Text)) {
        if ($c.Controls.Count -gt 0) { $found += Test-TextFits $c ($Path + '/' + $c.GetType().Name) $ThemeName }
        continue
      }
      $isButtonish = ($c -is [System.Windows.Forms.Button] -or $c -is [System.Windows.Forms.CheckBox])
      $isLabel = ($c -is [System.Windows.Forms.Label])
      if (($isButtonish -or $isLabel) -and -not $c.AutoSize) {
        if ($isButtonish) {
          # Einzeilig plus Innenabstand; Kaestchen brauchen zusaetzlich Platz fuer das Haekchen.
          $needed = [System.Windows.Forms.TextRenderer]::MeasureText([string]$c.Text, $c.Font).Width
          $padding = if ($c -is [System.Windows.Forms.CheckBox]) { 22 } else { 12 }
          if (($needed + $padding) -gt $c.Width) {
            Write-Host ("LAYOUT-TRUNCATED {0}/{1}: '{2}' braucht {3}px, hat {4}px" -f $ThemeName, $Path, $c.Text, ($needed + $padding), $c.Width)
            $found++
          }
        } else {
          $measured = [System.Windows.Forms.TextRenderer]::MeasureText([string]$c.Text, $c.Font,
            (New-Object System.Drawing.Size($c.Width, 0)), [System.Windows.Forms.TextFormatFlags]::WordBreak)
          if ($measured.Height -gt ($c.Height + 2)) {
            $text = ([string]$c.Text) -replace "`r`n", ' '
            if ($text.Length -gt 40) { $text = $text.Substring(0, 40) + '...' }
            Write-Host ("LAYOUT-TRUNCATED {0}/{1}: '{2}' braucht {3}px Hoehe, hat {4}px" -f $ThemeName, $Path, $text, $measured.Height, $c.Height)
            $found++
          }
        }
      }
      if ($c.Controls.Count -gt 0) { $found += Test-TextFits $c ($Path + '/' + $c.GetType().Name) $ThemeName }
    }
    return $found
  }

  $overlaps = 0
  foreach ($s in $script:sections) {
    Show-Section $s.Key
    [System.Windows.Forms.Application]::DoEvents()
    $overlaps += Test-LayoutPanel $s.Panel $s.Key
    $overlaps += Test-LayoutScrollShift $s
    $needed = 0
    foreach ($c in $s.Panel.Controls) { if ($c.Visible -and $c.Bottom -gt $needed) { $needed = $c.Bottom } }
    if ($needed -gt $s.Panel.ClientSize.Height) {
      Write-Host ("LAYOUT-SCROLL {0}: Inhalt {1}px, sichtbar {2}px" -f $s.Key, $needed, $s.Panel.ClientSize.Height)
    }
  }

  # Aufklapper ("Erweiterte Optionen"). Bis hierher hat diese Probe nur den ZUGEKLAPPTEN Zustand
  # gesehen - der aufgeklappte war nie gemessen, und dort lagen drei Beschriftungen auf ihren
  # eigenen Eingabefeldern (im Deutschen bis 98 px).
  #
  # Zweitens: ein Aufklapper darf nichts ausserhalb seiner eigenen Sektion bewegen. Der
  # WinGet-Aufklapper setzte $cardFavorites.Top - eine Karte der Sektion "Lokale Pakete". Gemessen
  # stand sie danach auf Top=1108 statt 48. Aufgefallen ist es nie, weil Update-LocalPackagesLayout
  # den Bereich beim Betreten neu anordnet; der Fehler war also nur einen Handler weit von einer
  # leeren Seite entfernt.
  $expanders = @(
    @{ Key = 'winget'; Toggle = $advToggle }
    @{ Key = 'store';  Toggle = $storeAdvToggle }
  )
  foreach ($e in $expanders) {
    if (-not $e.Toggle) { continue }
    $own = @($script:sections | Where-Object { $_.Key -eq $e.Key }) | Select-Object -First 1
    if (-not $own) { continue }

    # Lage ALLER Steuerelemente der uebrigen Sektionen merken. Nicht ueber GetHashCode: ein
    # verworfener Hashcode wird wiederverwendet, und dann vergleicht man zwei verschiedene Dinge.
    $foreign = New-Object System.Collections.Generic.List[object]
    foreach ($s in $script:sections) {
      if ($s.Key -eq $e.Key) { continue }
      foreach ($c in $s.Panel.Controls) {
        [void]$foreign.Add(@{ Section = $s.Key; Control = $c; Top = $c.Top; Height = $c.Height })
      }
    }

    Show-Section $e.Key
    [System.Windows.Forms.Application]::DoEvents()
    $e.Toggle.PerformClick()
    [System.Windows.Forms.Application]::DoEvents()
    foreach ($f in $foreign) {
      if ($f.Control.Top -ne $f.Top -or $f.Control.Height -ne $f.Height) {
        Write-Host ("LAYOUT-CROSS-SECTION {0}: der Aufklapper hat ein Steuerelement in '{1}' verschoben (Top {2}->{3}, Hoehe {4}->{5})" -f $e.Key, $f.Section, $f.Top, $f.Control.Top, $f.Height, $f.Control.Height)
        $overlaps++
      }
    }
    $overlaps += Test-LayoutPanel $own.Panel ("{0}[aufgeklappt]" -f $e.Key)

    # Wieder zuklappen - der Rest der Probe misst den Normalzustand.
    $e.Toggle.PerformClick()
    [System.Windows.Forms.Application]::DoEvents()
    $overlaps += Test-LayoutPanel $own.Panel ("{0}[zugeklappt]" -f $e.Key)
  }
  # Alle Designs: Kontrast UND Ueberlappung. Die Retro-Designs wechseln die Schriftart (Tahoma),
  # womit jede Beschriftung breiter oder hoeher wird - das ist die Lage, in der eine handgezaehlte
  # Koordinate zuschnappt. Deshalb wird hier je Design neu angeordnet und neu gemessen.
  $themeNames = if ($script:availableThemes) { @($script:availableThemes.Keys) } else { @('Dark') }
  foreach ($themeName in $themeNames) {
    try { Set-ActiveTheme -ThemeName $themeName } catch {
      Write-Host ("LAYOUT-THEME-FAILED {0}: {1}" -f $themeName, $_.Exception.Message)
      continue
    }
    [System.Windows.Forms.Application]::DoEvents()
    $before = $overlaps
    $labels = 0
    # ABSICHTLICH ohne Show-Section: gemessen wird der Fall "Design gewechselt, waehrend man den
    # Bereich ansieht". Jeder Bereich wurde in der ersten Runde oben schon einmal angeordnet; wenn
    # der Designwechsel seine Anordnung nicht nachzieht, faellt es genau hier auf.
    foreach ($s in $script:sections) {
      $labels += @($s.Panel.Controls | Where-Object { $_ -is [System.Windows.Forms.Label] }).Count
      $overlaps += Test-LabelContrast $s.Panel $s.Key $themeName
      $overlaps += Test-LayoutPanel $s.Panel ("{0}[{1}]" -f $s.Key, $themeName)
      $overlaps += Test-TextFits $s.Panel $s.Key $themeName
    }
    Write-Host ("LAYOUT-THEME {0}: {1} Sektion(en) geprueft, {2} Befund(e)" -f $themeName, @($script:sections).Count, ($overlaps - $before))
  }

  Write-Host ("LAYOUT_OVERLAPS={0}" -f $overlaps)
  Write-Host 'LAYOUT_PROBE_OK'
  [Environment]::Exit(0)
}
'@

$gate = "if (`$env:WINTUNER_SMOKE -eq '1') {"
$source = [IO.File]::ReadAllText($path)
if (-not $source.Contains($gate)) { throw 'Smoke gate not found in the assembled script; the layout probe cannot inject itself.' }

$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("wintuner-layout-" + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($sandbox)
$patched = Join-Path $sandbox 'WinTuner_GUI-layout.ps1'
[IO.File]::WriteAllText($patched, $source.Replace($gate, $probeBody + "`r`n" + $gate), [Text.UTF8Encoding]::new($true))

$failures = 0
try {
  $pwsh = (Get-Process -Id $PID).Path
  if (-not $pwsh) { $pwsh = 'pwsh' }

  foreach ($size in $Sizes) {
   foreach ($lang in $Languages) {
    $parts = $size -split 'x'
    if ($parts.Count -ne 2) { throw "Size must look like 1280x800; received: $size" }

    # Eigener Datenordner je Lauf, mit vorgelegter Sprache. Ein frischer Ordner ist zugleich der
    # Erstlauf-Zustand - der, in dem jeder CI-Laeufer startet und den vorher niemand gemessen hat.
    $dataDir = Join-Path $sandbox ("data-{0}-{1}" -f ($size -replace 'x', '_'), $lang)
    [void][IO.Directory]::CreateDirectory((Join-Path $dataDir 'WinTunerGUI'))
    [IO.File]::WriteAllText((Join-Path $dataDir 'WinTunerGUI\settings.json'),
      ('{{ "Language": "{0}" }}' -f $lang), [Text.UTF8Encoding]::new($false))

    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $pwsh
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    foreach ($a in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $patched)) {
      [void]$psi.ArgumentList.Add($a)
    }
    $psi.EnvironmentVariables['WINTUNER_LAYOUT'] = '1'
    $psi.EnvironmentVariables['WINTUNER_LAYOUT_W'] = $parts[0]
    $psi.EnvironmentVariables['WINTUNER_LAYOUT_H'] = $parts[1]
    # Kein echtes Profil anfassen: die Anwendung speichert beim Schliessen. WINTUNER_DATA_DIR ist
    # das, was wirkt - GetFolderPath ignoriert APPDATA (Begruendung in tests/SmokeTest.ps1).
    $psi.EnvironmentVariables['WINTUNER_DATA_DIR'] = $dataDir
    $psi.EnvironmentVariables['APPDATA'] = $dataDir
    $psi.EnvironmentVariables['LOCALAPPDATA'] = $dataDir

    $proc = [Diagnostics.Process]::Start($psi)
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $proc.StandardInput.Close()
    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
      try { $proc.Kill($true) } catch { }
      throw "Layout probe at $size ($lang) did not finish within $TimeoutSeconds seconds."
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()

    if ($stdout -notmatch 'LAYOUT_PROBE_OK') {
      Write-Host $stdout
      if ($stderr) { Write-Host $stderr }
      throw "Layout probe at $size ($lang) did not reach the end of the run."
    }
    # JEDE Befundzeile durchreichen, nicht eine Aufzaehlung bekannter Praefixe.
    #
    # Vorher standen hier vier Muster, und eine neu hinzugekommene Meldung (LAYOUT-CROSS-SECTION)
    # war in keinem davon: der Zaehler stieg, die Probe wurde rot - und sagte nicht, was sie
    # gefunden hatte. Ein Befund ohne Text ist fuer den, der ihn beheben soll, kein Befund.
    # Die Zaehl- und Endemarken (LAYOUT_OVERLAPS=, LAYOUT_PROBE_OK) tragen einen Unterstrich und
    # fallen deshalb nicht unter diese Regel.
    foreach ($line in ($stdout -split "`r?`n")) {
      if ($line -match '^LAYOUT-') { Write-Host "  $line" }
    }
    $count = if ($stdout -match 'LAYOUT_OVERLAPS=(\d+)') { [int]$Matches[1] } else { -1 }
    if ($count -lt 0) { throw "Layout probe at $size ($lang) did not report a result." }
    if ($count -gt 0) {
      Write-Host ("Layout probe {0} [{1}]: {2} finding(s)." -f $size, $lang, $count)
      $failures += $count
    } else {
      Write-Host ("Layout probe {0} [{1}]: no overlapping controls, no scroll shift." -f $size, $lang)
    }
   }
  }
} finally {
  try { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

if ($failures -gt 0) {
  throw "Layout probe found $failures layout defect(s). A label drawn over its own input is invisible, and a card that moves while the page is scrolled leaves an empty block at the top."
}
Write-Host 'Layout probe passed: no section draws a control over another, and none shifts when it is re-laid out while scrolled.'
