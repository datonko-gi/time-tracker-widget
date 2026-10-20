Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ===== Crash insulation + logging =====
$script:LogFile = Join-Path $env:APPDATA "WorkTracker\widget.log"
function Write-WidgetLog($msg) {
    try {
        $dir = Split-Path $script:LogFile
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Add-Content -Path $script:LogFile -Value "$ts  $msg" -ErrorAction SilentlyContinue
        $fi = Get-Item $script:LogFile -ErrorAction SilentlyContinue
        if ($fi -and $fi.Length -gt 200000) {
            $tail = Get-Content $script:LogFile -Tail 400 -ErrorAction SilentlyContinue
            Set-Content -Path $script:LogFile -Value $tail -ErrorAction SilentlyContinue
        }
    } catch {}
}
try { [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException) } catch {}

# Single instance
$script:Mutex = New-Object System.Threading.Mutex($false, 'WorkTrackerWidgetMutex')
if (-not $script:Mutex.WaitOne(0)) { Write-WidgetLog "second instance blocked"; exit }

# Dates are stored as yyyy-MM-ddTHH:mm:ss text: format and parse them the same way on every PC
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class Native {
    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll")]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")]
    public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);
    [DllImport("user32.dll")]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    [DllImport("gdi32.dll")]
    public static extern IntPtr CreateRoundRectRgn(int x1, int y1, int x2, int y2, int cx, int cy);
    [DllImport("user32.dll")]
    public static extern int SetWindowRgn(IntPtr hWnd, IntPtr hRgn, bool redraw);
    [DllImport("gdi32.dll")]
    public static extern bool DeleteObject(IntPtr o);
    [DllImport("user32.dll")]
    public static extern bool SetLayeredWindowAttributes(IntPtr hWnd, uint crKey, byte bAlpha, uint dwFlags);
    public const uint MOD_ALT = 0x1;
    public const uint MOD_CONTROL = 0x2;
    public const uint MOD_SHIFT = 0x4;
    public static readonly IntPtr HWND_BOTTOM = new IntPtr(1);
    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_NOACTIVATE = 0x08000000;
    public const int WS_EX_TOOLWINDOW = 0x00000080;
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_NOACTIVATE = 0x0010;
    public const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
    public const int DWMWCP_ROUND = 2;
    [DllImport("user32.dll")]
    public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr h, out RECTW r);
    public static readonly IntPtr DPI_PMV2 = new IntPtr(-4);
}
public struct RECTW { public int Left, Top, Right, Bottom; }
"@

# WndProc hook: WM_HOTKEY (0x0312) and WM_MOUSEWHEEL (0x020A, arrives when cursor
# hovers the widget thanks to Windows "scroll inactive windows").
Add-Type -TypeDefinition @"
using System;
using System.Windows.Forms;

public class MsgHook : NativeWindow {
    public event Action<int> HotkeyPressed;
    public event Action<int> WheelMoved;
    public void Hook(IntPtr h) { AssignHandle(h); }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0312) {
            if (HotkeyPressed != null) HotkeyPressed(m.WParam.ToInt32());
        } else if (m.Msg == 0x020A) {
            if (WheelMoved != null) {
                int d = (short)((m.WParam.ToInt64() >> 16) & 0xFFFF);
                WheelMoved(d);
            }
        }
        base.WndProc(ref m);
    }
}
"@ -ReferencedAssemblies "System.Windows.Forms"

# Per-pixel-alpha layered window. This is how the widget gets smooth (anti-aliased)
# rounded corners AND zero drop shadow at the same time: a UpdateLayeredWindow window has no DWM
# frame -> no shadow, and its alpha channel gives true AA corners (a region cannot be AA). It is
# also monitor-agnostic (no region to clip). pptDst = NULL so WinForms keeps owning the position.
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class Layered {
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr o);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [DllImport("user32.dll")] static extern bool UpdateLayeredWindow(IntPtr h, IntPtr dcDst, IntPtr pDst, ref SIZE size, IntPtr dcSrc, ref POINT pSrc, int key, ref BLENDFUNCTION blend, int flags);
    [StructLayout(LayoutKind.Sequential)] public struct SIZE { public int cx, cy; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
    [StructLayout(LayoutKind.Sequential)] public struct BLENDFUNCTION { public byte Op, Flags, Alpha, Format; }
    public static void Update(IntPtr hwnd, IntPtr hbmp, int w, int h) {
        IntPtr screenDC = GetDC(IntPtr.Zero);
        IntPtr memDC = CreateCompatibleDC(screenDC);
        IntPtr old = SelectObject(memDC, hbmp);
        SIZE size; size.cx = w; size.cy = h;
        POINT src; src.x = 0; src.y = 0;
        BLENDFUNCTION bf; bf.Op = 0; bf.Flags = 0; bf.Alpha = 255; bf.Format = 1; // AC_SRC_ALPHA
        UpdateLayeredWindow(hwnd, screenDC, IntPtr.Zero, ref size, memDC, ref src, 0, ref bf, 2); // ULW_ALPHA
        SelectObject(memDC, old);
        DeleteDC(memDC);
        ReleaseDC(IntPtr.Zero, screenDC);
    }
}
"@

