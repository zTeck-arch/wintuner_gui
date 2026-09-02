# Vorab-Bau: das Paket der naechsten App entsteht, waehrend die aktuelle hochgeladen wird.
#
# Der teure Fehler ist hier nicht "es wird nichts gespart", sondern "es wird das FALSCHE Paket
# uebernommen": ein Vorab-Bau mit anderen Optionen faellt beim Bauen nicht auf, sondern erst auf den
# Endgeraeten. Deshalb pruefen diese Faelle vor allem den Schluessel und die Randbedingungen, unter
# denen ueberhaupt vorgebaut werden darf.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '35-Packaging.ps1' -Name @(
    'Get-WingetPackageArguments', 'Get-PackageBuildKey',
    'Stop-PackagePrebuild', 'Get-PrebuildResult'))))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '60-Batch.ps1' -Name @(
    'Get-BatchTargetKey', 'Test-ShouldPrebuildNext'))))
}

Describe 'Get-WingetPackageArguments' {

  It 'nennt ohne erweiterte Optionen nur das Noetigste' {
    $a = Get-WingetPackageArguments -PackageId 'Google.Chrome' -PackageFolder 'C:\pkg'
    @($a.Keys | Sort-Object) | Should -Be @('ErrorAction', 'PackageFolder', 'PackageId')
  }

  It 'nimmt eine gesetzte Option auf und laesst eine leere weg' {
    $a = Get-WingetPackageArguments -PackageId 'X.Y' -PackageFolder 'C:\pkg' -Architecture 'x64' -Locale ''
    $a.Architecture | Should -Be 'x64'
    $a.ContainsKey('Locale') | Should -BeFalse
  }

  # Das Modul schreibt den Parameter mit einem 'r'. Steht der Tippfehler an zwei Stellen, baut der
  # Vorab-Bau irgendwann mit einem anderen Installertyp als der Hauptlauf.
  It 'uebersetzt PreferredInstaller in die Schreibweise des Moduls' {
    $a = Get-WingetPackageArguments -PackageId 'X.Y' -PackageFolder 'C:\pkg' -PreferredInstaller 'Msi'
    $a.PreferedInstaller | Should -Be 'Msi'
    $a.ContainsKey('PreferredInstaller') | Should -BeFalse
  }

  It 'setzt PackageScript nur, wenn der Schalter gesetzt ist' {
    (Get-WingetPackageArguments -PackageId 'X.Y' -PackageFolder 'C:\p').ContainsKey('PackageScript') | Should -BeFalse
    (Get-WingetPackageArguments -PackageId 'X.Y' -PackageFolder 'C:\p' -PackageScript).PackageScript | Should -BeTrue
  }
}

Describe 'Get-PackageBuildKey' {

  It 'ist unabhaengig davon, in welcher Reihenfolge die Argumente entstanden sind' {
    $a = @{ PackageId = 'X.Y'; Version = '1.0'; PackageFolder = 'C:\p' }
    $b = @{ PackageFolder = 'C:\p'; PackageId = 'X.Y'; Version = '1.0' }
    Get-PackageBuildKey -Arguments $a | Should -Be (Get-PackageBuildKey -Arguments $b)
  }

  # ErrorAction steuert nur, wie ein Fehler gemeldet wird - am erzeugten Paket aendert es nichts.
  # Stuende es im Schluessel, wuerde ein Vorab-Bau nie uebernommen, weil eine Seite 'Stop' und die
  # andere 'SilentlyContinue' fuehrt.
  It 'laesst ErrorAction ausser Acht' {
    $mit  = @{ PackageId = 'X.Y'; Version = '1.0'; ErrorAction = 'Stop' }
    $ohne = @{ PackageId = 'X.Y'; Version = '1.0' }
    Get-PackageBuildKey -Arguments $mit | Should -Be (Get-PackageBuildKey -Arguments $ohne)
  }

  It 'unterscheidet zwei Baeufe derselben Version mit anderer Architektur' {
    $x64 = @{ PackageId = 'X.Y'; Version = '1.0'; Architecture = 'x64' }
    $x86 = @{ PackageId = 'X.Y'; Version = '1.0'; Architecture = 'x86' }
    Get-PackageBuildKey -Arguments $x64 | Should -Not -Be (Get-PackageBuildKey -Arguments $x86)
  }

  It 'unterscheidet zwei Versionen desselben Pakets' {
    $a = @{ PackageId = 'X.Y'; Version = '1.0' }
    $b = @{ PackageId = 'X.Y'; Version = '1.1' }
    Get-PackageBuildKey -Arguments $a | Should -Not -Be (Get-PackageBuildKey -Arguments $b)
  }

  # Der Fall, um den es eigentlich geht: eine Option, die NUR eine Seite kennt, muss den Schluessel
  # verschieben. Sonst uebernimmt der Hauptlauf ein Paket ohne diese Option.
  It 'unterscheidet einen Satz MIT von einem Satz OHNE Zusatzoption' {
    $ohne = Get-WingetPackageArguments -PackageId 'X.Y' -PackageFolder 'C:\p'
    $mit  = Get-WingetPackageArguments -PackageId 'X.Y' -PackageFolder 'C:\p' -InstallerArguments '/quiet'
    Get-PackageBuildKey -Arguments $ohne | Should -Not -Be (Get-PackageBuildKey -Arguments $mit)
  }

  # Der Kern der Sache: Stapellauf und Hauptlauf bilden den Satz ueber DIESELBE Funktion, also
  # stimmen die Schluessel ueberein - und nur dann darf uebernommen werden.
  It 'stimmt zwischen Vorab-Bau und Hauptlauf ueberein, wenn die Eingaben gleich sind' {
    $vorab = (Get-WingetPackageArguments -PackageId 'Google.Chrome' -PackageFolder 'C:\pkg') + @{ Version = '152.0' }
    $haupt = (Get-WingetPackageArguments -PackageId 'Google.Chrome' -PackageFolder 'C:\pkg') + @{ Version = '152.0' }
    Get-PackageBuildKey -Arguments $vorab | Should -Be (Get-PackageBuildKey -Arguments $haupt)
  }
}

