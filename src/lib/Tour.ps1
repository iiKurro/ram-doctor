# ==========================================================================================
#  RAM Doctor - the guided tour of the window (src/lib/Tour.ps1)
#
#  A short "coach marks" tour: the window is dimmed, one real control at a time is lit with an accent ring, and a small
#  card explains it (step counter, title, one to three plain sentences, Back / Next / Skip). The card has the keyboard while
#  the tour is open: Tab moves between its buttons, Enter or Space presses the focused one (Next at first), Esc = leave, and
#  the arrow that points at the Next button = next (Right in English, Left in Arabic, where the card is mirrored), the other
#  arrow = back. Screen readers see the card as a dialog with its texts and buttons, and each step is announced.
#
#  The tour is optional and harmless: it never starts a scan, never presses anything, and saves nothing. A part that is
#  not on screen yet (the result buttons before the first scan, for example) is explained on a card in the middle of the
#  window; the "More" section is opened for its step and closed again afterwards, and the scroll position is put back.
#  Any error stops the tour quietly (one line in "Technical details"); the window keeps working.
#
#  Pieces
#    * pure helpers (no window): the step list, which steps apply, the card texts, key handling, card placement and
#      scrolling. tests\Tour.Tests.ps1 covers them.
#    * runtime: Start-Tour / Show-TourStep / Move-TourStep / Stop-Tour, the first-use offer on the ready bar (Add-TourOffer) and
#      Connect-Tour, which RAM-Doctor-GUI.ps1 calls once. They use the window's own variables ($form, $page, $btnScan ...)
#      and its Bind-Text / Add-Log, so they only run inside the window.
#    * the overlay itself is Fluent.FCoach in lib\Fluent.cs (a layered window over the window's content; when the tour
#      closes, the keyboard focus goes back to the window).
#
#  Every text is a tour.* key in lib\Strings.ps1. Keep this file UTF-8 WITH BOM.
# ==========================================================================================

# ---------------------------------------------------------------- pure helpers

function Get-TourSteps {
    <# Every step, in order. Fields:
         Id        short name (tests, screenshots)
         Glyph     Segoe Fluent icon code shown on the card
         Targets   names of window controls (variables of RAM-Doctor-GUI.ps1) that the step lights up; empty = the card
                   stands alone in the middle of the window. Only the visible ones count.
         Title     string-table key of the card title
         Body      string-table key of the card text; BodyArgs = keys whose texts fill its {0} {1} ... (button names, so
                   the tour always quotes the buttons exactly)
         Extra     @{ Key; When; Args }: a sentence added when the state flag When is true
         Later     key added when none of the targets is visible (that part only appears after a scan)
         Only      state flag that must be true for the step to be shown at all ('' = always shown)
         Expand    expander (variable name) opened for this step and closed again when the step is left #>
    $step = {
        param([string]$Id, [int]$Glyph, [string[]]$Targets, [string]$Title, [string]$Body, [string[]]$BodyArgs, $Extra, [string]$Later, [string]$Only, [string]$Expand)
        [pscustomobject]@{ Id = $Id; Glyph = $Glyph; Targets = @($Targets | Where-Object { $_ }); Title = $Title; Body = $Body; BodyArgs = @($BodyArgs | Where-Object { $_ })
            Extra = $Extra; Later = $Later; Only = $Only; Expand = $Expand }
    }
    @(
        (& $step 'welcome' 0xE9D9 @() 'tour.welcome.t' 'tour.welcome.b' @() $null '' '' '')
        (& $step 'admin' 0xE7BA @('banner') 'tour.admin.t' 'tour.admin.b' @() $null '' 'admin' '')
        (& $step 'scan' 0xE721 @('btnScan') 'tour.scan.t' 'tour.scan.b' @('gui.btn.scan') $null '' '' '')
        (& $step 'progress' 0xE916 @('bar', 'lblStatus') 'tour.progress.t' 'tour.progress.b' @() $null '' '' '')
        (& $step 'verdict' 0xE946 @('info') 'tour.verdict.t' 'tour.verdict.b' @() $null '' '' '')
        (& $step 'actions' 0xE8A5 @('btnReport', 'btnFolder', 'btnCopy', 'btnShare') 'tour.acts.t' 'tour.acts.b' @() @{ Key = 'tour.acts.share'; When = 'share'; Args = @('gui.btn.share') } 'tour.acts.later' '' '')
        (& $step 'findings' 0xE8FD @('find') 'tour.find.t' 'tour.find.b' @('level.high', 'level.med') $null 'tour.find.later' '' '')
        (& $step 'quarantine' 0xEA18 @('btnQ') 'tour.q.t' 'tour.q.b' @('gui.btn.q') $null 'tour.q.later' '' '')
        (& $step 'more' 0xE713 @('more') 'tour.more.t' 'tour.more.b' @('gui.btn.restore', 'gui.btn.purge', 'gui.btn.clean') $null '' '' 'exMore')
        (& $step 'details' 0xE9D9 @('details') 'tour.details.t' 'tour.details.b' @() $null '' '' '')
        (& $step 'language' 0xE774 @('btnLang') 'tour.lang.t' 'tour.lang.b' @() $null '' '' '')
        (& $step 'help' 0xE897 @('btnTour') 'tour.help.t' 'tour.help.b' @('gui.btn.copy') $null '' '' '')
    )
}

