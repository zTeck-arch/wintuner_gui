BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '35-Packaging.ps1' `
    -Name 'Test-IsProtectedSystemFolder', 'Test-PackageFolderUsable')))
  function global:Get-UiString { param($k) $k }
  # Keep the low-disk-space branch from ever popping a modal dialog during the test run.
  function global:Get-PSDrive { param($Name, $ErrorAction) [pscustomobject]@{ Free = 500GB } }
}

Describe 'Test-IsProtectedSystemFolder' {
  It 'rejects the protected folder itself' {
    Test-IsProtectedSystemFolder -Folder $env:ProgramFiles | Should -BeTrue
    Test-IsProtectedSystemFolder -Folder "$env:SystemRoot\System32" | Should -BeTrue
  }

  It 'rejects a subfolder of a protected folder' {
    Test-IsProtectedSystemFolder -Folder "$env:ProgramFiles\WinTunerPakete" | Should -BeTrue
  }

  # Regression: the guard mixed two comparison semantics in one line. PowerShell's -eq ignores case,
  # but .NET's String.StartsWith(String) does not, so a lower-case spelling of the same path walked
  # straight through a guard that the canonical spelling tripped.
  It 'rejects a protected path regardless of spelling' {
    Test-IsProtectedSystemFolder -Folder ($env:ProgramFiles.ToLower() + '\pakete') | Should -BeTrue
    Test-IsProtectedSystemFolder -Folder ($env:ProgramFiles.ToUpper() + '\PAKETE') | Should -BeTrue
    Test-IsProtectedSystemFolder -Folder ($env:SystemRoot.ToLower() + '\system32\x') | Should -BeTrue
  }

  It 'ignores a trailing backslash' {
    Test-IsProtectedSystemFolder -Folder ($env:ProgramFiles + '\') | Should -BeTrue
  }

  It 'allows ordinary folders' {
    Test-IsProtectedSystemFolder -Folder 'C:\Intune\Paketierung' | Should -BeFalse
    Test-IsProtectedSystemFolder -Folder (Join-Path $env:LOCALAPPDATA 'WinTunerGUI\Packages') | Should -BeFalse
  }

  # "C:\Program FilesX" merely starts with the same letters - it is a different folder and must not
  # be blocked. That is why the check appends a separator instead of comparing prefixes.
  It 'does not block a folder that only shares the name prefix' {
    Test-IsProtectedSystemFolder -Folder ($env:ProgramFiles + 'Data') | Should -BeFalse
  }

  It 'treats empty input as harmless rather than throwing' {
    Test-IsProtectedSystemFolder -Folder '   ' | Should -BeFalse
  }
}

Describe 'Test-PackageFolderUsable' {
  # Audit finding #11: a package folder whose name contains '[' or ']' made the -Path write probe
  # fail, and a writable folder was reported to the user as "not writable".
  It 'accepts a writable folder whose name contains brackets and spaces' {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ("Intune Pakete [Kunde] " + [guid]::NewGuid().ToString('N'))
    try {
      Test-PackageFolderUsable -Folder $dir | Should -BeTrue
      # The probe file must be cleaned up, not left behind.
      @(Get-ChildItem -LiteralPath $dir -Filter '.wtgui_write_test_*' -Force).Count | Should -Be 0
    } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
  }

  It 'creates the folder when it does not exist yet (bracket path)' {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ("Kunde [X] " + [guid]::NewGuid().ToString('N'))
    try {
      Test-PackageFolderUsable -Folder $dir | Should -BeTrue
      Test-Path -LiteralPath $dir | Should -BeTrue
    } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
  }
}
