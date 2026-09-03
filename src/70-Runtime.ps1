# Logging function (thread-safe for WinForms event handlers)
# One writer at a time across processes. Add-Content opens, writes and closes without any lock, so
# two running instances interleave and can truncate each other's lines - which is exactly the kind
# of corruption that makes a log useless at the moment it is needed. A named mutex is cheap here:
# writes are short, and a caller that cannot get the lock within a second simply skips the file and
# still shows the line in the window.
$script:logMutex = $null
function Get-LogMutex {
  if ($script:logMutex) { return $script:logMutex }
  try { $script:logMutex = [System.Threading.Mutex]::new($false, 'WinTunerGUI_LogFile') } catch { $script:logMutex = $null }
  return $script:logMutex
}

# The one place that decides where the log file lives. Write-Log used to derive it from
# $PSScriptRoot, which put customer data next to the script - the Downloads folder for the
# documented way of running it - and quietly ignored the configured directory.
function Get-CurrentLogPath {
  param([datetime]$Now = (Get-Date))
  $base = if ($script:logDirectory) { $script:logDirectory } else { Get-LocalAppDataRoot }
  if (-not (Test-Path -LiteralPath $base)) {
    try { [void][System.IO.Directory]::CreateDirectory($base) } catch { return $null }
  }
  $isoYear = [System.Globalization.ISOWeek]::GetYear($Now)
  $isoWeek = [System.Globalization.ISOWeek]::GetWeekOfYear($Now)
  return (Join-Path $base ("WinTuner_GUI_{0}-W{1:D2}.log" -f $isoYear, $isoWeek))
}

function Write-Log {
  param([string]$message)
  if ([string]::IsNullOrWhiteSpace($message)) { return }

  try {
    $now = Get-Date
    $timestamp = $now.ToString("yyyy-MM-dd HH:mm:ss")
    $logLine = "$timestamp - $message"

    # Write to file
    try {
      $logPath = Get-CurrentLogPath -Now $now
      if ($logPath) {
        # Keep UI/help actions in sync even if the application remains open across a week boundary.
        $script:logFilePath = $logPath
        $mutex = Get-LogMutex
        $held = $false
        try {
          if ($mutex) {
            # A second is generous for appending one line. Timing out is not worth failing over:
            # the line still reaches the window, and the alternative is blocking the UI thread.
            try { $held = $mutex.WaitOne(1000) } catch [System.Threading.AbandonedMutexException] { $held = $true }
          }
          Add-Content -LiteralPath $logPath -Value $logLine -Encoding utf8 -ErrorAction SilentlyContinue
        } finally {
          if ($held) { try { $mutex.ReleaseMutex() } catch { } }
        }
      }
    } catch {
      # Silently ignore file write errors
    }

    # Update UI - always try to append (suppress any errors)
    if ($script:outputBox) {
      try {
        if ($script:outputBox.InvokeRequired) {
          # Cross-thread call - use Invoke
          $script:outputBox.Invoke([Action]{
            $script:outputBox.AppendText("$logLine`r`n")
          })
        } else {
          # Same thread - direct call
          $script:outputBox.AppendText("$logLine`r`n")
        }
      } catch {
        # Silently ignore UI update errors (threading issues)
      }
    }
  } catch {
    # Completely suppress all logging errors to prevent crashes
  }
}

# ---------------------------------------------------------------------------------------------
# ERROR-HANDLING POLICY (see the empty `catch {}` blocks throughout this file)
#
# Failures fall into three classes and are handled differently ON PURPOSE:
#
#  1. Operational  – anything that changes WHAT happens in Intune or WHICH apps are processed
#                    (deploy results, id resolution, winget lookups, selection sync, settings).
#                    These ALWAYS log via Write-Log. A silent failure here is a real defect:
#                    it looks like "the app is up to date" when in fact it was never checked.
#
#  2. Diagnostic   – theme, layout, menu styling, icons. A failure is cosmetic and must not spam
#                    the log during normal use, but it is useful when hunting a UI problem.
#                    These use Write-LogDebug, which only writes when diagnostics are enabled:
#                        set WINTUNER_GUI_DEBUG=1   (environment variable, per session)
#
#  3. Hard-silent  – Paint handlers and best-effort teardown (Disconnect-*, temp-file cleanup).
#                    Paint fires continuously, so logging from there would flood the log and can
#                    re-enter the logger; teardown failures have no consequence for the user.
#                    These keep a bare `catch {}` deliberately.
# ---------------------------------------------------------------------------------------------
$script:debugLogging = ($env:WINTUNER_GUI_DEBUG -eq '1')

# Class 2 logger – no-op unless WINTUNER_GUI_DEBUG=1, so cosmetic failures stay out of the log
# a technician reads, while still being recoverable when a UI problem has to be tracked down.
function Write-LogDebug {
  param([string]$Message)
  if (-not $script:debugLogging) { return }
  try { Write-Log "[debug] $Message" } catch { }
}

