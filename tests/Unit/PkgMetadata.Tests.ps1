#requires -Version 7
# Metadaten aus einer macOS-.pkg lesen.
#
# Der Leser ersetzt "installer -pkginfo", das es unter Windows nicht gibt. Was er liefert, landet
# als primaryBundleId / primaryBundleVersion / includedApps an der Intune-App - und ein Fehler darin
# ergibt eine App, die Intune anlegt und auf dem Geraet NIE als installiert erkennt. Sie wird dann
# bei jeder Pruefung neu installiert, und zwar auf jedem zugewiesenen Mac.
#
# Geprueft wird gegen zwei Pakete:
#   - tests/Fixtures/sample-app.pkg, 1147 Byte, selbst erzeugt (tests/Fixtures/New-SamplePkg.ps1),
#     im Repository, laeuft immer.
#   - tests/GoogleChrome.pkg, 252 MB, NICHT im Repository (.gitignore). Liegt sie auf dem Rechner,
#     wird gegen ein echtes Hersteller-Paket geprueft; fehlt sie, ueberspringt sich der Block -
#     dasselbe Muster wie beim Modulvertrag.

BeforeDiscovery {
  # Discovery-Phase, weil Pester -Skip hier auswertet. Nichts darf fliegen, sonst faellt die
  # ganze Datei aus.
  $script:skipReal = -not (Test-Path -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'GoogleChrome.pkg') -PathType Leaf)
}

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  # Der GANZE Teil, nicht einzelne Funktionen: er setzt die Obergrenzen und die Tabelle der
  # macOS-Versionen als Zuweisungen: eine Kopie davon im Test wuerde von der Quelle abdriften.
  . ([scriptblock]::Create((Get-SourcePartText -Part '43-PkgMetadata.ps1')))
  . ([scriptblock]::Create((Get-UiStringsText)))

  $script:fixture = Join-Path $PSScriptRoot '..\Fixtures\sample-app.pkg' | Convert-Path
  $script:realPkgPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'GoogleChrome.pkg'

  # Legt eine Datei mit selbst gesetztem xar-Kopf an, um die Abwehrfaelle zu erzeugen.
  function New-BrokenPkg {
    param([string]$Signature = 'xar!', [int]$HeaderSize = 28, [int64]$TocLength = 64, [int]$BodyBytes = 0)
    $path = Join-Path ([IO.Path]::GetTempPath()) ("wtgui-test-broken-{0}.pkg" -f [guid]::NewGuid().ToString('N'))
    $ms = [System.IO.MemoryStream]::new()
    $ms.Write([System.Text.Encoding]::ASCII.GetBytes($Signature), 0, 4)
    foreach ($pair in @(@($HeaderSize, 2), @(1, 2), @($TocLength, 8), @(1024, 8), @(0, 4))) {
      $value = [uint64]$pair[0]; $count = [int]$pair[1]
      for ($i = $count - 1; $i -ge 0; $i--) { $ms.WriteByte([byte](($value -shr ($i * 8)) -band 0xFF)) }
    }
    if ($BodyBytes -gt 0) { $ms.Write([byte[]]::new($BodyBytes), 0, $BodyBytes) }
    [System.IO.File]::WriteAllBytes($path, $ms.ToArray())
    $ms.Dispose()
    return $path
  }
}

