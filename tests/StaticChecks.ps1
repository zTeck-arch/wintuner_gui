# Checks run against the assembled script, not the individual parts in src/, because that is
# what users actually download. Run build/Build-SingleFile.ps1 first.
param(
  [string]$ScriptPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist/WinTuner_GUI_ntg.ps1')
)

$ErrorActionPreference = 'Stop'
$path = (Resolve-Path -LiteralPath $ScriptPath).Path
$content = [IO.File]::ReadAllText($path)

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

# The shipped file must carry a UTF-8 BOM. Its prerequisite bootstrap runs under Windows
# PowerShell 5.1, which decodes a BOM-less file using the ANSI code page and would turn the
# German umlauts in its console output into mojibake - for exactly those users who lack
# PowerShell 7 and depend on that message.
$prefix = [byte[]]::new(3)
$stream = [IO.File]::OpenRead($path)
try { $null = $stream.Read($prefix, 0, 3) } finally { $stream.Dispose() }
Assert-True (($prefix[0] -eq 0xEF) -and ($prefix[1] -eq 0xBB) -and ($prefix[2] -eq 0xBF)) 'Assembled script is missing its UTF-8 BOM.'

$tokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) "PowerShell parser reported $($parseErrors.Count) error(s)."

$version = [regex]::Match($content, '(?m)^\s*\$script:appVersion\s*=\s*["''](?<v>[^"'']+)["'']\s*$')
$header = [regex]::Match($content, '(?m)^# v(?<v>\d+\.\d+\.\d+)\s')
Assert-True $version.Success 'appVersion not found.'
Assert-True $header.Success 'Version header not found.'
Assert-True ($version.Groups['v'].Value -eq $header.Groups['v'].Value) 'Version header and appVersion differ.'

$functionNames = [regex]::Matches($content, '(?im)^function\s+(?<name>[A-Za-z][A-Za-z0-9_-]*)\s*\{') |
  ForEach-Object { $_.Groups['name'].Value.ToLowerInvariant() }
$duplicateFunctions = @($functionNames | Group-Object | Where-Object Count -gt 1)
Assert-True ($duplicateFunctions.Count -eq 0) "Duplicate functions: $($duplicateFunctions.Name -join ', ')"

$enStart = $content.IndexOf('  en = @{')
$deStart = $content.IndexOf('  de = @{')
$i18nEnd = $content.IndexOf('# Returns the current-language string')
Assert-True ($enStart -ge 0 -and $deStart -gt $enStart -and $i18nEnd -gt $deStart) 'Language blocks could not be isolated.'
$keyPattern = '(?m)^    (?<key>[A-Za-z][A-Za-z0-9_]*)\s*='
$enKeys = @([regex]::Matches($content.Substring($enStart, $deStart - $enStart), $keyPattern) | ForEach-Object { $_.Groups['key'].Value })
$deKeys = @([regex]::Matches($content.Substring($deStart, $i18nEnd - $deStart), $keyPattern) | ForEach-Object { $_.Groups['key'].Value })
Assert-True (@($enKeys | Group-Object | Where-Object Count -gt 1).Count -eq 0) 'Duplicate English UI keys found.'
Assert-True (@($deKeys | Group-Object | Where-Object Count -gt 1).Count -eq 0) 'Duplicate German UI keys found.'
$keyDiff = @(Compare-Object ($enKeys | Sort-Object) ($deKeys | Sort-Object))
Assert-True ($keyDiff.Count -eq 0) 'German and English UI keys differ.'
$defined = [Collections.Generic.HashSet[string]]::new([string[]]$enKeys, [StringComparer]::OrdinalIgnoreCase)
$usedKeys = @([regex]::Matches($content, 'Get-UiString\s+["''](?<key>[A-Za-z][A-Za-z0-9_]*)["'']') | ForEach-Object { $_.Groups['key'].Value } | Sort-Object -Unique)
$missingKeys = @($usedKeys | Where-Object { -not $defined.Contains($_) })
Assert-True ($missingKeys.Count -eq 0) "Undefined UI keys: $($missingKeys -join ', ')"

# "(if (...) {...} else {...})" parses cleanly but fails at RUNTIME with "The term 'if' is not
# recognized", because a plain parenthesis opens a command context. Only the subexpression form
# "$(if ...)" works. The parser cannot catch this, so it is checked textually - it once shipped a
# crash into the update list that every automated check happily approved.
$badConditional = [regex]::Matches($content, '(?<![$@])\(\s*if\s*\(')
Assert-True ($badConditional.Count -eq 0) "Found $($badConditional.Count) '(if ...)' expression(s); use '`$(if ...)' instead."