# Logging helper that never throws if Write-Log is unavailable in delegate scopes
function Write-LogSafe {
  param([string]$Message)
  if ([string]::IsNullOrWhiteSpace($Message)) { return }
  try {
    if (Get-Command -Name Write-Log -CommandType Function -ErrorAction SilentlyContinue) {
      & (Get-Command -Name Write-Log -CommandType Function) $Message
      return
    }
  } catch {}
  try {
    $now = Get-Date
    $timestamp = $now.ToString("yyyy-MM-dd HH:mm:ss")
    $logLine = "$timestamp - $Message"
    $base = if ($script:logDirectory) { $script:logDirectory } else { Get-LocalAppDataRoot }
    if (-not (Test-Path -LiteralPath $base)) { [void][System.IO.Directory]::CreateDirectory($base) }
    $isoYear = [System.Globalization.ISOWeek]::GetYear($now)
    $isoWeek = [System.Globalization.ISOWeek]::GetWeekOfYear($now)
    $logPath = Join-Path $base ("WinTuner_GUI_{0}-W{1:D2}.log" -f $isoYear, $isoWeek)
    # Same named mutex as Write-Log: a background runspace writing to the same file is exactly the
    # collision this guards against.
    $m = $null; $held = $false
    try {
      try { $m = [System.Threading.Mutex]::new($false, 'WinTunerGUI_LogFile'); $held = $m.WaitOne(1000) } catch { }
      Add-Content -LiteralPath $logPath -Value $logLine -Encoding utf8 -ErrorAction SilentlyContinue
    } finally {
      if ($held -and $m) { try { $m.ReleaseMutex() } catch { } }
      if ($m) { try { $m.Dispose() } catch { } }
    }
  } catch {}
}

# Rich, one-line error detail for the log. A bare .Message frequently hides WHICH kind of failure it
# was: a parameter-binding error, a Graph/HTTP error and a module race read very differently in a bug
# report, and the real cause often sits in an InnerException the top message never shows. Kept to a
# single greppable line: "[Type] message | inner[Type]: message | HTTP 403 | at line 512".
function Format-ErrorDetail {
  param([Parameter(Mandatory)]$ErrorRecord)
  try {
    $parts = @()
    $ex = $ErrorRecord.Exception
    if ($ex) {
      $parts += ("[{0}] {1}" -f $ex.GetType().Name, $ex.Message)
      $inner = $ex.InnerException
      $depth = 0
      while ($inner -and $depth -lt 3) {
        $parts += ("inner[{0}]: {1}" -f $inner.GetType().Name, $inner.Message)
        $inner = $inner.InnerException; $depth++
      }
    } else {
      $parts += [string]$ErrorRecord
    }
    $status = try { Get-ErrorHttpStatus -ErrorRecord $ErrorRecord } catch { 0 }
    if ($status -gt 0) { $parts += ("HTTP {0}" -f $status) }
    $inv = $ErrorRecord.InvocationInfo
    if ($inv -and $inv.ScriptLineNumber) { $parts += ("at line {0}" -f $inv.ScriptLineNumber) }
    return ($parts -join ' | ')
  } catch {
    # The detail formatter must never be the thing that throws while logging an error.
    try { return [string]$ErrorRecord.Exception.Message } catch { return [string]$ErrorRecord }
  }
}

# Runs an action on the UI thread if required
function Invoke-UiAction {
  param(
    [Parameter(Mandatory=$true)]
    [System.Windows.Forms.Control]$Control,
    [Parameter(Mandatory=$true)]
    [scriptblock]$Action
  )

  if (-not $Control) { return }
  if ($Control.IsDisposed) { return }

  if ($Control.InvokeRequired) {
    $Control.Invoke([Action]$Action)
  } else {
    & $Action
  }
}

# Status update function
# -NoLog ist fuer Zeilen, die sich SEKUENDLICH aendern.
#
# Gemessen an einem Protokoll vom 03.09.2026: eine einzige 429-Wartezeit (5 s + 15 s + 30 s)
# hinterliess ueber 50 Zeilen "The package source is throttling requests ... Retrying 3 in 29
# seconds...". Das Protokoll wandert in Tickets, und dort verdeckt so ein Countdown alles andere -
# der GRUND steht ohnehin schon in der Zeile davor ("Package source throttled ...; retry 1/3 after
# 5s"). Die Statuszeile soll weiterzaehlen, das Protokoll nicht.
function Update-Status {
  param([string]$status, [switch]$NoLog)
  $statusText = if ([string]::IsNullOrWhiteSpace($status)) { "" } else { $status }
  try {
    Invoke-UiAction -Control $script:statusLabel -Action {
      $script:statusLabel.Text = $statusText
    }
  } catch {
    # Keep status updates non-fatal even on cross-thread/disposed-control races
  }
  if ($NoLog) { return }
  try {
    $safeLogger = Get-Command -Name Write-LogSafe -CommandType Function -ErrorAction SilentlyContinue
    if ($safeLogger) {
      & $safeLogger $status
    }
  } catch {}
}

