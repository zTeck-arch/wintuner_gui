BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '83-OwnPackage.ps1' `
    -Name 'Get-MsiInstallCommand', 'Get-MsiUninstallCommand')))
}

Describe 'MSI commands handed to Intune' {
  # The command runs on the device with the package contents as its working directory, so only the
  # file name belongs in it. A full path from the packaging machine would never resolve there.
  It 'uses only the file name, not the path from this machine' {
    $cmd = Get-MsiInstallCommand -MsiPath 'C:\Users\someone\Downloads\Acme Installer\Acme.msi'
    $cmd | Should -Match 'Acme\.msi'
    $cmd | Should -Not -Match 'Downloads'
  }

  # Paths with spaces are the normal case, not the exception.
  It 'quotes the file name' {
    Get-MsiInstallCommand -MsiPath 'C:\x\My App.msi' | Should -Match '"My App\.msi"'
  }

  It 'installs silently' {
    Get-MsiInstallCommand -MsiPath 'C:\x\a.msi' | Should -Match '/qn'
  }

  # Intune decides about restarts through the assignment. An installer that reboots on its own
  # would take the device down while Intune still believes the install is running.
  It 'suppresses a self-initiated restart' {
    $cmd = Get-MsiInstallCommand -MsiPath 'C:\x\a.msi'
    $cmd | Should -Match '/norestart'
    $cmd | Should -Match 'REBOOT=ReallySuppress'
  }

  # Uninstall goes by product code, never by file: the .msi is not on the device at removal time.
  It 'uninstalls by product code' {
    $cmd = Get-MsiUninstallCommand -ProductCode '{12345678-1234-1234-1234-123456789012}'
    $cmd | Should -Match '/x \{12345678-1234-1234-1234-123456789012\}'
    $cmd | Should -Match '/qn'
    $cmd | Should -Not -Match '\.msi'
  }
}