function New-RoundedPath([single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $r * 2.0
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

# ===== Geometry (all real pixels; approved design = 2x mockup / 2) =====
$script:FormW   = 294
$script:FormH   = 115
$script:LColW   = 70
$script:KnobCX  = 35.0
$script:KnobCY  = 51.0
$script:KnobR   = 26.0
$script:NumR    = 34.0
$script:RowX    = 70
$script:RowY0   = 6
$script:RowH    = 18
$script:RowX1   = 287
$script:FootY   = 98

# ===== Palette =====
function C($r,$g,$b) { return [System.Drawing.Color]::FromArgb($r,$g,$b) }
function CA($a,$r,$g,$b) { return [System.Drawing.Color]::FromArgb($a,$r,$g,$b) }
$script:ColBg       = C 232 234 238
$script:Hues  = @((C 100 140 180),(C 188 148 90),(C 120 165 120),(C 160 120 165),(C 138 138 144))
$script:Tints = @((C 199 213 228),(C 234 224 205),(C 216 228 216),(C 229 216 230),(C 222 222 226))
$script:ColTrack    = CA 165 255 255 255
$script:ColTick     = C 40 40 40
$script:ColName     = C 48 52 60
$script:ColNameHot  = C 22 32 44
$script:ColNums     = C 90 94 102
$script:ColFoot     = C 107 112 120
$script:ColStatus   = C 138 142 150
$script:ColDayPast  = C 198 203 211
$script:ColDayNow   = C 74 78 86
$script:ColDayFut   = C 225 228 234
$script:ColWire     = C 169 175 185
$script:KnobRunT    = C 132 202 132
$script:KnobRunB    = C 89 166 89
$script:KnobOffT    = C 199 206 217
$script:KnobOffB    = C 150 161 176
$script:ColPlayIcon = C 74 84 98

function Get-Hue($i)  { return $script:Hues[$i % $script:Hues.Count] }
function Get-Tint($i) { return $script:Tints[$i % $script:Tints.Count] }

# ===== Time helpers (all day and week math runs in the local time zone) =====
function Get-Now { [DateTime]::Now }
function Get-MondayOf($d) {
    $dow = [int]$d.DayOfWeek
    $off = 6; if ($dow -ne 0) { $off = $dow - 1 }
    return $d.Date.AddDays(-$off)
}
function Format-DKey($d) { $d.ToString("yyyy-MM-dd") }

$script:EnDays   = @('Mon','Tue','Wed','Thu','Fri','Sat','Sun')
$script:EnMonths = @('Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec')

# ===== Data =====
$script:DataDir  = Join-Path $env:APPDATA "WorkTracker"
$script:DataFile = Join-Path $script:DataDir "data.json"
$script:SessFile = Join-Path $script:DataDir "sessions.jsonl"
if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }

function New-DefaultProjects {
    return @(
        @{ name = "Client work"; plan = 15 },
        @{ name = "Product";     plan = 10 },
        @{ name = "Learning";    plan = 5 },
        @{ name = "Admin";       plan = 5 },
        @{ name = "Other";       plan = 5 }
    )
}

function Load-Data {
    if (-not (Test-Path $script:DataFile)) {
        return @{ projects = (New-DefaultProjects); active = 0; running = $false; sessionStart = $null; lastAlive = $null; posX = $null; posY = $null }
    }
    try {
        $obj = Get-Content $script:DataFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $projects = @()
        foreach ($p in @($obj.projects)) {
            $nm = "Project"; if ($p.name) { $nm = [string]$p.name }
            $pl = 10
            $tmp = 0
            if ([int]::TryParse([string]$p.plan, [ref]$tmp) -and $tmp -ge 1 -and $tmp -le 100) { $pl = $tmp }
            $projects += @{ name = $nm; plan = $pl }
        }
        if ($projects.Count -eq 0) { $projects = New-DefaultProjects }
        $active = 0
        if ($obj.PSObject.Properties.Name -contains 'active') { $active = [int]$obj.active }
        if ($active -lt 0) { $active = 0 }
        if ($active -ge $projects.Count) { $active = $projects.Count - 1 }
        $running = $false
        if ($obj.PSObject.Properties.Name -contains 'running') { $running = [bool]$obj.running }
        $ss = $null; if ($obj.sessionStart) { $ss = [string]$obj.sessionStart }
        $la = $null; if ($obj.lastAlive)    { $la = [string]$obj.lastAlive }
        $px = $null; $py = $null
        if ($obj.PSObject.Properties.Name -contains 'posX') { $px = $obj.posX }
        if ($obj.PSObject.Properties.Name -contains 'posY') { $py = $obj.posY }
        return @{ projects = $projects; active = $active; running = $running; sessionStart = $ss; lastAlive = $la; posX = $px; posY = $py }
    } catch {
        Write-WidgetLog "Load-Data failed: $($_.Exception.Message)"
        return @{ projects = (New-DefaultProjects); active = 0; running = $false; sessionStart = $null; lastAlive = $null; posX = $null; posY = $null }
    }
}

function Save-Data {
    $projOut = @()
    foreach ($p in $script:Data.projects) { $projOut += [PSCustomObject]@{ name = $p.name; plan = $p.plan } }
    $obj = [PSCustomObject]@{
        version      = 1
        projects     = @($projOut)
        active       = $script:Data.active
        running      = $script:Data.running
        sessionStart = $script:Data.sessionStart
        lastAlive    = $script:Data.lastAlive
        posX         = $script:Data.posX
        posY         = $script:Data.posY
    }
    try { $obj | ConvertTo-Json -Depth 5 -Compress | Set-Content -Path $script:DataFile -Encoding UTF8 } catch {}
}

$script:Data = Load-Data
function Active-Proj { return $script:Data.projects[$script:Data.active] }

# ===== Sessions log + aggregation =====
# sessions.jsonl line: {"id":"...","n":"Product","s":"2026-07-03T09:12:00","e":"2026-07-03T10:00:00","m":48.0}
# Aggregate: weekKey(Monday yyyy-MM-dd) -> name -> double[7] minutes
$script:Agg = @{}

function Add-Agg($name, [DateTime]$s, [double]$min) {
    $wk = Format-DKey (Get-MondayOf $s)
    if (-not $script:Agg.ContainsKey($wk)) { $script:Agg[$wk] = @{} }
    if (-not $script:Agg[$wk].ContainsKey($name)) { $script:Agg[$wk][$name] = @(0.0,0.0,0.0,0.0,0.0,0.0,0.0) }
    $dow = [int]$s.DayOfWeek; $di = 6; if ($dow -ne 0) { $di = $dow - 1 }
    $script:Agg[$wk][$name][$di] = [double]$script:Agg[$wk][$name][$di] + $min
}

function Rebuild-Agg {
    $script:Agg = @{}
    if (-not (Test-Path $script:SessFile)) { return }
    foreach ($line in (Get-Content $script:SessFile -ErrorAction SilentlyContinue)) {
        if (-not $line -or -not $line.Trim()) { continue }
        try {
            $o = $line | ConvertFrom-Json
            $s = [DateTime]::Parse($o.s)
            Add-Agg ([string]$o.n) $s ([double]$o.m)
        } catch {}
    }
}

# Append a finished session, splitting at local midnight so each line lives in one day
function Add-Session($name, [DateTime]$s, [DateTime]$e) {
    if ($e -le $s) { return }
    $id = (Get-Now).ToString("yyyyMMddHHmmssfff")
    $cur = $s
    while ($cur -lt $e) {
        $dayEnd = $cur.Date.AddDays(1)
        $segEnd = $e; if ($dayEnd -lt $e) { $segEnd = $dayEnd }
        $min = [Math]::Round(($segEnd - $cur).TotalMinutes, 1)
        if ($min -ge 0.1) {
            $rec = [PSCustomObject]@{ id = $id; n = $name; s = $cur.ToString("yyyy-MM-ddTHH:mm:ss"); e = $segEnd.ToString("yyyy-MM-ddTHH:mm:ss"); m = $min }
            try { Add-Content -Path $script:SessFile -Value ($rec | ConvertTo-Json -Compress) -Encoding UTF8 } catch {}
            Add-Agg $name $cur $min
        }
        $cur = $segEnd
    }
}

function Undo-LastSession {
    if (-not (Test-Path $script:SessFile)) { return }
    $lines = @(Get-Content $script:SessFile -ErrorAction SilentlyContinue | Where-Object { $_ -and $_.Trim() })
    if ($lines.Count -eq 0) { return }
    try { $lastId = ([string](($lines[$lines.Count - 1] | ConvertFrom-Json).id)) } catch { return }
    $keep = @($lines | Where-Object { try { ([string](($_ | ConvertFrom-Json).id)) -ne $lastId } catch { $true } })
    Set-Content -Path $script:SessFile -Value $keep -Encoding UTF8
    Rebuild-Agg
}

function Get-WeekMinutes($name, $weekKey) {
    if (-not $script:Agg.ContainsKey($weekKey)) { return 0.0 }
    if (-not $script:Agg[$weekKey].ContainsKey($name)) { return 0.0 }
    $t = 0.0
    foreach ($v in $script:Agg[$weekKey][$name]) { $t += [double]$v }
    return $t
}

function Get-DayMinutes($name, $weekKey, $di) {
    if (-not $script:Agg.ContainsKey($weekKey)) { return 0.0 }
    if (-not $script:Agg[$weekKey].ContainsKey($name)) { return 0.0 }
    return [double]$script:Agg[$weekKey][$name][$di]
}

Rebuild-Agg

# ===== Crash recovery =====
# Fresh heartbeat (gap < 3 min, e.g. a deliberate widget restart) -> resume the session seamlessly.
# Stale heartbeat (real crash discovered later) -> close the orphan session at lastAlive.
if ($script:Data.running -and $script:Data.sessionStart) {
    $resume = $false
    try {
        $la = [DateTime]::Parse($script:Data.sessionStart)
        if ($script:Data.lastAlive) {
            $la2 = [DateTime]::Parse($script:Data.lastAlive)
            if ($la2 -gt $la) { $la = $la2 }
        }
        if (((Get-Now) - $la).TotalMinutes -lt 3) { $resume = $true }
    } catch {}
    if ($resume) {
        Write-WidgetLog "resuming running session across restart (started $($script:Data.sessionStart))"
    } else {
        try {
            $s = [DateTime]::Parse($script:Data.sessionStart)
            $e = $s
            if ($script:Data.lastAlive) {
                $la3 = [DateTime]::Parse($script:Data.lastAlive)
                if ($la3 -gt $s) { $e = $la3 }
            }
            Add-Session (Active-Proj).name $s $e
            Write-WidgetLog "recovered orphan session $($script:Data.sessionStart) -> $($e.ToString('s'))"
        } catch { Write-WidgetLog "recovery failed: $($_.Exception.Message)" }
        $script:Data.running = $false
        $script:Data.sessionStart = $null
        Save-Data
    }
}

# ===== Session control =====
function Get-LiveMinutes {
    if (-not $script:Data.running -or -not $script:Data.sessionStart) { return 0.0 }
    try { return ((Get-Now) - [DateTime]::Parse($script:Data.sessionStart)).TotalMinutes } catch { return 0.0 }
}

function Start-Session {
    $script:AutoPaused = $false
    $script:Data.running = $true
    $script:Data.sessionStart = (Get-Now).ToString("yyyy-MM-ddTHH:mm:ss")
    $script:Data.lastAlive = $script:Data.sessionStart
    Save-Data
    Write-WidgetLog "start [$($script:Data.active)] $((Active-Proj).name)"
}

function Stop-Session-At([DateTime]$end) {
    if (-not $script:Data.running) { return }
    try {
        $s = [DateTime]::Parse($script:Data.sessionStart)
        if ($end -lt $s) { $end = $s }
        Add-Session (Active-Proj).name $s $end
    } catch {}
    $script:Data.running = $false
    $script:Data.sessionStart = $null
    Save-Data
    Write-WidgetLog "stop [$($script:Data.active)] $((Active-Proj).name)"
}

function Stop-Session {
    Stop-Session-At (Get-Now)
}

function Switch-To($i) {
    if ($i -lt 0 -or $i -ge $script:Data.projects.Count) { return }
    if ($script:Data.running) {
        if ($i -eq $script:Data.active) { return }
        Stop-Session
        $script:Data.active = $i
        Start-Session
    } else {
        $script:Data.active = $i
        Start-Session
    }
    Render-Widget
}

function Select-Only($i) {
    if ($i -lt 0 -or $i -ge $script:Data.projects.Count) { return }
    if ($i -eq $script:Data.active) { return }
    $script:Data.active = $i
    Save-Data
    Render-Widget
}

function Toggle-Session {
    if ($script:Data.running) { Stop-Session } else { Start-Session }
    Render-Widget
}

# ===== Layout helpers =====
function Get-Angles($n) {
    if ($n -le 1) { return @(0.0) }
    $step = 100.0 / ($n - 1)
    if ($step -gt 25.0) { $step = 25.0 }
    $start = -$step * ($n - 1) / 2.0
    $a = @()
    for ($i = 0; $i -lt $n; $i++) { $a += ($start + $i * $step) }
    return $a
}

function Get-NumPos($i) {
    $angles = Get-Angles $script:Data.projects.Count
    $rad = $angles[$i] * [Math]::PI / 180.0
    return @{
        x = $script:KnobCX + $script:NumR * [Math]::Cos($rad)
        y = $script:KnobCY + $script:NumR * [Math]::Sin($rad)
        deg = $angles[$i]
    }
}

function Get-RowCenterY($i) { return $script:RowY0 + $i * $script:RowH + $script:RowH / 2.0 }

function Get-HourScale {
    $maxPlan = 10
    foreach ($p in $script:Data.projects) { if ([int]$p.plan -gt $maxPlan) { $maxPlan = [int]$p.plan } }
    $s = [Math]::Ceiling(($maxPlan * 4.0 / 3.0) / 5.0) * 5
    if ($s -lt 40) { $s = 40 }
    return [double]$s
}

function New-RoundedPath([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $r * 2
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

# ===== Form =====
$form = New-Object System.Windows.Forms.Form
$form.Size = New-Object System.Drawing.Size($script:FormW, $script:FormH)
$form.FormBorderStyle = "None"
$form.ShowInTaskbar = $false
$form.StartPosition = "Manual"
$form.BackColor = $script:ColBg
$form.TopMost = $false
$form.Text = "WorkTracker"

function Test-OnScreen($x, $y, $w, $h) {
    foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
        $wa = $s.WorkingArea
        if (($x + $w) -gt ($wa.Left + 60) -and $x -lt ($wa.Right - 60) -and
            ($y + $h) -gt ($wa.Top + 24) -and $y -lt ($wa.Bottom - 24)) { return $true }
    }
    return $false
}

$scr = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$defX = $scr.Right - $script:FormW - 20
$defY = $scr.Top + 10
if ($null -ne $script:Data.posX -and $null -ne $script:Data.posY) {
    $x = [int]$script:Data.posX; $y = [int]$script:Data.posY
    if (-not (Test-OnScreen $x $y $script:FormW $script:FormH)) {
        $x = [Math]::Max($scr.Left, [Math]::Min($x, $scr.Right - $script:FormW))
        $y = [Math]::Max($scr.Top,  [Math]::Min($y, $scr.Bottom - $script:FormH))
        Write-WidgetLog "saved pos off-screen, clamped to $x,$y"
    }
    $form.Location = New-Object System.Drawing.Point($x, $y)
} else {
    $form.Location = New-Object System.Drawing.Point([int]$defX, [int]$defY)
}

# No child panel: the whole widget is drawn into a 32bpp premultiplied-alpha bitmap and blitted
# with UpdateLayeredWindow (see Render-Widget). Mouse handlers live on $form directly.
$script:CornerR = 9   # logical px; matches the Win11 DWMWCP_ROUND look

# ===== Drawing =====
function Draw-Widget($g) {
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

    $now      = Get-Now
    $curWk    = Format-DKey (Get-MondayOf $now)
    $projects = $script:Data.projects
    $n        = $projects.Count
    $active   = $script:Data.active
    $running  = $script:Data.running
    $scaleMin = (Get-HourScale) * 60.0
    $liveMin  = Get-LiveMinutes

    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment = [System.Drawing.StringAlignment]::Center
    $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
    $fmtC = New-Object System.Drawing.StringFormat
    $fmtC.Alignment = [System.Drawing.StringAlignment]::Center
    $fmtC.LineAlignment = [System.Drawing.StringAlignment]::Center
    $fmtC.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
    $fmtC.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
    $fmtR = New-Object System.Drawing.StringFormat
    $fmtR.Alignment = [System.Drawing.StringAlignment]::Far
    $fmtR.LineAlignment = [System.Drawing.StringAlignment]::Center
    $fmtL = New-Object System.Drawing.StringFormat
    $fmtL.Alignment = [System.Drawing.StringAlignment]::Near
    $fmtL.LineAlignment = [System.Drawing.StringAlignment]::Center
    $fmtL.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
    $fmtL.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter

    $fName  = New-Object System.Drawing.Font("Segoe UI", 7.5)
    $fNameB = New-Object System.Drawing.Font("Segoe UI", 7.5, [System.Drawing.FontStyle]::Bold)
    $fNums  = New-Object System.Drawing.Font("Segoe UI", 6.5)
    $fNumsB = New-Object System.Drawing.Font("Segoe UI", 6.5, [System.Drawing.FontStyle]::Bold)
    $fBig   = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
    $fSmall = New-Object System.Drawing.Font("Segoe UI", 7)
    $fChip  = New-Object System.Drawing.Font("Segoe UI", 6.5, [System.Drawing.FontStyle]::Bold)

    # ---- connector (ribbon when running, thin wire when paused) ----
    $np = Get-NumPos $active
    $rowCY = Get-RowCenterY $active
    $rad = $np.deg * [Math]::PI / 180.0
    $p0 = New-Object System.Drawing.PointF ([float]$np.x, [float]$np.y)
    $p1 = New-Object System.Drawing.PointF ([float]($script:KnobCX + 46 * [Math]::Cos($rad)), [float]($script:KnobCY + 46 * [Math]::Sin($rad)))
    $p2 = New-Object System.Drawing.PointF ([float]64, [float]$rowCY)
    $p3 = New-Object System.Drawing.PointF ([float]78, [float]$rowCY)
    if ($running) {
        $pen = New-Object System.Drawing.Pen((Get-Tint $active), 8.0)
    } else {
        $pen = New-Object System.Drawing.Pen($script:ColWire, 1.4)
    }
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $g.DrawBezier($pen, $p0, $p1, $p2, $p3)
    $pen.Dispose()

    # ---- rows ----
    $rowsPath = New-RoundedPath ([float]$script:RowX) ([float]$script:RowY0) ([float]($script:RowX1 - $script:RowX)) ([float]($script:RowH * $n)) 4
    $g.SetClip($rowsPath)
    for ($i = 0; $i -lt $n; $i++) {
        $ry = $script:RowY0 + $i * $script:RowH
        if ($running -and $i -eq $active) {
            $b = New-Object System.Drawing.SolidBrush((Get-Tint $i))
            $g.FillRectangle($b, $script:RowX, $ry, ($script:RowX1 - $script:RowX), $script:RowH)
            $b.Dispose()
        }
    }
    $g.ResetClip()
    $rowsPath.Dispose()

    for ($i = 0; $i -lt $n; $i++) {
        $ry  = $script:RowY0 + $i * $script:RowH
        $cy  = $ry + $script:RowH / 2.0
        $hue = Get-Hue $i
        $isA = ($i -eq $active)

        # color square
        $b = New-Object System.Drawing.SolidBrush($hue)
        $g.FillRectangle($b, 75, [float]($cy - 3.5), 7, 7)
        $b.Dispose()
        if ($isA) {
            $op = New-Object System.Drawing.Pen((CA 115 0 0 0), 1.0)
            $g.DrawRectangle($op, 74, [float]($cy - 4.5), 9, 9)
            $op.Dispose()
        }

        # name
        $nameCol = $script:ColName; $nf = $fName
        if ($isA) { $nameCol = $script:ColNameHot; $nf = $fNameB }
        $nb = New-Object System.Drawing.SolidBrush($nameCol)
        $nameRect = New-Object System.Drawing.RectangleF ([float]86, [float]$ry, [float]68, [float]$script:RowH)
        $g.DrawString([string]$projects[$i].name, $nf, $nb, $nameRect, $fmtL)
        $nb.Dispose()

        # track: common hour scale, tick at plan, overtime keeps the same color
        $tx = 158.0; $tw = 84.0; $th = 5.0; $ty = $cy - $th / 2.0
        $tb = New-Object System.Drawing.SolidBrush($script:ColTrack)
        $tp = New-RoundedPath ([float]$tx) ([float]$ty) ([float]$tw) ([float]$th) 2.5
        $g.FillPath($tb, $tp)
        $tp.Dispose(); $tb.Dispose()

        $factMin = Get-WeekMinutes $projects[$i].name $curWk
        if ($running -and $isA) { $factMin += $liveMin }
        $frac = $factMin / $scaleMin
        if ($frac -gt 1.0) { $frac = 1.0 }
        if ($frac -gt 0.005) {
            $fw = [float]($tw * $frac)
            if ($fw -lt $th) { $fw = $th }
            $fb = New-Object System.Drawing.SolidBrush($hue)
            $fp = New-RoundedPath ([float]$tx) ([float]$ty) $fw ([float]$th) 2.5
            $g.FillPath($fb, $fp)
            $fp.Dispose(); $fb.Dispose()
        }
        $planFrac = ([double]$projects[$i].plan * 60.0) / $scaleMin
        if ($planFrac -gt 1.0) { $planFrac = 1.0 }
        $tickX = [float]($tx + $tw * $planFrac)
        $tkp = New-Object System.Drawing.Pen($script:ColTick, 1.0)
        $g.DrawLine($tkp, $tickX, [float]($ty - 1.5), $tickX, [float]($ty + $th + 1.5))
        $tkp.Dispose()

        # numbers fact/plan
        $numCol = $script:ColNums; $numF = $fNums
        if ($isA) { $numCol = $script:ColNameHot; $numF = $fNumsB }
        $numB = New-Object System.Drawing.SolidBrush($numCol)
        $factH = [Math]::Round($factMin / 60.0, 1)
        $factTxt = "$factH"
        if ($factH -eq [Math]::Floor($factH)) { $factTxt = "$([int]$factH)" }
        $numRect = New-Object System.Drawing.RectangleF ([float]247, [float]$ry, [float]35, [float]$script:RowH)
        $g.DrawString("$factTxt/$([int]$projects[$i].plan)", $numF, $numB, $numRect, $fmtR)
        $numB.Dispose()
    }

    # ---- footer: day squares + date + week total ----
    $dowNow = [int]$now.DayOfWeek; $diNow = 6; if ($dowNow -ne 0) { $diNow = $dowNow - 1 }
    for ($d = 0; $d -lt 7; $d++) {
        $col = $script:ColDayFut
        if ($d -lt $diNow) { $col = $script:ColDayPast }
        elseif ($d -eq $diNow) { $col = $script:ColDayNow }
        $b = New-Object System.Drawing.SolidBrush($col)
        $g.FillRectangle($b, [float](71 + $d * 7), [float]($script:FootY + 3), 5, 5)
        $b.Dispose()
    }
    $fb2 = New-Object System.Drawing.SolidBrush($script:ColFoot)
    $dateTxt = "$($script:EnDays[$diNow]), $($script:EnMonths[$now.Month - 1]) $($now.Day)"
    $dateRect = New-Object System.Drawing.RectangleF ([float]124, [float]$script:FootY, [float]90, [float]12)
    $g.DrawString($dateTxt, $fSmall, $fb2, $dateRect, $fmtL)
    $totMin = 0.0
    foreach ($p in $projects) { $totMin += Get-WeekMinutes $p.name $curWk }
    if ($running) { $totMin += $liveMin }
    $planTot = 0
    foreach ($p in $projects) { $planTot += [int]$p.plan }
    $totH = [Math]::Round($totMin / 60.0, 1)
    $totRect = New-Object System.Drawing.RectangleF ([float]182, [float]$script:FootY, [float]100, [float]12)
    $g.DrawString("$totH / $planTot h", $fSmall, $fb2, $totRect, $fmtR)
    $fb2.Dispose()

    # ---- knob ----
    for ($i = 3; $i -ge 1; $i--) {
        $a = 25 - ($i * 5)
        $sh = New-Object System.Drawing.SolidBrush((CA $a 0 0 0))
        $g.FillEllipse($sh, [float]($script:KnobCX - $script:KnobR + $i - 1), [float]($script:KnobCY - $script:KnobR + $i), [float]($script:KnobR * 2), [float]($script:KnobR * 2))
        $sh.Dispose()
    }
    $kT = $script:KnobOffT; $kB = $script:KnobOffB
    if ($running) { $kT = $script:KnobRunT; $kB = $script:KnobRunB }
    $bodyRect = New-Object System.Drawing.RectangleF ([float]($script:KnobCX - $script:KnobR), [float]($script:KnobCY - $script:KnobR), [float]($script:KnobR * 2), [float]($script:KnobR * 2))
    $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush($bodyRect, $kT, $kB, 90.0)
    $g.FillEllipse($grad, $bodyRect.X, $bodyRect.Y, $bodyRect.Width, $bodyRect.Height)
    $grad.Dispose()
    $rim = New-Object System.Drawing.Pen((CA 80 0 0 0), 1.0)
    $g.DrawEllipse($rim, $bodyRect.X, $bodyRect.Y, $bodyRect.Width, $bodyRect.Height)
    $rim.Dispose()
    $hlW = $script:KnobR * 2 * 0.62; $hlH = $script:KnobR * 2 * 0.28
    $hlX = $script:KnobCX - $hlW / 2.0; $hlY = $script:KnobCY - $script:KnobR + $script:KnobR * 2 * 0.09
    $hlRect = New-Object System.Drawing.RectangleF ([float]$hlX, [float]$hlY, [float]$hlW, [float]$hlH)
    $hlGrad = New-Object System.Drawing.Drawing2D.LinearGradientBrush($hlRect, (CA 150 255 255 255), (CA 0 255 255 255), 90.0)
    $g.FillEllipse($hlGrad, [float]$hlX, [float]$hlY, [float]$hlW, [float]$hlH)
    $hlGrad.Dispose()

    # detents + indicator capsule (rotated precisely around the knob center)
    $angles = Get-Angles $n
    for ($i = 0; $i -lt $n; $i++) {
        $g.TranslateTransform([float]$script:KnobCX, [float]$script:KnobCY)
        $g.RotateTransform([float]$angles[$i])
        if ($i -eq $active) {
            $capCol = [System.Drawing.Color]::White
            if (-not $running) { $capCol = C 62 70 82 }
            $cb = New-Object System.Drawing.SolidBrush($capCol)
            $cap = New-RoundedPath 19.0 -1.75 6.5 3.5 1.75
            $g.FillPath($cb, $cap)
            $cap.Dispose(); $cb.Dispose()
        } else {
            $dCol = CA 130 255 255 255
            if (-not $running) { $dCol = CA 110 0 0 0 }
            $dp = New-Object System.Drawing.Pen($dCol, 1.2)
            $dp.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
            $dp.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
            $g.DrawLine($dp, 22.0, 0.0, 24.5, 0.0)
            $dp.Dispose()
        }
        $g.ResetTransform()
    }

    # center: pause bars + timer when running, play triangle when paused
    if ($running) {
        $wb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
        $bar1 = New-RoundedPath 30.5 42.0 3.0 8.5 1.2
        $bar2 = New-RoundedPath 36.5 42.0 3.0 8.5 1.2
        $g.FillPath($wb, $bar1); $g.FillPath($wb, $bar2)
        $bar1.Dispose(); $bar2.Dispose()
        $el = ""
        try {
            $ts = (Get-Now) - [DateTime]::Parse($script:Data.sessionStart)
            $el = "{0}:{1:d2}:{2:d2}" -f [int][Math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds
        } catch {}
        $tRect = New-Object System.Drawing.RectangleF ([float]($script:KnobCX - 26), [float]54, [float]52, [float]10)
        $g.DrawString($el, $fSmall, $wb, $tRect, $fmt)
        $wb.Dispose()
    } else {
        $pb = New-Object System.Drawing.SolidBrush($script:ColPlayIcon)
        $pts = @(
            (New-Object System.Drawing.PointF 31.5, 44.5),
            (New-Object System.Drawing.PointF 42.5, 51.0),
            (New-Object System.Drawing.PointF 31.5, 57.5)
        )
        $g.FillPolygon($pb, $pts)
        $pb.Dispose()
    }

    # numbers around the knob
    for ($i = 0; $i -lt $n; $i++) {
        $pt = Get-NumPos $i
        $hue = Get-Hue $i
        if ($i -eq $active) {
            $cb = New-Object System.Drawing.SolidBrush($hue)
            $g.FillEllipse($cb, [float]($pt.x - 5.5), [float]($pt.y - 5.5), 11, 11)
            $cb.Dispose()
            $cp = New-Object System.Drawing.Pen((CA 40 0 0 0), 1.0)
            $g.DrawEllipse($cp, [float]($pt.x - 5.5), [float]($pt.y - 5.5), 11, 11)
            $cp.Dispose()
            $wb2 = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
            $r = New-Object System.Drawing.RectangleF ([float]($pt.x - 6), [float]($pt.y - 5.6), [float]12, [float]11)
            $g.DrawString("$($i + 1)", $fChip, $wb2, $r, $fmt)
            $wb2.Dispose()
        } else {
            $nb2 = New-Object System.Drawing.SolidBrush($hue)
            $r = New-Object System.Drawing.RectangleF ([float]($pt.x - 6), [float]($pt.y - 5.5), [float]12, [float]11)
            $g.DrawString("$($i + 1)", $fNums, $nb2, $r, $fmt)
            $nb2.Dispose()
        }
    }

    # name + status under the knob
    $hueA = Get-Hue $active
    $nb3 = New-Object System.Drawing.SolidBrush($hueA)
    $nmRect = New-Object System.Drawing.RectangleF ([float]0, [float]80, [float]$script:LColW, [float]12)
    $g.DrawString((Active-Proj).name, $fBig, $nb3, $nmRect, $fmtC)
    $nb3.Dispose()
    $sb3 = New-Object System.Drawing.SolidBrush($script:ColStatus)
    $stTxt = "paused"
    if ($running) { $stTxt = "recording" }
    else {
        $lbl = "paused"
        if ($script:AutoPaused) { $lbl = "auto-paused" }
        $stTxt = $lbl
        $todayMin = 0.0
        foreach ($p in $projects) { $todayMin += Get-DayMinutes $p.name $curWk $diNow }
        # the 70 px status column has no room for "paused" and the total together
        if ($todayMin -gt 0 -and -not $script:AutoPaused) { $stTxt = "today $([Math]::Round($todayMin / 60.0, 1)) h" }
    }
    $stRect = New-Object System.Drawing.RectangleF ([float]0, [float]93, [float]$script:LColW, [float]11)
    $g.DrawString($stTxt, $fSmall, $sb3, $stRect, $fmtC)
    $sb3.Dispose()

    $fName.Dispose(); $fNameB.Dispose(); $fNums.Dispose(); $fNumsB.Dispose()
    $fBig.Dispose(); $fSmall.Dispose(); $fChip.Dispose()
    $fmt.Dispose(); $fmtR.Dispose(); $fmtL.Dispose(); $fmtC.Dispose()
}

# Render the widget into a premultiplied-alpha bitmap with AA rounded corners, then push it to
# the layered window. FillPath with a texture brush (AA on) is what anti-aliases the corner edge
# a region never can. Replaces every old Render-Widget.
$script:Rendering = $false
function Render-Widget {
    if ($script:Rendering) { return }
    $script:Rendering = $true
    try {
        $w = [int]$script:FormW; $h = [int]$script:FormH
        $content = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppPArgb)
        $gc = [System.Drawing.Graphics]::FromImage($content)
        $bgBrush = New-Object System.Drawing.SolidBrush($script:ColBg)
        $gc.FillRectangle($bgBrush, 0, 0, $w, $h)
        $bgBrush.Dispose()
        Draw-Widget $gc
        $gc.Dispose()

        $final = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppPArgb)
        $gf = [System.Drawing.Graphics]::FromImage($final)
        $gf.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $gf.Clear([System.Drawing.Color]::Transparent)
        $path = New-RoundedPath 0 0 $w $h $script:CornerR
        $tb = New-Object System.Drawing.TextureBrush($content)
        $gf.FillPath($tb, $path)
        $tb.Dispose(); $path.Dispose(); $gf.Dispose()
        $content.Dispose()

        $hbmp = $final.GetHbitmap([System.Drawing.Color]::FromArgb(0, 0, 0, 0))
        [Layered]::Update($form.Handle, $hbmp, $w, $h)
        [Native]::DeleteObject($hbmp) | Out-Null
        $final.Dispose()
    } catch { Write-WidgetLog "render: $($_.Exception.Message)" }
    $script:Rendering = $false
}

# ===== Hit testing / click vs drag =====
$script:Drag = @{ Down=$false; Dragging=$false; StartSX=0; StartSY=0; FormStartX=0; FormStartY=0; ClickX=0; ClickY=0 }
$script:UiOpen = $false

function Hit-Knob($x, $y) {
    $dx = $x - $script:KnobCX; $dy = $y - $script:KnobCY
    return (($dx * $dx + $dy * $dy) -le ($script:KnobR * $script:KnobR))
}
function Hit-Number($x, $y) {
    for ($i = 0; $i -lt $script:Data.projects.Count; $i++) {
        $pt = Get-NumPos $i
        $dx = $x - $pt.x; $dy = $y - $pt.y
        if (($dx * $dx + $dy * $dy) -le 64) { return $i }
    }
    return -1
}
function Hit-Row($x, $y) {
    if ($x -lt $script:RowX) { return -1 }
    $n = $script:Data.projects.Count
    if ($y -lt $script:RowY0 -or $y -ge ($script:RowY0 + $n * $script:RowH)) { return -1 }
    return [int][Math]::Floor(($y - $script:RowY0) / $script:RowH)
}

$form.Add_MouseDown({
    param($s, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    $script:Drag.Down = $true
    $script:Drag.Dragging = $false
    $pt = [System.Windows.Forms.Cursor]::Position
    $script:Drag.StartSX = $pt.X
    $script:Drag.StartSY = $pt.Y
    $script:Drag.FormStartX = $form.Location.X
    $script:Drag.FormStartY = $form.Location.Y
    $script:Drag.ClickX = $e.X
    $script:Drag.ClickY = $e.Y
})

$form.Add_MouseMove({
    param($s, $e)
    if (-not $script:Drag.Down) { return }
    $pt = [System.Windows.Forms.Cursor]::Position
    $dx = $pt.X - $script:Drag.StartSX
    $dy = $pt.Y - $script:Drag.StartSY
    if (-not $script:Drag.Dragging) {
        if ([Math]::Abs($dx) + [Math]::Abs($dy) -gt 4) { $script:Drag.Dragging = $true }
    }
    if ($script:Drag.Dragging) {
        $form.Location = New-Object System.Drawing.Point([int]($script:Drag.FormStartX + $dx), [int]($script:Drag.FormStartY + $dy))
    }
})

$form.Add_MouseUp({
    param($s, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    if ($script:Drag.Down) {
        if ($script:Drag.Dragging) {
            $script:Data.posX = $form.Location.X
            $script:Data.posY = $form.Location.Y
            Save-Data
        } else {
            $cx = $script:Drag.ClickX; $cy = $script:Drag.ClickY
            if (Hit-Knob $cx $cy) {
                Toggle-Session
            } else {
                $hitN = Hit-Number $cx $cy
                if ($hitN -ge 0) {
                    if ($script:Data.running -and $hitN -eq $script:Data.active) { Toggle-Session } else { Switch-To $hitN }
                } else {
                    $hitR = Hit-Row $cx $cy
                    if ($hitR -ge 0) {
                        if ($script:Data.running -and $hitR -eq $script:Data.active) { Toggle-Session } else { Switch-To $hitR }
                    }
                }
            }
        }
    }
    $script:Drag.Down = $false
    $script:Drag.Dragging = $false
    if (-not $script:UiOpen) { try { Sink-ToBottom } catch {} }
})

# ===== Idle detection (auto-pause) =====
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class IdleHelper {
    [StructLayout(LayoutKind.Sequential)]
    struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    public static double IdleSeconds() {
        LASTINPUTINFO lii = new LASTINPUTINFO();
        lii.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (!GetLastInputInfo(ref lii)) return 0;
        return ((uint)Environment.TickCount - lii.dwTime) / 1000.0;
    }
}
"@
$script:AutoPaused = $false
$script:IdleLimitSec = 1500  # 25 min without keyboard/mouse -> auto-pause

# ===== Timer: live repaint + heartbeat + day rollover =====
$script:LastShown = ""
$script:HeartTick = 0
$script:LastTodayKey = Format-DKey ((Get-Now).Date)
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    try {
        $needs = $false
        if ($script:Data.running) {
            $idleSec = 0.0
            try { $idleSec = [IdleHelper]::IdleSeconds() } catch {}
            if ($idleSec -ge $script:IdleLimitSec) {
                # user walked away mid-recording: close the session at the moment input stopped
                $end = (Get-Now).AddSeconds(-$idleSec)
                Stop-Session-At $end
                $script:AutoPaused = $true
                Write-WidgetLog "auto-pause: idle $([int]($idleSec / 60)) min, session credited up to $($end.ToString('HH:mm:ss'))"
            }
            $needs = $true
            $script:HeartTick++
            if ($script:HeartTick -ge 60) {
                $script:HeartTick = 0
                $script:Data.lastAlive = (Get-Now).ToString("yyyy-MM-ddTHH:mm:ss")
                Save-Data
            }
        }
        $nk = Format-DKey ((Get-Now).Date)
        if ($nk -ne $script:LastTodayKey) { $script:LastTodayKey = $nk; $needs = $true }
        if ($needs) { Render-Widget }
    } catch { Write-WidgetLog "timer tick: $($_.Exception.Message)" }
})
$timer.Start()

# ===== Analytics window =====
$script:AnaForm = $null
$script:AnaOffset = 0

function Refresh-Analytics {
    if (-not $script:AnaForm -or $script:AnaForm.IsDisposed) { return }
    $grid = $script:AnaForm.Controls["grid"]
    $lbl  = $script:AnaForm.Controls["top"].Controls["lblWeek"]
    $btnN = $script:AnaForm.Controls["top"].Controls["btnNext"]
    $now = Get-Now
    $curMon = Get-MondayOf $now
    $mon = $curMon.AddDays(-7 * $script:AnaOffset)
    $sun = $mon.AddDays(6)
    $wk = Format-DKey $mon
    $lbl.Text = "$($script:EnMonths[$mon.Month - 1]) $($mon.Day) - $($script:EnMonths[$sun.Month - 1]) $($sun.Day), $($sun.Year)"
    $btnN.Enabled = ($script:AnaOffset -gt 0)
    $isCur = ($script:AnaOffset -eq 0)
    $liveMin = 0.0
    if ($isCur -and $script:Data.running) { $liveMin = Get-LiveMinutes }
    $dowNow = [int]$now.DayOfWeek; $diNow = 6; if ($dowNow -ne 0) { $diNow = $dowNow - 1 }

    $grid.Rows.Clear()
    $dayTot = @(0.0,0.0,0.0,0.0,0.0,0.0,0.0)
    $factTot = 0.0; $planTot = 0
    for ($i = 0; $i -lt $script:Data.projects.Count; $i++) {
        $p = $script:Data.projects[$i]
        $vals = @("$($i + 1) $($p.name)")
        $wkFact = 0.0
        for ($d = 0; $d -lt 7; $d++) {
            $m = Get-DayMinutes $p.name $wk $d
            if ($isCur -and $script:Data.running -and $i -eq $script:Data.active -and $d -eq $diNow) { $m += $liveMin }
            $dayTot[$d] = $dayTot[$d] + $m
            $wkFact += $m
            $h = [Math]::Round($m / 60.0, 1)
            if ($h -gt 0) { $vals += "$h" } else { $vals += "" }
        }
        $factTot += $wkFact
        $planTot += [int]$p.plan
        $fh = [Math]::Round($wkFact / 60.0, 1)
        $dl = [Math]::Round($wkFact / 60.0 - [int]$p.plan, 1)
        $dlTxt = "$dl"; if ($dl -gt 0) { $dlTxt = "+$dl" }
        $vals += "$fh"; $vals += "$([int]$p.plan)"; $vals += $dlTxt
        [void]$grid.Rows.Add($vals)
    }
    $tv = @("Total")
    for ($d = 0; $d -lt 7; $d++) {
        $h = [Math]::Round($dayTot[$d] / 60.0, 1)
        if ($h -gt 0) { $tv += "$h" } else { $tv += "" }
    }
    $fh2 = [Math]::Round($factTot / 60.0, 1)
    $dl2 = [Math]::Round($factTot / 60.0 - $planTot, 1)
    $dl2Txt = "$dl2"; if ($dl2 -gt 0) { $dl2Txt = "+$dl2" }
    $tv += "$fh2"; $tv += "$planTot"; $tv += $dl2Txt
    $ri = $grid.Rows.Add($tv)
    $grid.Rows[$ri].DefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
}

function Show-Analytics {
    if ($script:AnaForm -and -not $script:AnaForm.IsDisposed) {
        Refresh-Analytics
        $script:AnaForm.Activate()
        return
    }
    $script:AnaOffset = 0
    $f = New-Object System.Windows.Forms.Form
    $f.Text = "WorkTracker - Analytics"
    $f.Size = New-Object System.Drawing.Size(700, 320)
    $f.StartPosition = "CenterScreen"
    $f.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $f.ShowInTaskbar = $true

    $top = New-Object System.Windows.Forms.Panel
    $top.Name = "top"
    $top.Dock = "Top"
    $top.Height = 40

    $btnPrev = New-Object System.Windows.Forms.Button
    $btnPrev.Name = "btnPrev"
    $btnPrev.Text = "< Prev"
    $btnPrev.Location = New-Object System.Drawing.Point(10, 7)
    $btnPrev.Size = New-Object System.Drawing.Size(70, 26)
    $btnPrev.Add_Click({ $script:AnaOffset++; Refresh-Analytics })

    $lblWeek = New-Object System.Windows.Forms.Label
    $lblWeek.Name = "lblWeek"
    $lblWeek.Location = New-Object System.Drawing.Point(90, 11)
    $lblWeek.Size = New-Object System.Drawing.Size(300, 20)
    $lblWeek.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)

    $btnNext = New-Object System.Windows.Forms.Button
    $btnNext.Name = "btnNext"
    $btnNext.Text = "Next >"
    $btnNext.Location = New-Object System.Drawing.Point(395, 7)
    $btnNext.Size = New-Object System.Drawing.Size(70, 26)
    $btnNext.Add_Click({ if ($script:AnaOffset -gt 0) { $script:AnaOffset--; Refresh-Analytics } })

    $top.Controls.Add($btnPrev)
    $top.Controls.Add($lblWeek)
    $top.Controls.Add($btnNext)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Name = "grid"
    $grid.Dock = "Fill"
    $grid.ReadOnly = $true
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.RowHeadersVisible = $false
    $grid.AutoSizeColumnsMode = "Fill"
    $grid.SelectionMode = "FullRowSelect"
    $grid.MultiSelect = $false
    $grid.BackgroundColor = [System.Drawing.Color]::White
    $grid.BorderStyle = "None"
    $grid.CellBorderStyle = "SingleHorizontal"
    $grid.GridColor = C 230 230 234
    $grid.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::White
    $grid.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::Black
    $grid.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
    $grid.ColumnHeadersHeightSizeMode = "AutoSize"
    $cols = @("Project","Mon","Tue","Wed","Thu","Fri","Sat","Sun","Actual","Plan","Δ")
    foreach ($c in $cols) { [void]$grid.Columns.Add($c, $c) }
    $grid.Columns[0].FillWeight = 200
    for ($ci = 1; $ci -lt 11; $ci++) {
        $grid.Columns[$ci].FillWeight = 70
        $grid.Columns[$ci].DefaultCellStyle.Alignment = "MiddleRight"
    }

    $f.Controls.Add($grid)
    $f.Controls.Add($top)
    $script:AnaForm = $f
    Refresh-Analytics
    $f.Show()
}