function Select-TourSteps {
    <# The steps that apply: a step with an Only flag is kept only when that flag is true in $State. #>
    param([object[]]$Steps, [hashtable]$State = @{})
    if (-not $State) { $State = @{} }
    return @($Steps | Where-Object { $_ -and (-not $_.Only -or [bool]$State[$_.Only]) })
}

function Get-TourStepText {
    <# Title, body and note of a card in the current language. The note is the step's "appears later" sentence, given only
       when none of its targets is on screen ($TargetShown = $false); otherwise it is empty. #>
    param([Parameter(Mandatory)]$Step, [hashtable]$State = @{}, [bool]$TargetShown = $true)
    if (-not $State) { $State = @{} }
    $fill = { param([string]$key, [string[]]$argKeys)
        $a = @($argKeys | Where-Object { $_ } | ForEach-Object { Get-Text $_ })
        if ($a.Count -gt 0) { Get-Text $key @a } else { Get-Text $key }
    }
    $body = & $fill $Step.Body $Step.BodyArgs
    if ($Step.Extra -and [bool]$State[$Step.Extra.When]) { $body += ' ' + (& $fill $Step.Extra.Key $Step.Extra.Args) }
    $note = $(if (-not $TargetShown -and $Step.Later) { Get-Text $Step.Later } else { '' })
    return [pscustomobject]@{ Title = (Get-Text $Step.Title); Body = $body; Note = $note }
}

function Get-TourKeyAction {
    <# What a key does in the tour: 'next', 'back', 'skip' or '' (ignored). $Key is a [Windows.Forms.Keys] name.
       Enter / Space / PageDown go on, Backspace / PageUp go back, Esc leaves. The arrows follow the reading direction:
       the one that points at the Next button goes on (Right in English, Left in Arabic, where the card is mirrored). #>
    param([string]$Key, [bool]$Rtl = $false)
    switch -Regex ($Key) {
        '^(Return|Enter|Space|PageDown)$' { return 'next' }
        '^(Back|PageUp)$' { return 'back' }
        '^Escape$' { return 'skip' }
        '^Right$' { if ($Rtl) { return 'back' } else { return 'next' } }
        '^Left$' { if ($Rtl) { return 'next' } else { return 'back' } }
    }
    return ''
}

