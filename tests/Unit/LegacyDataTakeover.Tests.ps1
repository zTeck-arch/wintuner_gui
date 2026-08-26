# Zwischen 0.15.8 und 0.16.0 hieß die Anwendung eine Zeit lang "Verteilwerk" und legte ihre Daten
# unter %APPDATA%\Verteilwerk ab. Die Umbenennung ist zurückgenommen: der Name ist wieder
# "WinTuner GUI", die Ordner heißen wieder WinTunerGUI. Veröffentlicht wurde die Zwischenfassung nie
# - wer sie aber aus dem Quellbaum gebaut und benutzt hat, hätte seine Einstellungen sonst scheinbar
# verloren. Die Übernahme läuft deshalb weiter, nur in die andere Richtung: Verteilwerk -> WinTunerGUI.
#
# Zwei Eigenschaften sind hier nicht Komfort, sondern Bedingung:
#   1. Die Übernahme KOPIERT. Wer zur Zwischenfassung zurückgeht, muss dort seine Daten unverändert
#      vorfinden.
#   2. Sie läuft genau einmal. Ein zweiter Durchlauf würde einen neueren Stand durch den alten
#      ersetzen - der teuerste denkbare Fehler an dieser Stelle.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '10-Settings.ps1' `
    -Name 'Copy-LegacyDataFile', 'Get-LegacyDataPath')))
  $script:legacyDataFolderName = 'Verteilwerk'
  $script:currentDataFolderName = 'WinTunerGUI'

  # Die Inhalte sind ABSICHTLICH untypisiert: mit [string] wandelt PowerShell ein übergebenes $null
  # in einen Leerstring, und dann hätte "keine Datei vorhanden" eine leere Datei erzeugt - die
  # Vorlage selbst hätte den Fall gar nicht mehr herstellen können, den sie prüfen soll.
  function New-TakeoverFixture {
    param($LegacyContent, $CurrentContent)
    $root = Join-Path ([IO.Path]::GetTempPath()) ("takeover-" + [guid]::NewGuid().ToString('N'))
    $legacyDir  = Join-Path $root 'Verteilwerk'
    $currentDir = Join-Path $root 'WinTunerGUI'
    [void][IO.Directory]::CreateDirectory($legacyDir)
    $legacy  = Join-Path $legacyDir  'settings.json'
    $current = Join-Path $currentDir 'settings.json'
    if ($null -ne $LegacyContent) { [IO.File]::WriteAllText($legacy, [string]$LegacyContent) }
    if ($null -ne $CurrentContent) {
      [void][IO.Directory]::CreateDirectory($currentDir)
      [IO.File]::WriteAllText($current, [string]$CurrentContent)
    }
    return @{ Root = $root; Legacy = $legacy; Current = $current }
  }
}

Describe 'Get-LegacyDataPath' {
  It 'maps the current folder to the one of the pre-release' {
    $current = 'C:\Users\x\AppData\Roaming\WinTunerGUI\settings.json'
    Get-LegacyDataPath -CurrentPath $current |
      Should -Be 'C:\Users\x\AppData\Roaming\Verteilwerk\settings.json'
  }
  It 'rewrites only the LAST occurrence, so a profile of the same name stays intact' {
    # Ein Benutzer, dessen Profilordner selbst "WinTuner GUI" heißt, darf nicht mitverbogen werden -
    # sonst zeigt der Altpfad auf ein Verzeichnis, das es nie gab.
    $current = 'C:\Users\WinTunerGUI\AppData\Roaming\WinTunerGUI\settings.json'
    Get-LegacyDataPath -CurrentPath $current |
      Should -Be 'C:\Users\WinTunerGUI\AppData\Roaming\Verteilwerk\settings.json'
  }
  It 'returns nothing for a path that does not contain the app folder at all' {
    Get-LegacyDataPath -CurrentPath 'C:\somewhere\else\settings.json' | Should -BeNullOrEmpty
  }
}

Describe 'Copy-LegacyDataFile' {
  It 'takes over the old settings and reports the source it came from' {
    $f = New-TakeoverFixture -LegacyContent '{"DefaultPackagePath":"D:\\Pakete"}' -CurrentContent $null
    $result = Copy-LegacyDataFile -CurrentPath $f.Current -LegacyPath $f.Legacy
    $result | Should -Be $f.Legacy
    [IO.File]::Exists($f.Current) | Should -BeTrue
    (Get-Content -LiteralPath $f.Current -Raw) | Should -Match 'D:\\\\Pakete'
  }

  It 'leaves the old file in place, so a rollback still finds its data' {
    $f = New-TakeoverFixture -LegacyContent '{"Language":"de"}' -CurrentContent $null
    [void](Copy-LegacyDataFile -CurrentPath $f.Current -LegacyPath $f.Legacy)
    [IO.File]::Exists($f.Legacy) | Should -BeTrue
    (Get-Content -LiteralPath $f.Legacy -Raw) | Should -Be '{"Language":"de"}'
  }

  It 'creates the target folder when it does not exist yet' {
    $f = New-TakeoverFixture -LegacyContent '{"x":1}' -CurrentContent $null
    (Test-Path -LiteralPath (Split-Path $f.Current -Parent)) | Should -BeFalse
    [void](Copy-LegacyDataFile -CurrentPath $f.Current -LegacyPath $f.Legacy)
    [IO.File]::Exists($f.Current) | Should -BeTrue
  }

  It 'NEVER overwrites an existing new file - the second run must be a no-op' {
    $f = New-TakeoverFixture -LegacyContent '{"alt":true}' -CurrentContent '{"neu":true}'
    Copy-LegacyDataFile -CurrentPath $f.Current -LegacyPath $f.Legacy | Should -BeNullOrEmpty
    (Get-Content -LiteralPath $f.Current -Raw) | Should -Be '{"neu":true}'
  }

  It 'ignores an empty legacy file rather than replacing nothing with nothing' {
    $f = New-TakeoverFixture -LegacyContent '' -CurrentContent $null
    Copy-LegacyDataFile -CurrentPath $f.Current -LegacyPath $f.Legacy | Should -BeNullOrEmpty
    [IO.File]::Exists($f.Current) | Should -BeFalse
  }

  It 'does nothing when there is no old installation at all' {
    $f = New-TakeoverFixture -LegacyContent $null -CurrentContent $null
    Copy-LegacyDataFile -CurrentPath $f.Current -LegacyPath $f.Legacy | Should -BeNullOrEmpty
    [IO.File]::Exists($f.Current) | Should -BeFalse
  }

  It 'survives an unusable legacy path instead of stopping the start-up' {
    # Läuft vor Write-Log und vor dem Fenster: eine Ausnahme hier wäre ein Start, der nicht passiert.
    $f = New-TakeoverFixture -LegacyContent $null -CurrentContent $null
    { Copy-LegacyDataFile -CurrentPath $f.Current -LegacyPath 'Z:\gibt-es-nicht\settings.json' } |
      Should -Not -Throw
    { Copy-LegacyDataFile -CurrentPath $f.Current -LegacyPath '' } | Should -Not -Throw
  }
}
