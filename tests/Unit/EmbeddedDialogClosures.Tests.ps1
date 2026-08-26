# Ereignisse eines EINGEBETTETEN Dialogs duerfen keine lokalen Variablen ihrer Funktion lesen.
#
# Show-AppSettingsDialog baut denselben Editor entweder in ein eigenes Fenster oder - mit
# -HostPanel - als festen Bereich in die Seitenleiste. Im Fensterfall laeuft die Funktion noch,
# solange der Dialog offen ist; im Bereichsfall kehrt sie beim Aufbau des Fensters sofort zurueck.
# Danach sind ihre lokalen Variablen weg, und jedes Ereignis, das spaeter feuert, sah $null:
#
#   App settings load failed: The property 'Text' cannot be found on this object.
#   FATAL UI ERROR: The expression after '&' in a pipeline element produced an object that was
#   not valid. It must result in a command name, a script block, or a CommandInfo object.
#
# .GetNewClosure() ist dafuer NICHT die Loesung, auch wenn es zunaechst hilft: der Block haengt
# danach an einem dynamischen Modul, in dem $script: woanders hinzeigt und die Funktionen des
# Skripts nur gefunden werden, solange das Skript zufaellig das oberste ist. Beides ist unten
# als Sprachverhalten festgehalten, damit niemand den Griff erneut versucht.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  $script:dialogsPath = Join-Path (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src') '55-Dialogs.ps1'

  $tokens = $null; $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:dialogsPath, [ref]$tokens, [ref]$errors)
  if ($errors.Count -gt 0) { throw "55-Dialogs.ps1 has $($errors.Count) parser error(s)." }
  $script:appSettingsFn = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-AppSettingsDialog'
  }, $true) | Select-Object -First 1
  if (-not $script:appSettingsFn) { throw 'Show-AppSettingsDialog not found.' }

  # Alle Ereignisblöcke der Funktion: { ... } als Argument eines Add_*-Aufrufs.
  $script:handlers = foreach ($call in $script:appSettingsFn.FindAll({
      param($node) $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst]
    }, $true)) {
    if ([string]$call.Member.Value -notlike 'Add_*') { continue }
    [pscustomobject]@{
      Event = [string]$call.Member.Value
      Line  = $call.Extent.StartLineNumber
      Block = @($call.Arguments)[0]
    }
  }
  $script:handlers = @($script:handlers)

  $script:automatics = @('_', 'this', 'args', 'true', 'false', 'null', 'PSItem', 'PSScriptRoot', 'input', 'ErrorActionPreference')
}

Describe 'Warum das so aussehen muss (Sprachverhalten)' {

  It 'verliert ein einfacher Block die lokalen Variablen der Funktion' {
    function New-PlainHandler {
      $local = [pscustomobject]@{ Text = 'da' }
      return { $local.Text }
    }
    & (New-PlainHandler) | Should -BeNullOrEmpty
  }

  It 'behaelt eine Closure zwar die Variablen - verliert dafuer aber $script:' {
    function New-ClosureHandler {
      $local = [pscustomobject]@{ Text = 'da' }
      return { "$($local.Text)|$script:someProbeState" }.GetNewClosure()
    }
    $script:someProbeState = 'SCRIPTSTATE'
    & (New-ClosureHandler) | Should -Be 'da|'
  }
}

Describe 'Show-AppSettingsDialog' {

  It 'hat ueberhaupt Ereignisbloecke gefunden (sonst prueft der Rest nichts)' {
    $script:handlers.Count | Should -BeGreaterThan 5
  }

  It 'verwendet in keinem Ereignisblock .GetNewClosure()' {
    $bad = foreach ($h in $script:handlers) {
      if ($h.Block.Extent.Text -match 'GetNewClosure') { "$($h.Event) at line $($h.Line)" }
    }
    $bad | Should -BeNullOrEmpty
  }

  It 'liest in keinem Ereignisblock eine lokale Variable der Funktion' {
    $bad = foreach ($h in $script:handlers) {
      $block = $h.Block
      if (-not ($block -is [System.Management.Automation.Language.ScriptBlockExpressionAst])) { continue }
      # Was der Block selbst setzt, darf er auch lesen.
      $assigned = @($block.FindAll({
        param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst]
      }, $true) | ForEach-Object {
        if ($_.Left -is [System.Management.Automation.Language.VariableExpressionAst]) { $_.Left.VariablePath.UserPath }
      })
      # Schleifenvariablen ebenso.
      $assigned += @($block.FindAll({
        param($node) $node -is [System.Management.Automation.Language.ForEachStatementAst]
      }, $true) | ForEach-Object { $_.Variable.VariablePath.UserPath })

      foreach ($v in $block.FindAll({
          param($node) $node -is [System.Management.Automation.Language.VariableExpressionAst]
        }, $true)) {
        $name = $v.VariablePath.UserPath
        if ($v.VariablePath.IsScript) { continue }
        if ($script:automatics -contains $name) { continue }
        if ($assigned -contains $name) { continue }
        "$name in $($h.Event) at line $($v.Extent.StartLineNumber)"
      }
    }
    $bad | Should -BeNullOrEmpty
  }

  It 'legt einen Zustandsbeutel im Skript-Bereich an und stellt ihn nach dem modalen Dialog zurueck' {
    $text = $script:appSettingsFn.Extent.Text
    $text | Should -Match '\$previousAppSettingsUi = \$script:appSettingsUi'
    $text | Should -Match '\$script:appSettingsUi = \$previousAppSettingsUi'
  }

  It 'reicht den Ladeblock ueber den Beutel weiter - "& $loadApps" traf spaeter auf $null' {
    $script:appSettingsFn.Extent.Text | Should -Match '\$reload\.Add_Click\(\{ & \$script:appSettingsUi\.LoadApps \}\)'
  }

  It 'stellt "App-Liste neu laden" vor die Auswahlknoepfe' {
    $text = [IO.File]::ReadAllText($script:dialogsPath)
    $posReload = $text.IndexOf("`$reload = New-Object")
    $posCheck = $text.IndexOf("`$checkAll = New-Object")
    $posUncheck = $text.IndexOf("`$uncheckAll = New-Object")
    $posReload | Should -BeGreaterThan 0
    $posReload | Should -BeLessThan $posCheck
    $posCheck | Should -BeLessThan $posUncheck
  }
}
