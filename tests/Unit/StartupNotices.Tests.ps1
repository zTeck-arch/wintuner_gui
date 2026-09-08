#requires -Version 7
# Startmeldungen: ausblendbar, aber nicht blind.
#
# Zwei Dinge werden hier geprueft, und beide haben denselben Ursprung - den Fehlerbericht vom
# 03.09.2026, bei dem ein zu altes WinTuner-Modul erst beim Klick auffiel:
#
# 1. Was der Start ueberhaupt prueft. Gemessen am 07.09.2026 fehlten drei Befehle, die die
#    Anwendung bindet (Deploy-WtWin32ContentVersion, New-IntuneWinPackage, Show-MsiInfo), UND der
#    Fall "das Modul ist zweimal installiert". Letzteres ist der unangenehmere: PowerShell laedt das
#    ERSTE Modul im PSModulePath, nicht die hoechste Version - nachgemessen laedt derselbe Rechner
#    mit umgedrehter Pfadreihenfolge 1.3.2 statt 1.4.1. Wer das nicht weiss, sucht den Fehler in
#    der Version, die er installiert hat, statt in der, die laeuft.
#
# 2. Dass "Diese Meldung nicht mehr anzeigen" den INHALT ausblendet und nicht die Meldungsart. Ohne
#    den Fingerabdruck waere ein Haekchen von heute eine Blindheit fuer jede kuenftige
#    Modulinkompatibilitaet - also genau fuer den Fall, um dessentwillen die Meldung existiert.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '05-Config.ps1' -Name @(
    'Get-MissingOptionalCommands', 'Get-ModuleVersionConflict'))))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '10-Settings.ps1' -Name 'Test-StartupNoticeSuppressed')))

  function New-ModuleInfo {
    param([string]$Version, [string]$Base)
    [pscustomobject]@{ Version = [version]$Version; ModuleBase = $Base }
  }
}

Describe 'Get-MissingOptionalCommands' {
  It 'nennt genau die fehlenden Befehle' {
    $required = @(
      @{ Command = 'Deploy-WtWin32ContentVersion'; Feature = 'A' },
      @{ Command = 'New-IntuneWinPackage'; Feature = 'B' }
    )
    $missing = @(Get-MissingOptionalCommands -Required $required -CommandLookup {
      param($name) if ($name -eq 'New-IntuneWinPackage') { return [pscustomobject]@{ Name = $name } }
      return $null
    })
    $missing.Count | Should -Be 1
    $missing[0] | Should -Be 'Deploy-WtWin32ContentVersion'
  }

  It 'meldet nichts, wenn alle da sind' {
    $missing = @(Get-MissingOptionalCommands -Required @(@{ Command = 'X'; Feature = 'A' }) -CommandLookup {
      param($name) [pscustomobject]@{ Name = $name }
    })
    $missing.Count | Should -Be 0
  }

  It 'behandelt einen werfenden Get-Command-Aufruf als "fehlt"' {
    # Fail-safe in die harmlose Richtung: eine Warnung zu viel kostet einen Klick, eine zu wenig
    # kostet einen gescheiterten Klick mitten in der Arbeit.
    $missing = @(Get-MissingOptionalCommands -Required @(@{ Command = 'X'; Feature = 'A' }) -CommandLookup {
      param($name) throw 'kaputt'
    })
    $missing.Count | Should -Be 1
  }

  It 'vertraegt eine leere Liste' {
    @(Get-MissingOptionalCommands -Required @() -CommandLookup { param($name) $null }).Count | Should -Be 0
    @(Get-MissingOptionalCommands -Required $null -CommandLookup { param($name) $null }).Count | Should -Be 0
  }
}