# Says so before the module downloads its 3.2 MB package index, and keeps quiet otherwise.
#
# The download is synchronous and runs on the UI thread, so the window stops repainting for its
# whole duration - measured at 130 seconds on 2026-08-21, during which the status line still read
# "Prüfe Favorit (1/4)" and the only explanation ("Loading package index from ...") went to the
# console, where a user of the shipped single file never looks. This does not make the window
# responsive - that would mean moving the call off the UI thread - it makes the wait explained,
# which is the difference between "it hangs" and "it is fetching something big".
#
# Runs at most once per session: after the first call the module holds the index in memory, so a
# second notice would be a lie.
$script:wingetIndexWarmed = $false
$script:wingetIndexWarmupStartedAt = $null
$script:wingetIndexBarState = $null
function Initialize-WingetPackageIndex {
  if ($script:wingetIndexWarmed) { return }
  $script:wingetIndexWarmed = $true
  $state = Test-WingetIndexCacheCold
  if (-not $state.Cold) {
    Write-LogDebug ("Winget package index cache is fresh ({0} h old); no download expected." -f $state.AgeHours)
    return
  }
  Write-Log ("Winget package index cache is {0} ({1}); the module will download it now. This blocks the window until it finishes." -f $state.Reason, $state.Path)
  $script:wingetIndexWarmupStartedAt = [datetime]::Now
  Update-Status (Get-UiString 'WingetIndexDownloading')
  # This runs INSIDE loops that drive the progress display themselves (the favourites run counts its
  # packages up). Borrowing it without putting it back left those loops without an indicator for the
  # rest of the run, so the previous state is saved and restored rather than overwritten.
  # progress-restored-elsewhere: Complete-WingetPackageIndexWarmup stellt den gemerkten Zustand
  # wieder her - hier darf NICHT ausgeblendet werden, weil dieser Aufwaermer INNERHALB von Laeufen
  # laeuft, die die Anzeige selbst fuehren (die Favoritenrunde zaehlt ihre Pakete hoch).
  if ($script:progressLabel) {
    $script:wingetIndexBarState = @{
      Total   = $script:progressTotal
      Current = $script:progressCurrent
      Visible = $script:progressLabel.Visible
    }
    Show-Progress
  }
  # Repaints the status line and the progress text before the thread goes away for a minute or two. Without
  # this the new text never reaches the screen and the notice is worthless.
  try { [System.Windows.Forms.Application]::DoEvents() } catch { }
}

# Puts the bar back and records how long the download actually took, so the next report is not
# guesswork. Silent unless a download was announced.
function Complete-WingetPackageIndexWarmup {
  if (-not $script:wingetIndexWarmupStartedAt) { return }
  $elapsed = ([datetime]::Now - $script:wingetIndexWarmupStartedAt).TotalSeconds
  $script:wingetIndexWarmupStartedAt = $null
  if ($script:progressLabel -and $script:wingetIndexBarState) {
    $script:progressTotal = [int]$script:wingetIndexBarState.Total
    $script:progressCurrent = [int]$script:wingetIndexBarState.Current
    Update-ProgressDisplay
    $script:progressLabel.Visible = [bool]$script:wingetIndexBarState.Visible
  }
  $script:wingetIndexBarState = $null
  Write-Log ("Winget package index ready after {0:n1} s." -f $elapsed)
}

# NOTE: there used to be an Invoke-AsyncOperation helper here that ran work on a
# System.ComponentModel.BackgroundWorker. It was removed because it never worked: a worker thread
# has no PowerShell runspace, so the scriptblock handed to it was not executed at all - not even
# its own try/catch. Callers received $null and could not tell that from a real result. That is
# what kept the dashboard tiles on "-" and made the self-update check report "up to date" for
# every release ever shipped.
#
# Was daraus lange abgeleitet wurde - "Nebenlaeufigkeit geht hier nicht" - stimmt so NICHT, und das
# ist gemessen: [Microsoft.Graph.PowerShell.Authentication.GraphSession]::Instance ist ein
# statisches Singleton, ein zweiter Runspace im selben Prozess sieht also dieselbe Anmeldung
# (siehe tests/Unit/GraphSessionSharing.Tests.ps1). Der BackgroundWorker scheiterte am fehlenden
# RUNSPACE, nicht am Graph-Kontext. Ein echter Runspace hat beides.
#
# Ausgelagert ist bisher: das Paketieren (Get-PackageRunspace) und die Inventar-Abfrage
# (Get-Win32AppsOffThread), die laengste Blockade. Alles Uebrige laeuft weiterhin auf dem
# UI-Thread mit Application::DoEvents - Schritt fuer Schritt, jeweils mit Rueckfall.

# Der Leerzustand einer Liste sagt jetzt, WARUM sie leer ist.
#
# Bisher stand dort immer "auf Suchen klicken, um zu laden" - auch ohne Anmeldung, wo genau das
# nicht geht. Der Klick fuehrte dann zu einem Anmelde-Dialog, also erst nach dem Versuch. Der
# Zustand gehoert vor den Klick, und die Stelle dafuer ist die Flaeche, auf die man sowieso schaut.
#
# Die Knoepfe bleiben absichtlich bedienbar (siehe Set-ConnectedUIState): sie sollen angemeldet und
# abgemeldet gleich aussehen. Diese Funktion ergaenzt das, statt es umzudrehen.
function Set-ListEmptyText {
  param(
    [System.Windows.Forms.Label]$Label,
    [Parameter(Mandatory)][string]$NormalKey
  )
  if (-not $Label) { return }
  try {
    $Label.Text = if ($script:isConnected) { Get-UiString $NormalKey } else { Get-UiString 'NotConnectedListHint' }
  } catch { }   # class 3: ein Leerzustandstext darf nie eine Sektion aufhalten
}