Describe 'Get-BatchTargetKey' {

  It 'macht aus Paket-Id und Version einen Schluessel' {
    Get-BatchTargetKey -PackageId 'Google.Chrome' -Version '152.0' | Should -Be 'google.chrome|152.0'
  }

  It 'ignoriert Gross-/Kleinschreibung und Leerraum' {
    Get-BatchTargetKey -PackageId '  Google.CHROME ' -Version '152.0' |
      Should -Be (Get-BatchTargetKey -PackageId 'google.chrome' -Version '152.0')
  }
}

Describe 'Test-ShouldPrebuildNext' {

  It 'baut fuer eine gewoehnliche naechste App vor' {
    Test-ShouldPrebuildNext -PackageId 'Mozilla.Firefox' -Version '141.0' -ExistingTargetGraphId '' `
      -CurrentTargetKey 'google.chrome|152.0' -KnownTargets @{} -UnresolvedKeys @() | Should -BeTrue
  }

  # Ein Eintrag, der ein vorhandenes Ziel wiederverwendet, baut ueberhaupt kein Paket - und wuerde
  # den einen Platz belegen, den die naechste wirklich bauende App braucht.
  It 'baut NICHT vor, wenn der Eintrag ein vorhandenes Ziel wiederverwendet' {
    Test-ShouldPrebuildNext -PackageId 'Mozilla.Firefox' -Version '141.0' `
      -ExistingTargetGraphId '11111111-1111-1111-1111-111111111111' `
      -CurrentTargetKey 'google.chrome|152.0' -KnownTargets @{} -UnresolvedKeys @() | Should -BeFalse
  }

  # Der zweite Vorgaenger derselben App: er faehrt in dasselbe Ziel. Wer hier vorbaut, riskiert ein
  # zweites App-Objekt fuer dieselbe Paketversion.
  It 'baut NICHT vor, wenn der naechste Eintrag denselben Zielschluessel traegt' {
    Test-ShouldPrebuildNext -PackageId 'Google.Chrome' -Version '152.0' -ExistingTargetGraphId '' `
      -CurrentTargetKey 'google.chrome|152.0' -KnownTargets @{} -UnresolvedKeys @() | Should -BeFalse
  }

  It 'baut NICHT vor, wenn das Ziel im Lauf schon erzeugt wurde' {
    $known = @{ 'mozilla.firefox|141.0' = [pscustomobject]@{ Id = 'abc'; Version = '141.0' } }
    Test-ShouldPrebuildNext -PackageId 'Mozilla.Firefox' -Version '141.0' -ExistingTargetGraphId '' `
      -CurrentTargetKey 'google.chrome|152.0' -KnownTargets $known -UnresolvedKeys @() | Should -BeFalse
  }

  It 'baut NICHT vor, wenn der Zielschluessel als unaufloesbar gilt' {
    Test-ShouldPrebuildNext -PackageId 'Mozilla.Firefox' -Version '141.0' -ExistingTargetGraphId '' `
      -CurrentTargetKey 'google.chrome|152.0' -KnownTargets @{} `
      -UnresolvedKeys @('mozilla.firefox|141.0') | Should -BeFalse
  }

  It 'baut NICHT vor, wenn Paket-Id oder Version fehlen' {
    Test-ShouldPrebuildNext -PackageId '' -Version '141.0' -ExistingTargetGraphId '' `
      -CurrentTargetKey 'x|1' -KnownTargets @{} -UnresolvedKeys @() | Should -BeFalse
    Test-ShouldPrebuildNext -PackageId 'Mozilla.Firefox' -Version '' -ExistingTargetGraphId '' `
      -CurrentTargetKey 'x|1' -KnownTargets @{} -UnresolvedKeys @() | Should -BeFalse
  }
}

Describe 'Get-PrebuildResult' {

  BeforeEach {
    $script:prebuild = $null
    $script:pendingPrebuild = $null
    $global:TestLog.Clear()
  }

  It 'uebernimmt nichts, wenn gar kein Vorab-Bau laeuft' {
    Get-PrebuildResult -Arguments @{ PackageId = 'X.Y'; Version = '1.0' } -Label 'X' | Should -BeNullOrEmpty
  }

  # Der wichtigste Fall: passt der Schluessel nicht, wird NICHTS uebernommen - und der Vorab-Bau
  # wird verworfen statt irgendwie verwertet. Ein "fast passendes" Paket gibt es nicht.
  It 'verwirft einen Vorab-Bau mit anderem Schluessel und uebernimmt ihn nicht' {
    $script:prebuild = @{
      Key   = (Get-PackageBuildKey -Arguments @{ PackageId = 'Mozilla.Firefox'; Version = '141.0' })
      Label = 'Firefox'
      Shell = [pscustomobject]@{}      # wird nur in try/catch angefasst
    }
    $r = Get-PrebuildResult -Arguments @{ PackageId = 'Google.Chrome'; Version = '152.0' } -Label 'Chrome'
    $r | Should -BeNullOrEmpty
    $script:prebuild | Should -BeNullOrEmpty
    @($global:TestLog | Where-Object { $_ -like '*does not match what Chrome needs*' }).Count | Should -Be 1
  }
}

Describe 'Verdrahtung im Quelltext' {

  # Zwei Fassungen des Argumentsatzes waeren genau der Fehler, den der Schluessel verhindern soll.
  It 'bildet den Argumentsatz nur an EINER Stelle' {
    $fn = Get-SourceFunctionText -Part '35-Packaging.ps1' -Name 'New-WingetPackageWithFallback'
    $fn | Should -Match 'Get-WingetPackageArguments'
    $fn | Should -Not -Match "PackageId = \`$PackageId; PackageFolder"
  }

  # Die Uebernahme muss im gemeinsamen Trichter sitzen, nicht in einem der Aufrufer: sonst umgeht
  # ein Weg sie und baut ein zweites Mal.
  It 'uebernimmt den Vorab-Bau im gemeinsamen Trichter' {
    $fn = Get-SourceFunctionText -Part '35-Packaging.ps1' -Name 'Invoke-WtPackageBuild'
    $fn | Should -Match 'Get-PrebuildResult'
  }

  It 'stoesst den Vorab-Bau erst zum Upload an, nicht schon beim Paketieren' {
    $fn = Get-SourceFunctionText -Part '50-UpdateEngine.ps1' -Name 'Update-SingleApp'
    $fn | Should -Match 'Start-PendingPackagePrebuild'
    # Vor dem Upload, nach dem Paketbau: die Reihenfolge im Text belegt die Stelle.
    $idxPrebuild = $fn.IndexOf('Start-PendingPackagePrebuild')
    $idxDeploy   = $fn.IndexOf('Deploy-WtWin32App')
    $idxPackage  = $fn.IndexOf('New-WingetPackageWithFallback')
    $idxPrebuild | Should -BeGreaterThan $idxPackage
    $idxPrebuild | Should -BeLessThan $idxDeploy
  }

  # Ein Vorab-Bau, den niemand abholt, belegt sonst bis zum Programmende den Runspace.
  It 'raeumt den Vorab-Bau bei Abbruch und am Ende des Laufs ab' {
    (Get-SourceFunctionText -Part '75-UiState.ps1' -Name 'Request-RunCancel') | Should -Match 'Stop-PackagePrebuild'
    (Get-SourceFunctionText -Part '60-Batch.ps1' -Name 'Invoke-AppUpdateBatch') | Should -Match 'Stop-PackagePrebuild'
    (Get-SourcePartText -Part '90-Main.ps1') | Should -Match 'Close-PrebuildRunspace'
  }

  # Zwei Aufrufer, zwei Runspaces - geteilt fuehrt ein Runspace genau eine Pipeline, und das
  # Nebeneinander waere dahin.
  It 'haelt fuer Hauptbau und Vorab-Bau je einen eigenen Runspace' {
    $part = Get-SourcePartText -Part '35-Packaging.ps1'
    $part | Should -Match '\$script:prebuildRunspace = New-PackagingRunspace'
    $part | Should -Match '\$script:pkgRunspace = New-PackagingRunspace'
  }
}
