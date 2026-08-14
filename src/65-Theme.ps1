# Blends Fore 50% toward Back – used to draw legible "disabled" button text/borders
# ourselves, since WinForms' own disabled rendering ignores ForeColor (see Set-GuiTheme).
function Get-DimmedColor {
  param([System.Drawing.Color]$Fore, [System.Drawing.Color]$Back, [double]$Ratio = 0.5)
  $r = [int]($Fore.R * $Ratio + $Back.R * (1 - $Ratio))
  $g = [int]($Fore.G * $Ratio + $Back.G * (1 - $Ratio))
  $b = [int]($Fore.B * $Ratio + $Back.B * (1 - $Ratio))
  return [System.Drawing.Color]::FromArgb($r, $g, $b)
}

# Card surface + border colors derived from the active theme (works for all 6 themes):
# a subtle raised panel that sits slightly above the section background.
function Get-CardBackColor {
  param($theme)
  Get-DimmedColor -Fore $theme.TextBoxBackColor -Back $theme.BackColor -Ratio 0.5
}
function Get-CardBorderColor {
  param($theme)
  Get-DimmedColor -Fore $theme.ForeColor -Back $theme.BackColor -Ratio 0.28
}
# A slightly stronger border than the card, so rounded input fields read as distinct.
function Get-InputBorderColor {
  param($theme)
  Get-DimmedColor -Fore $theme.ForeColor -Back $theme.BackColor -Ratio 0.34
}
# Header surface: a subtly elevated bar above the canvas (lighter in dark, white in light).
function Get-HeaderBackColor {
  param($theme)
  # A subtly elevated bar above the canvas, derived from each theme so the colourful themes get a
  # matching (lighter) header instead of a fixed white one; header text uses theme.ForeColor.
  if ($theme.Dark) { Get-DimmedColor -Fore ([System.Drawing.Color]::White) -Back $theme.BackColor -Ratio 0.06 }
  else { Get-DimmedColor -Fore ([System.Drawing.Color]::White) -Back $theme.BackColor -Ratio 0.35 }
}

# Corner radii used across the UI to match the rounded, modern mockup (cards rounder
# than the smaller controls). Reused later by owner-drawn buttons/inputs.
$script:cornerRadiusCard    = 12
$script:cornerRadiusControl = 8

# Rounding is theme-dependent: the modern themes (Dark/Light + the accent header) round
# their surfaces, while the four retro Windows themes stay period-accurately square.
# Returns 0 (= square) for any theme without Rounded=$true.
function Get-CornerRadius {
  param($theme, [int]$Base)
  if ($theme -and $theme.Rounded) { return $Base }
  return 0
}

# Builds a rounded-rectangle GraphicsPath. Coordinates are single-precision so the 0.5px
# inset used for crisp anti-aliased borders works. Radius is clamped so it can never
# exceed half the shorter side (which would otherwise produce a self-overlapping path).
function New-RoundedRectPath {
  param([single]$X, [single]$Y, [single]$W, [single]$H, [single]$R)
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  if ($R -le 0 -or $W -le 0 -or $H -le 0) {
    $path.AddRectangle((New-Object System.Drawing.RectangleF($X, $Y, [math]::Max($W, 0), [math]::Max($H, 0))))
    $path.CloseFigure()
    return $path
  }
  $d = [math]::Min($R * 2, [math]::Min($W, $H))
  $path.AddArc($X,           $Y,           $d, $d, 180, 90)
  $path.AddArc($X + $W - $d, $Y,           $d, $d, 270, 90)
  $path.AddArc($X + $W - $d, $Y + $H - $d, $d, $d,   0, 90)
  $path.AddArc($X,           $Y + $H - $d, $d, $d,  90, 90)
  $path.CloseFigure()
  return $path
}