# Friendly tenant name from a UPN: adm@alsterspree.de -> "Alsterspree" (full UPN shown on hover).
# Picks the label that actually identifies the customer.
#
# The first label is only right for the *.onmicrosoft.com default domains, where the tenant name
# IS that label (contoso.onmicrosoft.com -> Contoso). For a real domain it is misleading: a UPN
# under microsoft.demomehr.de showed "Microsoft" - the name of a subdomain, not the customer.
# For those the registrable label is what identifies the tenant (demomehr.de -> Demomehr).
function Get-TenantDisplayName {
  param([string]$Upn)
  if ([string]::IsNullOrWhiteSpace($Upn)) { return "" }
  # A name the technician set by hand wins over everything derived below: they know what they call
  # this customer, and the derivation is only ever a guess from the domain.
  try {
    $manual = $script:settings.TenantDisplayNames
    if ($manual -and $manual.ContainsKey($Upn)) {
      $chosen = [string]$manual[$Upn]
      if (-not [string]::IsNullOrWhiteSpace($chosen)) { return $chosen }
    }
  } catch { }   # class 3: a broken name map must never stop a label from rendering
  try {
    $domain = ($Upn -split '@')[-1]
    $labels = @($domain -split '\.' | Where-Object { $_ })
    if ($labels.Count -eq 0) { return $Upn }

    $name = $null
    if ($domain -match '(?i)\.onmicrosoft\.[a-z]+$') {
      $name = $labels[0]
    } elseif ($labels.Count -ge 2) {
      # Second-to-last label: the registrable name in front of the top-level domain. Handles both
      # demomehr.de and microsoft.demomehr.de.
      $offset = 2
      # Two-part public suffixes shift that by one, otherwise example.co.uk would read as "Co".
      # Not the full public-suffix list - just the ones a customer domain realistically uses.
      $twoPartSuffixes = @('co.uk', 'org.uk', 'ac.uk', 'gov.uk', 'com.au', 'net.au', 'org.au',
                           'co.nz', 'co.za', 'co.jp', 'com.br', 'com.mx', 'com.tr')
      if ($labels.Count -ge 3) {
        $lastTwo = ($labels[$labels.Count - 2] + '.' + $labels[$labels.Count - 1]).ToLowerInvariant()
        if ($twoPartSuffixes -contains $lastTwo) { $offset = 3 }
      }
      $name = $labels[$labels.Count - $offset]
    } else {
      $name = $labels[0]
    }
    if ($name) { return ($name.Substring(0,1).ToUpper() + $name.Substring(1)) }
  } catch { Write-LogDebug ("Tenant display name: {0}" -f $_.Exception.Message) }
  return $Upn
}

# Replaces tenant data in log text with STABLE pseudonyms so a log can be attached to a bug report
# without leaking customer identifiers. Stable = the same input maps to the same pseudonym within the
# text, so the relationships needed for diagnosis survive. Covers UPNs, GUIDs (Intune app / Entra
# group ids), the Windows user name and the user profile path.
function Get-SanitizedLogText {
  param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [string]$UserName = $env:USERNAME, [string]$UserProfile = $env:USERPROFILE)
  if ([string]::IsNullOrEmpty($Text)) { return $Text }

  $maps = @{ user = @{}; id = @{} }
  $counters = @{ user = 0; id = 0 }
  $pseudonym = {
    param($category, $value)
    $m = $maps[$category]
    if (-not $m.ContainsKey($value)) { $counters[$category]++; $m[$value] = "$category-$($counters[$category])" }
    return $m[$value]
  }

  # 1) User profile path first (literal), before the user name inside it is touched separately.
  if (-not [string]::IsNullOrWhiteSpace($UserProfile)) {
    $Text = $Text.Replace($UserProfile, 'C:\Users\user-profile')
  }
  # 2) UPNs (contain '@' and the domain) -> user-N. Case-insensitive, stable per distinct UPN.
  $upn = '(?i)[A-Za-z0-9._%+\-]+@(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}'
  $Text = [regex]::Replace($Text, $upn, { param($m) & $pseudonym 'user' $m.Value.ToLowerInvariant() })
  # 3) GUIDs -> id-N.
  $guid = '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b'
  $Text = [regex]::Replace($Text, $guid, { param($m) & $pseudonym 'id' $m.Value.ToLowerInvariant() })
  # 4) The bare Windows user name (whole word), last so it does not disturb the UPN match above.
  if (-not [string]::IsNullOrWhiteSpace($UserName)) {
    $Text = [regex]::Replace($Text, ('(?i)\b' + [regex]::Escape($UserName) + '\b'), 'user-name')
  }
  return $Text
}

# Helper: validate M365 username (UPN-like)
function Test-ValidM365UserName {
  param([string]$UserName)
  if ([string]::IsNullOrWhiteSpace($UserName)) { return $false }
  # Balanced, pragmatic UPN check
  $upnRegex = '^(?=.{3,256}$)(?![.])(?!.*[.]{2})[A-Za-z0-9._%+\-]+@(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}$'
  return ($UserName -match $upnRegex)
}

