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

# Die Gegenrichtung: Schluessel, die DEFINIERT aber nicht mehr benutzt werden. Die Pruefung oben
# faengt nur den umgekehrten Fall, weshalb beim Umbau der Einstellungsseite drei Schluessel
# uebrigblieben, deren Steuerelemente es nicht mehr gab - unsichtbar fuer jede Pruefung.
#
# Zwei Umwege muessen mitgezaehlt werden, sonst meldet die Pruefung fast nur Fehlalarme:
#   -TextKey/-TitleKey/-InfoKey   Info-Badges und Kartentitel bekommen den Schluessel als Parameter.
#   Get-UiString $variable Der Schluessel steckt in einer Variablen (z. B. die Dashboard-Kachel,
#                          die je nach Einstellung einen von zwei Tooltips zeigt).
# Der zweite Fall ist statisch nicht aufloesbar; deshalb ist das eine WARNUNG und kein Fehler -
# ein zu Recht vorgehaltener Schluessel darf den Build nicht blockieren.
$indirectKeys = @([regex]::Matches($content, '-(?:TextKey|TitleKey|InfoKey)\s+["''](?<key>[A-Za-z][A-Za-z0-9_]*)["'']') |
  ForEach-Object { $_.Groups['key'].Value })
$dynamicLookup = [regex]::IsMatch($content, 'Get-UiString\s+\$')
$reachable = [Collections.Generic.HashSet[string]]::new([string[]]($usedKeys + $indirectKeys), [StringComparer]::OrdinalIgnoreCase)
$deadKeys = @($enKeys | Where-Object { -not $reachable.Contains($_) } | Sort-Object)
if ($deadKeys.Count -gt 0) {
  $note = if ($dynamicLookup) { ' (einige davon koennen ueber eine Variable geholt werden)' } else { '' }
  Write-Host ("  Hinweis: {0} UI-Schluessel werden nirgends gelesen{1}: {2}" -f $deadKeys.Count, $note, ($deadKeys -join ', ')) -ForegroundColor DarkYellow
}

# Ein deutsches Anfuehrungszeichen beendet einen einzeiligen PowerShell-String.
#
# In einem einzeiligen doppelt gequoteten String muss ein Anfuehrungszeichen "" geschrieben werden,
# in einem Here-String (@"..."@) nicht. Die deutschen Texte benutzen typografische Anfuehrungszeichen,
# und ,,Updates" beendet den String beim schliessenden Zeichen - beim Umbau der Einstellungsseite hat
# genau das den Build zweimal gebrochen. Gefunden hat es der Parser, mit einer Zeilennummer in der
# zusammengebauten Datei; diese Pruefung nennt stattdessen den Schluessel.
$openingQuote = [char]0x201E   # ,, - oeffnendes deutsches Anfuehrungszeichen
$badQuoteKeys = @()
foreach ($line in ($content -split "`r?`n")) {
  $m = [regex]::Match($line, '^    (?<key>[A-Za-z][A-Za-z0-9_]*)\s*=\s*"(?<body>.*)"\s*$')
  if (-not $m.Success) { continue }
  if ($m.Groups['body'].Value.Contains($openingQuote)) { $badQuoteKeys += $m.Groups['key'].Value }
}
Assert-True ($badQuoteKeys.Count -eq 0) ("Einzeilige UI-Strings mit deutschem Anfuehrungszeichen (bitte zwei gerade Anfuehrungszeichen verwenden oder einen Here-String): $($badQuoteKeys -join ', ')")

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

# Filesystem cmdlets must not take a wildcard-interpreting path.
#
# -Path treats [ and ] as a character-class pattern, so a package or log folder called
# "Intune Pakete [Kunde]" is reported as non-existent while sitting right there. That is not
# hypothetical: it produced a self-update that claimed success without replacing the file, and a
# package folder reported as "not writable". Both were real findings.
#
# The rule is enforced on the ASSEMBLED script, so it covers every part at once. New-Item has no
# -LiteralPath at all - use [System.IO.Directory]::CreateDirectory instead.
$fsCmdlets = 'Test-Path', 'Get-Content', 'Set-Content', 'Add-Content', 'Remove-Item', 'Copy-Item',
             'Move-Item', 'Rename-Item', 'Get-ChildItem', 'Get-Item', 'Out-File', 'New-Item'
$pathOffenders = [Collections.Generic.List[string]]::new()
$lines = $content -split "`r`n"
for ($i = 0; $i -lt $lines.Count; $i++) {
  $line = $lines[$i]
  if ($line -match '^\s*#') { continue }
  foreach ($cmdlet in $fsCmdlets) {
    # -Path anywhere on the same line as the cmdlet. Good enough for a single-line style, and the
    # whole source base is written that way.
    if ($line -match ([regex]::Escape($cmdlet) + '\b') -and $line -match '\s-Path\b') {
      $pathOffenders.Add(('line {0}: {1}' -f ($i + 1), $line.Trim()))
      break
    }
  }
}
Assert-True ($pathOffenders.Count -eq 0) (
  "Filesystem cmdlet called with -Path instead of -LiteralPath ({0} site(s)); a folder name containing [ or ] would silently not be found:`r`n  {1}" -f
    $pathOffenders.Count, ($pathOffenders -join "`r`n  "))

