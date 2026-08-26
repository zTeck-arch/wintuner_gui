BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '25-WinGetData.ps1' -Name @(
    'Test-IsTransientModuleRace', 'Invoke-WithTransientRetry', 'Get-Win32AppsResilient',
    'Test-Win32InventoryTruncated'))))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '30-UpdateTargets.ps1' -Name 'Remove-SupersededInventoryOverlap')))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '70-Runtime.ps1' -Name 'Format-ErrorDetail')))
}

Describe 'Format-ErrorDetail' {
  It 'includes the exception type, the message and any inner exception' {
    $err = $null
    try {
      throw [System.InvalidOperationException]::new(
        'outer failed', [System.ArgumentNullException]::new('key', 'inner was null'))
    } catch { $err = $_ }

    $detail = Format-ErrorDetail $err
    $detail | Should -Match '\[InvalidOperationException\]'
    $detail | Should -Match 'outer failed'
    $detail | Should -Match 'inner\[ArgumentNullException\]'
    $detail | Should -Match 'inner was null'
  }

  It 'never throws, even on a bare error without an inner exception' {
    $err = $null
    try { throw 'plain message' } catch { $err = $_ }
    { Format-ErrorDetail $err } | Should -Not -Throw
    (Format-ErrorDetail $err) | Should -Match 'plain message'
  }
}

Describe 'Test-IsTransientModuleRace' {
  It 'recognises the module race and throttle shapes as transient' {
    foreach ($m in @(
      'Collection was modified; enumeration operation may not execute.',
      'Value cannot be null. (Parameter ''key'')',
      'The operation has timed out',
      'ServiceUnavailable',
      'Response status code 503',
      'Too Many Requests')) {
      Test-IsTransientModuleRace $m | Should -BeTrue -Because "'$m' is a known transient race/throttle"
    }
  }

  It 'does NOT treat real errors as transient' {
    foreach ($m in @(
      'Request not applicable to target tenant.',
      'Cannot bind argument to parameter ''ActiveApps'' because it is an empty array.',
      'Forbidden: application is not authorized',
      '',
      $null)) {
      Test-IsTransientModuleRace $m | Should -BeFalse -Because "'$m' must fail immediately, not retry"
    }
  }
}

Describe 'Invoke-WithTransientRetry' {
  It 'retries a transient failure and then returns the eventual result' {
    $script:calls = 0
    $result = Invoke-WithTransientRetry -Label 'test' -Action {
      $script:calls++
      if ($script:calls -lt 3) { throw 'Collection was modified; enumeration operation may not execute.' }
      'ok'
    }
    $result | Should -Be 'ok'
    $script:calls | Should -Be 3
  }

  It 'rethrows a non-transient error immediately without retrying' {
    $script:calls = 0
    { Invoke-WithTransientRetry -Action {
        $script:calls++
        throw 'Request not applicable to target tenant.'
      } } | Should -Throw '*not applicable to target tenant*'
    $script:calls | Should -Be 1
  }

  It 'gives up after MaxRetries and rethrows the transient error' {
    $script:calls = 0
    { Invoke-WithTransientRetry -MaxRetries 2 -Action {
        $script:calls++
        throw 'Collection was modified; enumeration operation may not execute.'
      } } | Should -Throw '*Collection was modified*'
    # one initial attempt plus two retries
    $script:calls | Should -Be 3
  }
}