# Helper: check if WinTuner is connected (simple smoke test).
# The reason for a failure is kept in $script:lastConnectionProbeError. Swallowing it silently
# made every cause - Graph outage, timeout, missing permission - surface as "Authentication error",
# which sent troubleshooting in the wrong direction even though the sign-in itself had worked.
function Test-WtConnected {
  param([int]$Attempts = 3)
  $script:lastConnectionProbeError = $null
  for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
    try {
      # Materialised right here with @(): the module hands back a collection it may still be
      # filling, and enumerating that live is what produced "Collection was modified" during
      # sign-in. Select-Object -First 1 is still avoided - it crashed the pipeline under WinForms.
      # Deliberately NOT Get-Win32AppsResilient: this function IS the retry loop (see $Attempts), it
      # runs before 25-WinGetData's state is meaningful, and it must report the raw failure reason
      # rather than swallow it into a retry - the caller classifies the message.
      $null = @(Get-WtWin32Apps -Superseded:$false -ErrorAction Stop)
      $script:lastConnectionProbeError = $null
      return $true   # the query itself worked; an empty tenant is a valid answer
    } catch {
      $probeError = $_.Exception.Message
      $script:lastConnectionProbeError = $probeError
      Write-LogSafe ("Sign-in succeeded, but the first Intune query failed (attempt {0}/{1}): {2}" -f $attempt, $Attempts, $probeError)
      # These shapes say "ask again", not "you are not signed in": a race inside the module/Graph
      # SDK, throttling, or a momentary service blip. Turning them into a hard authentication error
      # sent troubleshooting after credentials that were never the problem. Anything else - a
      # missing permission, for example - still fails immediately, because retrying cannot fix it.
      $transient = (
        $probeError -match 'Collection was modified' -or
        # Observed in the same session as "Collection was modified", moments apart, on a sign-in
        # that then worked on a manual retry: both are races inside the module's inventory call,
        # not a statement about the session. Without this the user had to click Login again.
        $probeError -match "Value cannot be null" -or
        $probeError -match 'timed out' -or
        $probeError -match 'ServiceUnavailable' -or
        $probeError -match 'temporarily unavailable' -or
        $probeError -match 'Too Many Requests' -or
        $probeError -match '\b(429|500|503|504)\b')
      if (-not $transient -or $attempt -eq $Attempts) { return $false }
      # DoEvents keeps the window alive during the pause, like the other post-deploy waits.
      for ($second = 0; $second -lt (2 * $attempt); $second++) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Seconds 1
      }
    }
  }
  return $false
}

# Heuristic filter to avoid very slow/low-value WinGet queries (mainly mobile/system artifacts)
function Test-WingetSearchCandidate {
  param(
    [string]$DisplayName
  )

  if ([string]::IsNullOrWhiteSpace($DisplayName)) { return $false }
  $name = $DisplayName.Trim()
  if ($name.Length -lt 3) { return $false }

  # Android-style package ids and similar technical identifiers are typically not useful for WinGet search
  if ($name -match '^[a-z0-9]+(\.[a-z0-9_]+){2,}$') { return $false }
  if ($name -match '(?i)^com\.') { return $false }

  # Skip common mobile/system terms that frequently stall searches and rarely map to WinGet packages
  if ($name -match '(?i)\b(apn|provisioner|sim toolkit|sim card|carrier services|system ui|one ui home|setup wizard)\b') { return $false }

  return $true
}

# Guard for tenant actions: instead of disabling the action buttons while signed out (which made
# them look muted/worse than when signed in), the buttons now always look active. Each tenant
# action calls this first – if not connected it shows a "please sign in" popup and the caller
# returns, so nothing runs against a missing Graph session.
# Re-entrancy guard, introduced together with background packaging: while a build runs the UI
# thread keeps pumping messages (that is the whole point), so the user can now click other actions
# mid-run - something that was impossible while the thread was blocked. Every handler that starts a
# long operation or changes Intune asks here first.
# Actions that were asked for while another operation was running, to be carried out afterwards.
#
# Keyed and therefore de-duplicated: asking for the same thing three times queues it once. Insertion
# order is preserved so the first request is also the first to run.
$script:deferredActions = [ordered]@{}
$script:deferredRunning = $false
# Set around a trigger the USER did not click - the login-time update check, the favourites run.
# Those must never open a modal dialog: nobody is looking at the screen for them, and a message box
# nobody dismisses stops the whole application until someone walks past.
$script:automaticTrigger = $false

function Add-DeferredAction {
  param(
    [Parameter(Mandatory)][string]$Key,
    [Parameter(Mandatory)][scriptblock]$Action,
    [string]$Label = ''
  )
  $script:deferredActions[$Key] = @{ Label = $Label; Action = $Action }
}

# True while an operation owns the UI. Split out of Test-UiBusy so the deferred-action pump can ask
# the same question without producing a status line or a dialog as a side effect.
function Test-OperationRunning {
  if ($script:packagingBusy) { return $true }
  if (Test-ProgressVisible) { return $true }
  return $false
}

