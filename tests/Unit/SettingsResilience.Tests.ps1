BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '10-Settings.ps1' -Name @(
    'Backup-CorruptSettingsFile', 'Get-SettingValue'))))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '25-WinGetData.ps1' -Name @(
    'Resolve-AssignmentTargetFromIndex', 'Select-LiveVersionCacheEntries'))))

  # The index constants are top-level assignments in the source, so a test that loads only the
  # function has to supply them - same values, same order as Update-AssignTargetCombo builds.
  $script:assignTargetIndexNotAssigned = 0
  $script:assignTargetIndexAllUsers    = 1
  $script:assignTargetIndexAllDevices  = 2
  $script:assignTargetIndexCustomGroup = 3
  $script:assignTargetFixedEntryCount  = 4
  $script:versionCacheMaxAgeDays = 7
  $script:versionCacheMaxEntries = 2000
}

Describe 'Backup-CorruptSettingsFile' {
  # Regression: an unreadable settings.json left the defaults in place, and the first Save-Settings
  # then wrote those defaults straight over it. The package path, the saved logins and the per-tenant
  # group favourites were gone with no way back and no message anywhere.
  BeforeEach {
    $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ("wt-settings-" + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($script:tmp)
    $script:file = Join-Path $script:tmp 'settings.json'
  }
  AfterEach {
    try { [IO.Directory]::Delete($script:tmp, $true) } catch { }
  }

  It 'copies the unreadable file aside and returns the copy path' {
    [IO.File]::WriteAllText($script:file, '{ this is not json')
    $backup = Backup-CorruptSettingsFile -Path $script:file -Now ([datetime]'2026-08-20T14:05:06')
    $backup | Should -Not -BeNullOrEmpty
    [IO.File]::Exists($backup) | Should -BeTrue
    [IO.File]::ReadAllText($backup) | Should -Be '{ this is not json'
    (Split-Path $backup -Leaf) | Should -Be 'settings.json.corrupt-20260820-140506'
  }

  It 'leaves the original in place - the copy is a copy, not a move' {
    [IO.File]::WriteAllText($script:file, '{ bad')
    $null = Backup-CorruptSettingsFile -Path $script:file
    [IO.File]::Exists($script:file) | Should -BeTrue
  }

  It 'does not overwrite an earlier backup from the same second' {
    [IO.File]::WriteAllText($script:file, 'first')
    $now = [datetime]'2026-08-20T14:05:06'
    $one = Backup-CorruptSettingsFile -Path $script:file -Now $now
    [IO.File]::WriteAllText($script:file, 'second')
    $two = Backup-CorruptSettingsFile -Path $script:file -Now $now
    $two | Should -Not -Be $one
    # The first backup is the one closest to the user's real data, so it must survive.
    [IO.File]::ReadAllText($one) | Should -Be 'first'
    [IO.File]::ReadAllText($two) | Should -Be 'second'
  }

  It 'reports nothing to preserve when the file does not exist' {
    Backup-CorruptSettingsFile -Path (Join-Path $script:tmp 'missing.json') | Should -BeNullOrEmpty
  }

  It 'reports nothing to preserve for an empty file' {
    [IO.File]::WriteAllText($script:file, '')
    Backup-CorruptSettingsFile -Path $script:file | Should -BeNullOrEmpty
  }

  It 'never throws, so a failed backup cannot stop the application from starting' {
    { Backup-CorruptSettingsFile -Path 'Z:\does\not\exist\settings.json' } | Should -Not -Throw
  }
}

Describe 'Resolve-AssignmentTargetFromIndex' {
  # Regression: the selection used to be read by comparing the combo's display text against
  # Get-UiString. The items are built in the language active at that moment while Get-UiString
  # answers in the language active now, so after a runtime language switch nothing matched, the
  # function returned $null, and an app pointed at All Users was deployed with NO assignment.
  It 'maps the fixed entries by index, independently of any language' {
    Resolve-AssignmentTargetFromIndex -Index 1 | Should -Be 'AllUsers'
    Resolve-AssignmentTargetFromIndex -Index 2 | Should -Be 'AllDevices'
  }

  It 'treats "not assigned" and "nothing selected" alike' {
    Resolve-AssignmentTargetFromIndex -Index 0 | Should -BeNullOrEmpty
    Resolve-AssignmentTargetFromIndex -Index -1 | Should -BeNullOrEmpty
  }

  It 'returns the pasted group id for the custom-group entry' {
    Resolve-AssignmentTargetFromIndex -Index 3 -GroupId '  11111111-2222-3333-4444-555555555555 ' |
      Should -Be '11111111-2222-3333-4444-555555555555'
  }

  It 'refuses the custom-group entry with an empty box rather than assigning something else' {
    Resolve-AssignmentTargetFromIndex -Index 3 -GroupId '   ' | Should -BeNullOrEmpty
  }

  It 'resolves a favorite to its stored id, never to the text on screen' {
    $ids = @('aaaaaaaa-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000002')
    Resolve-AssignmentTargetFromIndex -Index 4 -FavoriteIds $ids | Should -Be $ids[0]
    Resolve-AssignmentTargetFromIndex -Index 5 -FavoriteIds $ids | Should -Be $ids[1]
  }

  It 'falls back to unassigned when the favorite is gone, instead of picking a neighbour' {
    Resolve-AssignmentTargetFromIndex -Index 9 -FavoriteIds @('aaaaaaaa-0000-0000-0000-000000000001') |
      Should -BeNullOrEmpty
  }

  It 'ignores a blank stored id' {
    Resolve-AssignmentTargetFromIndex -Index 4 -FavoriteIds @('') | Should -BeNullOrEmpty
  }
}

Describe 'Select-LiveVersionCacheEntries' {
  # Regression: reads already refuse an entry older than six hours, so a stale version could never be
  # served - but nothing ever removed one either, and the file grew one entry per package ever looked
  # up, for the life of the installation.
  BeforeEach {
    $script:now = [datetime]::SpecifyKind([datetime]'2026-08-20T12:00:00', [DateTimeKind]::Utc)
  }

  It 'keeps a fresh entry' {
    $cache = @{ 'Acme.Tool' = @{ versions = @('1.0'); timestamp = $script:now.AddHours(-2) } }
    $out = Select-LiveVersionCacheEntries -Cache $cache -Now $script:now
    $out.Count | Should -Be 1
    $out['Acme.Tool'].versions | Should -Be @('1.0')
  }

  It 'drops an entry past the age limit' {
    $cache = @{ 'Acme.Tool' = @{ versions = @('1.0'); timestamp = $script:now.AddDays(-8) } }
    (Select-LiveVersionCacheEntries -Cache $cache -Now $script:now).Count | Should -Be 0
  }

  It 'keeps an entry exactly inside the limit' {
    $cache = @{ 'Acme.Tool' = @{ versions = @('1.0'); timestamp = $script:now.AddDays(-6.9) } }
    (Select-LiveVersionCacheEntries -Cache $cache -Now $script:now).Count | Should -Be 1
  }

  It 'drops an entry stamped in the future, which would otherwise never expire' {
    $cache = @{ 'Acme.Tool' = @{ versions = @('1.0'); timestamp = $script:now.AddDays(5) } }
    (Select-LiveVersionCacheEntries -Cache $cache -Now $script:now).Count | Should -Be 0
  }

  It 'caps the entry count and keeps the newest' {
    $cache = @{}
    foreach ($i in 1..10) {
      $cache["Pkg.$i"] = @{ versions = @("$i.0"); timestamp = $script:now.AddHours(-$i) }
    }
    $out = Select-LiveVersionCacheEntries -Cache $cache -Now $script:now -MaxEntries 3
    $out.Count | Should -Be 3
    # Pkg.1 is the newest (one hour old), Pkg.10 the oldest.
    $out.ContainsKey('Pkg.1') | Should -BeTrue
    $out.ContainsKey('Pkg.3') | Should -BeTrue
    $out.ContainsKey('Pkg.4') | Should -BeFalse
  }

  It 'skips an entry without a timestamp instead of throwing' {
    $cache = @{
      'Good.One' = @{ versions = @('1.0'); timestamp = $script:now.AddHours(-1) }
      'Bad.One'  = @{ versions = @('2.0') }
    }
    $out = Select-LiveVersionCacheEntries -Cache $cache -Now $script:now
    $out.Count | Should -Be 1
    $out.ContainsKey('Good.One') | Should -BeTrue
  }

  It 'handles an empty cache' {
    (Select-LiveVersionCacheEntries -Cache @{} -Now $script:now).Count | Should -Be 0
  }
}

Describe 'Get-SettingValue: Zahlengrenzen' {
  # Die settings.json ist ausdruecklich von Hand bearbeitbar (der Kommentar an MaxRecentLogins sagt
  # es), also ist ein absurder Wert ein zu erwartender Eingabefall und kein Ausnahmezustand.
  It 'nimmt einen Wert innerhalb der Grenzen' {
    $src = [pscustomobject]@{ MaxRecentLogins = 20 }
    Get-SettingValue -Source $src -Name 'MaxRecentLogins' -Type Int -Default 15 -Minimum 1 -Maximum 50 | Should -Be 20
  }
  It 'faellt bei einem Wert ueber der Obergrenze auf die Vorgabe zurueck' {
    $src = [pscustomobject]@{ MaxRecentLogins = 1500 }
    Get-SettingValue -Source $src -Name 'MaxRecentLogins' -Type Int -Default 15 -Minimum 1 -Maximum 50 | Should -Be 15
  }
  It 'faellt bei einem Wert unter der Untergrenze auf die Vorgabe zurueck' {
    $src = [pscustomobject]@{ MaxRecentLogins = 0 }
    Get-SettingValue -Source $src -Name 'MaxRecentLogins' -Type Int -Default 15 -Minimum 1 -Maximum 50 | Should -Be 15
  }
  It 'nimmt genau die Grenzwerte noch an' {
    $low = [pscustomobject]@{ MaxRecentLogins = 1 }
    $high = [pscustomobject]@{ MaxRecentLogins = 50 }
    Get-SettingValue -Source $low -Name 'MaxRecentLogins' -Type Int -Default 15 -Minimum 1 -Maximum 50 | Should -Be 1
    Get-SettingValue -Source $high -Name 'MaxRecentLogins' -Type Int -Default 15 -Minimum 1 -Maximum 50 | Should -Be 50
  }
  # Der Grund, warum KeepVersionCount bewusst KEINE Obergrenze hat: ein hoher Wert bewahrt dort nur
  # mehr Versionen (harmlose Richtung), ein Rueckfall auf die Vorgabe 2 wuerde die Versionen LOESCHEN,
  # die jemand behalten wollte. Diese Pruefung haelt fest, dass eine solche Grenze nicht nachtraeglich
  # eingebaut wird, ohne dass jemand darueber nachdenkt.
  It 'laesst einen hohen KeepVersionCount stehen, weil die Vorgabe hier loeschen wuerde' {
    $src = [pscustomobject]@{ KeepVersionCount = 500 }
    Get-SettingValue -Source $src -Name 'KeepVersionCount' -Type Int -Default 2 -Minimum 1 | Should -Be 500
  }
}