function Get-TourCardPlacement {
    <# Where the card goes, in client coordinates of the overlay. Order of preference: below the lit rectangle, above it,
       beside it (first on the side where reading ends, then on the other side), and when nothing fits over the top or the
       bottom edge of the window, whichever covers less of the lit rectangle. With no lit rectangle the card is centred.
       Horizontally the card lines up with the reading-start edge of the lit rectangle (left in English, right in Arabic)
       and always stays inside the window. Returns X, Y and Side (below, above, right, left, over, center). #>
    param([System.Drawing.Rectangle]$Hole, [System.Drawing.Size]$Area, [System.Drawing.Size]$Card, [bool]$Rtl = $false, [int]$Gap = 14, [int]$Margin = 16)
    $maxX = [Math]::Max($Margin, $Area.Width - $Margin - $Card.Width)
    $maxY = [Math]::Max($Margin, $Area.Height - $Margin - $Card.Height)
    $fitX = { param([int]$v) [int][Math]::Min($maxX, [Math]::Max($Margin, $v)) }
    $fitY = { param([int]$v) [int][Math]::Min($maxY, [Math]::Max($Margin, $v)) }
    $result = { param([int]$x, [int]$y, [string]$side) [pscustomobject]@{ X = $x; Y = $y; Side = $side } }
    if ($Hole.IsEmpty -or $Hole.Width -le 0 -or $Hole.Height -le 0) {
        return (& $result (& $fitX ([Math]::Floor(($Area.Width - $Card.Width) / 2))) (& $fitY ([Math]::Floor(($Area.Height - $Card.Height) / 2))) 'center')
    }
    $x = & $fitX $(if ($Rtl) { $Hole.Right - $Card.Width } else { $Hole.Left })
    if ($Hole.Bottom + $Gap + $Card.Height -le $Area.Height - $Margin) { return (& $result $x ($Hole.Bottom + $Gap) 'below') }
    if ($Hole.Top - $Gap - $Card.Height -ge $Margin) { return (& $result $x ($Hole.Top - $Gap - $Card.Height) 'above') }
    $y = & $fitY $Hole.Top
    $rightX = $Hole.Right + $Gap; $leftX = $Hole.Left - $Gap - $Card.Width
    $rightFits = ($rightX + $Card.Width -le $Area.Width - $Margin); $leftFits = ($leftX -ge $Margin)
    $sides = $(if ($Rtl) { @('left', 'right') } else { @('right', 'left') })
    foreach ($s in $sides) {
        if ($s -eq 'right' -and $rightFits) { return (& $result $rightX $y 'right') }
        if ($s -eq 'left' -and $leftFits) { return (& $result $leftX $y 'left') }
    }
    $coverTop = $Card.Height + $Gap - ($Hole.Top - $Margin)                  # how much of the lit area a card at the top would hide
    $coverBottom = $Card.Height + $Gap - ($Area.Height - $Margin - $Hole.Bottom)
    return (& $result $x $(if ($coverTop -lt $coverBottom) { $Margin } else { $maxY }) 'over')
}

function Get-TourScrollDelta {
    <# How far to scroll the page (pixels; positive = down) so that the lit target is in view, together with the card below
       it when both fit. $Top / $Bottom: the target relative to the top of the visible area; $View: height of that area. #>
    param([int]$Top, [int]$Bottom, [int]$View, [int]$CardHeight, [int]$Gap = 14, [int]$Margin = 16)
    $blockTop = $Top - $Margin
    $blockBottom = $Bottom + $Gap + $CardHeight + $Margin
    if ($blockBottom - $blockTop -le $View) {
        if ($blockTop -ge 0 -and $blockBottom -le $View) { return 0 }                                         # target and card below: in view
        if ($blockTop -ge 0 -and $Bottom + $Margin -le $View -and $Top - $Gap - $CardHeight -ge $Margin) { return 0 }   # card fits above
        if ($blockTop -lt 0) { return $blockTop }
        return ($blockBottom - $View)
    }
    if ($Top -ge $Margin -and $Bottom + $Margin -le $View) { return 0 }   # target fully visible, the card goes beside or over it
    return ($Top - $Margin)
}

function Test-TourFirstRun {
    <# True when the reports folder holds no report or plan yet: the very first use (the window then offers the tour). #>
    param([string]$ReportsDir)
    if (-not $ReportsDir -or -not (Test-Path -LiteralPath $ReportsDir)) { return $true }
    $any = @(Get-ChildItem -LiteralPath $ReportsDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'RAMDoctor-*.html' -or $_.Name -like 'Plan-*.json' } | Select-Object -First 1)
    return ($any.Count -eq 0)
}

# ---------------------------------------------------------------- runtime (inside the window only)

$script:Tour = $null            # the running tour, $null when none
$script:TourNoAnimation = $false   # screenshots and tests switch the movement off for stable pictures
$script:TourLastError = ''        # why the tour last stopped by itself (empty = never); tests read it

function Get-TourControl([string]$Name) { Get-Variable -Name $Name -Scope Script -ValueOnly -ErrorAction SilentlyContinue }

function Invoke-TourSafely([scriptblock]$Action) {
    # the tour is optional: whatever goes wrong, stop it quietly and keep the window working
    try { & $Action }
    catch {
        $msg = $_.Exception.Message
        $script:TourLastError = $msg
        try { if (Get-Command -Name Add-Log -ErrorAction SilentlyContinue) { Add-Log ('[tour] stopped after an error: ' + $msg) } } catch { }
        try { Stop-Tour } catch { $script:Tour = $null }
    }
}

