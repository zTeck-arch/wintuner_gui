BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '50-UpdateEngine.ps1' -Name 'Get-AppVersionGroups')))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '20-Version.ps1' `
    -Name 'Get-ComparableVersionParts', 'Test-IsNewerVersion')))
  # Get-AppVersionGroups now reads through the resilient inventory wrapper, which retries the module's
  # "Collection was modified" race. Load the real wrapper so it exercises the same path the app does;
  # it still bottoms out in the mocked Get-WtWin32Apps below.
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '25-WinGetData.ps1' -Name @(
    'Test-IsTransientModuleRace', 'Invoke-WithTransientRetry', 'Get-Win32AppsResilient',
    'Test-Win32InventoryTruncated'))))

  function global:Resolve-WtWingetId { param($AppOrResult) [string]$AppOrResult.PackageId }
  # Models the real cmdlet's FILTER semantics instead of just accepting its parameters.
  #
  # The previous stand-in took $Update as an untyped parameter and never looked at it. That is why
  # all nine tests in this file stayed green through 0.15.8, in which the version cleanup read an
  # inventory containing ONLY apps that were already up to date - the mock could not tell
  # "-Update not bound" from "-Update:$false", which was the entire bug.
  #
  # Typed like the module (Nullable[bool], verified against WinTuner 1.4.1) so binding a raw switch
  # fails here the same way it fails in production, and $Update is applied as what it is: a filter on
  # each app's UpdateAvailable, where "not bound" means "no filter".
  function global:Get-WtWin32Apps {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
      [Nullable[bool]]$Superseded,
      [Nullable[bool]]$Update,
      [Nullable[bool]]$Superseding,
      [string]$NameContains,
      [Nullable[bool]]$IsAssigned
    )
    $global:lastInventoryQuery = $PSBoundParameters
    $apps = if ($Superseded) { @($global:SupersededApps) } else { @($global:ActiveApps) }
    if ($PSBoundParameters.ContainsKey('Update') -and $null -ne $Update) {
      $apps = @($apps | Where-Object { [bool]$_.UpdateAvailable -eq [bool]$Update })
    }
    return @($apps)
  }
  function global:New-TestApp {
    param(
      $Version, $Id, $Name = 'Adobe Acrobat Reader (64-bit)', $PackageId = 'Adobe.Acrobat.Reader.64-bit',
      # Mirrors the property the real -Update filter works on. Defaults to "an update is available",
      # because those are exactly the apps 0.15.8 dropped out of the inventory.
      [bool]$UpdateAvailable = $true
    )
    [pscustomobject]@{
      Name = $Name; CurrentVersion = $Version; GraphId = $Id; PackageId = $PackageId
      UpdateAvailable = $UpdateAvailable
    }
  }
}

Describe 'Get-AppVersionGroups' {
  BeforeEach {
    $global:A89 = New-TestApp -Version '26.001.21789' -Id 'aaaa-0001'
    $global:A71 = New-TestApp -Version '26.001.21771' -Id 'aaaa-0002'
    $global:A91 = New-TestApp -Version '26.001.21691' -Id 'aaaa-0003'
    $global:A29 = New-TestApp -Version '26.001.21529' -Id 'aaaa-0004'
  }

  It 'keeps the newest N and marks the rest obsolete' {
    $global:ActiveApps = @($global:A89, $global:A91)
    $global:SupersededApps = @($global:A71, $global:A29)
    $groups = @(Get-AppVersionGroups -KeepCount 2)
    $groups.Count | Should -Be 1
    @($groups[0].Keep | ForEach-Object { $_.Raw }) | Should -Be @('26.001.21789', '26.001.21771')
    @($groups[0].Obsolete | ForEach-Object { $_.Raw }) | Should -Be @('26.001.21691', '26.001.21529')
  }

  It 'leaves a group alone when it does not exceed the limit' {
    $global:ActiveApps = @($global:A89, $global:A71)
    $global:SupersededApps = @()
    @(Get-AppVersionGroups -KeepCount 2).Count | Should -Be 0
  }

  It 'never touches a single remaining version' {
    $global:ActiveApps = @($global:A89)
    $global:SupersededApps = @()
    @(Get-AppVersionGroups -KeepCount 1).Count | Should -Be 0
  }

  Context 'the same app object in both inventories' {
    # The two queries are documented as disjoint, but they have been seen overlapping right after a
    # supersedence was created - which is why Remove-SupersededInventoryOverlap exists at all.
    # Concatenating them without comparing GraphIds counted such an app twice: the duplicate decided
    # whether a group was trimmed and occupied one of the "keep newest N" slots, pushing a version
    # that should have been kept into the delete list.
    It 'counts a duplicate once' {
      $global:ActiveApps = @($global:A89, $global:A91)
      $global:SupersededApps = @($global:A89, $global:A71, $global:A29)
      $groups = @(Get-AppVersionGroups -KeepCount 2)
      ($groups[0].Keep.Count + $groups[0].Obsolete.Count) | Should -Be 4
    }

    It 'does not let the duplicate occupy both keep slots' {
      $global:ActiveApps = @($global:A89, $global:A91)
      $global:SupersededApps = @($global:A89, $global:A71, $global:A29)
      $groups = @(Get-AppVersionGroups -KeepCount 2)
      @($groups[0].Keep | ForEach-Object { $_.Raw }) | Should -Be @('26.001.21789', '26.001.21771')
      @($groups[0].Obsolete | ForEach-Object { $_.Raw }) | Should -Not -Contain '26.001.21771'
    }

    It 'does not push a two-version group over the limit' {
      $global:ActiveApps = @($global:A89, $global:A71)
      $global:SupersededApps = @($global:A89)
      @(Get-AppVersionGroups -KeepCount 2).Count | Should -Be 0
    }
  }

  Context 'versions that cannot be compared' {
    It 'skips the whole group rather than guessing an order' {
      $odd = New-TestApp -Version 'build-xyz' -Id 'aaaa-0005'
      $global:ActiveApps = @($global:A89, $global:A71, $global:A91, $odd)
      $global:SupersededApps = @()
      @(Get-AppVersionGroups -KeepCount 2).Count | Should -Be 0
    }
  }

  Context 'apps without a package id' {
    It 'skips them, because grouping by display name alone is unsafe' {
      $noId = [pscustomobject]@{ Name = 'Mystery App'; CurrentVersion = '1.0'; GraphId = 'bbbb-1'; PackageId = '' }
      $noId2 = [pscustomobject]@{ Name = 'Mystery App'; CurrentVersion = '2.0'; GraphId = 'bbbb-2'; PackageId = '' }
      $noId3 = [pscustomobject]@{ Name = 'Mystery App'; CurrentVersion = '3.0'; GraphId = 'bbbb-3'; PackageId = '' }
      $global:ActiveApps = @($noId, $noId2, $noId3)
      $global:SupersededApps = @()
      @(Get-AppVersionGroups -KeepCount 1).Count | Should -Be 0
    }
  }

  Context 'different products' {
    It 'groups by package id and name, not across products' {
      $zoom1 = New-TestApp -Version '7.1.0' -Id 'cccc-1' -Name 'Zoom Workplace' -PackageId 'Zoom.Zoom'
      $zoom2 = New-TestApp -Version '7.0.0' -Id 'cccc-2' -Name 'Zoom Workplace' -PackageId 'Zoom.Zoom'
      $zoom3 = New-TestApp -Version '6.0.0' -Id 'cccc-3' -Name 'Zoom Workplace' -PackageId 'Zoom.Zoom'
      $global:ActiveApps = @($global:A89, $global:A71, $global:A91, $zoom1, $zoom2, $zoom3)
      $global:SupersededApps = @()
      $groups = @(Get-AppVersionGroups -KeepCount 2)
      $groups.Count | Should -Be 2
      foreach ($g in $groups) { $g.Obsolete.Count | Should -Be 1 }
    }
  }

  Context 'the inventory it reads' {
    # This is the test that was missing when 0.15.8 shipped. The cleanup reads the same inventory as
    # the update scan; binding -Update:$false there left it with only up-to-date apps, so superseded
    # versions were never even considered for deletion - and every test in this file still passed.
    BeforeEach { $global:lastInventoryQuery = $null }

    It 'does not filter the inventory by update state' {
      $global:ActiveApps = @($global:A89, $global:A91)
      $global:SupersededApps = @($global:A71)
      $null = @(Get-AppVersionGroups -KeepCount 2)
      $global:lastInventoryQuery | Should -Not -BeNullOrEmpty
      $global:lastInventoryQuery.ContainsKey('Update') |
        Should -BeFalse -Because 'the cleanup must see every version, not only the current ones'
    }

    It 'still finds obsolete versions when every app reports an available update' {
      # With the 0.15.8 bug in place this returned nothing at all: -Update:$false removed exactly
      # these apps from the list.
      $global:ActiveApps = @(
        (New-TestApp -Version '26.001.21789' -Id 'dddd-1' -UpdateAvailable $true),
        (New-TestApp -Version '26.001.21691' -Id 'dddd-2' -UpdateAvailable $true),
        (New-TestApp -Version '26.001.21529' -Id 'dddd-3' -UpdateAvailable $true)
      )
      $global:SupersededApps = @()
      $groups = @(Get-AppVersionGroups -KeepCount 2)
      $groups.Count | Should -Be 1
      $groups[0].Obsolete.Count | Should -Be 1
    }

    It 'asks for the superseded side of the inventory as well' {
      $global:ActiveApps = @($global:A89)
      $global:SupersededApps = @($global:A71)
      $null = @(Get-AppVersionGroups -KeepCount 1)
      # The last call of the two is the superseded one.
      $global:lastInventoryQuery['Superseded'] | Should -BeTrue
    }
  }
}
