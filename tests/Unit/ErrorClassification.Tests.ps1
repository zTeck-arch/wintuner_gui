BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '40-Graph.ps1' `
    -Name 'Get-ErrorHttpStatus', 'Test-IsNotFoundError')))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '10-Settings.ps1' -Name 'Get-SettingValue')))

  # Builds an ErrorRecord whose exception carries an HTTP status, the way Invoke-RestMethod and the
  # Graph SDK surface one - optionally nested, which some wrappers do.
  function global:New-HttpError {
    param([int]$Status, [string]$Message = 'request failed', [switch]$Nested)
    $inner = [pscustomobject]@{ Message = $Message; Response = [pscustomobject]@{ StatusCode = $Status }; InnerException = $null }
    $exception = if ($Nested) {
      [pscustomobject]@{ Message = $Message; InnerException = $inner }
    } else { $inner }
    return [pscustomobject]@{ Exception = $exception }
  }
  function global:New-PlainError {
    param([string]$Message)
    [pscustomobject]@{ Exception = [pscustomobject]@{ Message = $Message; InnerException = $null } }
  }
}

Describe 'Get-ErrorHttpStatus' {
  It 'reads the status from the response' {
    Get-ErrorHttpStatus -ErrorRecord (New-HttpError -Status 404) | Should -Be 404
  }
  It 'finds a status wrapped one level deeper' {
    Get-ErrorHttpStatus -ErrorRecord (New-HttpError -Status 429 -Nested) | Should -Be 429
  }
  It 'returns 0 when the exception carries no status' {
    Get-ErrorHttpStatus -ErrorRecord (New-PlainError -Message 'something went wrong') | Should -Be 0
  }
}

Describe 'Test-IsNotFoundError' {
  # A deletion counts as successful when the object is already gone. That decision used to rest on
  # the English substring 'not found', so a reworded or localized message would have turned a failed
  # deletion into a reported success.
  Context 'a status is available' {
    It 'accepts 404' {
      Test-IsNotFoundError -ErrorRecord (New-HttpError -Status 404) -Context 'App' | Should -BeTrue
    }
    It 'rejects any other status, whatever the message says' {
      # The decisive case: a 403 whose message happens to contain the words.
      Test-IsNotFoundError -ErrorRecord (New-HttpError -Status 403 -Message 'Resource not found in scope') -Context 'App' | Should -BeFalse
      Test-IsNotFoundError -ErrorRecord (New-HttpError -Status 500) -Context 'App' | Should -BeFalse
    }
  }

  Context 'no status available - text fallback' {
    It 'still recognises the English message' {
      Test-IsNotFoundError -ErrorRecord (New-PlainError -Message 'The resource was not found.') -Context 'App' | Should -BeTrue
    }
    It 'records that it had to rely on the text' {
      $global:TestLog.Clear()
      $null = Test-IsNotFoundError -ErrorRecord (New-PlainError -Message 'not found') -Context 'Adobe'
      @($global:TestLog | Where-Object { $_ -like '*based on the error TEXT*' }).Count | Should -Be 1
    }
    It 'does not treat an unrelated failure as already deleted' {
      Test-IsNotFoundError -ErrorRecord (New-PlainError -Message 'Access denied') -Context 'App' | Should -BeFalse
      Test-IsNotFoundError -ErrorRecord (New-PlainError -Message 'The service is unavailable') -Context 'App' | Should -BeFalse
    }
    It 'does not mistake a version number containing 404 for a missing object' {
      Test-IsNotFoundError -ErrorRecord (New-PlainError -Message 'Package 1.404.0 could not be built') -Context 'App' | Should -BeFalse
    }
  }
}

Describe 'Get-SettingValue' {
  # Regression: the whole of Load-Settings sat in ONE try block, so a single unusable value abandoned
  # every setting after it - the user lost the package path and the recent logins because of one bad
  # number, and it could not even be logged (Write-Log does not exist that early).
  BeforeAll {
    $global:GoodSettings = [pscustomobject]@{
      AutoCheckUpdates = $true; KeepVersionCount = 5; ThemeName = 'Dark'
      RecentLogins = @('a@x.de', 'b@x.de'); MaxRecentLogins = 3
    }
    $global:BrokenSettings = [pscustomobject]@{
      AutoCheckUpdates = $true; KeepVersionCount = 'abc'; ThemeName = 'Dark'
    }
  }

  It 'reads well-formed values' {
    Get-SettingValue -Source $global:GoodSettings -Name 'AutoCheckUpdates' -Type Bool -Default $false | Should -BeTrue
    Get-SettingValue -Source $global:GoodSettings -Name 'KeepVersionCount' -Type Int -Default 2 | Should -Be 5
    Get-SettingValue -Source $global:GoodSettings -Name 'ThemeName' -Type String -Default 'Light' | Should -Be 'Dark'
    (Get-SettingValue -Source $global:GoodSettings -Name 'RecentLogins' -Type StringArray -Default @()).Count | Should -Be 2
  }

  It 'falls back for a missing key' {
    Get-SettingValue -Source $global:GoodSettings -Name 'DoesNotExist' -Type String -Default 'fallback' | Should -Be 'fallback'
  }

  It 'falls back for an unusable value instead of throwing' {
    { Get-SettingValue -Source $global:BrokenSettings -Name 'KeepVersionCount' -Type Int -Default 2 } | Should -Not -Throw
    Get-SettingValue -Source $global:BrokenSettings -Name 'KeepVersionCount' -Type Int -Default 2 | Should -Be 2
  }

  It 'does not let one bad value affect the next one' {
    $null = Get-SettingValue -Source $global:BrokenSettings -Name 'KeepVersionCount' -Type Int -Default 2
    Get-SettingValue -Source $global:BrokenSettings -Name 'ThemeName' -Type String -Default 'Light' | Should -Be 'Dark'
  }

  It 'enforces the minimum' {
    $tooSmall = [pscustomobject]@{ KeepVersionCount = 0 }
    Get-SettingValue -Source $tooSmall -Name 'KeepVersionCount' -Type Int -Default 2 -Minimum 1 | Should -Be 2
  }
}