# Clips a control to a rounded-rectangle Region so its corners show the parent behind
# them (WinForms has no native rounded panels). Region is honored on real screen output
# but NOT by DrawToBitmap – verify rounding via Region.IsVisible or a live screenshot.
function Set-RoundedRegion {
  param([System.Windows.Forms.Control]$Control, [int]$Radius)
  if ($Control.Width -le 0 -or $Control.Height -le 0) { return }
  $rp  = New-RoundedRectPath 0 0 $Control.Width $Control.Height $Radius
  $old = $Control.Region
  $Control.Region = New-Object System.Drawing.Region($rp)
  $rp.Dispose()
  if ($old) { $old.Dispose() }
}

# Creates a themed "card" panel: subtle raised bg (BackColor, solid so transparent child
# labels inherit the card colour) + rounded corners via Region + a 1px anti-aliased
# rounded border drawn in Paint so it follows the active theme. Tag='card' lets
# Set-GuiTheme recolor it on theme switches.
function New-Card {
  param([int]$X, [int]$Y, [int]$W, [int]$H)
  $card = New-Object System.Windows.Forms.Panel
  $card.Location = New-Object System.Drawing.Point($X, $Y)
  $card.Size = New-Object System.Drawing.Size($W, $H)
  $card.Tag = 'card'
  # Remember the width the card was DESIGNED at. Update-CardWidths only grows cards meant to span
  # the section; the dashboard tiles are cards too, and stretching those stacked all three on top
  # of each other. The tag itself cannot carry this - Set-GuiTheme keys its styling off 'card'.
  if (-not $script:cardDesignWidths) { $script:cardDesignWidths = @{} }
  $script:cardDesignWidths[$card.GetHashCode()] = $W
  Set-RoundedRegion -Control $card -Radius (Get-CornerRadius $script:currentTheme $script:cornerRadiusCard)
  $card.Add_Resize({ Set-RoundedRegion -Control $args[0] -Radius (Get-CornerRadius $script:currentTheme $script:cornerRadiusCard) })
  $card.Add_Paint({
    param($snd, $e)
    $col = Get-CardBorderColor $script:currentTheme
    $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $r   = Get-CornerRadius $script:currentTheme $script:cornerRadiusCard
    # inset 0.5px so the 1px pen sits fully inside the clipped region (crisp AA edge);
    # r=0 (retro themes) yields a plain rectangle -> crisp square border, as before
    $bp  = New-RoundedRectPath 0.5 0.5 ($snd.Width - 1.5) ($snd.Height - 1.5) ([math]::Max($r - 0.5, 0))
    $pen = New-Object System.Drawing.Pen($col, 1)
    $e.Graphics.DrawPath($pen, $bp)
    $pen.Dispose(); $bp.Dispose()
  })
  return $card
}

