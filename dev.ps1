<#
.SYNOPSIS
  Starts WinTuner GUI directly from the source parts in src/, without building.

.DESCRIPTION
  Use this while developing: edit a file under src/ and re-run this script. No build step is
  involved, and error messages point at the real source file and line number rather than at
  a line in the assembled release script.

  The parts are dot-sourced, not imported. Dot-sourcing runs them in this script's scope, so
  the ~110 shared $script: variables behave exactly as they do in the single-file release.
  Import-Module would give each part its own scope and break them at runtime.

  Run build/Build-SingleFile.ps1 to produce the single file that end users download.

.NOTES
  One known difference from the shipped single file: inside a dot-sourced part, $PSScriptRoot
  resolves to src/ rather than to the folder holding the script. Activity logs therefore land
  in src/ during development instead of next to the script (*.log is git-ignored, so nothing
  ends up in the repository).

  The self-update path is unaffected, because $script:githubRepo is empty in the source tree
  and only gets patched in when the release workflow builds the asset - the update check is
  simply skipped here and can never rewrite a file under src/.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$sourceDirectory = Join-Path $PSScriptRoot 'src'
$parts = @(Get-ChildItem -LiteralPath $sourceDirectory -Filter '*.ps1' -File | Sort-Object Name)
if ($parts.Count -eq 0) { throw "No source parts found in $sourceDirectory." }

foreach ($part in $parts) { . $part.FullName }
