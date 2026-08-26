BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '20-Version.ps1' -Name @(
    'Get-ComparableVersionParts', 'Test-IsNewerVersion', 'Test-VersionsEquivalent'))))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '30-UpdateTargets.ps1' -Name @(
    'Measure-AvailableUpdates', 'Find-NewerTenantPackageTarget', 'Find-ExistingUpdateTarget'))))

  function global:New-InvApp {
    param([string]$Name, [string]$Version, [string]$GraphId, [string]$PackageId = 'Acme.Tool')
    [pscustomobject]@{ Name = $Name; CurrentVersion = $Version; GraphId = $GraphId; PackageId = $PackageId }
  }
}

Describe 'Measure-AvailableUpdates' {
  # The dashboard tile and the update scan were answering two different questions with the same word:
  # the tile asked Intune's own UpdateAvailable flag, the scan compares versions. This function is the
  # shared comparison so the two can no longer disagree about a single app.
  BeforeEach {
    $global:LatestByPackage = @{ 'acme.tool' = '3.0' }
    $global:LookupCalls = [System.Collections.Generic.List[string]]::new()

    function global:Resolve-WingetIdForApp {
      param($App)
      return [string]$App.PackageId
    }
    function global:Get-FreshLatestPackageVersion {
      param([string]$PackageId)
      $global:LookupCalls.Add($PackageId)
      $key = $PackageId.ToLowerInvariant()
      if ($global:LatestByPackage.ContainsKey($key)) {
        return [pscustomobject]@{ Latest = $global:LatestByPackage[$key] }
      }
      return $null
    }
    function global:Resolve-WtWingetId { param($AppOrResult) [string]$AppOrResult.PackageId }
  }
  AfterAll {
    foreach ($f in 'Resolve-WingetIdForApp', 'Get-FreshLatestPackageVersion', 'Resolve-WtWingetId') {
      Remove-Item "function:global:$f" -ErrorAction SilentlyContinue
    }
    Remove-Variable -Name LatestByPackage, LookupCalls -Scope Global -ErrorAction SilentlyContinue
  }

  It 'counts an app with a newer version as outdated' {
    $out = Measure-AvailableUpdates -Apps @((New-InvApp -Name 'Acme' -Version '1.0' -GraphId 'g1'))
    $out.Outdated | Should -Be 1
    $out.UpToDate | Should -Be 0
    $out.Checked  | Should -Be 1
  }

  It 'counts an app already on the newest version as up to date' {
    $out = Measure-AvailableUpdates -Apps @((New-InvApp -Name 'Acme' -Version '3.0' -GraphId 'g1'))
    $out.Outdated | Should -Be 0
    $out.UpToDate | Should -Be 1
  }

  It 'does not demand work that is already done' {
    # 1.0 is outdated, but 3.0 is ALREADY deployed in the tenant - so there is nothing to update.
    # Counting it would make the tile ask for an upload that would only create a duplicate.
    $out = Measure-AvailableUpdates -Apps @(
      (New-InvApp -Name 'Acme' -Version '1.0' -GraphId 'g1'),
      (New-InvApp -Name 'Acme' -Version '3.0' -GraphId 'g2'))
    $out.Outdated | Should -Be 0
    $out.AlreadyNewerInTenant | Should -Be 1
    $out.UpToDate | Should -Be 1
  }

  It 'reports an app without a WinGet id instead of dropping it' {
    function global:Resolve-WingetIdForApp { param($App) return '' }
    $out = Measure-AvailableUpdates -Apps @((New-InvApp -Name 'Handmade' -Version '1.0' -GraphId 'g1'))
    $out.NoWingetId | Should -Be 1
    $out.Outdated | Should -Be 0
    # It was still LOOKED at - the tally has to account for it.
    $out.Checked | Should -Be 1
  }

  It 'reports a failed lookup instead of silently treating it as up to date' {
    # Silently counting a failure as "nothing to do" is exactly how an app slips through unnoticed.
    $global:LatestByPackage = @{}
    $out = Measure-AvailableUpdates -Apps @((New-InvApp -Name 'Acme' -Version '1.0' -GraphId 'g1'))
    $out.Failed | Should -Be 1
    $out.UpToDate | Should -Be 0
    $out.Outdated | Should -Be 0
  }

  It 'survives a lookup that throws' {
    function global:Get-FreshLatestPackageVersion { param([string]$PackageId) throw 'index unreachable' }
    $out = Measure-AvailableUpdates -Apps @((New-InvApp -Name 'Acme' -Version '1.0' -GraphId 'g1'))
    $out.Failed | Should -Be 1
  }

  It 'accounts for every checked app exactly once' {
    # The property that makes the number trustworthy: nothing may fall between the categories.
    $global:LatestByPackage = @{ 'acme.tool' = '3.0'; 'other.tool' = '2.0' }
    $apps = @(
      (New-InvApp -Name 'Acme'  -Version '1.0' -GraphId 'g1'),
      (New-InvApp -Name 'Acme'  -Version '3.0' -GraphId 'g2'),
      (New-InvApp -Name 'Other' -Version '2.0' -GraphId 'g3' -PackageId 'Other.Tool'),
      (New-InvApp -Name 'Nope'  -Version '1.0' -GraphId 'g4' -PackageId 'Unknown.Tool'))
    $out = Measure-AvailableUpdates -Apps $apps
    ($out.Outdated + $out.UpToDate + $out.AlreadyNewerInTenant + $out.NoWingetId + $out.Failed) |
      Should -Be $out.Checked
    $out.Checked | Should -Be 4
  }

  It 'looks a package up once, however many versions of it are deployed' {
    $null = Measure-AvailableUpdates -Apps @(
      (New-InvApp -Name 'Acme' -Version '1.0' -GraphId 'g1'),
      (New-InvApp -Name 'Acme' -Version '2.0' -GraphId 'g2'))
    @($global:LookupCalls).Count | Should -Be 1 -Because 'the lookup is per package, not per app object'
  }

  It 'ignores app objects without a version or Graph id' {
    $out = Measure-AvailableUpdates -Apps @(
      ([pscustomobject]@{ Name = 'Broken'; CurrentVersion = ''; GraphId = 'g1'; PackageId = 'Acme.Tool' }),
      (New-InvApp -Name 'Acme' -Version '1.0' -GraphId 'g2'))
    $out.Checked | Should -Be 1
    $out.Outdated | Should -Be 1
  }

  It 'handles an empty tenant' {
    $out = Measure-AvailableUpdates -Apps @()
    $out.Checked | Should -Be 0
    $out.Outdated | Should -Be 0
  }

  It 'reports progress per app when a caller asks for it' {
    $seen = [System.Collections.Generic.List[string]]::new()
    $null = Measure-AvailableUpdates -Apps @(
      (New-InvApp -Name 'Erste'  -Version '1.0' -GraphId 'g1'),
      (New-InvApp -Name 'Zweite' -Version '1.0' -GraphId 'g2')) -OnProgress {
        param($i, $total, $name) $seen.Add("$i/$total $name")
      }
    $seen.Count | Should -Be 2
    $seen[0] | Should -Be '1/2 Erste'
  }
}
