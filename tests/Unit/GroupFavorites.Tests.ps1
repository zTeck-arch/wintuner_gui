BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '10-Settings.ps1' `
    -Name 'Get-TenantFavoriteKey', 'Get-GroupFavorites', 'Add-GroupFavorite', 'Remove-GroupFavorite')))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '20-Version.ps1' -Name 'Test-GuidString')))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '25-WinGetData.ps1' `
    -Name 'Get-FavoriteIdForSelection', 'Test-IsGroupSelection')))

  # Persisting is not what these tests are about; capture the calls instead of touching the real
  # settings file, which lives in the user's profile.
  $global:SaveCalls = 0
  Set-Item -Path function:global:Save-Settings -Value { $global:SaveCalls++ }

  $global:GuidA = '3f2504e0-4f89-11d3-9a0c-0305e82c3301'
  $global:GuidB = '9c5b94b1-35ad-49bb-b118-8e8fc24abf80'

  function global:New-TargetComboFixture {
    param([int]$FavoriteCount)
    $c = New-Object System.Windows.Forms.ComboBox
    [void]$c.Items.AddRange(@('not assigned', 'all users', 'all devices', 'custom group'))
    for ($i = 0; $i -lt $FavoriteCount; $i++) { [void]$c.Items.Add("* fav$i") }
    return $c
  }
}

Describe 'Group favorites are scoped to one tenant' {
  BeforeEach {
    $script:settings = @{ GroupFavorites = @{} }
    $script:currentUserUpn = 'admin@kunde-a.de'
  }

  It 'derives the key from the UPN domain, lowercased' {
    $script:currentUserUpn = 'Admin@Kunde-A.DE'
    Get-TenantFavoriteKey | Should -Be 'kunde-a.de'
  }

  It 'has no key without a session, so nothing can be stored under an empty tenant' {
    $script:currentUserUpn = ''
    Get-TenantFavoriteKey | Should -Be ''
    Add-GroupFavorite -Id $global:GuidA -Name 'Alle' | Should -BeFalse
    @(Get-GroupFavorites).Count | Should -Be 0
  }

  # The one that matters for an MSP tool: a group saved for customer A must never be offered while
  # connected to customer B. Assigning an app to the wrong organisation is not a recoverable slip.
  It 'never returns another customers group' {
    Add-GroupFavorite -Id $global:GuidA -Name 'Alle Mitarbeiter A' | Should -BeTrue
    $script:currentUserUpn = 'admin@kunde-b.de'
    @(Get-GroupFavorites).Count | Should -Be 0
    Add-GroupFavorite -Id $global:GuidB -Name 'Technik B' | Should -BeTrue
    @(Get-GroupFavorites).Count | Should -Be 1
    @(Get-GroupFavorites)[0].Name | Should -Be 'Technik B'
    $script:currentUserUpn = 'admin@kunde-a.de'
    @(Get-GroupFavorites)[0].Name | Should -Be 'Alle Mitarbeiter A'
  }
}

Describe 'Add-GroupFavorite' {
  BeforeEach {
    $script:settings = @{ GroupFavorites = @{} }
    $script:currentUserUpn = 'admin@kunde-a.de'
  }

  It 'refuses anything that is not a group object id' {
    Add-GroupFavorite -Id 'not-a-guid' -Name 'Alle' | Should -BeFalse
    Add-GroupFavorite -Id '' -Name 'Alle' | Should -BeFalse
    @(Get-GroupFavorites).Count | Should -Be 0
  }

  It 'refuses an empty name, which would show as a blank entry in the target list' {
    Add-GroupFavorite -Id $global:GuidA -Name '   ' | Should -BeFalse
    @(Get-GroupFavorites).Count | Should -Be 0
  }

  It 'renames instead of storing the same group twice' {
    $null = Add-GroupFavorite -Id $global:GuidA -Name 'Erster Name'
    $null = Add-GroupFavorite -Id $global:GuidA -Name 'Zweiter Name'
    $favorites = @(Get-GroupFavorites)
    $favorites.Count | Should -Be 1
    $favorites[0].Name | Should -Be 'Zweiter Name'
  }

  It 'keeps several distinct groups in insertion order' {
    $null = Add-GroupFavorite -Id $global:GuidA -Name 'Alle'
    $null = Add-GroupFavorite -Id $global:GuidB -Name 'Technik'
    $favorites = @(Get-GroupFavorites)
    $favorites.Count | Should -Be 2
    $favorites[0].Name | Should -Be 'Alle'
    $favorites[1].Name | Should -Be 'Technik'
  }
}

