BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '83-OwnPackage.ps1' `
    -Name 'Test-SetupFileInsideSource', 'Test-DestinationInsideSource')))

  function global:New-PathFixture {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('owntest_' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    $src = Join-Path $root 'source'
    $sub = Join-Path $src 'nested'
    $out = Join-Path $root 'out'
    foreach ($d in @($src, $sub, $out)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    $setup = Join-Path $src 'Setup.exe'
    Set-Content -LiteralPath $setup -Value 'x' -Encoding utf8
    $nestedSetup = Join-Path $sub 'Nested.exe'
    Set-Content -LiteralPath $nestedSetup -Value 'x' -Encoding utf8
    $outside = Join-Path $root 'Outside.exe'
    Set-Content -LiteralPath $outside -Value 'x' -Encoding utf8
    return [pscustomobject]@{
      Root = $root; Source = $src; Nested = $sub; Out = $out
      Setup = $setup; NestedSetup = $nestedSetup; Outside = $outside
    }
  }
}

Describe 'Test-SetupFileInsideSource' {
  BeforeEach { $script:fx = New-PathFixture }
  AfterEach { try { Remove-Item -LiteralPath $script:fx.Root -Recurse -Force -ErrorAction SilentlyContinue } catch { } }

  It 'accepts a setup file directly in the source folder' {
    Test-SetupFileInsideSource -SourcePath $script:fx.Source -SetupFile $script:fx.Setup | Should -BeTrue
  }

  It 'accepts a setup file in a subfolder of the source' {
    Test-SetupFileInsideSource -SourcePath $script:fx.Source -SetupFile $script:fx.NestedSetup | Should -BeTrue
  }

  It 'rejects a setup file outside the source folder' {
    Test-SetupFileInsideSource -SourcePath $script:fx.Source -SetupFile $script:fx.Outside | Should -BeFalse
  }

  # The comparison has to ignore case, because Windows paths do. A check that compared with the
  # .NET default would have passed for one spelling and failed for another.
  It 'ignores the spelling of the path' {
    Test-SetupFileInsideSource -SourcePath $script:fx.Source.ToUpper() -SetupFile $script:fx.Setup.ToLower() | Should -BeTrue
  }

  It 'rejects missing paths instead of guessing' {
    Test-SetupFileInsideSource -SourcePath $script:fx.Source -SetupFile (Join-Path $script:fx.Source 'gone.exe') | Should -BeFalse
    Test-SetupFileInsideSource -SourcePath '' -SetupFile $script:fx.Setup | Should -BeFalse
  }
}

Describe 'Test-DestinationInsideSource' {
  BeforeEach { $script:fx = New-PathFixture }
  AfterEach { try { Remove-Item -LiteralPath $script:fx.Root -Recurse -Force -ErrorAction SilentlyContinue } catch { } }

  # Regression: packaging a TeamViewer installer with source and destination both set to
  # Downloads\test returned in 0.0s and produced nothing. The packager compresses the whole source
  # folder and declines to write its output inside it, but it says so only as a WARNING, which slips
  # past -ErrorAction Stop. The run then failed with "produced no .intunewin file", naming the
  # symptom rather than the cause.
  It 'flags the destination being the source folder itself' {
    Test-DestinationInsideSource -SourcePath $script:fx.Source -DestinationPath $script:fx.Source | Should -BeTrue
  }

  It 'flags a destination inside the source folder' {
    Test-DestinationInsideSource -SourcePath $script:fx.Source -DestinationPath $script:fx.Nested | Should -BeTrue
  }

  It 'allows a destination beside the source folder' {
    Test-DestinationInsideSource -SourcePath $script:fx.Source -DestinationPath $script:fx.Out | Should -BeFalse
  }

  It 'ignores the spelling of the path' {
    Test-DestinationInsideSource -SourcePath $script:fx.Source -DestinationPath $script:fx.Source.ToUpper() | Should -BeTrue
  }

  # A destination that does not exist yet is created by the caller, so it must be judged on its
  # path alone rather than dismissed as "not found".
  It 'judges a destination that does not exist yet by its path' {
    $missingInside = Join-Path $script:fx.Source 'not-created-yet'
    $missingOutside = Join-Path $script:fx.Root 'elsewhere'
    Test-DestinationInsideSource -SourcePath $script:fx.Source -DestinationPath $missingInside | Should -BeTrue
    Test-DestinationInsideSource -SourcePath $script:fx.Source -DestinationPath $missingOutside | Should -BeFalse
  }

  # "sourceX" starts with "source" as a string but is a sibling, not a child. Comparing without the
  # separator would wrongly reject it.
  It 'does not confuse a sibling whose name merely starts the same' {
    $sibling = $script:fx.Source + 'X'
    New-Item -ItemType Directory -Path $sibling -Force | Out-Null
    Test-DestinationInsideSource -SourcePath $script:fx.Source -DestinationPath $sibling | Should -BeFalse
  }
}
