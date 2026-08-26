# Audit findings #18/#19: an empty DefaultPackagePath let the Settings card fall back to C:\Temp -
# a folder writable by every signed-in user, exactly the location the migration was meant to remove.
# Resolve-PackagePathSetting is the single authority that maps a stored value to the effective one.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '10-Settings.ps1' `
    -Name 'Get-DefaultPackagePath', 'Resolve-PackagePathSetting')))
  $script:legacyPackagePath = 'C:\Temp'
  $global:SafePath = Get-DefaultPackagePath
}

Describe 'Resolve-PackagePathSetting' {
  It 'maps an empty value to the safe per-user path (not C:\Temp)' {
    $r = Resolve-PackagePathSetting -Saved ''
    $r.Path | Should -Be $global:SafePath
    $r.Path | Should -Not -Be 'C:\Temp'
    $r.Migrated | Should -BeFalse
  }
  It 'maps whitespace to the safe path' {
    (Resolve-PackagePathSetting -Saved '   ').Path | Should -Be $global:SafePath
  }
  It 'migrates the legacy C:\Temp default and flags the move' {
    $r = Resolve-PackagePathSetting -Saved 'C:\Temp'
    $r.Path | Should -Be $global:SafePath
    $r.Migrated | Should -BeTrue
  }
  It 'migrates C:\Temp with a trailing backslash too' {
    (Resolve-PackagePathSetting -Saved 'C:\Temp\').Migrated | Should -BeTrue
  }
  It 'keeps a deliberate custom path unchanged' {
    $r = Resolve-PackagePathSetting -Saved 'D:\Intune\Pakete'
    $r.Path | Should -Be 'D:\Intune\Pakete'
    $r.Migrated | Should -BeFalse
  }
}