# Runs at most ONE queued action per call, and only while nothing else is running.
#
# One per call on purpose: an action typically makes the UI busy again immediately, and the next one
# has to wait for that in turn. The timer in 90-Main calls this again a moment later.
function Invoke-PendingDeferredActions {
  if ($script:deferredActions.Count -eq 0) { return }
  if (Test-OperationRunning) { return }
  # The timer also ticks inside the DoEvents of a running operation, and an action can itself pump
  # DoEvents - without this guard the pump would re-enter itself and run the same action twice.
  if ($script:deferredRunning) { return }

  $script:deferredRunning = $true
  try {
    $key = @($script:deferredActions.Keys)[0]
    $entry = $script:deferredActions[$key]
    [void]$script:deferredActions.Remove($key)
    $name = if ($entry.Label) { [string]$entry.Label } else { $key }
    Write-Log ("Deferred action now running: {0}" -f $name)
    try { & $entry.Action } catch {
      Write-Log ("Deferred action '{0}' failed: {1}" -f $name, (Format-ErrorDetail -ErrorRecord $_))
    }
  } finally {
    $script:deferredRunning = $false
  }
}

# Answers "is another operation running?" and, when one is, decides what happens to the request.
#
# Long-running handlers keep the shared progress bar visible. DoEvents makes the UI responsive, so
# that visibility is also the cross-handler operation lock. packagingBusy covers the short window
# before a build has made the progress bar visible.
#
# Passing -DeferKey/-DeferAction turns "refused" into "queued": the request is carried out as soon as
# the running operation finishes, instead of being thrown away. That matters most for the login-time
# update check, which used to collide with the start-up favourites build and was simply lost - the
# log said "another operation is running" at 08:39:26 and nothing ever picked it up again, so the
# technician waited for a scan that was never going to happen.
#
# Deferring is offered ONLY for read-only work (searching, refreshing). An action that writes to
# Intune stays refused, because running a deploy or a deletion minutes later, unattended, when the
# user has moved on to something else, is worse than making them click again.
function Test-UiBusy {
  param(
    [string]$DeferKey,
    [scriptblock]$DeferAction,
    [string]$DeferLabel = ''
  )
  if (-not (Test-OperationRunning)) { return $false }

  if ($DeferKey -and $DeferAction) {
    Add-DeferredAction -Key $DeferKey -Action $DeferAction -Label $DeferLabel
    $name = if ($DeferLabel) { [string]$DeferLabel } else { [string]$DeferKey }
    $text = (Get-UiString 'BusyDeferred') -f $name
    Update-Status $text
    Write-Log ("Deferred until the running operation finishes: {0}" -f $name)
    # No dialog for an automatic trigger, and none for a deferred request either: the status line
    # already says it will happen, and the point of queueing is that nobody has to acknowledge it.
    return $true
  }

  Update-Status (Get-UiString 'BusyStatus')
  if (-not $script:automaticTrigger) {
    [void][System.Windows.Forms.MessageBox]::Show(
      (Get-UiString 'BusyDialog'),
      (Get-UiString 'InfoTitle'),
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Information)
  }
  return $true
}

function Test-Connected {
  if ($script:isConnected) { return $true }
  [void][System.Windows.Forms.MessageBox]::Show(
    (Get-UiString 'LoginFirstDialog'),
    (Get-UiString 'InfoTitle'),
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Information)
  return $false
}
# ---------------------------------------------------------------------------------------------
# Manual tenant names, on top of the automatic derivation in Get-TenantDisplayName above.
#
# An MSP signs in to a dozen tenants whose UPNs all look the same, and the derived name is not
# always the one the technician uses ("Demomehr" when everyone says "Stadtwerke"). A name set here
# wins over the derivation - but the UPN must stay visible, because that is what actually gets
# signed in, and picking the wrong customer is the one mistake this tool must never make easy.
# ---------------------------------------------------------------------------------------------
# "Kunde GmbH (admin@kunde.de)" when a name is set, otherwise just the UPN - never a label that
# hides which account is meant.
function Get-TenantDisplayLabel {
  param([string]$Upn)
  if ([string]::IsNullOrWhiteSpace($Upn)) { return '' }
  $name = Get-TenantDisplayName -Upn $Upn
  if ([string]::Equals($name, $Upn, [System.StringComparison]::OrdinalIgnoreCase)) { return $Upn }
  return ('{0} ({1})' -f $name, $Upn)
}

function Set-TenantDisplayName {
  param([Parameter(Mandatory)][string]$Upn, [string]$Name = '')
  if ([string]::IsNullOrWhiteSpace($Upn)) { return }
  if ($null -eq $script:settings.TenantDisplayNames) { $script:settings.TenantDisplayNames = @{} }
  if ([string]::IsNullOrWhiteSpace($Name)) {
    if ($script:settings.TenantDisplayNames.ContainsKey($Upn)) { [void]$script:settings.TenantDisplayNames.Remove($Upn) }
  } else {
    $script:settings.TenantDisplayNames[$Upn] = $Name.Trim()
  }
}

