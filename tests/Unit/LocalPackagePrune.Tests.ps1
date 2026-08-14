BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '20-Version.ps1' -Name 'Get-ComparableVersionParts')))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '25-WinGetData.ps1' `
    -Name 'Get-VersionSortKey', 'Get-LocalPackagePrunePlan', 'Get-FolderSizeBytes', 'Format-ByteSize', 'Invoke-LocalPackagePrune')))

  # Builds <root>\<package>\<version>\ trees with a file inside, so sizes are measurable and the
  # deletion path is exercised against real folders rather than mocks.
  function global:New-PackageTree {
    param([hashtable]$Packages)
    $root = Join-Path ([IO.Path]::GetTempPath()) ("wtprune_" + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $root -Force
    foreach ($pkg in $Packages.Keys) {
      foreach ($version in $Packages[$pkg]) {
        $dir = Join-Path (Join-Path $root $pkg) $version
        $null = New-Item -ItemType Directory -Path $dir -Force
        Set-Content -Path (Join-Path $dir 'payload.txt') -Value ('x' * 100) -NoNewline
      }
    }
    return $root
  }
}

Describe 'Get-LocalPackagePrunePlan' {
  AfterEach {
    if ($script:tempRoot -and (Test-Path -LiteralPath $script:tempRoot)) {
      Remove-Item -LiteralPath $script:tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'keeps the newest N and plans the rest for deletion' {
    $script:tempRoot = New-PackageTree -Packages @{ 'Google.Chrome' = @('150.0.1', '151.0.2', '151.0.10', '149.0.9') }
    $plan = @(Get-LocalPackagePrunePlan -RootPackageFolder $script:tempRoot -KeepCount 2)
    $plan.Count | Should -Be 2
    @($plan.Version) | Should -Contain '150.0.1'
    @($plan.Version) | Should -Contain '149.0.9'
    @($plan.Version) | Should -Not -Contain '151.0.10'
  }

  # Numeric, not lexical: as text "151.0.9" sorts above "151.0.10", which would delete the newer one.
  It 'orders version components numerically' {
    $script:tempRoot = New-PackageTree -Packages @{ 'App' = @('1.0.9', '1.0.10', '1.0.2') }
    $plan = @(Get-LocalPackagePrunePlan -RootPackageFolder $script:tempRoot -KeepCount 1)
    @($plan.Version) | Should -Not -Contain '1.0.10'
    $plan.Count | Should -Be 2
  }

  It 'leaves a package alone when it does not exceed the limit' {
    $script:tempRoot = New-PackageTree -Packages @{ 'App' = @('1.0', '2.0') }
    @(Get-LocalPackagePrunePlan -RootPackageFolder $script:tempRoot -KeepCount 2).Count | Should -Be 0
  }

  It 'treats each package separately' {
    $script:tempRoot = New-PackageTree -Packages @{ 'A' = @('1.0', '2.0', '3.0'); 'B' = @('1.0') }
    $plan = @(Get-LocalPackagePrunePlan -RootPackageFolder $script:tempRoot -KeepCount 2)
    $plan.Count | Should -Be 1
    $plan[0].PackageId | Should -Be 'A'
    $plan[0].Version | Should -Be '1.0'
  }

  # A folder whose name is not a version is not build output we understand, so it is never a
  # deletion candidate - the plan simply ignores it.
  It 'never plans a folder that is not a version' {
    $script:tempRoot = New-PackageTree -Packages @{ 'App' = @('1.0', '2.0', '3.0', 'notes', 'backup-old') }
    $plan = @(Get-LocalPackagePrunePlan -RootPackageFolder $script:tempRoot -KeepCount 1)
    @($plan.Version) | Should -Not -Contain 'notes'
    @($plan.Version) | Should -Not -Contain 'backup-old'
    $plan.Count | Should -Be 2
  }

  It 'returns nothing for a folder that does not exist' {
    @(Get-LocalPackagePrunePlan -RootPackageFolder 'C:\does\not\exist\at\all' -KeepCount 2).Count | Should -Be 0
  }

  # Keeping zero versions would delete the package that was just built, so it is refused outright.
  It 'refuses a keep count below one' {
    $script:tempRoot = New-PackageTree -Packages @{ 'App' = @('1.0', '2.0', '3.0') }
    @(Get-LocalPackagePrunePlan -RootPackageFolder $script:tempRoot -KeepCount 0).Count | Should -Be 0
  }
}

Describe 'Invoke-LocalPackagePrune' {
  AfterEach {
    if ($script:tempRoot -and (Test-Path -LiteralPath $script:tempRoot)) {
      Remove-Item -LiteralPath $script:tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'deletes exactly the planned folders and leaves the kept ones' {
    $script:tempRoot = New-PackageTree -Packages @{ 'App' = @('1.0', '2.0', '3.0') }
    $plan = @(Get-LocalPackagePrunePlan -RootPackageFolder $script:tempRoot -KeepCount 1)
    $result = Invoke-LocalPackagePrune -Plan $plan
    $result.Removed | Should -Be 2
    $result.Failed | Should -Be 0
    $result.FreedBytes | Should -BeGreaterThan 0
    Test-Path -LiteralPath (Join-Path (Join-Path $script:tempRoot 'App') '3.0') | Should -BeTrue
    Test-Path -LiteralPath (Join-Path (Join-Path $script:tempRoot 'App') '1.0') | Should -BeFalse
  }

  It 'does nothing on an empty plan' {
    $result = Invoke-LocalPackagePrune -Plan @()
    $result.Removed | Should -Be 0
    $result.Failed | Should -Be 0
  }
}

Describe 'Format-ByteSize' {
  It 'scales the unit to the value' {
    Format-ByteSize -Bytes 512 | Should -Be '512 B'
    Format-ByteSize -Bytes 2048 | Should -Match 'KB'
    Format-ByteSize -Bytes (5 * 1MB) | Should -Match 'MB'
    Format-ByteSize -Bytes (3 * 1GB) | Should -Match 'GB'
  }
}