function Get-TourState {
    # the flags the steps depend on (see Get-TourSteps: Only / Extra.When)
    $b = Get-TourControl 'banner'
    $sh = Get-TourControl 'share'
    return @{
        admin = [bool]($b -and $b.Visible)
        share = [bool]($sh -and $sh.EndpointConfigured)
    }
}

function Get-TourTargets($Step) {
    foreach ($n in @($Step.Targets)) {
        $c = Get-TourControl $n
        if ($c -is [System.Windows.Forms.Control] -and $c.Visible -and $c.IsHandleCreated -and $c.Width -gt 0 -and $c.Height -gt 0) { $c }
    }
}

function Get-TourUnion([object[]]$Controls) {
    # screen rectangle around all the controls (window rectangles are never mirrored, so this is right in Arabic too)
    $r = [System.Drawing.Rectangle]::Empty
    foreach ($c in @($Controls)) {
        if (-not $c) { continue }
        $w = [Fluent.Win]::ScreenRect($c.Handle)
        if ($w.IsEmpty) { continue }
        $r = $(if ($r.IsEmpty) { $w } else { [System.Drawing.Rectangle]::Union($r, $w) })
    }
    return $r
}

function Close-TourExpanders {
    $t = $script:Tour
    if (-not $t) { return }
    foreach ($ex in @($t.Opened)) { try { if ($ex.Expanded) { $ex.Toggle() } } catch { } }
    $t.Opened.Clear()
}

function Update-TourLayout {
    <# Lays the overlay over the window, writes the card for the current step and places the lit hole and the card.
       -Scroll first scrolls the target into view; -Animate glides from the previous step. Only redraws on a change. #>
    param([switch]$Scroll, [switch]$Animate)
    $t = $script:Tour
    if (-not $t) { return }
    $o = $t.Overlay
    if (-not $o -or $o.IsDisposed) { Stop-Tour; return }
    if ($o.LastError) { throw ('the overlay could not draw: ' + $o.LastError) }
    $form = Get-TourControl 'form'; $page = Get-TourControl 'page'
    if (-not $form -or $form.IsDisposed -or -not $page) { Stop-Tour; return }
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { return }

    $pr = [Fluent.Win]::ScreenRect($page.Handle)
    if ($pr.Width -lt 80 -or $pr.Height -lt 80) { return }
    if ($o.Bounds -ne $pr) { $o.Bounds = $pr }

    $i = $t.Index
    $step = $t.Steps[$i]
    $targets = @(Get-TourTargets $step)
    $text = Get-TourStepText $step $t.State ($targets.Count -gt 0)
    $last = ($i -ge $t.Steps.Count - 1)
    $o.Rtl = ((Get-UiLang) -eq 'ar')
    $o.Title = $text.Title; $o.Body = $text.Body; $o.Note = $text.Note; $o.Glyph = [string][char]$step.Glyph
    $o.Counter = Get-Text 'tour.count' ($i + 1) $t.Steps.Count
    $o.StepIndex = $i; $o.StepCount = $t.Steps.Count; $o.CanBack = ($i -gt 0)
    $o.BackText = Get-Text 'tour.back'
    $o.NextText = $(if ($last) { Get-Text 'tour.done' } else { Get-Text 'tour.next' })
    $o.SkipText = $(if ($last) { '' } else { Get-Text 'tour.skip' })
    $o.CardWidth = [int][Math]::Min(384, [Math]::Max(260, ($pr.Width / $o.DpiScale) - 48))
    $size = $o.MeasureCard()

    $s = $o.DpiScale
    $gap = [int](14 * $s); $margin = [int](16 * $s); $pad = [int](6 * $s)
    $view = $page.RectangleToScreen($page.ClientRectangle)   # the visible part of the page, without its scroll bar
    $rect = Get-TourUnion $targets
    if ($Scroll -and -not $rect.IsEmpty -and $page.VerticalScroll.Visible) {
        $d = Get-TourScrollDelta ($rect.Top - $view.Top - $pad) ($rect.Bottom - $view.Top + $pad) $view.Height $size.Height $gap $margin
        if ($d -ne 0) {
            $cur = $page.AutoScrollPosition
            $page.AutoScrollPosition = New-Object System.Drawing.Point((-$cur.X), [Math]::Max(0, (-$cur.Y) + $d))
            $rect = Get-TourUnion $targets
        }
    }
    $hole = [System.Drawing.Rectangle]::Empty
    if (-not $rect.IsEmpty) {
        $h = [System.Drawing.Rectangle]::Intersect([System.Drawing.Rectangle]::Inflate($rect, $pad, $pad), $view)
        if ($h.Width -ge 8 -and $h.Height -ge 8) { $hole = New-Object System.Drawing.Rectangle(($h.X - $pr.X), ($h.Y - $pr.Y), $h.Width, $h.Height) }
    }
    $place = Get-TourCardPlacement $hole (New-Object System.Drawing.Size($pr.Width, $pr.Height)) $size $o.Rtl $gap $margin
    $o.Hole = $hole
    $o.CardLocation = New-Object System.Drawing.Point($place.X, $place.Y)
    $sig = '{0}|{1}|{2},{3}|{4}|{5}|{6}|{7}|{8}' -f $pr, $hole, $place.X, $place.Y, $i, $o.Body, $o.Note, $o.Rtl, $size
    if ($Animate -or $sig -ne $t.Sig) {
        $t.Sig = $sig
        $o.Render([bool]$Animate)
    }
}