# ---------------------------------------------------------------------------------------------
# Confirmation prompts that an experienced technician may switch off.
#
# The prompts exist for a reason, so switching them off is acknowledged once per version (see
# ChangeConfirmationRiskAcceptedVersion) rather than being a quiet checkbox. What is suppressed is
# the "are you sure you want to change this?" class. Two things are NEVER suppressed, because they
# are a different kind of risk than "I meant to do this to the tenant":
#   - the one-time production-risk warning at startup
#   - installing an installer locally on the technician's own machine
# ---------------------------------------------------------------------------------------------
function Test-ChangeConfirmationsSuppressed {
  if (-not $script:settings.SuppressChangeConfirmations) { return $false }
  # Only honoured once the risk has been acknowledged for THIS version, so a settings file carried
  # over from an older release cannot silently disable the prompts after an update.
  return [string]::Equals([string]$script:settings.ChangeConfirmationRiskAcceptedVersion, [string]$script:appVersion, [System.StringComparison]::OrdinalIgnoreCase)
}

# Drop-in replacement for a Yes/No MessageBox on a change. Returns $true when the action may proceed.
# -AlwaysAsk: diese Frage wird NICHT von der Einstellung "Rueckfragen abschalten" weggedrueckt.
#
# Gemeldet fuer die Zuweisungen in "Alle Tenant-Apps": wer dort das Ziel einer App aendert, aendert,
# WER die App bekommt - und das soll nie eine Nebenwirkung eines Klicks sein. Die Einstellung nimmt
# einem die Rueckfragen fuer die eigene Routine ab (Update-Lauf starten, Inhalt ersetzen); die
# Reichweite einer App gehoert nicht dazu.
function Confirm-ChangeAction {
  param(
    [Parameter(Mandatory)][string]$Text,
    [Parameter(Mandatory)][string]$Title,
    [string]$LogContext = '',
    [switch]$AlwaysAsk
  )
  if (-not $AlwaysAsk -and (Test-ChangeConfirmationsSuppressed)) {
    $what = if ($LogContext) { $LogContext } else { $Title }
    Write-Log ("Confirmation skipped (prompts switched off in Settings): {0}" -f $what)
    return $true
  }
  $answer = [System.Windows.Forms.MessageBox]::Show(
    $Text, $Title,
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Warning)
  return ($answer -eq [System.Windows.Forms.DialogResult]::Yes)
}

# Die eine Rueckfrage, die "Rueckfragen abschalten" NICHT abschalten darf.
#
# Geschuetzte Apps sind selbst paketierte Kundensoftware. Ein Update loest sie ab und zieht die
# Zuweisungen mit - bei einem Paket, das niemand schnell nachbaut, ist ein Fehlgriff der
# Totalverlust. Wer "Bestaetigungen unterdruecken" gesetzt hat, hat das fuer den Alltag getan
# (zwei Chrome-Updates), nicht fuer diesen Fall; deshalb -AlwaysAsk.
#
# Trennt eine Auswahl in geschuetzte und uebrige Apps. Eine Stelle fuer die Frage "ist diese App
# geschuetzt?", damit Rueckfrage, Protokoll und die tatsaechlich laufende Liste nie auseinandergehen.
function Split-ProtectedApps {
  param([AllowNull()][AllowEmptyCollection()][object[]]$Apps)
  $protected = @()
  $rest = @()
  foreach ($a in @($Apps)) {
    if (-not $a) { continue }
    if ($a.PSObject.Properties['IsProtected'] -and $a.IsProtected) { $protected += $a } else { $rest += $a }
  }
  return @{ Protected = @($protected); Unprotected = @($rest) }
}

# Was aus der Antwort des Benutzers folgt - als reine Rechnung, ohne Fenster.
#
# 'all'    alles laeuft, geschuetzte eingeschlossen
# 'skip'   die geschuetzten fallen raus, der Rest laeuft
# 'cancel' nichts laeuft
#
# Der Sonderfall, der sonst als "abgebrochen" durchginge: waren AUSSCHLIESSLICH geschuetzte Apps
# angehakt, bleibt bei 'skip' nichts uebrig. Das ist kein Abbruch durch den Benutzer, und die
# Meldung darf nicht so tun - er hat gewaehlt, es gab nur nichts mehr zu tun.
function Resolve-ProtectedRunChoice {
  param(
    [AllowNull()][AllowEmptyCollection()][object[]]$Apps,
    [ValidateSet('all', 'skip', 'cancel')][string]$Choice
  )
  $split = Split-ProtectedApps -Apps $Apps
  switch ($Choice) {
    'all' { return @{ Proceed = $true; Apps = @($Apps); Skipped = @(); Reason = 'all' } }
    'skip' {
      $kept = @($split.Unprotected)
      if ($kept.Count -eq 0) {
        return @{ Proceed = $false; Apps = @(); Skipped = @($split.Protected); Reason = 'empty' }
      }
      return @{ Proceed = $true; Apps = $kept; Skipped = @($split.Protected); Reason = 'skip' }
    }
    default { return @{ Proceed = $false; Apps = @(); Skipped = @(); Reason = 'cancel' } }
  }
}

