<#
.SYNOPSIS
  Assembles the source parts in src/ into the single script file that is shipped.

.DESCRIPTION
  Users never download the repository - they download exactly one .ps1 from the GitHub
  release. src/ therefore holds the maintainable source, and this script concatenates the
  parts back into that single file.

  The parts are plain text fragments, not modules. They are joined verbatim and in file-name
  order, which is why every part carries a numeric prefix: the code between the function
  definitions is top-level statements whose execution order must be preserved.

  Dot-sourcing (see dev.ps1) rather than Import-Module is used during development for the
  same reason the parts are not .psm1 files: the application shares 110 different $script:
  variables across roughly 990 references. Import-Module would give each module its own
  script scope and silently break that sharing at runtime.
#>
[CmdletBinding()]
param(
  [string]$SourceDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'src'),
  [string]$OutputPath      = (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist/WinTuner_GUI_ntg.ps1'),

  # Writes <output>.map.txt, mapping each part to its line range in the assembled file.
  # Useful when a user reports an error with a line number from the shipped script.
  [switch]$WriteLineMap
)

$ErrorActionPreference = 'Stop'

$found = @(Get-ChildItem -LiteralPath $SourceDirectory -Filter '*.ps1' -File)
if ($found.Count -eq 0) { throw "No source parts found in $SourceDirectory." }

# The load order IS the numeric prefix, so the prefix is checked rather than assumed.
#
# This used to be Sort-Object Name over whatever *.ps1 happened to be in src/. Two things could go
# wrong silently. A file without a numeric prefix (a scratch copy, a "90-Main.backup.ps1", an
# experiment) was concatenated at whatever position its name sorted to - possibly BEFORE
# 00-Bootstrap, where the top-level statements it contains run against a half-built world. And
# Sort-Object Name is culture-aware string sorting, so ordering by a two-digit prefix was luck
# rather than design. Sorting numerically on the prefix makes the order explicit and total.
$pattern = '^(?<prefix>\d{2})-'
$unprefixed = @($found | Where-Object { $_.Name -notmatch $pattern })
if ($unprefixed.Count -gt 0) {
  throw ("Refusing to build: {0} in {1} lack the two-digit load-order prefix (NN-Name.ps1): {2}. Move or rename them - a part without a prefix would be concatenated at an unpredictable position." -f
    $unprefixed.Count, $SourceDirectory, (($unprefixed | ForEach-Object { $_.Name }) -join ', '))
}

$parts = @($found | Sort-Object -Property @{ Expression = { [int]([regex]::Match($_.Name, $pattern).Groups['prefix'].Value) } }, Name)

# Two parts sharing a prefix have no defined order between them - it would come down to the
# secondary sort, i.e. to their file names. Say so instead of picking one.
$duplicatePrefixes = @($parts |
  Group-Object -Property { [int]([regex]::Match($_.Name, $pattern).Groups['prefix'].Value) } |
  Where-Object { $_.Count -gt 1 })
if ($duplicatePrefixes.Count -gt 0) {
  $detail = ($duplicatePrefixes | ForEach-Object {
    '{0:D2} -> {1}' -f [int]$_.Name, (($_.Group | ForEach-Object { $_.Name }) -join ' + ')
  }) -join '; '
  throw "Refusing to build: these load-order prefixes are used more than once, so the order between them is undefined: $detail"
}

$builder = [Text.StringBuilder]::new()
$map = [Collections.Generic.List[string]]::new()
$line = 1

foreach ($part in $parts) {
  # ReadAllText strips a BOM if a part happens to have one, so no BOM can end up mid-file.
  $content = [IO.File]::ReadAllText($part.FullName)
  # Checked before the CRLF test, which would otherwise report an empty file as a line-ending
  # problem and send the reader looking for the wrong thing.
  if ($content.Length -eq 0) {
    throw "Part '$($part.Name)' is empty. Delete it or give it content - an empty part is almost always a failed write or a leftover."
  }
  if (-not $content.EndsWith("`r`n")) {
    throw "Part '$($part.Name)' does not end with CRLF; concatenating it would join two statements."
  }
  if ($content -match "(?<!`r)`n") {
    throw "Part '$($part.Name)' contains bare LF line endings."
  }

  $lineCount = ([regex]::Matches($content, "`r`n")).Count
  $map.Add(('{0,-24} {1,6} - {2,-6}' -f $part.Name, $line, ($line + $lineCount - 1)))
  $line += $lineCount

  [void]$builder.Append($content)
}

$assembled = $builder.ToString()

$outputDirectory = Split-Path $OutputPath -Parent
if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory)) {
  New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

# UTF-8 *with* BOM on purpose: the prerequisite bootstrap runs under Windows PowerShell 5.1,
# which decodes BOM-less files using the ANSI code page and would mangle its German umlauts.
[IO.File]::WriteAllText($OutputPath, $assembled, [Text.UTF8Encoding]::new($true))

$tokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($OutputPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
  $parseErrors | ForEach-Object { Write-Error ("{0}:{1}: {2}" -f $_.Extent.StartLineNumber, $_.Extent.StartColumnNumber, $_.Message) }
  throw "Assembled script has $($parseErrors.Count) parser error(s)."
}

if ($WriteLineMap) {
  [IO.File]::WriteAllLines("$OutputPath.map.txt", $map, [Text.UTF8Encoding]::new($false))
}

$hash = (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host ("Built {0} from {1} parts, {2} lines, SHA256 {3}" -f $OutputPath, $parts.Count, ($line - 1), $hash)
