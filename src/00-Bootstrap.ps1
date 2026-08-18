# WinTuner GUI
#
# Copyright (C) 2026 Timo Schnabel, Lion Laurisch
#
# This program is free software: you can redistribute it and/or modify it under the terms of
# the GNU General Public License as published by the Free Software Foundation, either version
# 3 of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
# without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
# See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with this program.
# If not, see <https://www.gnu.org/licenses/>.
#
# Source code: https://github.com/zTeck-arch/wintuner_gui
#
# v0.15.6 - Public beta
# --- Guided prerequisite bootstrap (kept console-only so it also works in Windows PowerShell 5.1) ---
$minimumPowerShellVersion = [version]'7.4'
try { $psVersion = [version]$PSVersionTable.PSVersion } catch { $psVersion = [version]'0.0' }
$startupLanguage = if ([Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'de') { 'de' } else { 'en' }

if ($psVersion -lt $minimumPowerShellVersion) {
  Write-Host ''
  Write-Host ('=' * 72) -ForegroundColor DarkCyan
  if ($startupLanguage -eq 'de') {
    Write-Host 'WinTuner GUI kann noch nicht gestartet werden.' -ForegroundColor Yellow
    Write-Host ("Installiert: PowerShell {0} | Benötigt: PowerShell {1} oder neuer" -f $psVersion, $minimumPowerShellVersion)
    Write-Host 'PowerShell 7 wird parallel zu Windows PowerShell installiert und ersetzt diese nicht.'
    Write-Host ''
    Write-Host '[1] PowerShell 7 jetzt mit WinGet installieren/aktualisieren (empfohlen)'
    Write-Host '[2] Offizielle Microsoft-Installationsanleitung öffnen'
    Write-Host '[3] Beenden'
    $startupChoice = try { Read-Host 'Auswahl [1-3]' } catch { '3' }
  } else {
    Write-Host 'WinTuner GUI cannot start yet.' -ForegroundColor Yellow
    Write-Host ("Installed: PowerShell {0} | Required: PowerShell {1} or newer" -f $psVersion, $minimumPowerShellVersion)
    Write-Host 'PowerShell 7 is installed side-by-side and does not replace Windows PowerShell.'
    Write-Host ''
    Write-Host '[1] Install/update PowerShell 7 with WinGet now (recommended)'
    Write-Host '[2] Open the official Microsoft installation guide'
    Write-Host '[3] Exit'
    $startupChoice = try { Read-Host 'Select [1-3]' } catch { '3' }
  }

  if ($startupChoice -eq '2') {
    try {
      Start-Process 'https://learn.microsoft.com/powershell/scripting/install/install-powershell-on-windows' -ErrorAction Stop
    } catch {
      Write-Host $_.Exception.Message -ForegroundColor Red
    }
    return
  }

  if ($startupChoice -ne '1') { return }

  $wingetCommand = Get-Command winget.exe -ErrorAction SilentlyContinue
  if (-not $wingetCommand) {
    if ($startupLanguage -eq 'de') {
      Write-Host 'WinGet wurde nicht gefunden. Bitte installieren Sie PowerShell 7 über die offizielle Microsoft-Anleitung.' -ForegroundColor Red
    } else {
      Write-Host 'WinGet was not found. Install PowerShell 7 using the official Microsoft guide.' -ForegroundColor Red
    }
    try { Start-Process 'https://learn.microsoft.com/powershell/scripting/install/install-powershell-on-windows' -ErrorAction SilentlyContinue } catch {}
    return
  }

  if ($startupLanguage -eq 'de') {
    Write-Host 'PowerShell 7 wird installiert bzw. aktualisiert. Ein Windows-Dialog kann eine Bestätigung anfordern ...' -ForegroundColor Cyan
  } else {
    Write-Host 'Installing or updating PowerShell 7. Windows may ask for confirmation ...' -ForegroundColor Cyan
  }

  & $wingetCommand.Source install --id Microsoft.PowerShell --source winget --exact --force --accept-source-agreements --accept-package-agreements
  $wingetExitCode = $LASTEXITCODE
  if ($wingetExitCode -ne 0) {
    if ($startupLanguage -eq 'de') {
      Write-Host ("Die PowerShell-Installation ist fehlgeschlagen (WinGet-Code {0})." -f $wingetExitCode) -ForegroundColor Red
    } else {
      Write-Host ("PowerShell installation failed (WinGet code {0})." -f $wingetExitCode) -ForegroundColor Red
    }
    return
  }

  # WinGet may not refresh PATH in the current process, so also inspect the canonical MSI path.
  $pwshCandidates = @()
  $pwshCommand = Get-Command pwsh.exe -ErrorAction SilentlyContinue
  if ($pwshCommand) { $pwshCandidates += $pwshCommand.Source }
  if ($env:ProgramFiles) { $pwshCandidates += (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe') }
  $pwshPath = $null
  foreach ($candidate in ($pwshCandidates | Select-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $candidate)) { continue }
    try {
      $candidateVersion = [version](& $candidate -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')
      if ($candidateVersion -ge $minimumPowerShellVersion) {
        $pwshPath = $candidate
        break
      }
    } catch {}
  }

  if (-not $pwshPath) {
    if ($startupLanguage -eq 'de') {
      Write-Host 'PowerShell 7 wurde installiert, konnte aber noch nicht gefunden werden. Bitte dieses Fenster schließen und das Skript erneut starten.' -ForegroundColor Yellow
    } else {
      Write-Host 'PowerShell 7 was installed but is not visible yet. Close this window and start the script again.' -ForegroundColor Yellow
    }
    return
  }

  if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
    if ($startupLanguage -eq 'de') { Write-Host 'Bitte starten Sie die Skriptdatei erneut mit PowerShell 7.' -ForegroundColor Yellow }
    else { Write-Host 'Please start the script file again with PowerShell 7.' -ForegroundColor Yellow }
    return
  }

  if ($startupLanguage -eq 'de') { Write-Host 'PowerShell 7 ist bereit. WinTuner GUI wird neu gestartet ...' -ForegroundColor Green }
  else { Write-Host 'PowerShell 7 is ready. Restarting WinTuner GUI ...' -ForegroundColor Green }
  Start-Process -FilePath $pwshPath -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
  return
}

# Offer the required module before WinForms starts. Declining keeps the GUI available in a
# diagnostic state; no package is installed without an explicit confirmation.
if (-not (Get-Module -ListAvailable -Name WinTuner)) {
  Write-Host ''
  if ($startupLanguage -eq 'de') {
    Write-Host 'Das erforderliche PowerShell-Modul "WinTuner" ist nicht installiert.' -ForegroundColor Yellow
    $installWinTuner = try { Read-Host 'Jetzt aus der PowerShell Gallery für den aktuellen Benutzer installieren? [J/N]' } catch { 'N' }
    $confirmWinTunerInstall = ($installWinTuner -match '^(j|ja|y|yes)$')
  } else {
    Write-Host 'The required PowerShell module "WinTuner" is not installed.' -ForegroundColor Yellow
    $installWinTuner = try { Read-Host 'Install it from PowerShell Gallery for the current user now? [Y/N]' } catch { 'N' }
    $confirmWinTunerInstall = ($installWinTuner -match '^(j|ja|y|yes)$')
  }

  if ($confirmWinTunerInstall) {
    try {
      Write-Host 'Install-Module WinTuner ...' -ForegroundColor Cyan
      Install-Module -Name WinTuner -Scope CurrentUser -Repository PSGallery -Force -AllowClobber -ErrorAction Stop
      if ($startupLanguage -eq 'de') { Write-Host 'WinTuner wurde erfolgreich installiert.' -ForegroundColor Green }
      else { Write-Host 'WinTuner was installed successfully.' -ForegroundColor Green }
    } catch {
      if ($startupLanguage -eq 'de') { Write-Host ("WinTuner konnte nicht installiert werden: {0}" -f $_.Exception.Message) -ForegroundColor Red }
      else { Write-Host ("WinTuner could not be installed: {0}" -f $_.Exception.Message) -ForegroundColor Red }
    }
  }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Per-monitor DPI awareness BEFORE any control is created – without this, WinForms gets
# upscaled/blurred by Windows on any display above 100% scaling (the single biggest
# reason this looked "dated" on modern high-DPI screens).
try { [void][System.Windows.Forms.Application]::SetHighDpiMode([System.Windows.Forms.HighDpiMode]::PerMonitorV2) } catch {}

# Enable visual styles BEFORE creating controls
[System.Windows.Forms.Application]::EnableVisualStyles()

# Configure error handling for WinForms event handlers
# Suppress Write-* cmdlet errors that occur from non-pipeline threads
$WarningPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'
$DebugPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

# Redirect all output streams to prevent threading issues
# Note: '*:ProgressAction' is intentionally omitted here — using a wildcard for ProgressAction
# can corrupt URI parameter binding in Invoke-WebRequest/Invoke-RestMethod on some PS7 builds.
# $ProgressPreference = 'SilentlyContinue' (set above) already suppresses progress output globally.
$PSDefaultParameterValues = @{
  '*:WarningAction' = 'SilentlyContinue'
  '*:InformationAction' = 'SilentlyContinue'
  '*:Verbose' = $false
  '*:Debug' = $false
}

# ============================================================
# Script configuration – central place for all script-scoped
# constants and mutable state variables
# ============================================================

# --- Application metadata ---
$script:appVersion  = "0.15.6"