Describe 'Get-ModuleVersionConflict' {
  It 'meldet keinen Konflikt bei einer einzigen Installation' {
    $r = Get-ModuleVersionConflict -Available @((New-ModuleInfo '1.4.1' 'C:\A')) -Loaded (New-ModuleInfo '1.4.1' 'C:\A')
    $r.HasConflict | Should -BeFalse
    $r.LoadedIsOlder | Should -BeFalse
  }

  It 'meldet den Konflikt UND dass die aeltere laeuft' {
    # Der gemessene Fall auf dem Entwicklungsrechner: 1.4.1 im Benutzerprofil, 1.3.2 unter
    # C:\Program Files\WindowsPowerShell\Modules. Welche laeuft, entscheidet der PSModulePath.
    $r = Get-ModuleVersionConflict `
      -Available @((New-ModuleInfo '1.4.1' 'C:\Users\x\Documents\PowerShell\Modules\WinTuner\1.4.1'),
                   (New-ModuleInfo '1.3.2' 'C:\Program Files\WindowsPowerShell\Modules\WinTuner\1.3.2')) `
      -Loaded (New-ModuleInfo '1.3.2' 'C:\Program Files\WindowsPowerShell\Modules\WinTuner\1.3.2')
    $r.HasConflict | Should -BeTrue
    $r.Count | Should -Be 2
    $r.LoadedVersion | Should -Be '1.3.2'
    $r.HighestVersion | Should -Be '1.4.1'
    $r.LoadedIsOlder | Should -BeTrue
    # Die Fundorte gehoeren in die Meldung: ohne sie weiss niemand, welche Kopie er entfernen soll.
    @($r.Locations).Count | Should -Be 2
    $r.Locations[0] | Should -Match 'Program Files|Documents'
  }

  It 'meldet zwei Installationen, von denen die NEUERE laeuft, nicht als "aeltere laeuft"' {
    # Unordentlich, aber kein Grund fuer einen Dialog beim Start - nur fuer eine Protokollzeile.
    $r = Get-ModuleVersionConflict `
      -Available @((New-ModuleInfo '1.4.1' 'C:\A'), (New-ModuleInfo '1.3.2' 'C:\B')) `
      -Loaded (New-ModuleInfo '1.4.1' 'C:\A')
    $r.HasConflict | Should -BeTrue
    $r.LoadedIsOlder | Should -BeFalse
  }

  It 'vertraegt ein nicht geladenes Modul' {
    $r = Get-ModuleVersionConflict -Available @((New-ModuleInfo '1.4.1' 'C:\A')) -Loaded $null
    $r.LoadedVersion | Should -Be ''
    $r.LoadedIsOlder | Should -BeFalse
  }

  It 'vertraegt eine leere Liste' {
    $r = Get-ModuleVersionConflict -Available @() -Loaded $null
    $r.Count | Should -Be 0
    $r.HasConflict | Should -BeFalse
  }
}

Describe 'Test-StartupNoticeSuppressed' {
  It 'blendet die Meldung mit DEMSELBEN Inhalt aus' {
    $store = @{ 'ModParametersMissing' = 'Search-WtWinGetPackage -SearchQuery' }
    Test-StartupNoticeSuppressed -Store $store -Key 'ModParametersMissing' `
      -Fingerprint 'Search-WtWinGetPackage -SearchQuery' | Should -BeTrue
  }

  It 'zeigt sie WIEDER, wenn der Inhalt sich geaendert hat' {
    # Der eigentliche Punkt. Ohne diese Regel waere ein Haekchen von heute eine Blindheit fuer die
    # naechste Modulinkompatibilitaet - und die ist der Grund, aus dem die Meldung existiert.
    $store = @{ 'ModParametersMissing' = 'Search-WtWinGetPackage -SearchQuery' }
    Test-StartupNoticeSuppressed -Store $store -Key 'ModParametersMissing' `
      -Fingerprint 'Get-WtWin32Apps -Superseded' | Should -BeFalse
  }

  It 'blendet nichts aus, was nie ausgeblendet wurde' {
    Test-StartupNoticeSuppressed -Store @{} -Key 'ModVersionUntested' -Fingerprint '2.0.0' | Should -BeFalse
    Test-StartupNoticeSuppressed -Store $null -Key 'ModVersionUntested' -Fingerprint '2.0.0' | Should -BeFalse
  }

  It 'kommt mit einem leeren Fingerabdruck aus' {
    # Die Produktivwarnung hat keinen Inhalt, der sich aendern kann - sie wird dauerhaft ausgeblendet.
    Test-StartupNoticeSuppressed -Store @{ 'ProductionWarning' = '' } -Key 'ProductionWarning' -Fingerprint '' |
      Should -BeTrue
  }

  It 'liest auch einen PSCustomObject-Speicher (so kommt er aus der settings.json)' {
    $fromJson = [pscustomobject]@{ 'ModVersionUntested' = '2.0.0' }
    Test-StartupNoticeSuppressed -Store $fromJson -Key 'ModVersionUntested' -Fingerprint '2.0.0' | Should -BeTrue
    Test-StartupNoticeSuppressed -Store $fromJson -Key 'ModVersionUntested' -Fingerprint '2.1.0' | Should -BeFalse
  }
}