# Wraps an existing TextBox/ComboBox in a fixed-height rounded "field" host: the native
# control border is removed and the control is centered inside a panel that provides the
# rounded background + anti-aliased border (WinForms edit controls can't round themselves).
# The host has a FIXED height so vertical centering survives font/height changes on theme
# switches (re-centered from the inner control's own Resize). Returns the host panel, which
# the caller adds to the card in place of the raw control. Tag='input-host' lets
# Set-GuiTheme recolor it. Retro themes render it square via the theme-dependent radius.
# Horizontal padding inside a rounded input host. Script-scope so the (closure-free) Resize handler
# can read it – see the note there.
$script:inputPadX = 10
function New-RoundedInput {
  param(
    [System.Windows.Forms.Control]$Inner,
    [int]$X, [int]$Y, [int]$W, [int]$H = 34, [int]$PadX = $script:inputPadX
  )
  if     ($Inner -is [System.Windows.Forms.TextBox])  { $Inner.BorderStyle = [System.Windows.Forms.BorderStyle]::None }
  elseif ($Inner -is [System.Windows.Forms.ComboBox]) { $Inner.FlatStyle   = [System.Windows.Forms.FlatStyle]::Flat }

  $panel = New-Object System.Windows.Forms.Panel
  $panel.Tag = 'input-host'
  $panel.Location = New-Object System.Drawing.Point($X, $Y)
  $panel.Size = New-Object System.Drawing.Size($W, $H)

  # A borderless single-line TextBox draws its glyphs in the upper part of its line box
  # (the descender/leading slack sits at the bottom), so pure geometric centering makes the
  # text look ~2px too high. Nudge down by a small, font-scaled amount for true optical centering.
  # ONLY for TextBoxes – a ComboBox centres its own text, so the same nudge would push it low.
  $nudge = if ($Inner -is [System.Windows.Forms.TextBox]) { [int][math]::Round($Inner.Font.Height * 0.14) } else { 0 }
  $Inner.Location = New-Object System.Drawing.Point($PadX, ([int](($H - $Inner.Height) / 2) + $nudge))
  $Inner.Width = $W - 2 * $PadX
  $panel.Controls.Add($Inner)

  Set-RoundedRegion -Control $panel -Radius (Get-CornerRadius $script:currentTheme $script:cornerRadiusControl)

  # Keep the inner control centered + full-width as the host resizes or the inner control's
  # height changes (font swap on theme switch). $PadX is baked into the closures.
  # No .GetNewClosure() – a closure cannot call SCRIPT-scope functions (Set-RoundedRegion /
  # Get-CornerRadius would throw "not recognized" on every resize). $PadX was the only reason for
  # the closure and is always the default, so it is read from the script-scope constant instead.
  $panel.Add_Resize({
    param($snd, $e)
    $pad = $script:inputPadX
    Set-RoundedRegion -Control $snd -Radius (Get-CornerRadius $script:currentTheme $script:cornerRadiusControl)
    $c = if ($snd.Controls.Count) { $snd.Controls[0] } else { $null }
    if ($c) { $c.Left = $pad; $c.Width = $snd.ClientSize.Width - 2 * $pad; $c.Top = [int](($snd.ClientSize.Height - $c.Height) / 2) + $(if ($c -is [System.Windows.Forms.TextBox]) { [int][math]::Round($c.Font.Height * 0.14) } else { 0 }) }
  })
  $Inner.Add_Resize({
    param($snd, $e)
    $p = $snd.Parent
    if ($p) { $snd.Top = [int](($p.ClientSize.Height - $snd.Height) / 2) + $(if ($snd -is [System.Windows.Forms.TextBox]) { [int][math]::Round($snd.Font.Height * 0.14) } else { 0 }) }
  })

  $panel.Add_Paint({
    param($snd, $e)
    $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $rad = Get-CornerRadius $script:currentTheme $script:cornerRadiusControl
    $col = Get-InputBorderColor $script:currentTheme
    $bp  = New-RoundedRectPath 0.5 0.5 ($snd.Width - 1.5) ($snd.Height - 1.5) ([math]::Max($rad - 0.5, 0))
    $pen = New-Object System.Drawing.Pen($col, 1)
    $e.Graphics.DrawPath($pen, $bp)
    $pen.Dispose(); $bp.Dispose()
  })
  return $panel
}

# --- Paint-based rounded buttons -------------------------------------------------------
# Region-clipping a button does NOT scale with per-monitor DPI (the pixel region goes stale
# when WinForms rescales the control), which both looks jagged AND leaves dead click zones
# outside the stale region. Instead we fully owner-draw the button in Paint (anti-aliased
# rounded fill + border + image + text) against the CURRENT client rectangle, so it stays
# crisp and fully clickable at any DPI. Hover/press state is tracked in these sets.
$script:btnHover   = New-Object 'System.Collections.Generic.HashSet[object]'
$script:btnPress   = New-Object 'System.Collections.Generic.HashSet[object]'
$script:btnPainted = New-Object 'System.Collections.Generic.HashSet[object]'
$script:btnRadius  = @{}