Describe 'Remove-SupersededInventoryOverlap with an empty active inventory' {
  # Regression: a tenant whose apps are all superseded (managed=0, superseded>0) handed an empty
  # array here. The Mandatory parameter rejected it - "Cannot bind argument to parameter
  # 'ActiveApps' because it is an empty array" - which aborted the whole "load apps" step.
  It 'accepts an empty array and returns nothing instead of throwing a binding error' {
    $out = @(Remove-SupersededInventoryOverlap -ActiveApps @() -SupersededApps @(
      [pscustomobject]@{ GraphId = '11111111-1111-1111-1111-111111111111' }))
    $out.Count | Should -Be 0
  }

  It 'still filters overlapping superseded ids out of a non-empty active list' {
    $active = @(
      [pscustomobject]@{ Name = 'Keep'; GraphId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' },
      [pscustomobject]@{ Name = 'Drop'; GraphId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' })
    $superseded = @([pscustomobject]@{ GraphId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' })
    $out = @(Remove-SupersededInventoryOverlap -ActiveApps $active -SupersededApps $superseded)
    $out.Count | Should -Be 1
    $out[0].Name | Should -Be 'Keep'
  }
}

Describe 'Get-Win32AppsResilient parameter binding' {
  # Regression: the module declares -Update as Nullable[bool] and treats it as a FILTER on
  # UpdateAvailable. 0.15.7 always bound -Update:$false, so the inventory contained ONLY apps that
  # were already up to date and the update scan could never find a candidate.
  BeforeAll {
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
      $global:lastQuery = $PSBoundParameters
      return @([pscustomobject]@{ Name = 'App'; GraphId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' })
    }
  }
  AfterAll {
    Remove-Item function:global:Get-WtWin32Apps -ErrorAction SilentlyContinue
    Remove-Variable -Name lastQuery -Scope Global -ErrorAction SilentlyContinue
  }
  BeforeEach { $global:lastQuery = $null }

  It 'does NOT filter on UpdateAvailable unless a caller asks for it' {
    $out = @(Get-Win32AppsResilient -Label 'test')
    $out.Count | Should -Be 1
    $global:lastQuery.ContainsKey('Update') | Should -BeFalse -Because 'an unset filter must stay unset'
    $global:lastQuery['Superseded'] | Should -BeFalse
  }

  It 'still asks for the superseded side of the inventory' {
    $null = Get-Win32AppsResilient -Superseded -Label 'test'
    $global:lastQuery['Superseded'] | Should -BeTrue
    $global:lastQuery.ContainsKey('Update') | Should -BeFalse
  }

  It 'passes the UpdateAvailable filter through when it is requested explicitly' {
    $null = Get-Win32AppsResilient -UpdateAvailable $true -Label 'test'
    $global:lastQuery['Update'] | Should -BeTrue
    $null = Get-Win32AppsResilient -UpdateAvailable $false -Label 'test'
    $global:lastQuery.ContainsKey('Update') | Should -BeTrue
    $global:lastQuery['Update'] | Should -BeFalse
  }
}

Describe 'Test-Win32InventoryTruncated' {
  # Regression: the module asks Graph with $top=999 and does NOT follow @odata.nextLink (verified
  # against WinTuner 1.4.1). A tenant with more managed apps than one page hands back a silent
  # partial inventory - no error, no warning - and every decision built on it (which apps have
  # updates, which versions get deleted) would be made on incomplete data. The GUI cannot paginate
  # inside the module, so it must at least notice and say so.
  It 'treats a result below the page size as complete' {
    Test-Win32InventoryTruncated -Count 998 -PageSize 999 | Should -BeFalse
  }

  It 'treats a full page as possibly truncated' {
    # Exactly 999 matching apps is indistinguishable from more than 999 from outside the module,
    # so a full page has to count as suspect rather than as proven complete.
    Test-Win32InventoryTruncated -Count 999 -PageSize 999 | Should -BeTrue
  }

  It 'treats more than a page as possibly truncated' {
    Test-Win32InventoryTruncated -Count 1500 -PageSize 999 | Should -BeTrue
  }

  It 'says complete when the page size is unknown, rather than crying wolf' {
    # $script:win32AppsModulePageSize is a top-level assignment, so a caller that loads only the
    # function (every unit test here) gets 0. That must degrade to "no warning", not to a warning
    # on every read.
    Test-Win32InventoryTruncated -Count 5000 -PageSize 0 | Should -BeFalse
  }

  It 'handles an empty tenant' {
    Test-Win32InventoryTruncated -Count 0 -PageSize 999 | Should -BeFalse
  }
}

Describe 'Get-Win32AppsResilient truncation warning' {
  BeforeAll {
    # A small page size keeps the mock cheap; the wrapper reads the value at call time.
    $script:win32AppsModulePageSize = 3
    function global:Get-WtWin32Apps {
      param([Nullable[bool]]$Superseded, [Nullable[bool]]$Update)
      return @(1..$global:FakeAppCount | ForEach-Object {
        [pscustomobject]@{ Name = "App$_"; GraphId = ('aaaaaaaa-aaaa-aaaa-aaaa-{0:D12}' -f $_) } })
    }
    # This Describe is about the WARNING; the paged fallback has its own file. Defined here so the
    # outcome cannot depend on whether another test file left a stand-in behind - a throwing fallback
    # means the module result is kept, deterministically.
    function global:Get-Win32AppInventoryViaGraph {
      param([switch]$Superseded)
      throw 'paged fallback is not part of this test'
    }
  }
  AfterAll {
    Remove-Item function:global:Get-WtWin32Apps -ErrorAction SilentlyContinue
    Remove-Item function:global:Get-Win32AppInventoryViaGraph -ErrorAction SilentlyContinue
    Remove-Variable -Name FakeAppCount -Scope Global -ErrorAction SilentlyContinue
  }
  BeforeEach {
    $global:TestLog.Clear()
    $script:win32InventoryTruncationWarned = @{}
  }

  It 'warns when the module hands back a full page' {
    $global:FakeAppCount = 3
    $out = @(Get-Win32AppsResilient -Label 'unit read')
    $out.Count | Should -Be 3
    ($global:TestLog -join "`n") | Should -Match 'very likely INCOMPLETE'
  }

  It 'stays quiet on a short page' {
    $global:FakeAppCount = 2
    $null = Get-Win32AppsResilient -Label 'unit read'
    ($global:TestLog -join "`n") | Should -Not -Match 'INCOMPLETE'
  }

  It 'warns once per inventory kind, so a batch does not flood the log' {
    $global:FakeAppCount = 3
    $null = Get-Win32AppsResilient -Label 'first'
    $null = Get-Win32AppsResilient -Label 'second'
    @($global:TestLog | Where-Object { $_ -match 'INCOMPLETE' }).Count | Should -Be 1
  }

  It 'judges the active and the superseded side separately' {
    $global:FakeAppCount = 3
    $null = Get-Win32AppsResilient -Label 'active'
    $null = Get-Win32AppsResilient -Superseded -Label 'superseded'
    @($global:TestLog | Where-Object { $_ -match 'INCOMPLETE' }).Count | Should -Be 2
  }
}