function Show-TourStep {
    <# Shows step $Index (0-based) of the running tour. #>
    param([int]$Index)
    $t = $script:Tour
    if (-not $t) { return }
    if ($Index -ge $t.Steps.Count) { Stop-Tour; return }
    if ($Index -lt 0) { $Index = 0 }
    $first = ($t.Index -lt 0)
    Close-TourExpanders
    $t.Index = $Index
    $step = $t.Steps[$Index]
    if ($step.Expand) {
        $ex = Get-TourControl $step.Expand
        if ($ex -and -not $ex.Expanded) { $ex.Toggle(); [void]$t.Opened.Add($ex) }
    }
    Update-TourLayout -Scroll -Animate:(-not $first -and -not $script:TourNoAnimation)
}

function Move-TourStep([int]$Delta) {
    $t = $script:Tour
    if (-not $t) { return }
    $n = $t.Index + $Delta
    if ($n -ge $t.Steps.Count) { Stop-Tour; return }
    if ($n -lt 0) { return }
    Show-TourStep $n
}

function Invoke-TourKey([string]$Key) {
    $t = $script:Tour
    if (-not $t) { return }
    switch (Get-TourKeyAction $Key $t.Overlay.Rtl) {
        'next' { Move-TourStep 1 }
        'back' { Move-TourStep -1 }
        'skip' { Stop-Tour }
    }
}

# ---- first use: the window's "Ready to scan" bar also offers the tour (one calm message, not a second bar)
$script:TourOffer = $false        # true until the user takes the tour, closes the offer or starts a scan
$script:TourOfferUi = $null

function Add-TourOffer {
    <# Puts a "Start the tour" button and a close button on the window's result bar ($Bar). They show only on the first
       use and only while the bar still says "Ready to scan"; the bar then also says what the tour is (Update-TourOffer). #>
    param([Parameter(Mandatory)]$Bar, [bool]$FirstUse)
    $go = New-Object Fluent.FButton
    $go.Kind = 'Accent'; $go.Glyph = [string][char]0xE768; $go.Size = New-Object System.Drawing.Size(150, 34); $go.Font = [Fluent.Theme]::Semi(10)
    $x = New-Object Fluent.FButton
    $x.Kind = 'Subtle'; $x.Glyph = [string][char]0xE711; $x.Size = New-Object System.Drawing.Size(34, 34)
    $go.Visible = $false; $x.Visible = $false
    $Bar.Controls.Add($go); $Bar.Controls.Add($x)
    Bind-Text $go 'tour.offer.go'
    Bind-Text $x 'tour.offer.close' 'AccessibleName'
    $script:TourOfferUi = @{ Bar = $Bar; Go = $go; Close = $x; On = $false }
    $script:TourOffer = $FirstUse
    $Bar.Add_Layout({ param($s, $e) try { Set-TourOfferLayout } catch { } })
    $go.Add_Click({ Invoke-TourSafely { Start-Tour } })
    $x.Add_Click({ Hide-TourOffer })
}