# Ohne geschuetzte App kostet der Normalfall keinen Klick: dann wird nichts gefragt und die Liste
# geht unveraendert weiter.
#
# Mit geschuetzten Apps gibt es DREI Wege statt Ja/Nein. Der Grund ist der haeufigste reale Fall:
# zehn Apps angehakt, zwei davon geschuetzt uebersehen. Bei einer Ja/Nein-Frage muss man abbrechen,
# die zwei abwaehlen und von vorn anfangen - die Rueckfrage kostet dann mehr, als sie bringt, und
# genau so gewoehnt man sich an, sie wegzuklicken.
function Confirm-ProtectedAppsInRun {
  param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Apps)
  $split = Split-ProtectedApps -Apps $Apps
  $protected = @($split.Protected)
  if ($protected.Count -eq 0) {
    return @{ Proceed = $true; Apps = @($Apps); Skipped = @(); Reason = 'none' }
  }
  $preview = (@($protected | Select-Object -First 15 | ForEach-Object {
    "- {0}: {1} -> {2}" -f [string]$_.Name, [string]$_.CurrentVersion, [string]$_.LatestVersion
  }) -join "`r`n")
  if ($protected.Count -gt 15) { $preview += "`r`n- ..." }
  # Namentlich ins Protokoll: "3 geschuetzte Apps" beantwortet im Nachhinein nicht die Frage, WELCHE
  # freigegeben wurden - und genau die wird nach einem Fehlgriff gestellt.
  Write-Log ("Update run contains {0} protected app(s), asking for an explicit confirmation regardless of the suppression setting: {1}" -f `
    $protected.Count, ((@($protected | ForEach-Object { [string]$_.Name })) -join ', '))

  # Eigener Dialog statt Confirm-ChangeAction: drei Wege brauchen drei beschriftete Knoepfe.
  # "Ja/Nein/Abbrechen" einer MessageBox sagt nicht, WAS ja bedeutet. Dass diese Frage von
  # "Rueckfragen abschalten" nicht unterdrueckt wird, ergibt sich hier von selbst - der Dialog
  # geht gar nicht erst durch Confirm-ChangeAction.
  $choice = Show-ProtectedRunDialog -Count $protected.Count -Preview $preview
  $result = Resolve-ProtectedRunChoice -Apps $Apps -Choice $choice

  switch ($result.Reason) {
    'all' {
      Write-Log ("Protected apps confirmed for this run: {0} app(s) will be superseded." -f $protected.Count)
    }
    'skip' {
      Write-Log ("Protected apps left out of this run ({0}): {1}. Continuing with {2} app(s)." -f `
        $protected.Count, ((@($protected | ForEach-Object { [string]$_.Name })) -join ', '), @($result.Apps).Count)
    }
    'empty' {
      Write-Log 'Only protected apps were selected and the user chose to leave them out; nothing was built or uploaded.'
    }
    default {
      Write-Log 'Update run canceled at the protected-apps confirmation; nothing was built or uploaded.'
    }
  }
  return $result
}

# Laeuft dieser Start unbeaufsichtigt, also als Prueflauf ohne Benutzer?
#
# Beide Kennungen an EINER Stelle, und das ist keine Kosmetik: die erste Fassung fragte nur
# WINTUNER_SMOKE ab, worauf die Layout-Probe (WINTUNER_LAYOUT) genau in denselben Dialog lief und
# nach 240 s abbrach. Ein neuer Pruefkopf braucht deshalb nur hier eine Zeile.
function Test-UnattendedRun {
  return (($env:WINTUNER_SMOKE -eq '1') -or ($env:WINTUNER_LAYOUT -eq '1'))
}

# Modaler Hinweis WAEHREND des Starts - im Pruefmodus nur protokolliert statt angezeigt.
#
# Genau daran hing der CI-Lauf von 0.16.0: auf einem Rechner ohne installiertes WinTuner-Modul
# schlaegt Import-Module fehl, und der Fehlerzweig zeigte direkt eine MessageBox. Ein Lauf ohne
# Benutzer klickt sie nie weg - Smoke-Test und Layout-Probe liefen in ihren Zeitablauf (180 s bzw.
# 240 s), und zwar nur auf dem Laeufer, weil auf dem Entwicklungsrechner das Modul da ist. Fuer
# echte Starts bleibt der Dialog unveraendert: er ist die einzige Stelle, an der ein Benutzer von
# dem Problem erfaehrt.
#
# Die Regel dahinter steht in tests/StaticChecks.ps1: vor dem Smoke-Tor darf auf der obersten Ebene
# keine MessageBox mehr direkt aufgerufen werden.
function Show-StartupDialog {
  param(
    [Parameter(Mandatory)][string]$Text,
    [Parameter(Mandatory)][string]$Title,
    [System.Windows.Forms.MessageBoxIcon]$Icon = [System.Windows.Forms.MessageBoxIcon]::Information
  )
  if (Test-UnattendedRun) {
    # Auf die Standardausgabe, nicht auf den Fehlerkanal: der Smoke-Test wertet eine nicht leere
    # Fehlerausgabe als misslungenen Start.
    Write-Host ("STARTUP DIALOG [{0}] {1}" -f $Title, (($Text -replace '\s+', ' ').Trim()))
    return
  }
  [void][System.Windows.Forms.MessageBox]::Show(
    $Text, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, $Icon)
}
