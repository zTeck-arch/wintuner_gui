BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '20-Version.ps1' `
    -Name 'Test-IsNewerVersion', 'Get-ComparableVersionParts')))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '35-Packaging.ps1' `
    -Name 'Get-WingetPackageArguments', 'Get-PackageFallbackVersion',
          'Invoke-PackageFallbackBuild', 'New-WingetPackageWithFallback')))

  # Die zwei Nahtstellen nach draussen: die Versionsliste (Netz/Cache) und der eigentliche Bau
  # (das fremde Modul). Beide als Attrappe, damit die ENTSCHEIDUNG geprueft wird und nicht WinGet.
  function global:Get-PreviousWingetVersion {
    param([string]$PackageId, [string]$LatestVersion)
    return $global:FakePreviousVersion
  }
  function global:Invoke-PackageBuildWithThrottleRetry {
    param($Arguments, [string]$Label, [int]$MaxRetries)
    $global:BuiltVersions.Add([string]$Arguments.Version)
    $fail = $global:FailBuildFor
    if ($fail -and $fail.ContainsKey([string]$Arguments.Version)) { throw $fail[[string]$Arguments.Version] }
    return [pscustomobject]@{ }
  }
}

Describe 'Get-PackageFallbackVersion' {
  BeforeEach {
    $global:BuiltVersions = [System.Collections.Generic.List[string]]::new()
    $global:FakePreviousVersion = $null
    $global:FailBuildFor = @{}
    $global:TestLog.Clear()
  }

  It 'nimmt die naechstaeltere angebotene Version' {
    $global:FakePreviousVersion = '152.0.7977.55'
    Get-PackageFallbackVersion -PackageId 'Google.Chrome' -LatestVersion '152.0.7977.65' `
      -InstalledVersion '151.0.7900.10' | Should -Be '152.0.7977.55'
  }

  # Der Kern der Regel: ein Rueckfall auf das, was ohnehin im Tenant liegt, ist kein Notnagel,
  # sondern ein Paket, das niemand braucht - und beim naechsten Lauf noch einmal.
  It 'faellt NICHT auf die bereits ausgerollte Version zurueck' {
    $global:FakePreviousVersion = '152.0.7977.55'
    Get-PackageFallbackVersion -PackageId 'Google.Chrome' -LatestVersion '152.0.7977.65' `
      -InstalledVersion '152.0.7977.55' | Should -BeNullOrEmpty
  }

  It 'faellt NICHT auf eine aeltere als die ausgerollte Version zurueck' {
    $global:FakePreviousVersion = '151.0.7900.10'
    Get-PackageFallbackVersion -PackageId 'Google.Chrome' -LatestVersion '152.0.7977.65' `
      -InstalledVersion '152.0.7977.55' | Should -BeNullOrEmpty
  }

  It 'greift auch ohne bekannte Tenant-Version, weil dann nichts verschlechtert werden kann' {
    $global:FakePreviousVersion = '152.0.7977.55'
    Get-PackageFallbackVersion -PackageId 'Google.Chrome' -LatestVersion '152.0.7977.65' `
      -InstalledVersion '' | Should -Be '152.0.7977.55'
  }

  It 'ergibt nichts, wenn WinGet keine aeltere Version anbietet' {
    $global:FakePreviousVersion = $null
    Get-PackageFallbackVersion -PackageId 'Google.Chrome' -LatestVersion '152.0.7977.65' `
      -InstalledVersion '151.0.7900.10' | Should -BeNullOrEmpty
  }
}

Describe 'New-WingetPackageWithFallback bei einer Hash-Abweichung' {
  BeforeEach {
    $global:BuiltVersions = [System.Collections.Generic.List[string]]::new()
    $global:FakePreviousVersion = $null
    $global:FailBuildFor = @{}
    $global:TestLog.Clear()
  }

  # Regression aus dem echten Protokoll vom 02.09.2026: "Hash mismatch for
  # googlechromestandaloneenterprise64.msi" liess den Stapellauf die App ueberspringen. Der
  # Stapellauf reicht -AllowUserRetry nicht durch, also gab es keine Rueckfrage und keinen
  # Rueckfall - Chrome blieb auf dem alten Stand, bis jemand das Protokoll las.
  Context 'ohne Rueckfrage (Stapellauf)' {
    BeforeEach {
      $global:FailBuildFor = @{ '152.0.7977.65' = 'Hash mismatch for https://dl.google.com/x.msi. Expected F3B1 but got B622' }
      $global:FakePreviousVersion = '152.0.7977.55'
    }

    It 'baut die zuletzt angebotene Version statt aufzugeben' {
      $res = New-WingetPackageWithFallback -PackageId 'Google.Chrome' -PackageFolder 'C:\pkg' `
        -DesiredVersion '152.0.7977.65' -LatestVersion '152.0.7977.65' -InstalledVersion '151.0.7900.10'
      $res.Succeeded | Should -BeTrue
      $res.EffectiveVersion | Should -Be '152.0.7977.55'
      $res.UsedFallbackVersion | Should -BeTrue
      @($global:BuiltVersions) | Should -Be @('152.0.7977.65', '152.0.7977.55')
    }

    It 'sagt im Protokoll, dass eine ANDERE als die angeforderte Version gebaut wurde' {
      $null = New-WingetPackageWithFallback -PackageId 'Google.Chrome' -PackageFolder 'C:\pkg' `
        -DesiredVersion '152.0.7977.65' -LatestVersion '152.0.7977.65' -InstalledVersion '151.0.7900.10'
      @($global:TestLog | Where-Object { $_ -like '*hash mismatch on the newest version*' }).Count | Should -Be 1
      @($global:TestLog | Where-Object { $_ -like '*building the previously offered 152.0.7977.55 instead*' }).Count | Should -Be 1
    }

    # Sonst baut jeder Lauf dasselbe Paket neu, das im Tenant schon liegt.
    It 'gibt auf, wenn die Ausweichversion bereits ausgerollt ist' {
      $res = New-WingetPackageWithFallback -PackageId 'Google.Chrome' -PackageFolder 'C:\pkg' `
        -DesiredVersion '152.0.7977.65' -LatestVersion '152.0.7977.65' -InstalledVersion '152.0.7977.55'
      $res.Succeeded | Should -BeFalse
      $res.ErrorMessage | Should -Match 'Hash mismatch'
      @($global:BuiltVersions) | Should -Be @('152.0.7977.65')
      @($global:TestLog | Where-Object { $_ -like '*no older offered version is left*' }).Count | Should -Be 1
    }

    It 'meldet den Fehler der Ausweichversion, wenn auch sie nicht baut' {
      $global:FailBuildFor['152.0.7977.55'] = 'Hash mismatch for the older installer too'
      $res = New-WingetPackageWithFallback -PackageId 'Google.Chrome' -PackageFolder 'C:\pkg' `
        -DesiredVersion '152.0.7977.65' -LatestVersion '152.0.7977.65' -InstalledVersion '151.0.7900.10'
      $res.Succeeded | Should -BeFalse
      $res.UsedFallbackVersion | Should -BeFalse
      @($global:TestLog | Where-Object { $_ -like '*failed to build as well*' }).Count | Should -Be 1
    }
  }

  It 'laesst einen Fehler, der weder 404 noch Hash-Abweichung ist, unveraendert scheitern' {
    $global:FailBuildFor = @{ '9.9' = 'The remote server returned an error: (500) Internal Server Error.' }
    $global:FakePreviousVersion = '9.8'
    $res = New-WingetPackageWithFallback -PackageId 'Some.App' -PackageFolder 'C:\pkg' `
      -DesiredVersion '9.9' -LatestVersion '9.9' -InstalledVersion '9.0'
    $res.Succeeded | Should -BeFalse
    $res.ErrorMessage | Should -Match '500'
    @($global:BuiltVersions) | Should -Be @('9.9')
  }

  It 'faellt bei einem verschwundenen Manifest (404) weiterhin zurueck' {
    $global:FailBuildFor = @{ '9.9' = 'Response status code does not indicate success: 404 (Not Found).' }
    $global:FakePreviousVersion = '9.8'
    $res = New-WingetPackageWithFallback -PackageId 'Some.App' -PackageFolder 'C:\pkg' `
      -DesiredVersion '9.9' -LatestVersion '9.9' -InstalledVersion '9.0'
    $res.Succeeded | Should -BeTrue
    $res.EffectiveVersion | Should -Be '9.8'
  }

  It 'meldet bei einem glatten Lauf keine Ausweichversion' {
    $res = New-WingetPackageWithFallback -PackageId 'Some.App' -PackageFolder 'C:\pkg' `
      -DesiredVersion '9.9' -LatestVersion '9.9' -InstalledVersion '9.0'
    $res.Succeeded | Should -BeTrue
    $res.EffectiveVersion | Should -Be '9.9'
    $res.UsedFallbackVersion | Should -BeFalse
  }
}