# ===== Right-click menu =====
[void][System.Reflection.Assembly]::LoadWithPartialName('Microsoft.VisualBasic')

function Rename-Project {
    $p = Active-Proj
    $new = [Microsoft.VisualBasic.Interaction]::InputBox("New project name:", "WorkTracker", [string]$p.name)
    if ($null -eq $new -or $new.Trim() -eq "" -or $new.Trim() -eq [string]$p.name) { return }
    $old = [string]$p.name
    $new = $new.Trim()
    $p.name = $new
    # remap history so stats follow the rename
    if (Test-Path $script:SessFile) {
        $out = @()
        foreach ($line in (Get-Content $script:SessFile -ErrorAction SilentlyContinue)) {
            if (-not $line -or -not $line.Trim()) { continue }
            try {
                $o = $line | ConvertFrom-Json
                if ([string]$o.n -eq $old) { $o.n = $new }
                $out += ($o | ConvertTo-Json -Compress)
            } catch { $out += $line }
        }
        Set-Content -Path $script:SessFile -Value $out -Encoding UTF8
        Rebuild-Agg
    }
    Save-Data
    Render-Widget
}

function Edit-Plan {
    $p = Active-Proj
    $input = [Microsoft.VisualBasic.Interaction]::InputBox("Planned hours per week for '$($p.name)' (1-100):", "WorkTracker", [string]$p.plan)
    if ($null -eq $input -or $input.Trim() -eq "") { return }
    $n = 0
    if ([int]::TryParse($input.Trim(), [ref]$n) -and $n -ge 1 -and $n -le 100) {
        $p.plan = $n
        Save-Data
        Render-Widget
    }
}