# Positional path arguments have the same problem and are easy to miss, because they do not even
# mention a parameter name. Only the cmdlets whose first positional parameter IS the path.
$positionalCmdlets = 'Test-Path', 'Get-Content', 'Remove-Item', 'Get-ChildItem', 'Get-Item'
$positionalOffenders = [Collections.Generic.List[string]]::new()
for ($i = 0; $i -lt $lines.Count; $i++) {
  $line = $lines[$i]
  if ($line -match '^\s*#') { continue }
  foreach ($cmdlet in $positionalCmdlets) {
    # A variable, a quote or a sub-expression straight after the cmdlet name means positional.
    if ($line -match ([regex]::Escape($cmdlet) + '\s+[\$"''(]')) {
      $positionalOffenders.Add(('line {0}: {1}' -f ($i + 1), $line.Trim()))
      break
    }
  }
}
Assert-True ($positionalOffenders.Count -eq 0) (
  "Filesystem cmdlet called with a positional path ({0} site(s)); use -LiteralPath so [ and ] in a folder name are taken literally:`r`n  {1}" -f
    $positionalOffenders.Count, ($positionalOffenders -join "`r`n  "))

# Jede Fortschrittsanzeige muss auch wieder verschwinden.
#
# Die Sichtbarkeit der Anzeige IST die Sperre gegen gleichzeitige Vorgaenge (Test-OperationRunning in
# 70-Runtime liest sie). Ein Handler, der Show-Progress aufruft und im Fehlerfall - oder am Ende -
# kein Hide-Progress erreicht, laesst die Anwendung dauerhaft "beschaeftigt" aussehen: jeder weitere
# Klick wird abgewiesen oder in die Warteschlange gelegt, bis irgendein anderer Vorgang die Anzeige
# zufaellig ausblendet. Genau so lag es beim Loeschen abgeloester Apps.
#
# Geprueft wird ueber den Parser, nicht mit einer Textsuche: gefragt ist der umgebende Skriptblock
# (Funktion oder Ereignis), und nur der Parser weiss, wo der endet.
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
$showCalls = @($ast.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.CommandAst] -and
  $node.GetCommandName() -eq 'Show-Progress'
}, $true))
$unbalanced = [Collections.Generic.List[string]]::new()
foreach ($call in $showCalls) {
  # Der NAECHSTE umgebende Handler oder die naechste umgebende Funktion - nicht irgendein
  # Skriptblock weiter oben. Die erste Fassung dieser Regel lief bis zum Skript-Rumpf hoch, und der
  # enthaelt natuerlich irgendwo ein Hide-Progress: die Regel war gruen und der Fehler blieb drin.
  $scope = $null
  $node = $call.Parent
  while ($node) {
    if ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $scope = $node; break }
    if ($node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
        ([string]$node.Member.Value) -like 'Add_*') { $scope = $node; break }
    $node = $node.Parent
  }
  $text = if ($scope) { $scope.Extent.Text } else { '' }
  # Ausnahme mit Ansage: wer den Zustand ausdruecklich woanders wiederherstellt (der
  # Winget-Index-Aufwaermer tut das in seiner Partnerfunktion), schreibt das als Marker in den
  # Kommentar. Damit bleibt die Ausnahme sichtbar statt stillschweigend.
  if ($text -notmatch 'Hide-Progress' -and $text -notmatch 'progress-restored-elsewhere') {
    $where = if ($scope) { '' } else { ' (no enclosing function or event handler found)' }
    $unbalanced.Add(('line {0}: {1}{2}' -f $call.Extent.StartLineNumber, $call.Extent.Text, $where))
  }
}
Assert-True ($unbalanced.Count -eq 0) (
  "Show-Progress without a Hide-Progress in the same scope ({0} site(s)); the progress display is the busy lock, so it would stay switched on and refuse every later action:`r`n  {1}" -f
    $unbalanced.Count, ($unbalanced -join "`r`n  "))