Describe 'Get-MacOsPkgMetadata gegen das mitgelieferte Fixture' {

  BeforeAll { $script:meta = Get-MacOsPkgMetadata -PkgFile $script:fixture }

  It 'liest das Paket und nennt Distribution als Quelle' {
    $script:meta.Success | Should -BeTrue
    $script:meta.ErrorMessage | Should -BeNullOrEmpty
    # Ein Produktarchiv hat beides; Distribution muss gewinnen, weil nur dort ALLE Bundles stehen.
    $script:meta.Source | Should -Be 'Distribution'
    $script:meta.Title | Should -Be 'Sample App'
  }

  It 'nennt die Haupt-App als erstes Bundle' {
    $script:meta.PrimaryBundleId | Should -Be 'com.example.SampleApp'
  }

  It 'haelt CFBundleShortVersionString und CFBundleVersion AUSEINANDER' {
    # Der Punkt, an dem Chrome zwei verschiedene Versionen fuehrt (153.0.8010.37 gegen 8010.37).
    # Welche Intune vergleicht, ist ohne Mac nicht messbar - deshalb muessen BEIDE ankommen, damit
    # die Oberflaeche die Wahl lassen kann.
    $script:meta.ShortVersion | Should -Be '4.2.1'
    $script:meta.BuildVersion | Should -Be '4201'
    $script:meta.ShortVersion | Should -Not -Be $script:meta.BuildVersion
  }

  It 'findet alle enthaltenen Bundles, nicht nur die Haupt-App' {
    # includedApps mit nur einem Eintrag hiesse: die Hilfsanwendung wird nie erkannt.
    $script:meta.IncludedApps.Count | Should -Be 2
    $script:meta.IncludedApps[1].BundleId | Should -Be 'com.example.SampleHelper'
    $script:meta.IncludedApps[1].ShortVersion | Should -Be '1.0.7'
    $script:meta.IncludedApps[1].Path | Should -BeLike '*Helper.app'
  }

  It 'liest die Mindestversion aus dem volume-check und rundet sie ab' {
    $script:meta.MinimumSystemVersion | Should -Be '12.3'
    $script:meta.MinimumOsProperty | Should -Be 'v12_0'
  }

  It 'meldet, dass das Paket Installationsskripte mitbringt' {
    # Pre-/Postinstall laufen als root. Gehoert in die Warnkarte, nicht ins Protokoll allein.
    $script:meta.HasInstallScripts | Should -BeTrue
  }
}

Describe 'Get-MacOsMinimumOsProperty' {

  It 'trifft die Werte, die Graph kennt, genau' {
    Get-MacOsMinimumOsProperty -Version '13.0' | Should -Be 'v13_0'
    Get-MacOsMinimumOsProperty -Version '11.0' | Should -Be 'v11_0'
    Get-MacOsMinimumOsProperty -Version '10.14' | Should -Be 'v10_14'
  }

  It 'rundet nach UNTEN, wenn Graph die Version nicht kennt' {
    # Aufrunden hiesse, allen Geraeten zwischen 13.0 und 13.5 die App gar nicht anzubieten. Die
    # .pkg bringt ihre eigene volume-check-Bedingung mit und weigert sich auf zu alten Systemen
    # selbst - unsichtbar zu sein ist der schlimmere Fehler.
    Get-MacOsMinimumOsProperty -Version '13.5' | Should -Be 'v13_0'
    Get-MacOsMinimumOsProperty -Version '12.3' | Should -Be 'v12_0'
    Get-MacOsMinimumOsProperty -Version '10.15.7' | Should -Be 'v10_15'
  }

  It 'begrenzt auf den hoechsten bekannten Wert, statt leer zu bleiben' {
    # Ein Paket von morgen darf nicht dazu fuehren, dass gar keine Mindestanforderung gesetzt wird.
    Get-MacOsMinimumOsProperty -Version '26.0' | Should -Be 'v15_0'
  }

  It 'faellt auf den niedrigsten Wert, wenn das Paket aelter ist als alles Bekannte' {
    Get-MacOsMinimumOsProperty -Version '10.5' | Should -Be 'v10_7'
  }

  It 'versteht eine Version ohne Unterpunkt' {
    Get-MacOsMinimumOsProperty -Version '14' | Should -Be 'v14_0'
  }

  It 'gibt leer zurueck, wenn nichts Lesbares kommt' {
    Get-MacOsMinimumOsProperty -Version '' | Should -Be ''
    Get-MacOsMinimumOsProperty -Version 'Sonoma' | Should -Be ''
  }
}