function Add-Project {
    if ($script:Data.projects.Count -ge 5) {
        [System.Windows.Forms.MessageBox]::Show("Maximum 5 projects.", "WorkTracker") | Out-Null
        return
    }
    $new = [Microsoft.VisualBasic.Interaction]::InputBox("Name of the new project:", "WorkTracker", "")
    if ($null -eq $new -or $new.Trim() -eq "") { return }
    $script:Data.projects += @{ name = $new.Trim(); plan = 10 }
    Save-Data
    Render-Widget
}

function Remove-Project {
    if ($script:Data.projects.Count -le 1) {
        [System.Windows.Forms.MessageBox]::Show("The last project cannot be removed.", "WorkTracker") | Out-Null
        return
    }
    $p = Active-Proj
    $res = [System.Windows.Forms.MessageBox]::Show(
        "Remove project '$($p.name)' from the widget? Its history in sessions.jsonl is kept.", "WorkTracker",
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($res -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    if ($script:Data.running) { Stop-Session }
    $idx = $script:Data.active
    $new = @()
    for ($i = 0; $i -lt $script:Data.projects.Count; $i++) { if ($i -ne $idx) { $new += $script:Data.projects[$i] } }
    $script:Data.projects = $new
    if ($script:Data.active -ge $script:Data.projects.Count) { $script:Data.active = $script:Data.projects.Count - 1 }
    Save-Data
    Render-Widget
}

$ctx = New-Object System.Windows.Forms.ContextMenuStrip
$script:MenuHeader = $ctx.Items.Add("")
$script:MenuHeader.Enabled = $false
[void]$ctx.Items.Add("-")
[void]$ctx.Items.Add("Analytics and history...", $null, { Show-Analytics })
[void]$ctx.Items.Add("-")
[void]$ctx.Items.Add("Rename project...", $null, { Rename-Project })
$script:MenuPlanItem = $ctx.Items.Add("", $null, { Edit-Plan })
[void]$ctx.Items.Add("Add project...", $null, { Add-Project })
[void]$ctx.Items.Add("Remove this project", $null, { Remove-Project })
[void]$ctx.Items.Add("Undo last session", $null, {
    $res = [System.Windows.Forms.MessageBox]::Show("Delete the last recorded session?", "WorkTracker",
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($res -eq [System.Windows.Forms.DialogResult]::Yes) { Undo-LastSession; Render-Widget }
})
[void]$ctx.Items.Add("-")
[void]$ctx.Items.Add("Close widget", $null, { $form.Close() })
$ctx.add_Opening({
    $script:UiOpen = $true
    $p = Active-Proj
    $wk = Format-DKey (Get-MondayOf (Get-Now))
    $fh = [Math]::Round(((Get-WeekMinutes $p.name $wk) + (Get-LiveMinutes)) / 60.0, 1)
    $script:MenuHeader.Text = "$($p.name)  ($($script:Data.active + 1)/$($script:Data.projects.Count))  ·  $fh/$($p.plan) h"
    $script:MenuPlanItem.Text = "Plan hours: $([int]$p.plan)..."
})
$ctx.add_Closed({
    $script:UiOpen = $false
    try { Sink-ToBottom } catch {}
})
$form.ContextMenuStrip = $ctx

# ===== Pin below all windows + hotkeys + wheel =====
function Sink-ToBottom {
    # Re-sink only when actually raised: an unconditional HWND_BOTTOM makes DWM redo the
    # window shadow on every tick, which reads as widget shadows blinking (2026-08-13).
    if (-not ('SinkGuard' -as [type])) {
        Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public class SinkGuard {[DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);[DllImport("user32.dll", CharSet = CharSet.Auto)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder sb, int max);public static bool IsRaised(IntPtr hwnd) {IntPtr below = GetWindow(hwnd, 2);int g = 0;while (below != IntPtr.Zero && !IsWindowVisible(below) && g++ < 32) below = GetWindow(below, 2);if (below == IntPtr.Zero) return false;var sb = new System.Text.StringBuilder(64);GetClassName(below, sb, 64);string cls = sb.ToString();if (cls == "Progman" || cls == "WorkerW" || cls.StartsWith("WindowsForms10")) return false;return true;}}'
    }
    if (-not [SinkGuard]::IsRaised($form.Handle)) { return }
    [Native]::SetWindowPos($form.Handle, [Native]::HWND_BOTTOM, 0, 0, 0, 0,
        [Native]::SWP_NOMOVE -bor [Native]::SWP_NOSIZE -bor [Native]::SWP_NOACTIVATE) | Out-Null
}

$script:Hook = $null

$form.Add_Shown({
    try {
        $h = $form.Handle
        # WS_EX_LAYERED makes the window a per-pixel-alpha surface driven by UpdateLayeredWindow
        # (Render-Widget). No DWM frame -> no drop shadow, no flicker; the alpha channel gives
        # anti-aliased corners. No region -> nothing to clip across monitors.
        $ex = [Native]::GetWindowLong($h, [Native]::GWL_EXSTYLE)
        [Native]::SetWindowLong($h, [Native]::GWL_EXSTYLE,
            $ex -bor [Native]::WS_EX_NOACTIVATE -bor [Native]::WS_EX_TOOLWINDOW -bor 0x00080000) | Out-Null
        Render-Widget
        Sink-ToBottom

        $script:Hook = New-Object MsgHook
        $script:Hook.Hook($h)
        $script:Hook.add_HotkeyPressed({
            param($id)
            try {
                if ($id -eq 9) { Toggle-Session }
                elseif ($id -ge 1 -and $id -le 8) {
                    $i = $id - 1
                    if ($i -lt $script:Data.projects.Count) {
                        if ($script:Data.running -and $i -eq $script:Data.active) { Toggle-Session } else { Switch-To $i }
                    }
                }
            } catch { Write-WidgetLog "hotkey: $($_.Exception.Message)" }
        })
        $script:Hook.add_WheelMoved({
            param($delta)
            try {
                $n = $script:Data.projects.Count
                $step = 1; if ($delta -gt 0) { $step = -1 }
                $i = ($script:Data.active + $step + $n) % $n
                if ($script:Data.running) { Switch-To $i } else { Select-Only $i }
            } catch { Write-WidgetLog "wheel: $($_.Exception.Message)" }
        })

        $mods = [Native]::MOD_CONTROL -bor [Native]::MOD_ALT -bor [Native]::MOD_SHIFT
        [Native]::RegisterHotKey($h, 9, $mods, 0x39) | Out-Null
        for ($k = 1; $k -le 5; $k++) {
            [Native]::RegisterHotKey($h, $k, $mods, [uint32](0x30 + $k)) | Out-Null
        }
    } catch { Write-WidgetLog "Shown handler: $($_.Exception.Message)" }
    Render-Widget
})

$sinkTimer = New-Object System.Windows.Forms.Timer
# Slow safety net only: the widget re-sinks on the events that can raise it (own clicks,
# menu close), so the periodic pass is just insurance against unknown raisers.
# While the context menu is open sinking is paused - the owned popup would follow the
# form to HWND_BOTTOM and other widgets would cover the menu.
$sinkTimer.Interval = 30000
$sinkTimer.Add_Tick({ try { if (-not $script:UiOpen) { Sink-ToBottom } } catch { Write-WidgetLog "sink tick: $($_.Exception.Message)" } })
$sinkTimer.Start()

$form.Add_FormClosed({
    try {
        [Native]::UnregisterHotKey($form.Handle, 9) | Out-Null
        for ($k = 1; $k -le 5; $k++) { [Native]::UnregisterHotKey($form.Handle, $k) | Out-Null }
    } catch {}
    if ($script:Data.running) { Stop-Session }
    Save-Data
})

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::add_ThreadException({
    param($s, $e)
    try { Write-WidgetLog "ThreadException (recovered): $($e.Exception.Message)" } catch {}
})
[System.AppDomain]::CurrentDomain.add_UnhandledException({
    param($s, $e)
    try { Write-WidgetLog "AppDomain unhandled: $($e.ExceptionObject)" } catch {}
})

Write-WidgetLog "start (pid $PID), projects=$($script:Data.projects.Count), active=$($script:Data.active), running=$($script:Data.running), pos=$($form.Location.X),$($form.Location.Y)"
$form.ShowDialog() | Out-Null
Write-WidgetLog "ShowDialog returned (window closed) pid $PID"
