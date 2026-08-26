BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '40-Graph.ps1' `
    -Name 'Get-AppInstallationProbe', 'Get-AppInstallCountsFromReport', 'Get-AppInstallSummaryCount')))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '20-Version.ps1' -Name 'Test-GuidString')))

  function global:Get-WtToken { 'test-token' }
  # Routed by URI so a test can decide per endpoint what Intune answers.
  function global:Invoke-RestMethod {
    param($Method, $Uri, $Headers, $Body, $TimeoutSec, $ErrorAction)
    & $global:GraphHandler ([string]$Uri)
  }

  $global:AppId = 'eeeeeeee-1111-2222-3333-444444444444'

  function global:New-StatusReport {
    param([int[]]$InstalledPerRow)
    $rows = @()
    foreach ($n in $InstalledPerRow) { $rows += ,@('app-id', 0, 0, $n, 0) }
    [pscustomobject]@{
      TotalRowCount = $rows.Count
      Schema = @(
        [pscustomobject]@{ Column = 'ApplicationId' }
        [pscustomobject]@{ Column = 'FailedDeviceCount' }
        [pscustomobject]@{ Column = 'PendingInstallDeviceCount' }
        [pscustomobject]@{ Column = 'InstalledDeviceCount' }
        [pscustomobject]@{ Column = 'NotInstalledDeviceCount' })
      Values = $rows
    }
  }
  # The tenant this fallback was written for: every per-app endpoint answers HTTP 400.
  function global:Deny-DirectEndpoints {
    param($Uri)
    if ($Uri -notlike '*getAppStatusOverviewReport*') {
      throw 'Response status code does not indicate success: 400 (Bad Request).'
    }
  }
}

Describe 'Get-AppInstallationProbe' {
  Context 'device statuses answer normally' {
    It 'uses them and does not fall back' {
      $global:GraphHandler = {
        param($Uri)
        if ($Uri -like '*/deviceStatuses*') { return [pscustomobject]@{ value = @([pscustomobject]@{ installState = 'installed' }) } }
        throw 'no fallback should have been used'
      }
      $probe = Get-AppInstallationProbe -AppId $global:AppId -AppName 'Webex'
      $probe.Succeeded | Should -BeTrue
      $probe.HasInstallations | Should -BeTrue
    }

    It 'leaves Count null on a device-status hit (it stops at the first, cannot count) [#31]' {
      $global:GraphHandler = {
        param($Uri)
        if ($Uri -like '*/deviceStatuses*') { return [pscustomobject]@{ value = @([pscustomobject]@{ installState = 'installed' }) } }
        throw 'no fallback should have been used'
      }
      $probe = Get-AppInstallationProbe -AppId $global:AppId -AppName 'Webex'
      $probe.HasInstallations | Should -BeTrue
      $probe.Count | Should -BeNullOrEmpty
    }
  }

  Context 'empty device statuses must be cross-checked before confirming zero [#12]' {
    It 'confirms zero only when a second source agrees' {
      $global:GraphHandler = {
        param($Uri)
        if ($Uri -like '*/deviceStatuses*') { return [pscustomobject]@{ value = @() } }
        if ($Uri -like '*/installSummary*') { return [pscustomobject]@{ installedDeviceCount = 0; installedUserCount = 0 } }
        throw "unexpected $Uri"
      }
      $probe = Get-AppInstallationProbe -AppId $global:AppId -AppName 'Airtame'
      $probe.Succeeded | Should -BeTrue
      $probe.HasInstallations | Should -BeFalse
      $probe.Count | Should -Be 0
    }

    It 'does NOT confirm zero when install summary disagrees - takes the higher, blocks deletion' {
      $global:GraphHandler = {
        param($Uri)
        if ($Uri -like '*/deviceStatuses*') { return [pscustomobject]@{ value = @() } }
        if ($Uri -like '*/installSummary*') { return [pscustomobject]@{ installedDeviceCount = 4; installedUserCount = 1 } }
        throw "unexpected $Uri"
      }
      $probe = Get-AppInstallationProbe -AppId $global:AppId -AppName 'Adobe'
      $probe.HasInstallations | Should -BeTrue
      $probe.Count | Should -Be 5
    }

    It 'stays unknown (blocks deletion) when no second source can confirm zero' {
      # deviceStatuses says empty, installSummary AND the report are unavailable.
      $global:GraphHandler = {
        param($Uri)
        if ($Uri -like '*/deviceStatuses*') { return [pscustomobject]@{ value = @() } }
        throw 'Response status code does not indicate success: 400 (Bad Request).'
      }
      $probe = Get-AppInstallationProbe -AppId $global:AppId -AppName 'Zoom'
      $probe.Succeeded | Should -BeFalse
      $probe.HasInstallations | Should -BeTrue
    }
  }

  Context 'every per-app endpoint returns HTTP 400' {
    # Measured against a real tenant: deviceStatuses, userStatuses and installSummary all refuse,
    # on beta and v1.0, with and without the win32LobApp type cast. Without this third source the
    # state stayed unknown forever - and unknown blocks every deletion, so the version cleanup
    # reported "0 removed" run after run.
    It 'reads the count from the app status report' {
      $global:GraphHandler = { param($Uri) Deny-DirectEndpoints $Uri; New-StatusReport -InstalledPerRow @(18) }
      $probe = Get-AppInstallationProbe -AppId $global:AppId -AppName 'Google Chrome'
      $probe.Succeeded | Should -BeTrue
      $probe.HasInstallations | Should -BeTrue
      $probe.Count | Should -Be 18
    }

    It 'treats an empty report as a confirmed zero, not as unknown' {
      $global:GraphHandler = { param($Uri) Deny-DirectEndpoints $Uri; New-StatusReport -InstalledPerRow @() }
      $probe = Get-AppInstallationProbe -AppId $global:AppId -AppName 'Airtame'
      $probe.Succeeded | Should -BeTrue
      $probe.HasInstallations | Should -BeFalse
      $probe.Count | Should -Be 0
    }

    It 'sums several rows' {
      $global:GraphHandler = { param($Uri) Deny-DirectEndpoints $Uri; New-StatusReport -InstalledPerRow @(0, 2, 3) }
      (Get-AppInstallationProbe -AppId $global:AppId -AppName 'X').Count | Should -Be 5
    }
  }

  Context 'unexpected answers must block a deletion, never permit one' {
    # Every failure mode has to end in Succeeded=$false with HasInstallations=$true, because the
    # callers delete only when the state is confirmed. A parsing mistake may cost a cleanup run;
    # it must never cost an app version.
    It 'reports unknown when all three sources fail' {
      $global:GraphHandler = { param($Uri) throw 'Response status code does not indicate success: 400 (Bad Request).' }
      $probe = Get-AppInstallationProbe -AppId $global:AppId -AppName 'X'
      $probe.Succeeded | Should -BeFalse
      $probe.HasInstallations | Should -BeTrue
    }

    It 'reports unknown when the report has no schema' {
      $global:GraphHandler = { param($Uri) Deny-DirectEndpoints $Uri; [pscustomobject]@{ Schema = @(); Values = @() } }
      (Get-AppInstallationProbe -AppId $global:AppId -AppName 'X').Succeeded | Should -BeFalse
    }

    It 'reports unknown when the expected column is missing' {
      $global:GraphHandler = {
        param($Uri)
        Deny-DirectEndpoints $Uri
        [pscustomobject]@{ Schema = @([pscustomobject]@{ Column = 'ApplicationId' }); Values = @( ,@('app-id') ) }
      }
      (Get-AppInstallationProbe -AppId $global:AppId -AppName 'X').Succeeded | Should -BeFalse
    }

    It 'reports unknown when a row is shorter than the schema' {
      $global:GraphHandler = {
        param($Uri)
        Deny-DirectEndpoints $Uri
        [pscustomobject]@{
          Schema = @([pscustomobject]@{ Column = 'ApplicationId' }, [pscustomobject]@{ Column = 'InstalledDeviceCount' })
          Values = @( ,@('app-id') )
        }
      }
      (Get-AppInstallationProbe -AppId $global:AppId -AppName 'X').Succeeded | Should -BeFalse
    }

    It 'rejects an invalid app id without asking Graph at all' {
      $global:GraphHandler = { param($Uri) throw 'must not be called' }
      (Get-AppInstallationProbe -AppId 'not-a-guid' -AppName 'X').Succeeded | Should -BeFalse
    }
  }

  Context 'the column is located by name' {
    # A fixed position would silently read the wrong number the day Microsoft inserts a column -
    # and that number decides whether an app version is deleted.
    It 'finds the count even when the columns are in a different order' {
      $global:GraphHandler = {
        param($Uri)
        Deny-DirectEndpoints $Uri
        [pscustomobject]@{
          Schema = @([pscustomobject]@{ Column = 'InstalledDeviceCount' }, [pscustomobject]@{ Column = 'ApplicationId' })
          Values = @( ,@(7, 'app-id') )
        }
      }
      (Get-AppInstallationProbe -AppId $global:AppId -AppName 'X').Count | Should -Be 7
    }
  }
}
