BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  # Load the shipped string table plus Get-UiString, so the test asserts against the texts that
  # actually ship rather than copies that could drift.
  . ([scriptblock]::Create((Get-UiStringsText)))
}

Describe 'Packaging/upload phase status strings' {
  # These drive the step display that replaced the marquee: while an app is packaged the bar cannot
  # move (the tools report no percentage) and the upload blocks the UI thread, so the status line is
  # what tells the user which phase the run is in. Both keys must exist in both languages and must
  # keep their three format placeholders (prefix, name, version).
  It 'has both phase strings with all three placeholders in <Lang>' -ForEach @(
    @{ Lang = 'en' }, @{ Lang = 'de' }
  ) {
    $script:uiLanguage = $Lang
    foreach ($key in 'PhasePackagingStatus', 'PhaseUploadingStatus') {
      $s = Get-UiString $key
      $s | Should -Not -BeNullOrEmpty
      $s | Should -Match '\{0\}'
      $s | Should -Match '\{1\}'
      $s | Should -Match '\{2\}'
    }
  }

  It 'formats a batch counter prefix, name and version into one readable line' {
    $script:uiLanguage = 'de'
    $line = (Get-UiString 'PhasePackagingStatus') -f '(2/8) ', 'Google Chrome', '1.2.3'
    $line | Should -Match '\(2/8\) '
    $line | Should -Match 'Google Chrome'
    $line | Should -Match '1\.2\.3'
  }

  It 'yields no leading counter when the prefix is empty (single-app path)' {
    $script:uiLanguage = 'en'
    $line = (Get-UiString 'PhaseUploadingStatus') -f '', 'Adobe Reader', '24.0'
    $line | Should -Not -Match '^\s'
    $line | Should -Match '^Adobe Reader'
  }
}