Describe 'Abwehr unbrauchbarer und praeparierter Dateien' {

  It 'nennt eine fehlende Datei als solche, statt zu werfen' {
    $missing = Join-Path ([IO.Path]::GetTempPath()) ("nicht-da-{0}.pkg" -f [guid]::NewGuid().ToString('N'))
    $m = Get-MacOsPkgMetadata -PkgFile $missing
    $m.Success | Should -BeFalse
    $m.ErrorMessage | Should -Not -BeNullOrEmpty
  }

  It 'erkennt eine Datei, die kein xar-Archiv ist' {
    $path = New-BrokenPkg -Signature 'nope'
    try {
      $m = Get-MacOsPkgMetadata -PkgFile $path
      $m.Success | Should -BeFalse
      $m.ErrorMessage | Should -BeLike '*xar signature*'
    } finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
  }

  It 'verweigert eine absurde TOC-Groesse, BEVOR sie belegt wird' {
    # Die Zahl kommt aus dem Dateikopf, ist also von der Datei bestimmt. Ohne Grenze waeren ein
    # paar praeparierte Bytes eine Belegung von mehreren GB.
    $path = New-BrokenPkg -TocLength ([int64]900MB)
    try {
      $m = Get-MacOsPkgMetadata -PkgFile $path
      $m.Success | Should -BeFalse
      $m.ErrorMessage | Should -BeLike '*beyond anything*'
    } finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
  }

  It 'erkennt ein abgeschnittenes Inhaltsverzeichnis' {
    $path = New-BrokenPkg -TocLength 4096 -BodyBytes 10
    try {
      $m = Get-MacOsPkgMetadata -PkgFile $path
      $m.Success | Should -BeFalse
      $m.ErrorMessage | Should -Not -BeNullOrEmpty
    } finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
  }

  It 'bricht das Entpacken an der Obergrenze ab' {
    # Zip-Bombe: wenige Byte, die sich auf Gigabyte aufblasen.
    $big = [byte[]]::new(2MB)
    $ms = [System.IO.MemoryStream]::new()
    $z = [System.IO.Compression.ZLibStream]::new($ms, [System.IO.Compression.CompressionLevel]::Optimal, $true)
    try { $z.Write($big, 0, $big.Length) } finally { $z.Dispose() }
    { Expand-ZlibBytes -Data $ms.ToArray() -MaxBytes 4096 } | Should -Throw '*limit*'
    $ms.Dispose()
  }

  It 'liest kein XML mit DTD' {
    # Eine .pkg kommt aus dem Internet. Mit DTD-Verarbeitung waere eine praeparierte Datei ein Weg,
    # die Anwendung eine lokale Datei oder eine URL nachladen zu lassen.
    $evil = '<?xml version="1.0"?><!DOCTYPE foo [<!ENTITY x "harmlos">]><installer-gui-script><title>&x;</title></installer-gui-script>'
    { ConvertTo-SafeXml -Text $evil } | Should -Throw
  }
}

Describe 'Gegen ein echtes Hersteller-Paket' -Skip:$skipReal {
  # Uebersprungen statt rot, wenn die Datei fehlt: diese Testdatei muss auf einem Rechner laufen,
  # auf dem kein 252-MB-Paket liegt - und im Repository liegt es bewusst nicht.

  BeforeAll { $script:chrome = Get-MacOsPkgMetadata -PkgFile $script:realPkgPath }

  It 'liest Google Chrome vollstaendig' {
    $script:chrome.Success | Should -BeTrue
    $script:chrome.Source | Should -Be 'Distribution'
    $script:chrome.Title | Should -Be 'Google Chrome'
    $script:chrome.PrimaryBundleId | Should -Be 'com.google.Chrome'
    $script:chrome.HasInstallScripts | Should -BeTrue
  }

  It 'fuehrt die beiden Versionen getrennt, wie Chrome sie ablegt' {
    # Der Fall, der die Wahl in der Oberflaeche ueberhaupt begruendet.
    $script:chrome.ShortVersion | Should -Match '^\d+\.\d+\.\d+\.\d+$'
    $script:chrome.BuildVersion | Should -Not -Be $script:chrome.ShortVersion
    $script:chrome.ShortVersion | Should -BeLike ("*{0}" -f $script:chrome.BuildVersion)
  }

  It 'liest die Mindestversion aus dem echten volume-check' {
    $script:chrome.MinimumOsProperty | Should -Match '^v\d+_\d+$'
  }

  It 'laesst den Payload unberuehrt' {
    # Der eigentliche Beweis, dass nur Kopf, TOC und zwei Eintraege von je unter 2 KB gelesen
    # werden: die Datei ist 252 MB gross. Wer den Payload anfasst, braucht Sekunden bis Minuten -
    # gemessen am 11.09.2026 waren es 5 ms. Die Grenze ist bewusst weit, damit eine langsame
    # Platte den Test nicht rot macht; ein vollstaendiges Lesen sprengt sie trotzdem.
    (Get-Item -LiteralPath $script:realPkgPath).Length | Should -BeGreaterThan 100MB
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $again = Get-MacOsPkgMetadata -PkgFile $script:realPkgPath
    $sw.Stop()
    $again.Success | Should -BeTrue
    $sw.Elapsed.TotalSeconds | Should -BeLessThan 10
  }
}
