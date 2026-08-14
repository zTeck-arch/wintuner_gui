BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-UiStringsText)))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '20-Version.ps1' `
    -Name 'Remove-OldSelfUpdateBackups', 'Invoke-UpdateCheckFeedback')))
  $script:uiLanguage = 'en'
  $script:appVersion = '0.15.0'

  # Defined globally: helpers declared in a Describe body are not visible inside It blocks.
  function global:New-Backup {
    param([string]$Name, [datetime]$Written)
    $p = Join-Path $global:BackupWork $Name
    Set-Content -LiteralPath $p -Value 'old' -Encoding utf8
    (Get-Item -LiteralPath $p).LastWriteTime = $Written
  }
  function global:Get-BackupNames {
    @(Get-ChildItem -LiteralPath $global:BackupWork -File | Where-Object { $_.Name -like '*.backup' } | ForEach-Object { $_.Name })
  }
}

Describe 'Remove-OldSelfUpdateBackups' {
  BeforeEach {
    $global:BackupWork = Join-Path ([IO.Path]::GetTempPath()) ('wt-backup-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $global:BackupWork | Out-Null
    $script:scriptPath = Join-Path $global:BackupWork 'WinTuner_GUI_ntg.ps1'
    Set-Content -LiteralPath $script:scriptPath -Value 'script' -Encoding utf8
  }
  AfterEach {
    Remove-Item -LiteralPath $global:BackupWork -Recurse -Force -ErrorAction SilentlyContinue
  }

  It 'keeps everything while at or below the limit' {
    New-Backup 'WinTuner_GUI_ntg.ps1.20260810-100000.backup' (Get-Date).AddHours(-2)
    New-Backup 'WinTuner_GUI_ntg.ps1.20260811-100000.backup' (Get-Date).AddHours(-1)
    Remove-OldSelfUpdateBackups -ScriptPath $script:scriptPath -Keep 2
    (Get-BackupNames).Count | Should -Be 2
  }

  It 'removes the oldest beyond the limit' {
    New-Backup 'WinTuner_GUI_ntg.ps1.20260808-100000.backup' (Get-Date).AddHours(-4)
    New-Backup 'WinTuner_GUI_ntg.ps1.20260809-100000.backup' (Get-Date).AddHours(-3)
    New-Backup 'WinTuner_GUI_ntg.ps1.20260810-100000.backup' (Get-Date).AddHours(-2)
    New-Backup 'WinTuner_GUI_ntg.ps1.20260811-100000.backup' (Get-Date).AddHours(-1)
    Remove-OldSelfUpdateBackups -ScriptPath $script:scriptPath -Keep 2
    $names = Get-BackupNames
    $names | Should -Contain 'WinTuner_GUI_ntg.ps1.20260811-100000.backup'
    $names | Should -Contain 'WinTuner_GUI_ntg.ps1.20260810-100000.backup'
    $names | Should -Not -Contain 'WinTuner_GUI_ntg.ps1.20260808-100000.backup'
  }

  It 'also prunes the single .backup that older versions wrote' {
    New-Backup 'WinTuner_GUI_ntg.ps1.backup' (Get-Date).AddYears(-1)
    New-Backup 'WinTuner_GUI_ntg.ps1.20260810-100000.backup' (Get-Date).AddHours(-2)
    New-Backup 'WinTuner_GUI_ntg.ps1.20260811-100000.backup' (Get-Date).AddHours(-1)
    Remove-OldSelfUpdateBackups -ScriptPath $script:scriptPath -Keep 2
    Get-BackupNames | Should -Not -Contain 'WinTuner_GUI_ntg.ps1.backup'
  }

  It 'never touches files belonging to another script' {
    New-Backup 'OtherScript.ps1.20260101-000000.backup' (Get-Date).AddYears(-2)
    New-Backup 'WinTuner_GUI_ntg.ps1.20260810-100000.backup' (Get-Date).AddHours(-2)
    New-Backup 'WinTuner_GUI_ntg.ps1.20260811-100000.backup' (Get-Date).AddHours(-1)
    Remove-OldSelfUpdateBackups -ScriptPath $script:scriptPath -Keep 1
    Get-BackupNames | Should -Contain 'OtherScript.ps1.20260101-000000.backup'
  }

  It 'leaves the script itself alone' {
    New-Backup 'WinTuner_GUI_ntg.ps1.20260810-100000.backup' (Get-Date).AddHours(-2)
    New-Backup 'WinTuner_GUI_ntg.ps1.20260811-100000.backup' (Get-Date).AddHours(-1)
    Remove-OldSelfUpdateBackups -ScriptPath $script:scriptPath -Keep 1
    Test-Path -LiteralPath $script:scriptPath | Should -BeTrue
  }

  It 'always keeps at least one recoverable backup' {
    New-Backup 'WinTuner_GUI_ntg.ps1.20260810-100000.backup' (Get-Date).AddHours(-2)
    New-Backup 'WinTuner_GUI_ntg.ps1.20260811-100000.backup' (Get-Date).AddHours(-1)
    Remove-OldSelfUpdateBackups -ScriptPath $script:scriptPath -Keep 0
    (Get-BackupNames).Count | Should -Be 1
  }

  It 'does not fail the update when a backup cannot be deleted' {
    New-Backup 'WinTuner_GUI_ntg.ps1.20260808-100000.backup' (Get-Date).AddHours(-4)
    New-Backup 'WinTuner_GUI_ntg.ps1.20260810-100000.backup' (Get-Date).AddHours(-2)
    New-Backup 'WinTuner_GUI_ntg.ps1.20260811-100000.backup' (Get-Date).AddHours(-1)
    $locked = [IO.File]::Open((Join-Path $global:BackupWork 'WinTuner_GUI_ntg.ps1.20260808-100000.backup'), 'Open', 'Read', 'None')
    try {
      { Remove-OldSelfUpdateBackups -ScriptPath $script:scriptPath -Keep 2 } | Should -Not -Throw
      @($global:TestLog | Where-Object { $_ -like '*Could not remove old update backup*' }).Count | Should -Be 1
    } finally { $locked.Dispose() }
  }
}

Describe 'Invoke-UpdateCheckFeedback' {
  # Context 'Startup' shows no modal dialog, so it can be exercised unattended.
  BeforeEach { $global:TestStatus = $null }

  It 'reports a failed check when no result arrives at all' {
    # Regression: this fell through to "up to date". The self-update ran on a BackgroundWorker,
    # where the scriptblock never executed and the caller received $null - so a check that never
    # ran looked exactly like being current, for every release ever shipped.
    Invoke-UpdateCheckFeedback -UpdateResult $null -Context 'Startup'
    $global:TestStatus | Should -Be ((Get-UiString 'UpdCheckFailedStatus') -f '0.15.0')
  }

  It 'reports a failed check when the result carries no version' {
    Invoke-UpdateCheckFeedback -Context 'Startup' -UpdateResult ([pscustomobject]@{
      UpdateAvailable = $false; LatestVersion = ''; ErrorMessage = $null; NotConfigured = $false })
    $global:TestStatus | Should -Be ((Get-UiString 'UpdCheckFailedStatus') -f '0.15.0')
  }

  It 'still says up to date when a real version came back and nothing is newer' {
    Invoke-UpdateCheckFeedback -Context 'Startup' -UpdateResult ([pscustomobject]@{
      UpdateAvailable = $false; LatestVersion = '0.15.0'; ErrorMessage = $null; NotConfigured = $false })
    $global:TestStatus | Should -Be ((Get-UiString 'UpdUpToDateStatus') -f '0.15.0', '0.15.0')
  }

  It 'keeps its own message when no update source is configured' {
    Invoke-UpdateCheckFeedback -Context 'Startup' -UpdateResult ([pscustomobject]@{ NotConfigured = $true })
    $global:TestStatus | Should -Be ((Get-UiString 'UpdNotConfiguredStatus') -f '0.15.0')
  }

  It 'reports the error when the check itself failed' {
    Invoke-UpdateCheckFeedback -Context 'Startup' -UpdateResult ([pscustomobject]@{
      UpdateAvailable = $false; LatestVersion = ''; ErrorMessage = 'network down'; NotConfigured = $false })
    $global:TestStatus | Should -Be ((Get-UiString 'UpdCheckFailedStatus') -f '0.15.0')
  }
}