# Ein modaler Dialog auf der obersten Ebene VOR dem Smoke-Tor haelt jeden unbeaufsichtigten Lauf an.
#
# So ist 0.16.0 in der CI stehengeblieben: auf dem Laeufer ist das WinTuner-Modul nicht installiert,
# Import-Module schlug fehl, und der Fehlerzweig zeigte eine MessageBox. Niemand klickt sie weg -
# der Smoke-Test lief in seinen Zeitablauf. Auf dem Entwicklungsrechner ist das Modul da, deshalb
# hat es dort nie jemand gesehen.
#
# Geprueft wird ueber den Parser: gefragt ist, ob der Aufruf im Skript-Rumpf steht (also beim Start
# ohnehin ausgefuehrt wird) oder in einer Funktion bzw. einem Ereignis (dann klickt ein Benutzer).
# Nach dem Tor ist eine MessageBox erlaubt - dort laeuft nur noch, was der Smoke-Lauf nie erreicht.
$gateMatch = [regex]::Match($content, '(?m)^if \(\$env:WINTUNER_SMOKE -eq ''1''\) \{')
Assert-True $gateMatch.Success 'Smoke gate not found in the assembled script.'
$gateLine = ($content.Substring(0, $gateMatch.Index) -split "`r`n").Count
$startupDialogs = [Collections.Generic.List[string]]::new()
foreach ($call in $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
    ([string]$node.Expression) -match 'MessageBox' -and ([string]$node.Member.Value) -eq 'Show'
  }, $true)) {
  if ($call.Extent.StartLineNumber -ge $gateLine) { continue }
  $node = $call.Parent
  $nested = $false
  while ($node) {
    if ($node -is [System.Management.Automation.Language.FunctionDefinitionAst] -or
        $node -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { $nested = $true; break }
    $node = $node.Parent
  }
  if (-not $nested) { $startupDialogs.Add(('line {0}: {1}' -f $call.Extent.StartLineNumber, ($call.Extent.Text -split "`r`n")[0].Trim())) }
}
Assert-True ($startupDialogs.Count -eq 0) (
  "MessageBox on the top level before the smoke gate ({0} site(s)); an unattended run waits forever for the click. Use Show-StartupDialog instead:`r`n  {1}" -f
    $startupDialogs.Count, ($startupDialogs -join "`r`n  "))

# Ein Add_Shown-Handler, der einen modalen Dialog oeffnen kann, muss unbeaufsichtigte Laeufe
# ausschliessen.
#
# Diese Handler laufen, sobald das Fenster gezeigt wird - und die Layout-Probe zeigt es. Fuenf von
# ihnen oeffnen ueber BeginInvoke eine MessageBox; dass davon bisher keine zugeschlagen hat, lag an
# Einstellungen, die auf dem Rechner des Entwicklers gesetzt sind und auf einem frischen Profil
# (jeder CI-Laeufer) nicht. Vorher entschaerfte die Layout-Probe drei davon namentlich - ein
# vierter Dialog waere daran vorbeigelaufen.
$shownWithDialog = [Collections.Generic.List[string]]::new()
foreach ($h in $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
    ([string]$node.Member.Value) -eq 'Add_Shown'
  }, $true)) {
  $text = $h.Extent.Text
  if ($text -notmatch 'MessageBox\]::Show') { continue }
  if ($text -match 'Test-UnattendedRun') { continue }
  $shownWithDialog.Add(('line {0}' -f $h.Extent.StartLineNumber))
}
Assert-True ($shownWithDialog.Count -eq 0) (
  "Add_Shown handler opens a MessageBox without a Test-UnattendedRun guard ({0} site(s)); the layout probe shows the window, so an unattended run would wait for the click:`r`n  {1}" -f
    $shownWithDialog.Count, ($shownWithDialog -join "`r`n  "))

# Die eigenen Datenpfade duerfen nur ueber die zwei Wurzelfunktionen laufen.
#
# [Environment]::GetFolderPath('ApplicationData') ignoriert $env:APPDATA. Die Prueflaeufer setzten
# genau diese Variable und hielten sich fuer gekapselt, waehrend sie das echte Profil las und
# schrieb. Umgelenkt wird jetzt ueber $env:WINTUNER_DATA_DIR in Get-AppDataRoot /
# Get-LocalAppDataRoot; eine neue Stelle, die den bekannten Ordner direkt fragt, faellt aus der
# Kapselung heraus, ohne dass es auffaellt.
$folderCalls = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
    ([string]$node.Member.Value) -eq 'GetFolderPath' -and
    $node.Arguments.Count -eq 1 -and
    ([string]$node.Arguments[0].Extent.Text) -match "^'(ApplicationData|LocalApplicationData)'$"
  }, $true))
$strayFolderCalls = [Collections.Generic.List[string]]::new()
foreach ($call in $folderCalls) {
  $scope = $null
  $node = $call.Parent
  while ($node) {
    if ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $scope = $node.Name; break }
    $node = $node.Parent
  }
  if ($scope -in 'Get-AppDataRoot', 'Get-LocalAppDataRoot') { continue }
  $strayFolderCalls.Add(('line {0}: {1}' -f $call.Extent.StartLineNumber, $call.Extent.Text))
}
Assert-True ($strayFolderCalls.Count -eq 0) (
  "GetFolderPath for a per-user data folder outside Get-AppDataRoot/Get-LocalAppDataRoot ({0} site(s)); such a path ignores WINTUNER_DATA_DIR, so a verification run would read and write the real profile:`r`n  {1}" -f
    $strayFolderCalls.Count, ($strayFolderCalls -join "`r`n  "))

Write-Host "Static checks passed for WinTuner GUI $($version.Groups['v'].Value): $($functionNames.Count) functions, $($enKeys.Count) UI keys per language."