Describe 'Remove-GroupFavorite' {
  BeforeEach {
    $script:settings = @{ GroupFavorites = @{} }
    $script:currentUserUpn = 'admin@kunde-a.de'
    $null = Add-GroupFavorite -Id $global:GuidA -Name 'Alle'
    $null = Add-GroupFavorite -Id $global:GuidB -Name 'Technik'
  }

  It 'removes only the named group' {
    $null = Remove-GroupFavorite -Id $global:GuidA
    $favorites = @(Get-GroupFavorites)
    $favorites.Count | Should -Be 1
    $favorites[0].Name | Should -Be 'Technik'
  }

  It 'drops the tenant key entirely once its last favorite is gone' {
    $null = Remove-GroupFavorite -Id $global:GuidA
    $null = Remove-GroupFavorite -Id $global:GuidB
    @(Get-GroupFavorites).Count | Should -Be 0
    $script:settings.GroupFavorites.ContainsKey('kunde-a.de') | Should -BeFalse
  }
}

Describe 'Resolving a favorite back from the target list' {
  BeforeEach {
    $script:settings = @{ GroupFavorites = @{} }
    $script:currentUserUpn = 'admin@kunde-a.de'
    $null = Add-GroupFavorite -Id $global:GuidA -Name 'Alle'
    $null = Add-GroupFavorite -Id $global:GuidB -Name 'Technik'
  }

  # Favorites are appended AFTER the four fixed entries precisely so that every existing
  # "SelectedIndex -eq 3 means custom group" check keeps its meaning. If that offset ever moves,
  # an assignment would silently go to the wrong group - hence these tests.
  It 'returns nothing for the four fixed entries' {
    $combo = New-TargetComboFixture -FavoriteCount 2
    foreach ($i in 0..3) {
      $combo.SelectedIndex = $i
      Get-FavoriteIdForSelection -TargetCombo $combo | Should -Be ''
    }
  }

  It 'maps the first and second favorite to their stored ids' {
    $combo = New-TargetComboFixture -FavoriteCount 2
    $combo.SelectedIndex = 4
    Get-FavoriteIdForSelection -TargetCombo $combo | Should -Be $global:GuidA
    $combo.SelectedIndex = 5
    Get-FavoriteIdForSelection -TargetCombo $combo | Should -Be $global:GuidB
  }

  It 'returns nothing when the list holds more entries than there are favorites' {
    $combo = New-TargetComboFixture -FavoriteCount 3
    $combo.SelectedIndex = 6
    Get-FavoriteIdForSelection -TargetCombo $combo | Should -Be ''
  }

  # Excluding an assignment requires a group target. A favorite is a group, so it has to satisfy
  # that check just like a pasted object id does.
  It 'counts both the manual entry and a favorite as a group selection' {
    $combo = New-TargetComboFixture -FavoriteCount 2
    $combo.SelectedIndex = 3
    Test-IsGroupSelection -TargetCombo $combo | Should -BeTrue
    $combo.SelectedIndex = 4
    Test-IsGroupSelection -TargetCombo $combo | Should -BeTrue
  }

  It 'does not count all-users or all-devices as a group selection' {
    $combo = New-TargetComboFixture -FavoriteCount 2
    $combo.SelectedIndex = 1
    Test-IsGroupSelection -TargetCombo $combo | Should -BeFalse
    $combo.SelectedIndex = 2
    Test-IsGroupSelection -TargetCombo $combo | Should -BeFalse
  }
}

Describe 'Settings serialisation depth' {
  # Regression: Save-Settings used ConvertTo-Json without -Depth, whose default of 2 turns anything
  # deeper into the literal string "System.Collections.Hashtable". GroupFavorites is tenant -> list
  # of objects, so every favorite would have been destroyed on the first save.
  It 'round-trips a favorites structure at the depth Save-Settings uses' {
    $settings = @{ GroupFavorites = @{ 'kunde-a.de' = @(@{ Id = $global:GuidA; Name = 'Alle' }) } }
    $json = $settings | ConvertTo-Json -Compress -Depth 6
    $json | Should -Not -Match 'System.Collections.Hashtable'
    $back = $json | ConvertFrom-Json
    $back.GroupFavorites.'kunde-a.de'[0].Name | Should -Be 'Alle'
    $back.GroupFavorites.'kunde-a.de'[0].Id | Should -Be $global:GuidA
  }

  It 'shows why the default depth was not enough' {
    $settings = @{ GroupFavorites = @{ 'kunde-a.de' = @(@{ Id = $global:GuidA; Name = 'Alle' }) } }
    $shallow = $settings | ConvertTo-Json -Compress -Depth 2 -WarningAction SilentlyContinue
    $shallow | Should -Match 'System.Collections.Hashtable'
  }
}