Describe 'Verdrahtung der Startpruefungen' {
  BeforeAll {
    $script:main = Get-SourcePartText -Part '90-Main.ps1'
    $script:cfg = Get-SourcePartText -Part '05-Config.ps1'
  }

  It 'prueft die Mehrfachinstallation im Startpfad' {
    $script:main | Should -Match 'Get-ModuleVersionConflict'
    $script:main | Should -Match 'ModMultipleVersionsDialog'
  }

  It 'prueft die optionalen Befehle im Startpfad' {
    $script:main | Should -Match 'Get-MissingOptionalCommands'
    $script:main | Should -Match 'ModOptionalMissingDialog'
  }

  It 'haelt jeden Befehl, den src/ an das Modul bindet, in EINER der beiden Vertragslisten' {
    # Die Regel, die der Messung vom 07.09.2026 entspricht: drei gebundene Befehle standen in
    # keiner Liste, und ihr Ausfall zeigte sich erst als gescheiterter Klick. Gefunden wird ueber
    # den Parser, damit eine Erwaehnung im Kommentar nicht als Aufruf durchgeht.
    $ownNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $called = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '..\..\src') -Filter '*.ps1')) {
      $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
      foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        [void]$ownNames.Add($fn.Name)
      }
      foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $name = $c.GetCommandName()
        # Die Befehle des fremden Moduls: *-Wt* sowie die zwei ohne Wt-Praefix, die es mitbringt.
        if ($name -and ($name -like '*-Wt*' -or $name -in @('New-IntuneWinPackage', 'Show-MsiInfo'))) {
          [void]$called.Add($name)
        }
      }
    }
    $foreign = @($called | Where-Object { -not $ownNames.Contains($_) } | Sort-Object)
    $foreign.Count | Should -BeGreaterThan 0 -Because 'sonst prueft dieser Fall nichts'

    # Pflichtbefehle im Start, Parametervertrag und optionale Liste zusammengenommen.
    $requiredBlock = [regex]::Match($script:main, '(?s)\$requiredCommands = @\((.*?)\)').Groups[1].Value
    $covered = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($m in [regex]::Matches($requiredBlock, "'([^']+)'")) { [void]$covered.Add($m.Groups[1].Value) }
    foreach ($m in [regex]::Matches($script:cfg, "Command = '([^']+)'")) { [void]$covered.Add($m.Groups[1].Value) }

    # Resolve-WtWingetId ist die eine begruendete Ausnahme: sie wird ueberall in einem try/catch
    # benutzt, ihr Fehlen heisst nur "keine Id gefunden" - kein Absturz, kein falsches Paket.
    $exempt = @('Resolve-WtWingetId', 'Get-WtPackageIndexLatestVersion')
    $uncovered = @($foreign | Where-Object { -not $covered.Contains($_) -and $_ -notin $exempt })
    $uncovered -join ', ' | Should -BeNullOrEmpty -Because 'jeder gebundene Modulbefehl gehoert in eine der Vertragslisten'
  }

  It 'macht die Bannerzeile eindeutig - sie nannte die verfuegbare, nicht die geladene Version' {
    # In einem Ticket stand damit eine Zahl, die nicht lief. Der Import kommt erst danach.
    $script:main | Should -Match 'highest installed'
    $script:main | Should -Match 'WinTuner module \{0\} loaded from \{1\}'
  }

  It 'laesst den gescheiterten Modulimport NICHT ausblenden' {
    # Nach einem gescheiterten Import ist alles ausser den Einstellungen abgeschaltet, und diese
    # Meldung ist die einzige Stelle, an der jemand erfaehrt warum. Eine Warnung, die man
    # ausblenden kann, muss ohne sie noch benutzbar sein - diese ist es nicht.
    $importBlock = [regex]::Match($script:main, "(?s)ModImportFailedDialog.*?MessageBoxIcon\]::Error\)").Value
    $importBlock | Should -Not -BeNullOrEmpty
    $importBlock | Should -Not -Match 'SuppressKey'
  }

  It 'blendet die Produktivwarnung nur nach Zustimmung aus' {
    # Ein Haekchen bei "Beenden" darf die Warnung nicht loswerden.
    $dlg = Get-SourceFunctionText -Part '55-Dialogs.ps1' -Name 'Show-ProductionWarningDialog'
    $dlg | Should -Match '\$hide = \$accepted -and \[bool\]\$check\.Checked'
    # Und "Beenden" bleibt der Vorgabe- und Escape-Weg.
    $dlg | Should -Match '\$dlg\.CancelButton = \$noButton'
    $dlg | Should -Match '\$dlg\.AcceptButton = \$noButton'
  }

  It 'hat einen Rueckweg in den Einstellungen' {
    # Ohne ihn waere das Ausblenden eine Einbahnstrasse.
    $rows = Get-SourcePartText -Part '85-Rows.ps1'
    $rows | Should -Match 'SettingsStartupNoticesResetButton'
    $rows | Should -Match '\$script:settings\.SuppressedStartupNotices = @\{\}'
    # Auch die akzeptierte Version wird zurueckgesetzt, sonst kaeme die Produktivwarnung trotz
    # "wieder anzeigen" erst beim naechsten Update - und der Knopf haette scheinbar nichts getan.
    $rows | Should -Match "ProductionWarningAcceptedVersion = ''"
  }

  It 'protokolliert eine ausgeblendete Meldung trotzdem' {
    # Sonst waere ein Haekchen von heute in einem Ticket von morgen nicht nachvollziehbar.
    $fn = Get-SourceFunctionText -Part '70-Runtime.ps1' -Name 'Show-StartupDialog'
    $fn | Should -Match 'was hidden by the user and is only in the log'
  }
}