function Set-TourOfferLayout {
    # the two buttons sit at the far end of the bar (left in Arabic), vertically centred; the text keeps clear of them
    $ui = $script:TourOfferUi
    if (-not $ui) { return }
    $b = $ui.Bar; $g = $ui.Go; $c = $ui.Close
    if (-not $ui.On) { if ($b.ReserveEnd -ne 0) { $b.ReserveEnd = 0; [void]$b.FitHeight(); $b.Invalidate() }; return }
    $s = [Fluent.Theme]::Scale
    $gw = [Math]::Max([int](120 * $s), $g.ContentWidth() + [int](12 * $s))
    if ($g.Width -ne $gw) { $g.Width = $gw }
    $edge = [int](14 * $s); $gap = [int](8 * $s)
    $reserve = $gw + $gap + $c.Width + $edge
    if ($b.ReserveEnd -ne $reserve) { $b.ReserveEnd = $reserve; [void]$b.FitHeight(); $b.Invalidate() }
    $y = [int][Math]::Max(0, ($b.Height - $g.Height) / 2)
    $yc = [int][Math]::Max(0, ($b.Height - $c.Height) / 2)
    if ($b.RightToLeft -eq 'Yes') { $c.Location = New-Object System.Drawing.Point($edge, $yc); $g.Location = New-Object System.Drawing.Point(($edge + $c.Width + $gap), $y) }
    else { $c.Location = New-Object System.Drawing.Point(($b.Width - $edge - $c.Width), $yc); $g.Location = New-Object System.Drawing.Point(($c.Left - $gap - $g.Width), $y) }
}

function Update-TourOffer {
    <# Shows or hides the offer. The window calls it whenever its result bar may have changed (Show-Info, Refresh-Buttons). #>
    $ui = $script:TourOfferUi
    if (-not $ui) { return }
    $mode = Get-TourControl 'infoMode'; $titleKey = Get-TourControl 'infoTitleKey'; $msgKey = Get-TourControl 'infoMsgKey'
    $on = [bool]($script:TourOffer -and $mode -eq 'keys' -and $titleKey -eq 'gui.info.ready.t' -and -not $script:Tour)
    $want = $(if ($on) { (Get-Text $msgKey) + "`n" + (Get-Text 'tour.offer.m') } else { $null })
    if ($on -eq $ui.On -and (-not $on -or $ui.Bar.Message -eq $want.Replace("`n", "`r`n"))) { return }
    $ui.On = $on
    $ui.Go.Visible = $on; $ui.Close.Visible = $on
    if ($on) { $ui.Bar.Message = $want }
    elseif ($mode -eq 'keys' -and $msgKey) { $ui.Bar.Message = Get-Text $msgKey }   # back to the plain "ready" text (a result text is never touched)
    Set-TourOfferLayout
    [void]$ui.Bar.FitHeight()
}

function Hide-TourOffer {
    $script:TourOffer = $false
    Update-TourOffer
}
function Start-Tour {
    <# Opens the tour over the window (nothing happens when it is already open or the window is not on screen). #>
    param([int]$At = 0)
    if ($script:Tour) { return }
    $form = Get-TourControl 'form'; $page = Get-TourControl 'page'
    if (-not $form -or -not $form.Visible -or -not $form.IsHandleCreated -or -not $page) { return }
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { return }
    Hide-TourOffer
    $state = Get-TourState
    $o = New-Object Fluent.FCoach
    $script:Tour = [pscustomobject]@{
        Overlay = $o; Steps = @(Select-TourSteps @(Get-TourSteps) $state); State = $state; Index = -1
        Scroll = $page.AutoScrollPosition; Opened = (New-Object System.Collections.ArrayList); Sig = ''; Timer = $null
    }
    if ($script:TourNoAnimation) { $o.Animate = $false }
    $o.Text = Get-Text 'tour.btn'
    $o.Attach($form)
    $o.Add_NextClick({ Invoke-TourSafely { Move-TourStep 1 } })
    $o.Add_BackClick({ Invoke-TourSafely { Move-TourStep -1 } })
    $o.Add_SkipClick({ Invoke-TourSafely { Stop-Tour } })
    $o.Add_CoachKey({ param($s, $e) $k = $e.KeyCode.ToString(); Invoke-TourSafely { Invoke-TourKey $k } })
    $o.Add_CoachWheel({ param($s, $e)
            $d = $e.Delta
            Invoke-TourSafely {
                $pg = Get-TourControl 'page'
                if ($pg -and $pg.VerticalScroll.Visible) {
                    $cur = $pg.AutoScrollPosition
                    $pg.AutoScrollPosition = New-Object System.Drawing.Point((-$cur.X), [Math]::Max(0, (-$cur.Y) - [int]($d / 120 * 60)))
                    Update-TourLayout
                }
            } })
    $o.Bounds = [Fluent.Win]::ScreenRect($page.Handle)
    $null = $o.Handle   # the window's dpi is known from here on
    Show-TourStep $At
    if (-not $script:Tour) { return }
    $o.Show()   # the card takes the keyboard focus (Tab, Enter, screen readers); Stop-Tour gives it back to the window
    $o.Present()
    $o.Activate()
    $tm = New-Object System.Windows.Forms.Timer
    $tm.Interval = 400   # follows anything that moves underneath (a scan finishing, a toast, the window being resized)
    $tm.Add_Tick({ Invoke-TourSafely { Update-TourLayout } })
    $script:Tour.Timer = $tm
    $tm.Start()
}

