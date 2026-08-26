# Fuehrt die komplette Pruefkette aus CLAUDE.md in EINEM Aufruf aus und fasst das Ergebnis in
# einer Tabelle zusammen. Grund: die Kette bestand aus sieben Einzelbefehlen, deren Ausgaben
# unterschiedlich aussehen - wer sie von Hand abtippt, laesst unter Zeitdruck einen weg, und
# genau der haette den Fehler gefunden. Ein Aufruf, ein Urteil.
#
# Jeder Schritt laeuft in einem EIGENEN pwsh-Kindprozess. Das ist Absicht: SmokeTest und
# LayoutProbe starten WinForms und rufen exit auf, Build schreibt dist/ neu. Im selben Prozess
# hintereinander ausgefuehrt wuerde der erste exit-Aufruf die Kette abbrechen und der geladene
# WinForms-Zustand die spaeteren Schritte verfaelschen.
#
# Rueckgabe: Exit-Code 0 nur wenn ALLE ausgefuehrten Schritte gruen sind, sonst 1. Damit ist das
# Skript in Hooks, CI und Stapelverarbeitung brauchbar.
#
# Beispiele:
#   pwsh -NoProfile -File tests/Invoke-CheckChain.ps1
#   pwsh -NoProfile -File tests/Invoke-CheckChain.ps1 -FailFast
#   pwsh -NoProfile -File tests/Invoke-CheckChain.ps1 -Only Build,Static,Pester
[CmdletBinding()]
param(
  # Nur diese Schritte laufen lassen. Ohne Angabe laeuft die vollstaendige Kette.
  # Kein ValidateSet, und das ist gemessen: bei "pwsh -File" gibt die Shell "Static,Pester" als
  # EINEN String weiter, nie als Liste - ValidateSet lehnte damit jeden Mehrfachaufruf ab.
  # Resolve-StepName unten trennt an Komma und prueft die Namen selbst.
  [string[]]$Only,

  # Diese Schritte auslassen. Sinnvoll fuer Zwischenlaeufe: -Skip Layout spart die 7 Designs.
  [string[]]$Skip,

  # Beim ersten roten Schritt abbrechen statt die Kette durchzuziehen. Standard ist der
  # vollstaendige Lauf, weil ein zweiter Fehler sonst erst nach dem naechsten Anlauf sichtbar wird.
  [switch]$FailFast,

  # Ausgabe jedes Schrittes immer zeigen, nicht nur bei Fehlern.
  [switch]$ShowOutput
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$pwshPath = (Get-Process -Id $PID).Path

# Ein Schritt = Name, Anzeigetext und die Argumente fuer den Kindprozess. Die Analyzer- und
# Pester-Schritte brauchen -Command statt -File, deshalb die einheitliche Argumentliste statt
# zweier getrennter Aufrufwege.
$steps = @(
  [pscustomobject]@{
    Name  = 'Build'
    Label = 'Build-SingleFile'
    Args  = @('-NoProfile', '-File', (Join-Path $repoRoot 'build/Build-SingleFile.ps1'))
  }
  [pscustomobject]@{
    Name  = 'Static'
    Label = 'StaticChecks'
    Args  = @('-NoProfile', '-File', (Join-Path $repoRoot 'tests/StaticChecks.ps1'))
  }
  [pscustomobject]@{
    Name  = 'Smoke'
    Label = 'SmokeTest'
    Args  = @('-NoProfile', '-File', (Join-Path $repoRoot 'tests/SmokeTest.ps1'))
  }
  [pscustomobject]@{
    Name  = 'Layout'
    Label = 'LayoutProbe (7 Designs)'
    Args  = @('-NoProfile', '-File', (Join-Path $repoRoot 'tests/LayoutProbe.ps1'))
  }
  [pscustomobject]@{
    Name  = 'Pester'
    Label = 'Pester tests/Unit'
    # -PassThru liefert die Zahlen, die sonst nur im Fliesstext stehen. Der Exit-Code allein
    # unterscheidet nicht zwischen "keine Tests gefunden" und "alle gruen" - deshalb die
    # Marker-Zeile, die diese Kette wieder einliest.
    Args  = @('-NoProfile', '-Command', @'
$ErrorActionPreference = 'Stop'
$result = Invoke-Pester -Path (Join-Path $env:WT_REPO_ROOT 'tests/Unit') -Output Minimal -PassThru
"CHAIN_SUMMARY={0} passed, {1} failed, {2} skipped" -f $result.PassedCount, $result.FailedCount, $result.SkippedCount
if ($result.FailedCount -gt 0 -or $result.PassedCount -eq 0) { exit 1 }
'@)
  }
  [pscustomobject]@{
    Name  = 'AnalyzerSrc'
    Label = 'ScriptAnalyzer src/'
    # Blockierend ist alles ausser Information: die 5 informational in 65-Theme.ps1 sind
    # Altbestand und duerfen die Kette nicht rot faerben, sonst wird sie ignoriert.
    Args  = @('-NoProfile', '-Command', @'
$ErrorActionPreference = 'Stop'
$root = $env:WT_REPO_ROOT
$found = @(Invoke-ScriptAnalyzer -Path (Join-Path $root 'src') -Settings (Join-Path $root 'PSScriptAnalyzerSettings.psd1') -Recurse)
$blocking = @($found | Where-Object { $_.Severity -ne 'Information' })
$info = @($found | Where-Object { $_.Severity -eq 'Information' })
if ($blocking.Count -gt 0) { $blocking | Format-Table RuleName, Severity, ScriptName, Line -AutoSize | Out-String -Width 200 }
"CHAIN_SUMMARY={0} blockierend, {1} informational" -f $blocking.Count, $info.Count
if ($blocking.Count -gt 0) { exit 1 }
'@)
  }
  [pscustomobject]@{
    Name  = 'AnalyzerTests'
    Label = 'ScriptAnalyzer tests/'
    Args  = @('-NoProfile', '-Command', @'
$ErrorActionPreference = 'Stop'
$root = $env:WT_REPO_ROOT
$found = @(Invoke-ScriptAnalyzer -Path (Join-Path $root 'tests') -Settings (Join-Path $root 'PSScriptAnalyzerSettings.Tests.psd1') -Recurse)
$blocking = @($found | Where-Object { $_.Severity -ne 'Information' })
$info = @($found | Where-Object { $_.Severity -eq 'Information' })
if ($blocking.Count -gt 0) { $blocking | Format-Table RuleName, Severity, ScriptName, Line -AutoSize | Out-String -Width 200 }
"CHAIN_SUMMARY={0} blockierend, {1} informational" -f $blocking.Count, $info.Count
if ($blocking.Count -gt 0) { exit 1 }
'@)
  }
)

function Resolve-StepName {
  # Nimmt "Static,Pester" genauso wie @('Static','Pester') und liefert die Namen in der
  # Schreibweise der Tabelle zurueck. Gross-/Kleinschreibung ist egal, ein unbekannter Name ist
  # ein Fehler mit Aufzaehlung der erlaubten Namen - stiller Verwurf waere hier fatal, weil ein
  # vertippter Schrittname sonst als "Kette gruen" durchgeht.
  param([string[]]$Value, [string]$ParameterName, [string[]]$Known)

  $resolved = [System.Collections.Generic.List[string]]::new()
  foreach ($entry in @($Value)) {
    foreach ($token in ($entry -split ',')) {
      $trimmed = $token.Trim()
      if (-not $trimmed) { continue }
      $match = @($Known | Where-Object { $_ -eq $trimmed })
      if ($match.Count -eq 0) {
        throw ("-{0}: '{1}' ist kein Schritt. Erlaubt: {2}" -f $ParameterName, $trimmed, ($Known -join ', '))
      }
      $resolved.Add($match[0])
    }
  }
  return $resolved.ToArray()
}

$knownNames = @($steps.Name)
if ($Only) {
  $wanted = Resolve-StepName -Value $Only -ParameterName 'Only' -Known $knownNames
  $steps = @($steps | Where-Object { $wanted -contains $_.Name })
}
if ($Skip) {
  $unwanted = Resolve-StepName -Value $Skip -ParameterName 'Skip' -Known $knownNames
  $steps = @($steps | Where-Object { $unwanted -notcontains $_.Name })
}
if ($steps.Count -eq 0) { throw 'Nach -Only/-Skip bleibt kein Schritt uebrig.' }

# Die Kindprozesse finden das Repository ueber diese Variable. Ein relativer Pfad waere vom
# Arbeitsverzeichnis des Aufrufers abhaengig - und das ist beim Aufruf aus einem Editor oder
# einem Hook nicht das Repository.
$env:WT_REPO_ROOT = $repoRoot

# Ab PowerShell 7.4 steht $PSNativeCommandUseErrorActionPreference auf $true. Zusammen mit
# ErrorActionPreference='Stop' wuerde schon der erste Kindprozess mit Exit-Code 1 eine
# abbrechende Ausnahme werfen: die Kette waere beim ersten roten Schritt gestorben, ohne Tabelle
# und ohne die restlichen Schritte. Hier wird der Exit-Code selbst ausgewertet.
$PSNativeCommandUseErrorActionPreference = $false

$results = [System.Collections.Generic.List[object]]::new()
$aborted = $false

foreach ($step in $steps) {
  Write-Host ('--> {0}' -f $step.Label) -ForegroundColor Cyan
  $clock = [Diagnostics.Stopwatch]::StartNew()

  # stderr mit in die Ausgabe holen: die Pruefer schreiben Fehlertexte teils dorthin. Getrennt
  # eingesammelt stehen Ursache und Ort am Ende in falscher Reihenfolge im Protokoll.
  $output = (& $pwshPath @($step.Args) 2>&1 | Out-String)
  $exitCode = $LASTEXITCODE
  $clock.Stop()
  $seconds = [math]::Round($clock.Elapsed.TotalSeconds, 1)

  $summary = [regex]::Match($output, '(?m)^CHAIN_SUMMARY=(?<s>.*)$').Groups['s'].Value.Trim()
  if (-not $summary) {
    # Ohne Marker die letzte nicht-leere Zeile nehmen: StaticChecks und LayoutProbe melden ihr
    # Ergebnis dort ("Static checks passed ... 291 functions, 948 UI keys per language.").
    $lines = @($output -split "\r?\n" | Where-Object { $_.Trim() })
    if ($lines.Count -gt 0) { $summary = $lines[-1].Trim() }
  }

  $ok = ($exitCode -eq 0)
  $results.Add([pscustomobject]@{
      Name    = $step.Name
      Label   = $step.Label
      Ok      = $ok
      Seconds = $seconds
      Summary = $summary
    })

  if ($ok) {
    Write-Host ('    OK  {0}s  {1}' -f $seconds, $summary) -ForegroundColor Green
    if ($ShowOutput) { Write-Host $output }
  }
  else {
    Write-Host ('    FEHLGESCHLAGEN (Exit {0})' -f $exitCode) -ForegroundColor Red
    Write-Host $output
    if ($FailFast) { $aborted = $true; break }
  }
}

Write-Host ''
Write-Host 'Pruefkette' -ForegroundColor White
foreach ($entry in $results) {
  $mark = if ($entry.Ok) { 'OK  ' } else { 'FEHL' }
  $color = if ($entry.Ok) { 'Green' } else { 'Red' }
  Write-Host ('  [{0}] {1,-24} {2,6}s  {3}' -f $mark, $entry.Label, $entry.Seconds, $entry.Summary) -ForegroundColor $color
}

$ranNames = @($results.Name)
$notRun = @($steps | Where-Object { $ranNames -notcontains $_.Name })
if ($notRun.Count -gt 0) {
  Write-Host ('  nicht gelaufen: {0}' -f (@($notRun.Label) -join ', ')) -ForegroundColor Yellow
}

$failed = @($results | Where-Object { -not $_.Ok })
if ($failed.Count -gt 0 -or $aborted) {
  Write-Host ('{0} von {1} ausgefuehrten Schritten rot.' -f $failed.Count, $results.Count) -ForegroundColor Red
  exit 1
}

Write-Host ('Alle {0} Schritte gruen.' -f $results.Count) -ForegroundColor Green
exit 0