function Enable-RoundedPaint {
  param([System.Windows.Forms.Button]$Button, [int]$Radius = 8)
  $Button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $Button.FlatAppearance.BorderSize = 0
  if ($Button.Region) { $Button.Region = $null }   # drop any old region so it can't clip clicks
  $script:btnRadius[$Button] = $Radius
  if ($script:btnPainted.Contains($Button)) { return }
  [void]$script:btnPainted.Add($Button)
  $Button.Add_MouseEnter({ [void]$script:btnHover.Add($args[0]); $args[0].Invalidate() })
  $Button.Add_MouseLeave({ [void]$script:btnHover.Remove($args[0]); [void]$script:btnPress.Remove($args[0]); $args[0].Invalidate() })
  $Button.Add_MouseDown({ [void]$script:btnPress.Add($args[0]); $args[0].Invalidate() })
  $Button.Add_MouseUp({ [void]$script:btnPress.Remove($args[0]); $args[0].Invalidate() })
  $Button.Add_EnabledChanged({ $args[0].Invalidate() })
  $Button.Add_Paint({
    param($b, $e)
    try {
    $rad = $script:btnRadius[$b]; if (-not $rad) { $rad = 8 }
    $parent = if ($b.Parent) { $b.Parent.BackColor } else { $b.BackColor }
    $normal = $b.BackColor
    $fill =
      if (-not $b.Enabled) { Get-DimmedColor -Fore $normal -Back $parent -Ratio 0.55 }
      elseif ($script:btnPress.Contains($b)) { $b.FlatAppearance.MouseDownBackColor }
      elseif ($script:btnHover.Contains($b)) { $b.FlatAppearance.MouseOverBackColor }
      else { $normal }
    $fg = if (-not $b.Enabled) { Get-DimmedColor -Fore $b.ForeColor -Back $fill -Ratio 0.55 } else { $b.ForeColor }
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear($parent)
    $fp = New-RoundedRectPath 0 0 $b.Width $b.Height $rad
    $fb = New-Object System.Drawing.SolidBrush($fill); $g.FillPath($fb, $fp); $fb.Dispose(); $fp.Dispose()
    $bc = $b.FlatAppearance.BorderColor
    if ($bc.ToArgb() -ne $fill.ToArgb()) {
      $bpath = New-RoundedRectPath 0.5 0.5 ($b.Width - 1.5) ($b.Height - 1.5) ([math]::Max($rad - 0.5, 0))
      $pen = New-Object System.Drawing.Pen($bc, 1); $g.DrawPath($pen, $bpath); $pen.Dispose(); $bpath.Dispose()
    }
    $leftPad = $b.Padding.Left
    $flags = [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis
    if ($b.Image) {
      $img = $b.Image
      $g.DrawImage($img, $leftPad, [int](($b.Height - $img.Height) / 2), $img.Width, $img.Height)
      $tx = $leftPad + $img.Width + 6
      $textRect = New-Object System.Drawing.Rectangle($tx, 0, ($b.Width - $tx - 4), $b.Height)
      $flags = $flags -bor [System.Windows.Forms.TextFormatFlags]::Left
    } elseif ($b.TextAlign -eq [System.Drawing.ContentAlignment]::MiddleLeft) {
      $textRect = New-Object System.Drawing.Rectangle($leftPad, 0, ($b.Width - $leftPad - 4), $b.Height)
      $flags = $flags -bor [System.Windows.Forms.TextFormatFlags]::Left
    } else {
      $textRect = $b.ClientRectangle
      $flags = $flags -bor [System.Windows.Forms.TextFormatFlags]::HorizontalCenter
    }
    [System.Windows.Forms.TextRenderer]::DrawText($g, $b.Text, $b.Font, $textRect, $fg, $flags)
    } catch { }   # never let a paint hiccup surface as a fatal UI error
  })
}

# Small circled "i" badge placed after a section title. Hovering it shows a longer explanation
# (what the section is, what you can do, what it is NOT) so a technician can orient without docs.
# The tooltip is attached later in one pass, because $toolTip is created after all sections exist.
# Drawn (not a glyph) so it looks identical in every theme and at any DPI.
$script:infoBadges = [System.Collections.Generic.List[object]]::new()
function Add-SectionInfoBadge {
  param(
    [System.Windows.Forms.Control]$Parent,
    [System.Windows.Forms.Label]$AfterLabel,
    [string]$TextKey
  )
  $badge = New-Object System.Windows.Forms.Label
  $badge.AutoSize = $false
  $badge.Size = New-Object System.Drawing.Size(16,16)
  # Vertically centred on the (larger, bold) title text; PreferredWidth is exact for AutoSize labels.
  $badge.Location = New-Object System.Drawing.Point(
    ($AfterLabel.Left + $AfterLabel.PreferredWidth + 8),
    ($AfterLabel.Top + [int](($AfterLabel.PreferredHeight - 16) / 2))
  )
  # Hand rather than Help: the badge is clickable, not just hoverable.
  $badge.Cursor = [System.Windows.Forms.Cursors]::Hand

  # Hovering shows the tooltip (wired centrally from the badge registry). Clicking opens the same
  # text in a dialog, because a tooltip disappears while reading and cannot be resized - several of
  # these texts are long enough that this matters. The key is looked up from the registry instead
  # of captured in the closure, which would go stale once this function returns.
  $badge.Add_Click({
    param($badgeSender, $e)
    try {
      $entry = @($script:infoBadges | Where-Object { $_.Badge -eq $badgeSender }) | Select-Object -First 1
      if (-not $entry) { return }
      [void][System.Windows.Forms.MessageBox]::Show(
        (Get-UiString $entry.Key),
        (Get-UiString 'InfoTitle'),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information)
    } catch { }   # class 3: an info popup must never disturb the section
  })
  $badge.Add_Paint({
    param($lbl, $e)
    try {
      $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
      # Dimmed against the card so the badge reads as a hint, not as a headline element.
      $c = Get-DimmedColor -Fore $lbl.ForeColor -Back $lbl.Parent.BackColor -Ratio 0.75
      $pen = New-Object System.Drawing.Pen($c, 1.4)
      $e.Graphics.DrawEllipse($pen, 0.7, 0.7, ($lbl.Width - 2.4), ($lbl.Height - 2.4))
      $pen.Dispose()
      # GDI text (TextRenderer) instead of DrawString: at 16px the GDI+ glyph blurs noticeably.
      $f = New-Object System.Drawing.Font("Segoe UI", 8.25, [System.Drawing.FontStyle]::Bold)
      $rect = New-Object System.Drawing.Rectangle(0, 0, $lbl.Width, $lbl.Height)
      $flags = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter
      [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, "i", $f, $rect, $c, $flags)
      $f.Dispose()
    } catch { }
  })
  $Parent.Controls.Add($badge)
  $badge.BringToFront()
  $script:infoBadges.Add([pscustomobject]@{ Badge = $badge; Key = $TextKey })
  return $badge
}

# Native Windows 11 window chrome via DWM: a dark (or light) title bar that matches the
# active theme, plus rounded window corners. No-ops safely on Windows 10 / older (the
# attributes are simply ignored) and is fully wrapped in try/catch.
if (-not ('DwmChrome' -as [type])) {
  Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class DwmChrome {
  [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);
}
"@
}
function Set-WindowChrome {
  param([System.Windows.Forms.Form]$Form, [bool]$Dark)
  try {
    if (-not $Form -or -not $Form.IsHandleCreated) { return }
    $h = $Form.Handle
    $useDark = [int]([bool]$Dark)
    [void][DwmChrome]::DwmSetWindowAttribute($h, 20, [ref]$useDark, 4)  # DWMWA_USE_IMMERSIVE_DARK_MODE
    $round = 2                                                          # DWMWCP_ROUND
    [void][DwmChrome]::DwmSetWindowAttribute($h, 33, [ref]$round, 4)    # DWMWA_WINDOW_CORNER_PREFERENCE
  } catch {}
}

# Tracks which buttons already have the disabled-text-repaint handler attached, so
# repeated theme switches don't stack duplicate Paint subscribers on the same button.
$script:paintHookedButtons = New-Object 'System.Collections.Generic.HashSet[object]'
# Tracks which buttons already have the rounded-corner Resize handler attached.
$script:roundedResizeButtons = New-Object 'System.Collections.Generic.HashSet[object]'
# Set membership = "this button is currently drawn rounded". Set per theme-apply so the
# Paint handler rounds correctly even when the header (always rounded) differs from the
# active main theme (which may be a square retro theme).
$script:roundedButtons = New-Object 'System.Collections.Generic.HashSet[object]'
# Tracks which combo boxes already have the owner-draw handler attached (see Set-GuiTheme).
$script:ownerDrawnCombos = New-Object 'System.Collections.Generic.HashSet[object]'

# Function to apply theme to all controls
function Set-GuiTheme {
  param([System.Windows.Forms.Control]$control, [hashtable]$theme)
  if ($control.Tag -eq 'no-theme') {
    # Fixed visual elements (e.g. the accent bar) keep their color across every
    # theme switch instead of being recolored like a normal panel.
    return
  }
  # Swap the typeface per era (e.g. Tahoma for the Windows 2000/XP themes, Segoe UI for
  # Vista/7/Dark/Light) while preserving each control's own size/bold-ness.
  if ($theme.FontName -and $control.Font -and $control.Font.Name -ne $theme.FontName) {
    try { $control.Font = New-Object System.Drawing.Font($theme.FontName, $control.Font.Size, $control.Font.Style) } catch { Write-LogDebug ("Theme font on {0}: {1}" -f $control.GetType().Name, $_.Exception.Message) }
  }
  if ($control -is [System.Windows.Forms.Form]) {
    $control.BackColor = $theme.BackColor
    $control.ForeColor = $theme.ForeColor
  }
  elseif ($control -is [System.Windows.Forms.Button]) {
    if ($control.Tag -eq 'btn-secondary') {
      # Secondary/utility action: calm neutral fill with a subtle outline.
      $control.BackColor = $theme.ButtonSecondaryBackColor
      $control.ForeColor = $theme.ButtonSecondaryForeColor
      $control.FlatAppearance.BorderColor = $theme.ButtonSecondaryBorderColor
    } else {
      # Primary action: inverted (solid) fill; border == fill so no outline is drawn.
      $control.BackColor = $theme.ButtonBackColor
      $control.ForeColor = $theme.ButtonForeColor
      $control.FlatAppearance.BorderColor = $theme.ButtonBackColor
    }
    $control.FlatAppearance.MouseOverBackColor = if ($theme.ButtonHoverColor) { $theme.ButtonHoverColor } else { $script:accentColorHover }
    $control.FlatAppearance.MouseDownBackColor = if ($theme.ButtonPressColor) { $theme.ButtonPressColor } else { $script:accentColorPress }
    $control.Cursor = [System.Windows.Forms.Cursors]::Hand
    # Anti-aliased, DPI-safe rounded rendering (fill + border + text) with no clipping Region,
    # so corners stay crisp and the whole button stays clickable at any monitor scaling.
    Enable-RoundedPaint -Button $control -Radius $script:cornerRadiusControl
  }
  elseif ($control -is [System.Windows.Forms.TextBox]) {
    $control.BackColor = $theme.TextBoxBackColor
    $control.ForeColor = $theme.TextBoxForeColor
    # Standalone text boxes default to a Fixed3D (sunken, white-ish) border that looks broken on a
    # dark theme. Flatten to a single 1px border. Boxes inside a rounded input host have BorderStyle
    # None (set by New-RoundedInput) and must stay None so they don't draw a square border inside the
    # rounded field – so only touch boxes that currently have a visible (non-None) border.
    if ($control.BorderStyle -ne [System.Windows.Forms.BorderStyle]::None) {
      $control.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    }
  }
  elseif ($control -is [System.Windows.Forms.NumericUpDown]) {
    # A NumericUpDown is a container, not a TextBox, so the branch above never reaches it and it
    # would keep the system-white field on a dark theme. Its inner edit area follows the control's
    # own colours, so setting them here is enough.
    $control.BackColor = $theme.TextBoxBackColor
    $control.ForeColor = $theme.TextBoxForeColor
    $control.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
  }
  elseif ($control -is [System.Windows.Forms.ListView]) {
    # Detail lists (updates / discovered apps): input-coloured surface + flat border, matching the
    # other data surfaces. OwnerDraw is deliberately NOT used – the native rows stay crisp and the
    # column headers keep their system look, which is readable on every theme.
    $control.BackColor = $theme.TextBoxBackColor
    $control.ForeColor = $theme.TextBoxForeColor
    $control.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
  }
  elseif ($control -is [System.Windows.Forms.ListBox]) {
    # Covers ListBox and CheckedListBox. Give it the (lighter) input background + a 1px border so
    # an empty list reads as a clearly bounded box instead of blending into the dark card/canvas
    # ("no end in sight"). ForeColor follows the input text colour for readable item text.
    $control.BackColor = $theme.TextBoxBackColor
    $control.ForeColor = $theme.TextBoxForeColor
    $control.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
  }
  elseif ($control -is [System.Windows.Forms.ComboBox]) {
    # A Flat/Standard DropDownList ComboBox ignores BackColor under visual styles and renders
    # WHITE (confirmed by rendering to a bitmap). Owner-draw it so the closed box and the
    # dropdown items both follow the theme; selection uses the inverted (primary) fill.
    $control.BackColor = $theme.TextBoxBackColor
    $control.ForeColor = $theme.TextBoxForeColor
    $control.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $control.DrawMode  = [System.Windows.Forms.DrawMode]::OwnerDrawFixed
    # OwnerDrawFixed uses ItemHeight for BOTH the dropdown rows AND the closed display cell. The
    # default (~13px) is shorter than a 9pt line (~15px), which clipped the selected text (e.g.
    # "Available"). Size it to the font so nothing is cut.
    try { $control.ItemHeight = [int]([math]::Max($control.Font.Height + 4, 18)) } catch { Write-LogDebug ("Combo ItemHeight: {0}" -f $_.Exception.Message) }
    if (-not $script:ownerDrawnCombos.Contains($control)) {
      [void]$script:ownerDrawnCombos.Add($control)
      $control.Add_DrawItem({
        param($cb, $e)
        $t = $script:currentTheme
        $selected = ($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0
        $bg = if ($selected) { $t.ButtonBackColor } else { $t.TextBoxBackColor }
        $fg = if ($selected) { $t.ButtonForeColor } else { $t.TextBoxForeColor }
        $bb = New-Object System.Drawing.SolidBrush($bg)
        $e.Graphics.FillRectangle($bb, $e.Bounds); $bb.Dispose()
        if ($e.Index -ge 0) {
          $txt = [string]$cb.GetItemText($cb.Items[$e.Index])
          # DrawString wraps long package names by default and, because it does not clip to the
          # ComboBox row, the wrapped line paints over every following item. TextRenderer with
          # SingleLine + EndEllipsis guarantees that each item stays inside its own row at every DPI.
          $rect = New-Object System.Drawing.Rectangle(($e.Bounds.X + 4), $e.Bounds.Y, ([math]::Max(0, $e.Bounds.Width - 8)), $e.Bounds.Height)
          $flags = [System.Windows.Forms.TextFormatFlags]::Left -bor
                   [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor
                   [System.Windows.Forms.TextFormatFlags]::SingleLine -bor
                   [System.Windows.Forms.TextFormatFlags]::EndEllipsis -bor
                   [System.Windows.Forms.TextFormatFlags]::NoPrefix -bor
                   [System.Windows.Forms.TextFormatFlags]::PreserveGraphicsClipping
          [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $txt, $cb.Font, $rect, $fg, $bg, $flags)
        }
      })
    }
  }
  elseif ($control -is [System.Windows.Forms.Label]) {
    # The Tag-based branches further down are unreachable for labels (this type check runs first),
    # so the two label Tags are handled HERE:
    #   list-overlay – empty-state hint occupying a list's rectangle: it must match the LIST
    #                  background, not the card's, and use the muted text colour.
    #   hint         – secondary explanatory text (e.g. the file paths note).
    if ($control.Tag -eq 'list-overlay') {
      $control.BackColor = $theme.TextBoxBackColor
      $control.ForeColor = $theme.SecondaryForeColor
    } elseif ($control.Tag -eq 'hint') {
      $control.BackColor = [System.Drawing.Color]::Transparent
      $control.ForeColor = $theme.SecondaryForeColor
    } else {
      $control.BackColor = [System.Drawing.Color]::Transparent
      $control.ForeColor = $theme.ForeColor
    }
  }
  elseif ($control -is [System.Windows.Forms.TabControl]) {
    $control.BackColor = $theme.TabBackColor
    $control.ForeColor = $theme.TabForeColor
  }
  elseif ($control -is [System.Windows.Forms.TabPage]) {
    $control.BackColor = $theme.BackColor
    $control.ForeColor = $theme.ForeColor
  }
  elseif ($control -is [System.Windows.Forms.ProgressBar]) {
    $control.BackColor = $theme.TextBoxBackColor
  }
  elseif ($control.Tag -eq 'card') {
    # Raised card surface: subtle bg above the section; its border is drawn in Paint.
    # Re-apply the region so switching to/from a retro (square) theme updates the corners.
    $control.BackColor = Get-CardBackColor $theme
    $control.ForeColor = $theme.ForeColor
    Set-RoundedRegion -Control $control -Radius (Get-CornerRadius $theme $script:cornerRadiusCard)
    $control.Invalidate()
  }
  elseif ($control.Tag -eq 'input-host') {
    # Rounded field backing: matches the inner edit control's background; its border is
    # drawn in Paint. Re-apply the region so retro (square) themes drop the rounding.
    $control.BackColor = $theme.TextBoxBackColor
    Set-RoundedRegion -Control $control -Radius (Get-CornerRadius $theme $script:cornerRadiusControl)
    $control.Invalidate()
  }
  elseif ($control.Tag -eq 'list-overlay') {
    # Empty-state hint drawn on top of a (CheckedList)ListBox: match the list background so it
    # blends in, with secondary-colour centred text. Kept theme-aware here (it is not transparent
    # because a transparent label would show the card colour, not the list's, behind it).
    $control.BackColor = $theme.TextBoxBackColor
    $control.ForeColor = $theme.SecondaryForeColor
  }
  else {
    $control.BackColor = $theme.BackColor
    $control.ForeColor = $theme.ForeColor
  }
  foreach ($childControl in @($control.Controls)) {
    Set-GuiTheme -control $childControl -theme $theme
  }
}

# Function to toggle theme
# Switches to one of the 6 registered themes (Dark/Light/Win2000/WinXP/WinVista/Win7),
# applies it to the whole form, then re-applies the accent colors to the header so
# it stays white/black/orange regardless of which theme is active.
function Set-ActiveTheme {
  param([Parameter(Mandatory=$true)][string]$ThemeName)
  if (-not $script:availableThemes.Contains($ThemeName)) { return }
  $script:themeName    = $ThemeName
  $script:currentTheme = $script:availableThemes[$ThemeName]
  Set-GuiTheme -control $form -theme $script:currentTheme
  if ($headerPanel) {
    Set-GuiTheme -control $headerPanel -theme $script:currentTheme
    $headerPanel.BackColor = Get-HeaderBackColor $script:currentTheme
  }
  if (Get-Command Set-WindowChrome -ErrorAction SilentlyContinue) { Set-WindowChrome -Form $form -Dark ([bool]$script:currentTheme.Dark) }
  if (Get-Command Update-SidebarTheme -ErrorAction SilentlyContinue) { Update-SidebarTheme }
  if (Get-Command Update-MenuTheme -ErrorAction SilentlyContinue) { Update-MenuTheme }
  if (Get-Command Update-StatusStripTheme -ErrorAction SilentlyContinue) { Update-StatusStripTheme }
  $form.Refresh()
}

