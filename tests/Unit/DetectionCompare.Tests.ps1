BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '83-OwnPackage.ps1' `
    -Name 'Compare-UninstallSnapshot', 'Format-DetectionSuggestion')))
  function global:Get-UiString { param($k) if ($k -eq 'DetectUpdatedNote') { 'UPDATED {0} -> {1}' } else { $k } }

  function New-Entry {
    param($Path, $Name, $Version)
    [pscustomobject]@{
      RegistryPath = $Path; KeyName = 'k'; DisplayName = $Name; DisplayVersion = $Version
      Publisher = 'ACME'; InstallLocation = ''; UninstallString = ''; QuietUninstallString = ''
    }
  }
}

Describe 'Compare-UninstallSnapshot' {
  It 'reports an entry that was not there before as new' {
    $before = @{}
    $after = @{ 'k1' = (New-Entry -Path 'HKLM:\...\A' -Name 'App A' -Version '1.0') }
    $diff = Compare-UninstallSnapshot -Before $before -After $after
    $diff.New.Count | Should -Be 1
    $diff.Changed.Count | Should -Be 0
  }

  # The measured field case: the Firefox installer ran for 45 seconds and returned 0, but the key
  # 'Mozilla Firefox' carries no version, so nothing was added - only the version inside it moved.
  # A new-only comparison reported "nothing found" and the whole detection step looked broken.
  It 'reports an in-place upgrade as changed, not as nothing' {
    $before = @{ 'k1' = (New-Entry -Path 'HKLM:\...\Mozilla Firefox' -Name 'Mozilla Firefox (x64 de)' -Version '153.0') }
    $after  = @{ 'k1' = (New-Entry -Path 'HKLM:\...\Mozilla Firefox' -Name 'Mozilla Firefox (x64 de)' -Version '154.0') }
    $diff = Compare-UninstallSnapshot -Before $before -After $after
    $diff.New.Count | Should -Be 0
    $diff.Changed.Count | Should -Be 1
    $diff.Changed[0].PreviousVersion | Should -Be '153.0'
    $diff.Changed[0].DisplayVersion | Should -Be '154.0'
  }

  It 'stays silent when the same version is reinstalled' {
    $e = New-Entry -Path 'HKLM:\...\A' -Name 'App A' -Version '1.0'
    $diff = Compare-UninstallSnapshot -Before @{ 'k1' = $e } -After @{ 'k1' = $e }
    $diff.New.Count | Should -Be 0
    $diff.Changed.Count | Should -Be 0
  }

  # A display name can be rewritten by unrelated servicing. Only a changed version proves an
  # installer ran, so that alone is what promotes an entry to "changed".
  It 'ignores an entry whose version did not move' {
    $before = @{ 'k1' = (New-Entry -Path 'HKLM:\...\A' -Name 'App A' -Version '1.0') }
    $after  = @{ 'k1' = (New-Entry -Path 'HKLM:\...\A' -Name 'App A (x64)' -Version '1.0') }
    (Compare-UninstallSnapshot -Before $before -After $after).Changed.Count | Should -Be 0
  }

  It 'ignores an entry that lost its version' {
    $before = @{ 'k1' = (New-Entry -Path 'HKLM:\...\A' -Name 'App A' -Version '1.0') }
    $after  = @{ 'k1' = (New-Entry -Path 'HKLM:\...\A' -Name 'App A' -Version '') }
    (Compare-UninstallSnapshot -Before $before -After $after).Changed.Count | Should -Be 0
  }

  It 'does not add PreviousVersion to a new entry' {
    $diff = Compare-UninstallSnapshot -Before @{} -After @{ 'k1' = (New-Entry -Path 'p' -Name 'A' -Version '1.0') }
    $diff.New[0].PreviousVersion | Should -BeNullOrEmpty
  }

  It 'does not modify the snapshot it was given' {
    $after = @{ 'k1' = (New-Entry -Path 'p' -Name 'A' -Version '2.0') }
    $null = Compare-UninstallSnapshot -Before @{ 'k1' = (New-Entry -Path 'p' -Name 'A' -Version '1.0') } -After $after
    $after['k1'].PSObject.Properties.Name | Should -Not -Contain 'PreviousVersion'
  }
}

Describe 'Format-DetectionSuggestion' {
  It 'reports the no-change text only when both lists are empty' {
    Format-DetectionSuggestion -NewEntries @() -ChangedEntries @() | Should -Be 'DetectNoChange'
  }

  It 'builds a rule from a changed entry alone' {
    $changed = New-Entry -Path 'HKLM:\...\Mozilla Firefox' -Name 'Mozilla Firefox (x64 de)' -Version '154.0'
    Add-Member -InputObject $changed -NotePropertyName 'PreviousVersion' -NotePropertyValue '153.0'
    $text = Format-DetectionSuggestion -NewEntries @() -ChangedEntries @($changed)
    $text | Should -Match 'Mozilla Firefox \(x64 de\)'
    $text | Should -Match 'HKLM:\\\.\.\.\\Mozilla Firefox'
    $text | Should -Match 'UPDATED 153\.0 -> 154\.0'
  }

  It 'lists new entries before changed ones and marks only the changed one' {
    $new = New-Entry -Path 'p1' -Name 'Brand New' -Version '1.0'
    $changed = New-Entry -Path 'p2' -Name 'Was Here' -Version '2.0'
    Add-Member -InputObject $changed -NotePropertyName 'PreviousVersion' -NotePropertyValue '1.9'
    $text = Format-DetectionSuggestion -NewEntries @($new) -ChangedEntries @($changed)
    $text.IndexOf('Brand New') | Should -BeLessThan $text.IndexOf('Was Here')
    ([regex]::Matches($text, 'UPDATED')).Count | Should -Be 1
  }

  It 'still works when called without the changed list at all' {
    $text = Format-DetectionSuggestion -NewEntries @((New-Entry -Path 'p' -Name 'App A' -Version '1.0'))
    $text | Should -Match 'App A'
    $text | Should -Not -Match 'UPDATED'
  }
}
