# Shared loader for the unit tests.
#
# The application is a single WinForms script, not a module, so a test cannot simply import it:
# dot-sourcing a whole part would start building the UI. These helpers hand back the SOURCE TEXT of
# what a test needs; the test dot-sources it itself inside BeforeAll.
#
# That split matters: dot-sourcing inside a helper FUNCTION would define the functions in that
# function's scope, and they would be gone by the time an It block runs. Dot-sourcing in BeforeAll
# puts them where Pester can see them.
#
# Usage:
#   BeforeAll {
#     . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
#     Initialize-TestAmbient
#     . ([scriptblock]::Create((Get-SourceFunctionText -Part '20-Version.ps1' -Name 'Test-IsNewerVersion')))
#   }

$script:SourceRoot = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src'

function Get-SourcePartPath {
  param([Parameter(Mandatory)][string]$Part)
  $path = Join-Path $script:SourceRoot $Part
  if (-not (Test-Path -LiteralPath $path)) { throw "Source part not found: $path" }
  return $path
}

# Returns the definition text of one or more named functions from a part.
#
# Located through the PowerShell parser rather than by string matching, so a brace inside a string
# or a comment cannot cut a definition short - and a renamed function fails loudly here instead of
# silently testing nothing.
function Get-SourceFunctionText {
  param(
    [Parameter(Mandatory)][string]$Part,
    [Parameter(Mandatory)][string[]]$Name
  )
  $path = Get-SourcePartPath -Part $Part
  $tokens = $null; $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
  if ($errors.Count -gt 0) { throw "Source part $Part has $($errors.Count) parser error(s)." }

  $parts = foreach ($wanted in $Name) {
    $fn = $ast.FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $wanted
    }, $true) | Select-Object -First 1
    if (-not $fn) { throw "Function '$wanted' not found in $Part." }
    $fn.Extent.Text
  }
  return ($parts -join "`r`n`r`n")
}

# Whole part. Only safe for parts that define functions and set variables, without building UI.
function Get-SourcePartText {
  param([Parameter(Mandatory)][string]$Part)
  return [IO.File]::ReadAllText((Get-SourcePartPath -Part $Part))
}

# The shipped UI string table plus Get-UiString, so tests assert against the texts that actually
# ship rather than copies that can drift apart from them.
function Get-UiStringsText {
  return ((Get-SourcePartText -Part '15-Strings.ps1') + "`r`n" +
          (Get-SourceFunctionText -Part '20-Version.ps1' -Name 'Get-UiString'))
}

# Ambient functions every part assumes exist. Defined globally so the code under test finds them.
# Logging is captured so a test can assert on what was written.
function Initialize-TestAmbient {
  # The application is a WinForms app, so the code under test may reach for WinForms types - the
  # retry pause in Test-WtConnected calls [System.Windows.Forms.Application]::DoEvents(). A clean
  # runner (unlike a typical dev box) does not auto-load that assembly, so the type failed to
  # resolve there and only the retrying tests went red. Load it here so the ambient matches the
  # environment the code actually runs in.
  Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue

  # Die zwei Wurzeln der eigenen Datenpfade (05-Config). Jede Funktion, die einen Pfad im
  # Benutzerprofil bildet, ruft sie - ohne sie schlaegt schon BeforeAll fehl. Geladen wird der
  # ECHTE Rumpf aus der Quelle statt einer Kopie, sonst laufen Test und Anwendung auseinander;
  # global, weil dot-sourcing in einer Funktion sonst nur hier drin gilt.
  $rootFns = Get-SourceFunctionText -Part '05-Config.ps1' -Name 'Get-AppDataRoot', 'Get-LocalAppDataRoot'
  . ([scriptblock]::Create(($rootFns -replace 'function Get-', 'function global:Get-')))

  $global:TestLog = [System.Collections.Generic.List[string]]::new()
  $global:TestStatus = $null
  Set-Item -Path function:global:Write-Log      -Value { param([string]$message) $global:TestLog.Add($message) }
  Set-Item -Path function:global:Write-LogSafe  -Value { param([string]$message) $global:TestLog.Add($message) }
  Set-Item -Path function:global:Write-LogDebug -Value { param([string]$message) }
  Set-Item -Path function:global:Update-Status  -Value { param($t) $global:TestStatus = [string]$t }
}
