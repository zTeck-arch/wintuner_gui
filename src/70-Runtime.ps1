# Logging function (thread-safe for WinForms event handlers)
function Write-Log {
  param([string]$message)
  if ([string]::IsNullOrWhiteSpace($message)) { return }

  try {
    $now = Get-Date
    $timestamp = $now.ToString("yyyy-MM-dd HH:mm:ss")
    $logLine = "$timestamp - $message"

    # Write to file
    try {
      $base = if ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation -and $MyInvocation.MyCommand -and $MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { (Get-Location).Path }
      if ([string]::IsNullOrWhiteSpace($base)) { $base = [Environment]::GetFolderPath('LocalApplicationData') }
      if (-not (Test-Path $base)) {
          try { New-Item -ItemType Directory -Path $base -Force | Out-Null } catch { return }
      }
      $isoYear = [System.Globalization.ISOWeek]::GetYear($now)
      $isoWeek = [System.Globalization.ISOWeek]::GetWeekOfYear($now)
      $logPath = Join-Path $base ("WinTuner_GUI_{0}-W{1:D2}.log" -f $isoYear, $isoWeek)
      # Keep UI/help actions in sync even if the application remains open across a week boundary.
      $script:logFilePath = $logPath

      Add-Content -Path $logPath -Value $logLine -Encoding utf8 -ErrorAction SilentlyContinue
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
    $base = if ($PSScriptRoot) { $PSScriptRoot } else { [Environment]::GetFolderPath('LocalApplicationData') }
    if ([string]::IsNullOrWhiteSpace($base)) { $base = [Environment]::GetFolderPath('LocalApplicationData') }
    if (-not (Test-Path $base)) { New-Item -ItemType Directory -Path $base -Force | Out-Null }
    $isoYear = [System.Globalization.ISOWeek]::GetYear($now)
    $isoWeek = [System.Globalization.ISOWeek]::GetWeekOfYear($now)
    $logPath = Join-Path $base ("WinTuner_GUI_{0}-W{1:D2}.log" -f $isoYear, $isoWeek)
    Add-Content -Path $logPath -Value $logLine -Encoding utf8 -ErrorAction SilentlyContinue
  } catch {}
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
function Update-Status {
  param([string]$status)
  $statusText = if ([string]::IsNullOrWhiteSpace($status)) { "" } else { $status }
  try {
    Invoke-UiAction -Control $script:statusLabel -Action {
      $script:statusLabel.Text = $statusText
    }
  } catch {
    # Keep status updates non-fatal even on cross-thread/disposed-control races
  }
  try {
    $safeLogger = Get-Command -Name Write-LogSafe -CommandType Function -ErrorAction SilentlyContinue
    if ($safeLogger) {
      & $safeLogger $status
    }
  } catch {}
}

# NOTE: there used to be an Invoke-AsyncOperation helper here that ran work on a
# System.ComponentModel.BackgroundWorker. It was removed because it never worked: a worker thread
# has no PowerShell runspace, so the scriptblock handed to it was not executed at all - not even
# its own try/catch. Callers received $null and could not tell that from a real result. That is
# what kept the dashboard tiles on "-" and made the self-update check report "up to date" for
# every release ever shipped. Everything long-running in this app therefore runs on the UI thread
# with Application::DoEvents to keep the window responsive; the packaging step, which needs no
# Graph context, uses a dedicated runspace (Get-PackageRunspace) instead.

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
      $null = @(Get-WtWin32Apps -Update:$false -Superseded:$false -ErrorAction Stop)
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
function Test-UiBusy {
  # Long-running handlers keep the shared progress bar visible. DoEvents makes the UI responsive,
  # so that visibility is also the cross-handler operation lock. packagingBusy covers the short
  # window before a build has made the progress bar visible.
  if (-not $script:packagingBusy -and (-not $script:progressBar -or -not $script:progressBar.Visible)) { return $false }
  Update-Status (Get-UiString 'BusyStatus')
  [void][System.Windows.Forms.MessageBox]::Show(
    (Get-UiString 'BusyDialog'),
    (Get-UiString 'InfoTitle'),
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Information)
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

