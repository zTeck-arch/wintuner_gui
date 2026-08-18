BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '10-Settings.ps1' `
    -Name 'Get-WeeklyLogFileName', 'Remove-ExpiredLogs')))

  function global:New-LogFixture {
    param([string[]]$Names)
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('logtest_' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    foreach ($n in $Names) { Set-Content -LiteralPath (Join-Path $dir $n) -Value 'x' -Encoding utf8 }
    return $dir
  }
  function global:Get-RemainingNames {
    param([string]$Dir)
    return @(Get-ChildItem -LiteralPath $Dir -File | Select-Object -ExpandProperty Name | Sort-Object)
  }
}

Describe 'Weekly log housekeeping' {
  AfterEach {
    if ($script:logDirectory -and (Test-Path -LiteralPath $script:logDirectory)) {
      try { Remove-Item -LiteralPath $script:logDirectory -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
  }

  It 'keeps the current and the previous week, removes what is older' {
    # Retention is two weeks, "now" is week 10 of 2026.
    $script:logDirectory = New-LogFixture -Names @(
      'WinTuner_GUI_2026-W10.log', 'WinTuner_GUI_2026-W09.log',
      'WinTuner_GUI_2026-W08.log', 'WinTuner_GUI_2026-W05.log')
    $removed = Remove-ExpiredLogs -RetentionWeeks 2 -Now ([datetime]'2026-03-05')
    $removed | Should -Be 2
    Get-RemainingNames -Dir $script:logDirectory | Should -Be @('WinTuner_GUI_2026-W09.log', 'WinTuner_GUI_2026-W10.log')
  }

  # The year rolls over but the week number restarts at 1. Comparing week numbers alone would make
  # 2025-W52 look NEWER than 2026-W01, so December would never be cleaned up. Standing in the first
  # week of 2026, the previous week is 2025-W52 and has to survive, while W40 has to go.
  It 'handles the turn of the year' {
    $script:logDirectory = New-LogFixture -Names @(
      'WinTuner_GUI_2026-W01.log', 'WinTuner_GUI_2025-W52.log', 'WinTuner_GUI_2025-W40.log')
    $removed = Remove-ExpiredLogs -RetentionWeeks 2 -Now ([datetime]'2026-01-01')
    $removed | Should -Be 1
    Get-RemainingNames -Dir $script:logDirectory | Should -Be @('WinTuner_GUI_2025-W52.log', 'WinTuner_GUI_2026-W01.log')
  }

  # Anything not matching the weekly pattern is none of our business - deleting a file just
  # because it sits in the folder would be the worse failure.
  It 'never touches files that are not weekly logs' {
    $script:logDirectory = New-LogFixture -Names @(
      'WinTuner_GUI_2020-W01.log', 'notes.txt', 'WinTuner_GUI_backup.log', 'settings.json')
    $null = Remove-ExpiredLogs -RetentionWeeks 2 -Now ([datetime]'2026-03-05')
    Get-RemainingNames -Dir $script:logDirectory | Should -Be @('notes.txt', 'settings.json', 'WinTuner_GUI_backup.log')
  }

  # A retention of zero would mean "delete everything including today's log".
  It 'refuses a retention below one week rather than deleting everything' {
    $script:logDirectory = New-LogFixture -Names @('WinTuner_GUI_2020-W01.log')
    Remove-ExpiredLogs -RetentionWeeks 0 -Now ([datetime]'2026-03-05') | Should -Be 0
    (Get-RemainingNames -Dir $script:logDirectory).Count | Should -Be 1
  }

  It 'copes with a folder that does not exist' {
    $script:logDirectory = Join-Path ([IO.Path]::GetTempPath()) ('gone_' + [Guid]::NewGuid().ToString('N'))
    { Remove-ExpiredLogs -RetentionWeeks 2 } | Should -Not -Throw
  }
}