function Stop-Tour {
    <# Closes the tour and puts the window back as it was (sections it opened, scroll position). #>
    $t = $script:Tour
    if (-not $t) { return }
    try { Close-TourExpanders } catch { }
    $script:Tour = $null
    try { if ($t.Timer) { $t.Timer.Stop(); $t.Timer.Dispose() } } catch { }
    $hadFocus = $false
    try { $o = $t.Overlay; if ($o -and -not $o.IsDisposed) { $hadFocus = $o.ContainsFocus -or ([System.Windows.Forms.Form]::ActiveForm -eq $o); $o.Detach(); $o.Hide(); $o.Close(); $o.Dispose() } } catch { }
    try { $form = Get-TourControl 'form'; if ($hadFocus -and $form -and $form.Visible) { $form.Activate() } } catch { }   # the keyboard focus goes back where it was
    try {
        $page = Get-TourControl 'page'
        if ($page -and -not $page.IsDisposed) { $page.AutoScrollPosition = New-Object System.Drawing.Point((-$t.Scroll.X), (-$t.Scroll.Y)) }
    } catch { }
}

function Restore-TourFocus {
    $t = $script:Tour
    if (-not $t -or -not $t.Overlay -or $t.Overlay.IsDisposed) { return }
    $form = Get-TourControl 'form'
    if ($form) { [void]$form.BeginInvoke([Action] { try { if ($script:Tour -and -not $script:Tour.Overlay.IsDisposed) { $script:Tour.Overlay.Activate() } } catch { } }) }
}

function Connect-Tour {
    <# Wires the tour into the window once it is built: the header button, its tooltip, the first-use offer (hidden as soon
       as a scan starts) and the window events the overlay follows. #>
    $form = Get-TourControl 'form'; $btn = Get-TourControl 'btnTour'; $scan = Get-TourControl 'btnScan'
    if ($btn) {
        $btn.Add_Click({ Invoke-TourSafely { Start-Tour } })
        Bind-Text $btn 'tour.btn.tip' 'AccessibleDescription'
        $btn.Add_MouseEnter({ param($s, $e) try { $tip = Get-TourControl 'langTip'; if ($tip) { $tip.SetToolTip($s, (Get-Text 'tour.btn.tip')) } } catch { } })
    }
    if ($scan) { $scan.Add_Click({ Hide-TourOffer }) }
    if ($form) {
        $form.Add_Move({ if ($script:Tour) { Invoke-TourSafely { Update-TourLayout } } })
        $form.Add_Resize({ if ($script:Tour) { Invoke-TourSafely { Update-TourLayout } } })
        $form.Add_FormClosing({ if ($script:Tour) { Invoke-TourSafely { Stop-Tour } } })
        # the card keeps the keyboard while the tour is open: after a click on the window's title bar (a drag or a resize
        # ends first) it takes it back
        $form.Add_Activated({ if ($script:Tour -and [System.Windows.Forms.Control]::MouseButtons -eq 'None') { Invoke-TourSafely { Restore-TourFocus } } })
        $form.Add_ResizeEnd({ if ($script:Tour) { Invoke-TourSafely { Restore-TourFocus } } })
    }
}