$withoutCrlf = $content.Replace("`r`n", '')
Assert-True (-not $withoutCrlf.Contains("`n")) 'Script contains bare LF line endings.'
Assert-True (-not $content.Contains('$script:colors.Muted')) 'Undefined legacy color reference is present.'
Assert-True ($content.Contains('deviceAppManagement/mobileApps?`$top=100')) 'Compatible Microsoft Store inventory endpoint is missing.'
Assert-True ($content.Contains("`$script:updateAssetName = 'WinTuner_GUI_ntg.ps1'")) 'Deterministic update asset name is missing.'
Assert-True ($content.Contains("`$script:updateHashAssetName = 'WinTuner_GUI_ntg.ps1.sha256'")) 'Deterministic checksum asset name is missing.'
Assert-True ($content.Contains('Folgende Anwendungen in der Intune Kundenumgebung aktualisiert und bereitgestellt sowie benötigte Zuweisungen und Ablöse von alten Anwendungen vorgenommen:')) 'Required performance-record wording is missing.'
Assert-True ($content.Contains('function Remove-SupersededInventoryOverlap')) 'Superseded/active inventory overlap guard is missing.'
Assert-True ($content.Contains('function Test-RequiresExistingTargetFollowUp')) 'Existing targets are not checked for remaining source assignments.'
Assert-True ($content.Contains('no remaining source assignment; row omitted')) 'Completed existing-target follow-up is not removed from repeated scans.'
Assert-True ($content.Contains('already-superseded Graph objects are excluded')) 'Update scan does not document the superseded-object exclusion.'
Assert-True ($content.Contains('follow-up only; no upload')) 'Existing-target rows are not clearly identified as no-upload follow-up.'
Assert-True ($content.Contains('Follow-up only: {0}')) 'Existing-target scan log does not clearly state that no upload is required.'
Assert-True (-not $content.Contains('target already deployed:')) 'Ambiguous legacy update-available log wording is still present.'

Assert-True ($content.Contains('function Test-SuccessorAssignmentsConfirmed')) 'Successor assignment verification is missing.'
Assert-True ($content.Contains('function Resolve-CleanupOptionConflict')) 'Cleanup option exclusivity is not enforced in the settings model.'
Assert-True ($content.Contains('installSummary')) 'Install-summary fallback for the installation probe is missing; a tenant whose deviceStatuses returns 400 could never clean up.'

# A BackgroundWorker thread has no PowerShell runspace: the scriptblock handed to it never runs and
# the caller silently receives $null. That is what made the self-update check report "up to date"
# for every release. Nothing may reintroduce it.
Assert-True (-not $content.Contains('New-Object System.ComponentModel.BackgroundWorker')) 'A BackgroundWorker is back; work on such a thread has no runspace and fails silently.'
Assert-True ($content.Contains('UpdCheckNoVersion')) 'A version-less update result is not reported as a failed check.'

# The update batch must not scan the tenant again on its own: that cost a full re-read of every app
# plus a WinGet lookup per package after every run, and the click landed in the busy guard.
$batchStart = $content.IndexOf('function Invoke-AppUpdateBatch')
$batchEnd = $content.IndexOf("`r`n`$script:accentColor", $batchStart)
Assert-True ($batchStart -ge 0 -and $batchEnd -gt $batchStart) 'Invoke-AppUpdateBatch block could not be isolated.'
$batch = $content.Substring($batchStart, $batchEnd - $batchStart)
Assert-True (-not $batch.Contains('updateSearchButton.PerformClick')) 'The update batch triggers an automatic re-scan again.'

$singleStart = $content.IndexOf('function Update-SingleApp')
$batchStart = $content.IndexOf('function Invoke-AppUpdateBatch')
Assert-True ($singleStart -ge 0 -and $batchStart -gt $singleStart) 'Update-SingleApp block could not be isolated.'
$single = $content.Substring($singleStart, $batchStart - $singleStart)
$guardIndex = $single.IndexOf('Get-FreshExistingUpdateTarget')
$buildIndex = $single.IndexOf('New-WingetPackageWithFallback')
Assert-True ($guardIndex -ge 0 -and $buildIndex -gt $guardIndex) 'Fresh tenant duplicate guard must run before package build.'

Write-Host "Static checks passed for WinTuner GUI $($version.Groups['v'].Value): $($functionNames.Count) functions, $($enKeys.Count) UI keys per language."
