// Fluent.cs - small owner-drawn control kit that gives the WinForms window a Windows 11 (Fluent) look.
// Pure GDI+/WinForms, no third-party code. Everything mirrors correctly for RightToLeft (Arabic).
// Compiled at start-up by Add-Type (Windows PowerShell 5.1 => C# 5: no string interpolation, no ?., no expression bodies).
//
// Display scaling: the window makes the process dpi-aware (Dpi.Enable) before it creates any window, so Windows no longer
// stretches a blurry bitmap of it. Every size in this file is written for 96 dpi and multiplied by Theme.Scale where it is
// used (Theme.S / Theme.Sf); fonts come from Theme and follow the dpi of the window's monitor (Theme.SetDpi).
//
// Screen readers: every control describes itself (role, name, state, default action) through its AccessibleObject, the list
// exposes its rows as check boxes, and the tour card (FCoach) exposes its texts and buttons and announces each step.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace Fluent
{
    public enum FKind { Standard, Accent, Danger, Subtle }
    public enum FLevel { Info, Success, Warning, Error }

    // ------------------------------------------------------------------ palette / fonts / scale / drawing helpers
    public static class Theme
    {
        public static bool Dark;
        public static Color Accent, AccentHover, AccentPressed, AccentText;
        public static Color Window, Card, CardBorder, Text, SubText, Divider, Track, RowHover, Field;
        public static Color BtnFill, BtnBorder, BtnHover, BtnPressed, BtnOffFill, BtnOffText;
        public static Color Danger, DangerHover, DangerPressed, DangerText;
        public static string IconFamily = "Segoe Fluent Icons";
        public static string UiFamily = "Segoe UI Variable Text";
        public static string SemiFamily = "Segoe UI Semibold";
        static readonly Dictionary<string, Font> cache = new Dictionary<string, Font>();

        // ---- dots per inch of the window's monitor. Scale = device pixels per 96-dpi pixel. GDI turns point sizes into
        // pixels at the SYSTEM dpi (the dpi Windows started with), so fonts get FontScale = dpi / system dpi on top.
        public static int Dpi = 96, SystemDpi = 96;
        public static float Scale = 1f, FontScale = 1f;

        public static void SetDpi(int dpi, int systemDpi)
        {
            if (dpi < 48 || dpi > 960) dpi = 96;
            if (systemDpi < 48 || systemDpi > 960) systemDpi = 96;
            Dpi = dpi; SystemDpi = systemDpi;
            Scale = dpi / 96f;
            FontScale = (float)dpi / systemDpi;
            cache.Clear();
        }
        public static int S(float v) { return (int)Math.Round(v * Scale, MidpointRounding.AwayFromZero); }
        public static float Sf(float v) { return v * Scale; }

        public static bool HasFont(string name)
        {
            foreach (FontFamily f in FontFamily.Families)
                if (string.Equals(f.Name, name, StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }

        // accentMode: "system" (derive a readable accent from the Windows accent colour), "default" (Windows blue), "custom" (use accentArg as is)
        public static void Apply(bool dark, string accentMode, Color accentArg)
        {
            Dark = dark;
            if (!HasFont("Segoe Fluent Icons")) IconFamily = HasFont("Segoe MDL2 Assets") ? "Segoe MDL2 Assets" : "Segoe UI Symbol";
            if (!HasFont("Segoe UI Variable Text")) UiFamily = "Segoe UI";
            if (!HasFont("Segoe UI Semibold")) SemiFamily = UiFamily;
            cache.Clear();

            if (dark)
            {
                Window = C(0x20, 0x20, 0x20); Card = C(0x2B, 0x2B, 0x2B); CardBorder = C(0x3A, 0x3A, 0x3A);
                Text = C(0xFF, 0xFF, 0xFF); SubText = C(0xC8, 0xC8, 0xC8); Divider = C(0x3A, 0x3A, 0x3A);
                Track = C(0x55, 0x55, 0x55); RowHover = C(0x34, 0x34, 0x34); Field = C(0x23, 0x23, 0x23);
                BtnFill = C(0x38, 0x38, 0x38); BtnBorder = C(0x4A, 0x4A, 0x4A); BtnHover = C(0x40, 0x40, 0x40); BtnPressed = C(0x32, 0x32, 0x32);
                BtnOffFill = C(0x2E, 0x2E, 0x2E); BtnOffText = C(0x77, 0x77, 0x77);
                Danger = C(0xD1, 0x34, 0x38); DangerHover = C(0xBE, 0x2F, 0x33); DangerPressed = C(0xA8, 0x2A, 0x2D); DangerText = Color.White;
            }
            else
            {
                Window = C(0xF3, 0xF3, 0xF3); Card = C(0xFF, 0xFF, 0xFF); CardBorder = C(0xE5, 0xE5, 0xE5);
                Text = C(0x1A, 0x1A, 0x1A); SubText = C(0x5F, 0x5F, 0x5F); Divider = C(0xEC, 0xEC, 0xEC);
                Track = C(0xD6, 0xD6, 0xD6); RowHover = C(0xF5, 0xF5, 0xF5); Field = C(0xF7, 0xF7, 0xF7);
                BtnFill = C(0xFD, 0xFD, 0xFD); BtnBorder = C(0xD9, 0xD9, 0xD9); BtnHover = C(0xF6, 0xF6, 0xF6); BtnPressed = C(0xEE, 0xEE, 0xEE);
                BtnOffFill = C(0xF5, 0xF5, 0xF5); BtnOffText = C(0xA0, 0xA0, 0xA0);
                Danger = C(0xC4, 0x2B, 0x1C); DangerHover = C(0xB3, 0x27, 0x1A); DangerPressed = C(0xA2, 0x23, 0x17); DangerText = Color.White;
            }

            if (accentMode == "custom") Accent = accentArg;
            else if (accentMode == "system") Accent = Derive(accentArg, dark);
            else Accent = dark ? C(0x60, 0xCD, 0xFF) : C(0x00, 0x67, 0xC0);
            AccentHover = Mix(Accent, Window, 0.12);
            AccentPressed = Mix(Accent, Window, 0.24);
            AccentText = Luminance(Accent) > 0.58 ? Color.Black : Color.White;
        }

        static Color C(int r, int g, int b) { return Color.FromArgb(r, g, b); }

        public static double Luminance(Color c) { return (0.2126 * c.R + 0.7152 * c.G + 0.0722 * c.B) / 255.0; }

        // keep the hue the user picked in Windows settings, but make it readable as a UI accent
        static Color Derive(Color sys, bool dark)
        {
            double h, s, l;
            ToHsl(sys, out h, out s, out l);
            if (dark) return FromHsl(h, Math.Max(0.65, Math.Min(0.95, s)), 0.70);
            return FromHsl(h, Math.Max(0.55, Math.Min(0.90, s)), 0.36);
        }

        static void ToHsl(Color c, out double h, out double s, out double l)
        {
            double r = c.R / 255.0, g = c.G / 255.0, b = c.B / 255.0;
            double max = Math.Max(r, Math.Max(g, b)), min = Math.Min(r, Math.Min(g, b));
            l = (max + min) / 2.0;
            double d = max - min;
            if (d < 1e-9) { h = 0; s = 0; return; }
            s = l > 0.5 ? d / (2.0 - max - min) : d / (max + min);
            if (max == r) h = (g - b) / d + (g < b ? 6 : 0);
            else if (max == g) h = (b - r) / d + 2;
            else h = (r - g) / d + 4;
            h *= 60;
        }

        static Color FromHsl(double h, double s, double l)
        {
            double c = (1 - Math.Abs(2 * l - 1)) * s;
            double hp = h / 60.0;
            double x = c * (1 - Math.Abs(hp % 2 - 1));
            double r = 0, g = 0, b = 0;
            if (hp < 1) { r = c; g = x; }
            else if (hp < 2) { r = x; g = c; }
            else if (hp < 3) { g = c; b = x; }
            else if (hp < 4) { g = x; b = c; }
            else if (hp < 5) { r = x; b = c; }
            else { r = c; b = x; }
            double m = l - c / 2;
            return Color.FromArgb(Cl(r + m), Cl(g + m), Cl(b + m));
        }

        static int Cl(double v) { int i = (int)Math.Round(v * 255); return i < 0 ? 0 : (i > 255 ? 255 : i); }

        public static Color Mix(Color a, Color b, double t)
        {
            return Color.FromArgb(255, (int)Math.Round(a.R + (b.R - a.R) * t), (int)Math.Round(a.G + (b.G - a.G) * t), (int)Math.Round(a.B + (b.B - a.B) * t));
        }

        // fonts: sizes in points (UI / Semi / Mono) or 96-dpi pixels (Icons); all of them follow the dpi
        public static Font UI(float pt, FontStyle st) { return Get(UiFamily, pt * FontScale, st, GraphicsUnit.Point); }
        public static Font Semi(float pt) { return Get(SemiFamily, pt * FontScale, FontStyle.Regular, GraphicsUnit.Point); }
        public static Font Icons(float px) { return Get(IconFamily, px * Scale, FontStyle.Regular, GraphicsUnit.Pixel); }
        public static Font IconsPx(float px) { return Get(IconFamily, px, FontStyle.Regular, GraphicsUnit.Pixel); }   // exact pixels (bitmaps of a fixed size)
        public static Font Mono(float pt) { return Get(HasFont("Cascadia Mono") ? "Cascadia Mono" : "Consolas", pt * FontScale, FontStyle.Regular, GraphicsUnit.Point); }

        static Font Get(string fam, float size, FontStyle st, GraphicsUnit u)
        {
            size = (float)Math.Round(size, 2);
            string k = fam + "|" + size.ToString(System.Globalization.CultureInfo.InvariantCulture) + "|" + (int)st + "|" + (int)u;
            Font f;
            if (!cache.TryGetValue(k, out f))
            {
                try { f = new Font(fam, size, st, u); }
                catch { f = new Font("Segoe UI", size, st, u); }
                cache[k] = f;
            }
            return f;
        }

        // After a dpi change: every font in the tree grows or shrinks by k (fonts are read first, then replaced, so a
        // control that only inherits its parent's font is not scaled twice).
        public static void RescaleFonts(Control root, float k)
        {
            if (root == null || Math.Abs(k - 1f) < 0.001f) return;
            List<Control> all = new List<Control>();
            Collect(root, all);
            List<Font> fonts = new List<Font>();
            foreach (Control c in all) fonts.Add(c.Font);
            for (int i = 0; i < all.Count; i++)
            {
                Font f = fonts[i];
                try { all[i].Font = new Font(f.FontFamily, Math.Max(1f, f.Size * k), f.Style, f.Unit, f.GdiCharSet, f.GdiVerticalFont); } catch { }
            }
        }
        static void Collect(Control c, List<Control> all) { all.Add(c); foreach (Control k in c.Controls) Collect(k, all); }

        public static GraphicsPath RoundRect(RectangleF r, float rad)
        {
            GraphicsPath p = new GraphicsPath();
            float d = rad * 2;
            if (d > r.Width) d = r.Width;
            if (d > r.Height) d = r.Height;
            if (d <= 0) { p.AddRectangle(r); return p; }
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }

        // colour behind a control: cards paint Card, info bars their tint, everything else sits on the window colour
        public static Color Backdrop(Control c)
        {
            for (Control p = c.Parent; p != null; p = p.Parent)
            {
                if (p is FCard) return Card;
                FInfoBar bar = p as FInfoBar;
                if (bar != null) { Color bg, ic; string gl; FInfoBar.Palette(bar.Level, out bg, out ic, out gl); return bg; }
            }
            return Window;
        }

        public static TextFormatFlags Flags(bool rtl, bool right, bool center, bool wrap)
        {
            TextFormatFlags f = TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix | TextFormatFlags.EndEllipsis;
            if (rtl) f |= TextFormatFlags.RightToLeft;
            if (center) f |= TextFormatFlags.HorizontalCenter;
            else if (right) f |= TextFormatFlags.Right;
            else f |= TextFormatFlags.Left;
            if (wrap) f |= TextFormatFlags.WordBreak | TextFormatFlags.Top;
            else f |= TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter;
            return f;
        }

        public static void DrawText(Graphics g, string s, Font f, Rectangle r, Color c, bool rtl, bool right, bool center, bool wrap)
        {
            if (string.IsNullOrEmpty(s)) return;
            TextRenderer.DrawText(g, s, f, r, c, Flags(rtl, right, center, wrap));
        }

        public static int MeasureWidth(Graphics g, string s, Font f)
        {
            if (string.IsNullOrEmpty(s)) return 0;
            TextFormatFlags fl = TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine;
            return TextRenderer.MeasureText(g, s, f, new Size(100000, 1000), fl).Width;
        }

        public static int MeasureWrapped(Graphics g, string s, Font f, int width)
        {
            if (string.IsNullOrEmpty(s)) return 0;
            TextFormatFlags fl = TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix | TextFormatFlags.WordBreak;
            return TextRenderer.MeasureText(g, s, f, new Size(Math.Max(20, width), 100000), fl).Height;
        }

        // px: glyph size at 96 dpi (scaled here)
        public static void DrawGlyph(Graphics g, string glyph, float px, Rectangle r, Color c)
        {
            if (string.IsNullOrEmpty(glyph)) return;
            TextRenderer.DrawText(g, glyph, Icons(px), r, c, TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
        }
    }

    // ------------------------------------------------------------------ dpi awareness
    public static class Dpi
    {
        [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr value);
        [DllImport("shcore.dll")] static extern int SetProcessDpiAwareness(int value);
        [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr hwnd);
        [DllImport("user32.dll")] static extern uint GetDpiForSystem();
        [DllImport("user32.dll")] static extern IntPtr GetThreadDpiAwarenessContext();
        [DllImport("user32.dll")] static extern int GetAwarenessFromDpiAwarenessContext(IntPtr value);

        public static string Mode = "unaware";

        // Call once, before the first window of the process exists: Per-Monitor V2 (Windows 10 1703+), otherwise per-monitor
        // (Windows 8.1+), otherwise system-aware. Returns what the process now is.
        public static string Enable()
        {
            try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) { Mode = "per-monitor-v2"; return Mode; } } catch (EntryPointNotFoundException) { }
            try
            {
                int a = GetAwarenessFromDpiAwarenessContext(GetThreadDpiAwarenessContext());   // already set earlier in this process?
                if (a == 2) { Mode = "per-monitor"; return Mode; }
                if (a == 1) { Mode = "system"; return Mode; }
            }
            catch (EntryPointNotFoundException) { }
            try { if (SetProcessDpiAwareness(2) == 0) { Mode = "per-monitor"; return Mode; } } catch (DllNotFoundException) { } catch (EntryPointNotFoundException) { }
            try { if (SetProcessDPIAware()) { Mode = "system"; return Mode; } } catch (EntryPointNotFoundException) { }
            return Mode;
        }

        public static int ForSystem()
        {
            try { uint d = GetDpiForSystem(); if (d > 0) return (int)d; } catch (EntryPointNotFoundException) { }
            using (Graphics g = Graphics.FromHwnd(IntPtr.Zero)) return (int)Math.Round(g.DpiX);
        }

        public static int ForWindow(IntPtr hwnd)
        {
            try { uint d = GetDpiForWindow(hwnd); if (d > 0) return (int)d; } catch (EntryPointNotFoundException) { }
            return ForSystem();
        }
    }

    public class DpiChangedArgs : EventArgs
    {
        public int Dpi;
        public Rectangle Suggested;
        public DpiChangedArgs(int dpi, Rectangle suggested) { Dpi = dpi; Suggested = suggested; }
    }

    // Reports WM_DPICHANGED (the window moved to a monitor with another scale) and keeps the message from WinForms, which
    // would otherwise only scale part of a window that sets its own fonts. Attach again after the handle is re-created.
    public class DpiWatcher : NativeWindow
    {
        [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
        public event EventHandler<DpiChangedArgs> Changed;
        protected override void WndProc(ref Message m)
        {
            if (m.Msg == 0x02E0)
            {
                int dpi = (int)((long)m.WParam & 0xFFFF);
                Rectangle r = Rectangle.Empty;
                if (m.LParam != IntPtr.Zero)
                {
                    RECT rc = (RECT)Marshal.PtrToStructure(m.LParam, typeof(RECT));
                    r = Rectangle.FromLTRB(rc.Left, rc.Top, rc.Right, rc.Bottom);
                }
                if (Changed != null) { try { Changed(this, new DpiChangedArgs(dpi, r)); } catch { } }
                m.Result = IntPtr.Zero;
                return;
            }
            base.WndProc(ref m);
        }
    }

    // ------------------------------------------------------------------ window helpers (DWM / theme / icon)
    public static class Win
    {
        [DllImport("dwmapi.dll")]
        static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);
        [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
        static extern int SetWindowTheme(IntPtr hwnd, string app, string idlist);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern IntPtr SendMessage(IntPtr hwnd, int msg, IntPtr wp, string lp);

        [StructLayout(LayoutKind.Sequential)]
        struct RECT { public int Left, Top, Right, Bottom; }
        [DllImport("dwmapi.dll")]
        static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out RECT rect, int size);
        [DllImport("user32.dll")]
        static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);

        static int Rgb(Color c) { return c.R | (c.G << 8) | (c.B << 16); }

        // a window's rectangle in screen pixels; unlike the client-coordinate helpers it is never mirrored (right-to-left layout)
        public static Rectangle ScreenRect(IntPtr h)
        {
            RECT r;
            if (h != IntPtr.Zero && GetWindowRect(h, out r)) return Rectangle.FromLTRB(r.Left, r.Top, r.Right, r.Bottom);
            return Rectangle.Empty;
        }

        // visible window rectangle in screen pixels (without the invisible resize border / shadow)
        public static Rectangle FrameBounds(IntPtr h)
        {
            RECT r;
            if (DwmGetWindowAttribute(h, 9, out r, 16) == 0) return new Rectangle(r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top);
            return Rectangle.Empty;
        }

        // Windows 11 chrome: dark title bar, rounded corners, Mica backdrop, caption blended into the page colour. Ignored on older builds.
        public static void StyleWindow(IntPtr h, bool dark, Color bg, Color fg)
        {
            try
            {
                int v = dark ? 1 : 0;
                if (DwmSetWindowAttribute(h, 20, ref v, 4) != 0) DwmSetWindowAttribute(h, 19, ref v, 4);
                v = 2; DwmSetWindowAttribute(h, 33, ref v, 4);
                v = 2; DwmSetWindowAttribute(h, 38, ref v, 4);
                v = Rgb(bg); DwmSetWindowAttribute(h, 35, ref v, 4);
                v = Rgb(fg); DwmSetWindowAttribute(h, 36, ref v, 4);
            }
            catch { }
        }

        public static void SetScrollTheme(IntPtr h, bool dark)
        {
            try { SetWindowTheme(h, dark ? "DarkMode_Explorer" : "Explorer", null); } catch { }
        }

        // placeholder text for a single-line TextBox (EM_SETCUEBANNER)
        public static void SetCue(IntPtr h, string text)
        {
            try { SendMessage(h, 0x1501, (IntPtr)1, text); } catch { }
        }

        public static Icon MakeIcon(Color accent, Color fore, string glyph)
        {
            using (Bitmap bmp = new Bitmap(64, 64))
            {
                using (Graphics g = Graphics.FromImage(bmp))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
                    using (GraphicsPath p = Theme.RoundRect(new RectangleF(2, 2, 60, 60), 14))
                    using (SolidBrush b = new SolidBrush(accent)) g.FillPath(b, p);
                    using (SolidBrush tb = new SolidBrush(fore))
                    {
                        StringFormat sf = new StringFormat();
                        sf.Alignment = StringAlignment.Center; sf.LineAlignment = StringAlignment.Center;
                        g.DrawString(glyph, Theme.IconsPx(34f), tb, new RectangleF(0, 1, 64, 64), sf);
                    }
                }
                return (Icon)Icon.FromHandle(bmp.GetHicon()).Clone();
            }
        }
    }

    // ------------------------------------------------------------------ card
    public class FCard : Panel
    {
        public int Radius = 8;
        public FCard()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        }
        protected override void OnPaintBackground(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.Clear(Theme.Window);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using (GraphicsPath p = Theme.RoundRect(new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f), Theme.Sf(Radius)))
            {
                using (SolidBrush b = new SolidBrush(Theme.Card)) g.FillPath(b, p);
                using (Pen pen = new Pen(Theme.CardBorder, 1f)) g.DrawPath(pen, p);
            }
        }
    }

    // ------------------------------------------------------------------ button
    public class FButton : Control
    {
        FKind kind = FKind.Standard;
        string glyph = "";
        bool hover, down;

        public FButton()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.Selectable, true);
            TabStop = true;
            Cursor = Cursors.Hand;
            Font = Theme.Semi(10f);
            Size = new Size(160, 36);
        }

        public FKind Kind { get { return kind; } set { kind = value; Invalidate(); } }
        public string Glyph { get { return glyph; } set { glyph = value ?? ""; Invalidate(); } }

        public void PerformClick() { if (Enabled) OnClick(EventArgs.Empty); }

        protected override AccessibleObject CreateAccessibilityInstance() { return new ButtonAccessible(this); }
        class ButtonAccessible : ControlAccessibleObject
        {
            readonly FButton b;
            public ButtonAccessible(FButton owner) : base(owner) { b = owner; }
            public override AccessibleRole Role { get { return b.AccessibleRole != AccessibleRole.Default ? b.AccessibleRole : AccessibleRole.PushButton; } }
            public override string Name { get { return string.IsNullOrEmpty(b.AccessibleName) ? b.Text : b.AccessibleName; } set { b.AccessibleName = value; } }
            public override string Description { get { return b.AccessibleDescription; } }
            public override string DefaultAction { get { return "Press"; } }
            public override void DoDefaultAction() { b.PerformClick(); }
            public override AccessibleStates State
            {
                get
                {
                    AccessibleStates s = AccessibleStates.Focusable;
                    if (!b.Enabled) s = AccessibleStates.Unavailable;
                    if (b.Focused) s |= AccessibleStates.Focused;
                    if (!b.Visible) s |= AccessibleStates.Invisible;
                    return s;
                }
            }
        }

        protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hover = false; down = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e) { if (e.Button == MouseButtons.Left) { down = true; Focus(); Invalidate(); } base.OnMouseDown(e); }
        protected override void OnMouseUp(MouseEventArgs e) { down = false; Invalidate(); base.OnMouseUp(e); }
        protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
        protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }
        protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); if (IsHandleCreated) AccessibilityNotifyClients(AccessibleEvents.StateChange, -1); }
        protected override void OnTextChanged(EventArgs e) { Invalidate(); base.OnTextChanged(e); if (IsHandleCreated) AccessibilityNotifyClients(AccessibleEvents.NameChange, -1); }
        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Space || e.KeyCode == Keys.Enter) { PerformClick(); e.Handled = true; }
            base.OnKeyDown(e);
        }

        void Colors(out Color fill, out Color border, out Color fore)
        {
            border = Color.Transparent;
            if (!Enabled)
            {
                fill = kind == FKind.Subtle ? Color.Transparent : Theme.BtnOffFill;
                fore = Theme.BtnOffText;
                if (kind == FKind.Standard) border = Theme.CardBorder;
                return;
            }
            switch (kind)
            {
                case FKind.Accent:
                    fill = down ? Theme.AccentPressed : (hover ? Theme.AccentHover : Theme.Accent); fore = Theme.AccentText; break;
                case FKind.Danger:
                    fill = down ? Theme.DangerPressed : (hover ? Theme.DangerHover : Theme.Danger); fore = Theme.DangerText; break;
                case FKind.Subtle:
                    fill = down ? Theme.BtnPressed : (hover ? Theme.BtnHover : Color.Transparent); fore = Theme.Text; break;
                default:
                    fill = down ? Theme.BtnPressed : (hover ? Theme.BtnHover : Theme.BtnFill); border = Theme.BtnBorder; fore = Theme.Text; break;
            }
        }

        // the width the text and the icon need (tests: nothing may be cut off at any dpi)
        public int ContentWidth()
        {
            using (Graphics g = CreateGraphics())
            {
                int gw = glyph.Length > 0 ? Theme.S(18) : 0;
                int gap = (glyph.Length > 0 && (Text ?? "").Length > 0) ? Theme.S(8) : 0;
                return Theme.S(20) + gw + gap + Theme.MeasureWidth(g, Text ?? "", Font);
            }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Theme.Backdrop(this));
            bool rtl = RightToLeft == RightToLeft.Yes;
            Color fill, border, fore;
            Colors(out fill, out border, out fore);
            RectangleF r = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
            using (GraphicsPath p = Theme.RoundRect(r, Theme.Sf(4f)))
            {
                if (fill.A > 0) using (SolidBrush b = new SolidBrush(fill)) g.FillPath(b, p);
                if (border.A > 0) using (Pen pen = new Pen(border, 1f)) g.DrawPath(pen, p);
                if (Focused && ShowFocusCues && Enabled)
                {
                    float i = Theme.Sf(2.5f);
                    RectangleF fr = new RectangleF(i, i, Width - 2 * i - 0.5f, Height - 2 * i - 0.5f);
                    using (GraphicsPath fp = Theme.RoundRect(fr, Theme.Sf(3f)))
                    using (Pen pen = new Pen(Theme.Dark ? Color.White : Color.Black, Math.Max(1.5f, Theme.Sf(1.5f)))) g.DrawPath(pen, fp);
                }
            }

            string t = Text ?? "";
            bool hasG = glyph.Length > 0;
            int gw = hasG ? Theme.S(18) : 0;
            int gap = (hasG && t.Length > 0) ? Theme.S(8) : 0;
            int avail = Width - Theme.S(20) - gw - gap;
            int tw = Math.Min(Theme.MeasureWidth(g, t, Font), Math.Max(Theme.S(10), avail));
            int total = gw + gap + tw;
            int start = (Width - total) / 2;
            Rectangle gr, tr;
            if (rtl)
            {
                gr = new Rectangle(start + total - gw, 0, gw, Height);
                tr = new Rectangle(start, 0, tw, Height);
            }
            else
            {
                gr = new Rectangle(start, 0, gw, Height);
                tr = new Rectangle(start + gw + gap, 0, tw, Height);
            }
            if (hasG) Theme.DrawGlyph(g, glyph, 16f, gr, fore);
            Theme.DrawText(g, t, Font, tr, fore, rtl, false, true, false);
        }
    }

    // ------------------------------------------------------------------ progress
    public class FProgress : Control
    {
        int value;
        public FProgress()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            Size = new Size(300, 6);
        }
        public int Value
        {
            get { return value; }
            set
            {
                int v = Math.Max(0, Math.Min(100, value));
                if (v == this.value) return;
                this.value = v; Invalidate();
                if (IsHandleCreated) AccessibilityNotifyClients(AccessibleEvents.ValueChange, -1);
            }
        }
        protected override AccessibleObject CreateAccessibilityInstance() { return new ProgressAccessible(this); }
        class ProgressAccessible : ControlAccessibleObject
        {
            readonly FProgress p;
            public ProgressAccessible(FProgress owner) : base(owner) { p = owner; }
            public override AccessibleRole Role { get { return AccessibleRole.ProgressBar; } }
            public override string Name { get { return p.AccessibleName; } set { p.AccessibleName = value; } }
            public override string Value { get { return p.Value.ToString(System.Globalization.CultureInfo.InvariantCulture) + "%"; } set { } }
            public override AccessibleStates State { get { return AccessibleStates.ReadOnly; } }
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Theme.Backdrop(this));
            bool rtl = RightToLeft == RightToLeft.Yes;
            float h = Math.Min(Theme.Sf(6f), Height);
            float y = (Height - h) / 2f;
            using (GraphicsPath tp = Theme.RoundRect(new RectangleF(0, y, Width, h), h / 2f))
            using (SolidBrush tb = new SolidBrush(Theme.Track)) g.FillPath(tb, tp);
            if (value > 0)
            {
                float w = Math.Max(h, Width * value / 100f);
                float x = rtl ? Width - w : 0;
                using (GraphicsPath fp = Theme.RoundRect(new RectangleF(x, y, w, h), h / 2f))
                using (SolidBrush fb = new SolidBrush(Theme.Accent)) g.FillPath(fb, fp);
            }
        }
    }

    // ------------------------------------------------------------------ info bar
    public class FInfoBar : Control
    {
        FLevel level = FLevel.Info;
        string title = "", message = "";
        public bool AutoFit = true;
        public int ReserveEnd;   // device pixels kept free at the far end (right, or left when right-to-left) for buttons placed on the bar

        public FInfoBar()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            Size = new Size(400, 64);
        }

        public FLevel Level { get { return level; } set { level = value; Invalidate(); } }
        public string Title { get { return title; } set { title = value ?? ""; Fit(); Invalidate(); Notify(AccessibleEvents.NameChange); } }
        public string Message { get { return message; } set { message = (value ?? "").Replace("\r\n", "\n").Replace("\n", "\r\n"); Fit(); Invalidate(); Notify(AccessibleEvents.DescriptionChange); } }

        void Notify(AccessibleEvents ev) { if (IsHandleCreated) AccessibilityNotifyClients(ev, -1); }
        void Fit() { if (AutoFit && Width > 120) FitHeight(); }

        protected override void OnSizeChanged(EventArgs e) { base.OnSizeChanged(e); Fit(); }

        static int Pad { get { return Theme.S(16); } }
        static int IconCol { get { return Theme.S(36); } }

        protected override AccessibleObject CreateAccessibilityInstance() { return new InfoAccessible(this); }
        class InfoAccessible : ControlAccessibleObject
        {
            readonly FInfoBar b;
            public InfoAccessible(FInfoBar owner) : base(owner) { b = owner; }
            public override AccessibleRole Role { get { return (b.level == FLevel.Warning || b.level == FLevel.Error) ? AccessibleRole.Alert : AccessibleRole.StaticText; } }
            public override string Name { get { return string.IsNullOrEmpty(b.AccessibleName) ? b.title : b.AccessibleName; } set { b.AccessibleName = value; } }
            public override string Description { get { return b.message; } }
            public override AccessibleStates State { get { return AccessibleStates.ReadOnly | (b.Visible ? AccessibleStates.None : AccessibleStates.Invisible); } }
        }

        public int FitHeight()
        {
            using (Graphics g = CreateGraphics())
            {
                int tw = Math.Max(Theme.S(60), Width - Pad * 2 - IconCol - ReserveEnd);
                int th = Math.Max(Theme.S(20), Theme.MeasureWrapped(g, title, Theme.Semi(11.5f), tw));
                int mh = message.Length > 0 ? Theme.MeasureWrapped(g, message, Theme.UI(10f, FontStyle.Regular), tw) : 0;
                int h = (Pad - Theme.S(2)) + th + (mh > 0 ? Theme.S(6) + mh : 0) + (Pad - Theme.S(2));
                h = Math.Max(Theme.S(56), h);
                if (h != Height) Height = h;
                return h;
            }
        }

        public static void Palette(FLevel lv, out Color bg, out Color icon, out string glyph)
        {
            bool d = Theme.Dark;
            switch (lv)
            {
                case FLevel.Success: bg = d ? Color.FromArgb(0x39, 0x3D, 0x1B) : Color.FromArgb(0xDF, 0xF6, 0xDD); icon = d ? Color.FromArgb(0x6C, 0xCB, 0x5F) : Color.FromArgb(0x0F, 0x7B, 0x0F); glyph = "\uE930"; break;
                case FLevel.Warning: bg = d ? Color.FromArgb(0x43, 0x35, 0x19) : Color.FromArgb(0xFF, 0xF4, 0xCE); icon = d ? Color.FromArgb(0xFC, 0xE1, 0x00) : Color.FromArgb(0x9D, 0x5D, 0x00); glyph = "\uE7BA"; break;
                case FLevel.Error: bg = d ? Color.FromArgb(0x44, 0x27, 0x26) : Color.FromArgb(0xFD, 0xE7, 0xE9); icon = d ? Color.FromArgb(0xFF, 0x99, 0xA4) : Color.FromArgb(0xC4, 0x2B, 0x1C); glyph = "\uE783"; break;
                default: bg = Theme.Mix(Theme.Card, Theme.Accent, d ? 0.14 : 0.07); icon = Theme.Accent; glyph = "\uE946"; break;
            }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Theme.Backdrop(this));
            bool rtl = RightToLeft == RightToLeft.Yes;
            Color bg, ic; string glyph;
            Palette(level, out bg, out ic, out glyph);
            Color border = Theme.Mix(bg, Theme.Text, 0.10);
            using (GraphicsPath p = Theme.RoundRect(new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f), Theme.Sf(6f)))
            {
                using (SolidBrush b = new SolidBrush(bg)) g.FillPath(b, p);
                using (Pen pen = new Pen(border, 1f)) g.DrawPath(pen, p);
            }
            int tw = Math.Max(Theme.S(60), Width - Pad * 2 - IconCol - ReserveEnd);
            int tx = rtl ? Pad + ReserveEnd : Pad + IconCol;
            int isz = Theme.S(22);
            int ix = rtl ? Width - Pad - isz : Pad;
            int top = Pad - Theme.S(2);
            Font tf = Theme.Semi(11.5f), mf = Theme.UI(10f, FontStyle.Regular);
            int th = Math.Max(Theme.S(20), Theme.MeasureWrapped(g, title, tf, tw));
            Theme.DrawGlyph(g, glyph, 20f, new Rectangle(ix, top, isz, isz), ic);
            Theme.DrawText(g, title, tf, new Rectangle(tx, top, tw, th), Theme.Text, rtl, rtl, false, true);
            if (message.Length > 0)
            {
                int mh = Theme.MeasureWrapped(g, message, mf, tw);
                Theme.DrawText(g, message, mf, new Rectangle(tx, top + th + Theme.S(6), tw, mh + Theme.S(2)), Theme.Mix(Theme.Text, bg, 0.22), rtl, rtl, false, true);
            }
        }
    }

    // ------------------------------------------------------------------ icon badge
    public class FBadge : Control
    {
        public string Glyph = "";
        public bool Filled = true;
        public float GlyphPx = 22f;      // at 96 dpi
        public int Radius = 12;          // at 96 dpi
        public Color GlyphColor = Color.Empty;
        public bool Decorative;          // screen readers skip it (the text next to it says the same)

        public FBadge()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            Size = new Size(48, 48);
        }
        protected override AccessibleObject CreateAccessibilityInstance() { return new BadgeAccessible(this); }
        class BadgeAccessible : ControlAccessibleObject
        {
            readonly FBadge b;
            public BadgeAccessible(FBadge owner) : base(owner) { b = owner; }
            public override AccessibleRole Role { get { return AccessibleRole.Graphic; } }
            public override string Name { get { return b.AccessibleName; } set { b.AccessibleName = value; } }
            public override AccessibleStates State { get { return b.Decorative ? AccessibleStates.Invisible : AccessibleStates.ReadOnly; } }
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Theme.Backdrop(this));
            Color c;
            if (Filled)
            {
                using (GraphicsPath p = Theme.RoundRect(new RectangleF(0, 0, Width - 0.5f, Height - 0.5f), Theme.Sf(Radius)))
                using (SolidBrush b = new SolidBrush(Theme.Accent)) g.FillPath(b, p);
                c = GlyphColor.IsEmpty ? Theme.AccentText : GlyphColor;
            }
            else c = GlyphColor.IsEmpty ? Theme.Accent : GlyphColor;
            Theme.DrawGlyph(g, Glyph, GlyphPx, new Rectangle(0, 0, Width, Height), c);
        }
    }

    // ------------------------------------------------------------------ expander header (title row with chevron)
    public class FExpander : Control
    {
        public string Glyph = "";
        public bool Expanded;
        public event EventHandler Toggled;
        bool hover;

        public FExpander()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.Selectable, true);
            TabStop = true;
            Cursor = Cursors.Hand;
            Font = Theme.Semi(10.5f);
            Size = new Size(400, 48);
        }
        public void Toggle()
        {
            Expanded = !Expanded; Invalidate();
            if (Toggled != null) Toggled(this, EventArgs.Empty);
            if (IsHandleCreated) AccessibilityNotifyClients(AccessibleEvents.StateChange, -1);
        }
        protected override AccessibleObject CreateAccessibilityInstance() { return new ExpanderAccessible(this); }
        class ExpanderAccessible : ControlAccessibleObject
        {
            readonly FExpander x;
            public ExpanderAccessible(FExpander owner) : base(owner) { x = owner; }
            public override AccessibleRole Role { get { return AccessibleRole.PushButton; } }
            public override string Name { get { return string.IsNullOrEmpty(x.AccessibleName) ? x.Text : x.AccessibleName; } set { x.AccessibleName = value; } }
            public override string DefaultAction { get { return x.Expanded ? "Collapse" : "Expand"; } }
            public override void DoDefaultAction() { x.Toggle(); }
            public override AccessibleStates State
            {
                get
                {
                    AccessibleStates s = AccessibleStates.Focusable | (x.Expanded ? AccessibleStates.Expanded : AccessibleStates.Collapsed);
                    if (x.Focused) s |= AccessibleStates.Focused;
                    return s;
                }
            }
        }
        protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hover = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnClick(EventArgs e) { base.OnClick(e); Toggle(); }
        protected override void OnKeyDown(KeyEventArgs e) { if (e.KeyCode == Keys.Space || e.KeyCode == Keys.Enter) { Toggle(); e.Handled = true; } base.OnKeyDown(e); }
        protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
        protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }
        protected override void OnTextChanged(EventArgs e) { Invalidate(); base.OnTextChanged(e); if (IsHandleCreated) AccessibilityNotifyClients(AccessibleEvents.NameChange, -1); }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Theme.Backdrop(this));
            bool rtl = RightToLeft == RightToLeft.Yes;
            if (hover || Focused)
                using (GraphicsPath p = Theme.RoundRect(new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f), Theme.Sf(6f)))
                using (SolidBrush b = new SolidBrush(Theme.RowHover)) g.FillPath(b, p);
            int pad = Theme.S(14), gw = Theme.S(24);
            Rectangle gr = rtl ? new Rectangle(Width - pad - gw, 0, gw, Height) : new Rectangle(pad, 0, gw, Height);
            Rectangle cr = rtl ? new Rectangle(pad, 0, gw, Height) : new Rectangle(Width - pad - gw, 0, gw, Height);
            Rectangle tr = new Rectangle(pad + Theme.S(32), 0, Math.Max(Theme.S(40), Width - pad * 2 - Theme.S(36) - Theme.S(32)), Height);
            Theme.DrawGlyph(g, Glyph, 18f, gr, Theme.Accent);
            Theme.DrawText(g, Text, Font, tr, Theme.Text, rtl, rtl, false, false);
            Theme.DrawGlyph(g, Expanded ? "\uE70E" : "\uE70D", 12f, cr, Theme.SubText);
        }
    }

    // ------------------------------------------------------------------ check box
    public class FCheck : Control
    {
        public event EventHandler CheckedChanged;
        bool isChecked, hover;

        public FCheck()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.Selectable, true);
            TabStop = true;
            Cursor = Cursors.Hand;
            Font = Theme.UI(10f, FontStyle.Regular);
            Size = new Size(300, 28);
        }
        public bool Checked
        {
            get { return isChecked; }
            set
            {
                if (isChecked == value) return;
                isChecked = value; Invalidate();
                if (CheckedChanged != null) CheckedChanged(this, EventArgs.Empty);
                if (IsHandleCreated) AccessibilityNotifyClients(AccessibleEvents.StateChange, -1);
            }
        }
        protected override AccessibleObject CreateAccessibilityInstance() { return new CheckAccessible(this); }
        class CheckAccessible : ControlAccessibleObject
        {
            readonly FCheck c;
            public CheckAccessible(FCheck owner) : base(owner) { c = owner; }
            public override AccessibleRole Role { get { return AccessibleRole.CheckButton; } }
            public override string Name { get { return string.IsNullOrEmpty(c.AccessibleName) ? c.Text : c.AccessibleName; } set { c.AccessibleName = value; } }
            public override string DefaultAction { get { return c.isChecked ? "Uncheck" : "Check"; } }
            public override void DoDefaultAction() { c.Checked = !c.Checked; }
            public override AccessibleStates State
            {
                get
                {
                    AccessibleStates s = AccessibleStates.Focusable;
                    if (c.isChecked) s |= AccessibleStates.Checked;
                    if (c.Focused) s |= AccessibleStates.Focused;
                    return s;
                }
            }
        }
        protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hover = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnClick(EventArgs e) { base.OnClick(e); Checked = !Checked; }
        protected override void OnKeyDown(KeyEventArgs e) { if (e.KeyCode == Keys.Space) { Checked = !Checked; e.Handled = true; } base.OnKeyDown(e); }
        protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
        protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }
        protected override void OnTextChanged(EventArgs e) { Invalidate(); base.OnTextChanged(e); }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Theme.Backdrop(this));
            bool rtl = RightToLeft == RightToLeft.Yes;
            int box = Theme.S(20), m = Theme.S(2), gap = Theme.S(12);
            Rectangle cb = new Rectangle(rtl ? Width - box - m : m, (Height - box) / 2, box, box);
            using (GraphicsPath cp = Theme.RoundRect(new RectangleF(cb.X + 0.5f, cb.Y + 0.5f, cb.Width - 1, cb.Height - 1), Theme.Sf(5f)))
            {
                if (isChecked)
                {
                    using (SolidBrush ab = new SolidBrush(Theme.Accent)) g.FillPath(ab, cp);
                    Theme.DrawGlyph(g, "\uE73E", 12f, cb, Theme.AccentText);
                }
                else
                {
                    if (hover) using (SolidBrush hb = new SolidBrush(Theme.RowHover)) g.FillPath(hb, cp);
                    using (Pen pen = new Pen(Theme.SubText, Math.Max(1.4f, Theme.Sf(1.4f)))) g.DrawPath(pen, cp);
                }
                if (Focused && ShowFocusCues)
                    using (Pen fp = new Pen(Theme.Dark ? Color.White : Color.Black, Math.Max(1.2f, Theme.Sf(1.2f))))
                        g.DrawRectangle(fp, cb.X - Theme.S(3), cb.Y - Theme.S(3), cb.Width + Theme.S(5), cb.Height + Theme.S(5));
            }
            Rectangle tr = rtl ? new Rectangle(0, 0, Width - box - gap, Height) : new Rectangle(box + gap, 0, Width - box - gap, Height);
            Theme.DrawText(g, Text, Font, tr, Theme.Text, rtl, rtl, false, false);
        }
    }

    // ------------------------------------------------------------------ text field (rounded border + accent underline on focus)
    public class FField : Control
    {
        readonly TextBox tb = new TextBox();
        bool focused;

        public FField()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            Size = new Size(320, 40);
            tb.BorderStyle = BorderStyle.None;
            tb.Font = Theme.UI(10.5f, FontStyle.Regular);
            tb.BackColor = Theme.BtnFill;
            tb.ForeColor = Theme.Text;
            tb.GotFocus += delegate { focused = true; Invalidate(); };
            tb.LostFocus += delegate { focused = false; Invalidate(); };
            Controls.Add(tb);
        }

        public TextBox Input { get { return tb; } }
        public string Value { get { return tb.Text; } set { tb.Text = value; } }
        public bool Password { get { return tb.UseSystemPasswordChar; } set { tb.UseSystemPasswordChar = value; } }
        public int MaxLen { get { return tb.MaxLength; } set { tb.MaxLength = value; } }
        public string Cue { set { tb.HandleCreated += delegate { Win.SetCue(tb.Handle, value); }; if (tb.IsHandleCreated) Win.SetCue(tb.Handle, value); } }
        public string Label { get { return tb.AccessibleName; } set { tb.AccessibleName = value; AccessibleName = value; } }   // what a screen reader says for the box

        protected override void OnLayout(LayoutEventArgs e)
        {
            base.OnLayout(e);
            int h = tb.PreferredHeight;
            tb.SetBounds(Theme.S(12), (Height - h) / 2, Math.Max(Theme.S(20), Width - Theme.S(24)), h);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Theme.Backdrop(this));
            RectangleF r = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
            using (GraphicsPath p = Theme.RoundRect(r, Theme.Sf(4f)))
            {
                using (SolidBrush b = new SolidBrush(Theme.BtnFill)) g.FillPath(b, p);
                using (Pen pen = new Pen(Theme.BtnBorder, 1f)) g.DrawPath(pen, p);
            }
            if (focused)
            {
                // accent underline, clipped to the rounded shape
                using (GraphicsPath cp = Theme.RoundRect(r, Theme.Sf(4f)))
                {
                    g.SetClip(cp);
                    using (SolidBrush ab = new SolidBrush(Theme.Accent)) g.FillRectangle(ab, 0, Height - Theme.S(3), Width, Theme.S(2));
                    g.ResetClip();
                }
            }
        }
    }

    // ------------------------------------------------------------------ list with checkboxes
    public class FItem
    {
        public string Name = "";
        public string Reason = "";
        public string Risk = "";
        public int Level;          // 2 = high, 1 = medium, 0 = low
        public object Tag;
        public bool Checked;
    }

    public class FList : Control
    {
        readonly List<FItem> items = new List<FItem>();
        public int RowHeight = 64;            // at 96 dpi
        public string EmptyText = "";
        public string EmptyGlyph = "\uE73E";
        public event EventHandler ItemChecked;
        int scroll, hot = -1, cur = -1;

        public FList()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.Selectable, true);
            TabStop = true;
            Size = new Size(400, 192);
        }

        public List<FItem> Items { get { return items; } }
        public void Add(FItem it) { items.Add(it); Invalidate(); if (IsHandleCreated) AccessibilityNotifyClients(AccessibleEvents.Reorder, -1); }
        public void Clear() { items.Clear(); scroll = 0; hot = -1; cur = -1; Invalidate(); if (IsHandleCreated) AccessibilityNotifyClients(AccessibleEvents.Reorder, -1); }
        public int CheckedCount { get { int n = 0; foreach (FItem i in items) if (i.Checked) n++; return n; } }
        public FItem[] GetChecked() { List<FItem> l = new List<FItem>(); foreach (FItem i in items) if (i.Checked) l.Add(i); return l.ToArray(); }

        int RowH { get { return Math.Max(1, Theme.S(RowHeight)); } }
        public int Current { get { return cur; } }   // the row the keyboard is on (-1 = none)
        int ContentHeight { get { return items.Count * RowH; } }
        void ClampScroll() { int max = Math.Max(0, ContentHeight - Height); scroll = Math.Max(0, Math.Min(max, scroll)); }
        int IndexAt(Point p) { int idx = (p.Y + scroll) / RowH; return (idx >= 0 && idx < items.Count && p.Y >= 0 && p.Y < Height) ? idx : -1; }
        Rectangle RowRect(int i)
        {
            bool bar = ContentHeight > Height;
            int sb = Theme.S(12);
            return new Rectangle((RightToLeft == RightToLeft.Yes && bar) ? sb : 0, i * RowH - scroll, Width - (bar ? sb : 0), RowH);
        }
        string SpokenName(int i)
        {
            FItem it = items[i];
            string s = it.Name;
            if (it.Risk.Length > 0) s += ", " + it.Risk;
            if (it.Reason.Length > 0) s += ". " + it.Reason;
            return s;
        }

        public void Toggle(int i)
        {
            if (i < 0 || i >= items.Count) return;
            items[i].Checked = !items[i].Checked;
            Invalidate();
            if (ItemChecked != null) ItemChecked(this, EventArgs.Empty);
            if (IsHandleCreated) AccessibilityNotifyClients(AccessibleEvents.StateChange, i);
        }

        protected override AccessibleObject CreateAccessibilityInstance() { return new ListAccessible(this); }
        class ListAccessible : ControlAccessibleObject
        {
            readonly FList l;
            public ListAccessible(FList owner) : base(owner) { l = owner; }
            public override AccessibleRole Role { get { return AccessibleRole.List; } }
            public override string Name { get { return string.IsNullOrEmpty(l.AccessibleName) ? l.EmptyText : l.AccessibleName; } set { l.AccessibleName = value; } }
            public override int GetChildCount() { return l.Items.Count; }
            public override AccessibleObject GetChild(int index) { return (index >= 0 && index < l.Items.Count) ? new ItemAccessible(l, this, index) : null; }
            public override AccessibleObject GetFocused() { int c = l.Current; return (l.Focused && c >= 0 && c < l.Items.Count) ? new ItemAccessible(l, this, c) : base.GetFocused(); }
            public override AccessibleStates State { get { return AccessibleStates.Focusable | (l.Focused ? AccessibleStates.Focused : AccessibleStates.None); } }
        }
        class ItemAccessible : AccessibleObject
        {
            readonly FList l; readonly AccessibleObject parent; readonly int i;
            public ItemAccessible(FList list, AccessibleObject p, int index) { l = list; parent = p; i = index; }
            public override AccessibleObject Parent { get { return parent; } }
            public override AccessibleRole Role { get { return AccessibleRole.CheckButton; } }
            public override string Name { get { return i < l.Items.Count ? l.SpokenName(i) : ""; } set { } }
            public override Rectangle Bounds { get { return l.IsHandleCreated ? l.RectangleToScreen(Rectangle.Intersect(l.RowRect(i), l.ClientRectangle)) : Rectangle.Empty; } }
            public override string DefaultAction { get { return (i < l.Items.Count && l.Items[i].Checked) ? "Uncheck" : "Check"; } }
            public override void DoDefaultAction() { l.Toggle(i); }
            public override AccessibleStates State
            {
                get
                {
                    AccessibleStates s = AccessibleStates.Focusable | AccessibleStates.Selectable;
                    if (i < l.Items.Count && l.Items[i].Checked) s |= AccessibleStates.Checked;
                    if (i == l.Current) { s |= AccessibleStates.Selected; if (l.Focused) s |= AccessibleStates.Focused; }
                    Rectangle r = l.RowRect(i);
                    if (r.Bottom <= 0 || r.Top >= l.Height) s |= AccessibleStates.Offscreen;
                    return s;
                }
            }
            public override void Select(AccessibleSelection flags) { if (i < l.Items.Count) l.MoveTo(i); }
        }

        void MoveTo(int i) { cur = i; EnsureVisible(cur); Invalidate(); if (IsHandleCreated && Focused) AccessibilityNotifyClients(AccessibleEvents.Focus, cur); }
        protected override void OnMouseMove(MouseEventArgs e) { int h = IndexAt(e.Location); if (h != hot) { hot = h; Invalidate(); } base.OnMouseMove(e); }
        protected override void OnMouseLeave(EventArgs e) { hot = -1; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e)
        {
            int i = IndexAt(e.Location);
            if (i >= 0) { Focus(); cur = i; Toggle(i); }
            base.OnMouseDown(e);
        }
        protected override void OnMouseWheel(MouseEventArgs e) { scroll -= (e.Delta / 120) * (RowH / 2); ClampScroll(); Invalidate(); base.OnMouseWheel(e); }
        protected override bool IsInputKey(Keys k) { return k == Keys.Up || k == Keys.Down || base.IsInputKey(k); }
        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (items.Count > 0)
            {
                if (e.KeyCode == Keys.Down) { MoveTo(Math.Min(items.Count - 1, cur + 1)); e.Handled = true; }
                else if (e.KeyCode == Keys.Up) { MoveTo(Math.Max(0, cur - 1)); e.Handled = true; }
                else if (e.KeyCode == Keys.Space && cur >= 0) { Toggle(cur); e.Handled = true; }
            }
            base.OnKeyDown(e);
        }
        protected override void OnGotFocus(EventArgs e)
        {
            if (cur < 0 && items.Count > 0) cur = 0;
            Invalidate(); base.OnGotFocus(e);
            if (IsHandleCreated && cur >= 0) AccessibilityNotifyClients(AccessibleEvents.Focus, cur);
        }
        protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }
        void EnsureVisible(int i)
        {
            int top = i * RowH, bottom = top + RowH;
            if (top < scroll) scroll = top; else if (bottom > scroll + Height) scroll = bottom - Height;
            ClampScroll();
        }

        static void PillColors(int level, out Color bg, out Color fg)
        {
            bool d = Theme.Dark;
            if (level >= 2) { bg = d ? Color.FromArgb(0x44, 0x27, 0x26) : Color.FromArgb(0xFD, 0xE7, 0xE9); fg = d ? Color.FromArgb(0xFF, 0x99, 0xA4) : Color.FromArgb(0xC4, 0x2B, 0x1C); }
            else if (level == 1) { bg = d ? Color.FromArgb(0x43, 0x35, 0x19) : Color.FromArgb(0xFF, 0xF4, 0xCE); fg = d ? Color.FromArgb(0xFC, 0xE1, 0x00) : Color.FromArgb(0x9D, 0x5D, 0x00); }
            else { bg = Theme.Mix(Theme.Card, Theme.Accent, 0.12); fg = Theme.Accent; }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Theme.Backdrop(this));
            bool rtl = RightToLeft == RightToLeft.Yes;

            if (items.Count == 0)
            {
                Theme.DrawGlyph(g, EmptyGlyph, 28f, new Rectangle(0, Height / 2 - Theme.S(40), Width, Theme.S(40)), Theme.SubText);
                Theme.DrawText(g, EmptyText, Theme.UI(10f, FontStyle.Regular), new Rectangle(Theme.S(12), Height / 2 + Theme.S(4), Width - Theme.S(24), Theme.S(26)), Theme.SubText, rtl, false, true, false);
                return;
            }
            ClampScroll();
            bool bar = ContentHeight > Height;
            int rh = RowH;
            Font nf = Theme.Semi(10.5f), rf = Theme.UI(9.5f, FontStyle.Regular), pf = Theme.Semi(9f);
            int pad = Theme.S(14), box = Theme.S(20), pillH = Theme.S(24);

            for (int i = 0; i < items.Count; i++)
            {
                Rectangle row = RowRect(i);
                if (row.Bottom < 0 || row.Y > Height) continue;
                FItem it = items[i];
                if (i == hot || (i == cur && Focused))
                    using (GraphicsPath hp = Theme.RoundRect(new RectangleF(row.X + Theme.Sf(2), row.Y + Theme.Sf(3), row.Width - Theme.Sf(4), row.Height - Theme.Sf(6)), Theme.Sf(6f)))
                    using (SolidBrush hb = new SolidBrush(Theme.RowHover)) g.FillPath(hb, hp);
                if (i < items.Count - 1 && i != hot && i != hot - 1)
                    using (Pen dp = new Pen(Theme.Divider, 1f)) g.DrawLine(dp, row.X + pad, row.Bottom - 1, row.Right - pad, row.Bottom - 1);

                // checkbox
                int cbx = rtl ? row.Right - pad - box : row.X + pad;
                Rectangle cb = new Rectangle(cbx, row.Y + (rh - box) / 2, box, box);
                using (GraphicsPath cp = Theme.RoundRect(new RectangleF(cb.X + 0.5f, cb.Y + 0.5f, cb.Width - 1, cb.Height - 1), Theme.Sf(5f)))
                {
                    if (it.Checked)
                    {
                        using (SolidBrush ab = new SolidBrush(Theme.Accent)) g.FillPath(ab, cp);
                        Theme.DrawGlyph(g, "\uE73E", 12f, cb, Theme.AccentText);
                    }
                    else using (Pen cpn = new Pen(Theme.SubText, Math.Max(1.4f, Theme.Sf(1.4f)))) g.DrawPath(cpn, cp);
                }
                // risk pill
                Color pbg, pfg;
                PillColors(it.Level, out pbg, out pfg);
                int pw = Math.Max(Theme.S(58), Theme.MeasureWidth(g, it.Risk, pf) + Theme.S(22));
                int px = rtl ? row.X + pad : row.Right - pad - pw;       // pill sits at the far end of the row
                Rectangle pill = new Rectangle(px, row.Y + (rh - pillH) / 2, pw, pillH);
                using (GraphicsPath pp = Theme.RoundRect(pill, pillH / 2f))
                using (SolidBrush pb = new SolidBrush(pbg)) g.FillPath(pb, pp);
                Theme.DrawText(g, it.Risk, pf, pill, pfg, rtl, false, true, false);
                // texts: between the checkbox and the pill
                int tx0 = rtl ? pill.Right + Theme.S(16) : cb.Right + pad;
                int tx1 = rtl ? cb.X - pad : pill.X - Theme.S(16);
                int tw = Math.Max(Theme.S(40), tx1 - tx0);
                Rectangle nr = new Rectangle(tx0, row.Y + Theme.S(10), tw, Theme.S(22));
                Rectangle rr = new Rectangle(tx0, row.Y + Theme.S(33), tw, Theme.S(20));
                Theme.DrawText(g, it.Name, nf, nr, Theme.Text, false, rtl, false, false);
                Theme.DrawText(g, it.Reason, rf, rr, Theme.SubText, rtl, rtl, false, false);
            }
            if (bar)
            {
                float th = Math.Max(Theme.Sf(24f), Height * (float)Height / ContentHeight);
                float ty = (Height - th) * (ContentHeight - Height == 0 ? 0 : (float)scroll / (ContentHeight - Height));
                float sw = Theme.Sf(4f);
                float tx = rtl ? Theme.Sf(2f) : Width - Theme.Sf(7f);
                using (GraphicsPath sp = Theme.RoundRect(new RectangleF(tx, ty + Theme.Sf(2), sw, th - Theme.Sf(4)), sw / 2f))
                using (SolidBrush sb = new SolidBrush(Theme.Track)) g.FillPath(sb, sp);
            }
        }
    }

    // ------------------------------------------------------------------ coach marks (the guided tour, see lib\Tour.ps1)
    // A borderless per-pixel-alpha ("layered") window that the tour lays exactly over the main window's client area. It dims
    // the window, keeps a lit hole with an accent ring around one control, and draws the tour card (step counter, title,
    // text, Back / Next / Skip). While the tour is open the card has the keyboard focus: Tab moves between its buttons,
    // Enter / Space press the focused one (Next unless Tab moved), other keys are reported through CoachKey. A message filter
    // also catches the keys and the mouse wheel meant for the main window (if the user clicks its title bar), so nothing
    // underneath can be typed into; the hole is painted with alpha 1 (invisible, but it still catches clicks). Screen readers
    // see a dialog with the counter, title, text and the three buttons (each can be invoked), and each step is announced.
    // The main window keeps its active title bar. The tour logic (steps, texts, where the card goes) lives in PowerShell.
    public class FCoach : Form, IMessageFilter
    {
        [DllImport("user32.dll")] static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref PT dst, ref SZ size, IntPtr hdcSrc, ref PT src, int key, ref BLEND blend, int flags);
        [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr hwnd);
        [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);
        [DllImport("user32.dll")] static extern bool IsChild(IntPtr parent, IntPtr child);
        [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hwnd, int msg, IntPtr wp, IntPtr lp);
        [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
        [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
        [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
        [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr obj);
        [DllImport("gdi32.dll")] static extern IntPtr CreateDIBSection(IntPtr dc, ref BMI info, uint usage, out IntPtr bits, IntPtr section, uint offset);
        [DllImport("UIAutomationCore.dll")] static extern int UiaHostProviderFromHwnd(IntPtr hwnd, out IntPtr provider);
        [DllImport("UIAutomationCore.dll", CharSet = CharSet.Unicode)] static extern int UiaRaiseNotificationEvent(IntPtr provider, int kind, int processing, [MarshalAs(UnmanagedType.BStr)] string display, [MarshalAs(UnmanagedType.BStr)] string activityId);
        [DllImport("UIAutomationCore.dll")] static extern bool UiaClientsAreListening();

        [StructLayout(LayoutKind.Sequential)] struct PT { public int X, Y; public PT(int x, int y) { X = x; Y = y; } }
        [StructLayout(LayoutKind.Sequential)] struct SZ { public int W, H; public SZ(int w, int h) { W = w; H = h; } }
        [StructLayout(LayoutKind.Sequential, Pack = 1)] struct BLEND { public byte Op, Flags, Alpha, Format; }
        [StructLayout(LayoutKind.Sequential)]
        struct BMI
        {
            public int Size, Width, Height; public short Planes, Bits;
            public int Compression, SizeImage, XPels, YPels, ClrUsed, ClrImportant, Color0;
        }

        // ---- what the card shows (set by the tour, then call Render)
        public string Title = "", Body = "", Note = "", Counter = "", BackText = "", NextText = "", SkipText = "", Glyph = "";
        public bool Rtl, CanBack = true;
        public int StepIndex, StepCount;
        public Rectangle Hole = Rectangle.Empty;   // lit area in client coordinates; Empty = nothing lit (the card stands alone)
        public Point CardLocation;                 // top-left corner of the card in client coordinates (see MeasureCard)
        public int CardWidth = 384;                // at 96 dpi; multiplied by Theme.Scale
        public bool Animate = SystemInformation.UIEffectsEnabled;
        public byte DimAlpha;
        public string LastError = "";              // set when drawing failed on a timer or mouse event (nothing to throw to there); the tour then closes

        public event EventHandler NextClick, BackClick, SkipClick;
        public event KeyEventHandler CoachKey;
        public event MouseEventHandler CoachWheel;

        enum Hit { None, Skip, Back, Next }
        struct Lay { public Size Card; public Rectangle Badge, Counter, Dots, TitleR, BodyR, NoteIcon, NoteR, Skip, Back, Next; }

        bool filterOn, shown, detached, cues;
        Hit hot = Hit.None, pressed = Hit.None, focus = Hit.Next;
        Lay lay;
        Bitmap content;                        // the card, drawn opaque
        IntPtr memDc = IntPtr.Zero, dib = IntPtr.Zero, oldObj = IntPtr.Zero, bits = IntPtr.Zero;
        Bitmap surface;                        // premultiplied ARGB view of the DIB that UpdateLayeredWindow shows
        Size surfaceSize = Size.Empty;
        readonly Timer anim = new Timer();
        readonly System.Diagnostics.Stopwatch clock = new System.Diagnostics.Stopwatch();
        Rectangle curHole = Rectangle.Empty, fromHole = Rectangle.Empty, toHole = Rectangle.Empty;
        Point curCard, fromCard, toCard;
        byte curAlpha = 255;
        bool fading;
        string spoken = "";
        const int MoveMs = 190, FadeMs = 160;

        public FCoach()
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            KeyPreview = false;
            DimAlpha = Theme.Dark ? (byte)150 : (byte)120;
            anim.Interval = 15;
            anim.Tick += delegate { try { Step(); } catch (Exception ex) { Fail(ex); } };
        }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x00080000 | 0x00000080;   // WS_EX_LAYERED | WS_EX_TOOLWINDOW
                return cp;
            }
        }
        protected override void OnPaintBackground(PaintEventArgs e) { }   // a layered window shows what UpdateLayeredWindow gave it
        protected override void OnPaint(PaintEventArgs e) { }
        protected override void WndProc(ref Message m)
        {
            base.WndProc(ref m);
            if (m.Msg == 0x0006 && Owner != null && Owner.IsHandleCreated)   // WM_ACTIVATE: keep the main window's title bar looking active
            {
                bool active = ((long)m.WParam & 0xFFFF) != 0;
                if (active) SendMessage(Owner.Handle, 0x0086, (IntPtr)1, IntPtr.Zero);
                else if (m.LParam != Owner.Handle) SendMessage(Owner.Handle, 0x0086, IntPtr.Zero, IntPtr.Zero);
            }
        }
        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            // Alt+F4 on the card means "leave the tour": the tour closes it properly
            if (!detached && e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Press(Hit.Skip); return; }
            base.OnFormClosing(e);
        }

        public float DpiScale { get { return Theme.Scale; } }
        void Fail(Exception ex) { anim.Stop(); LastError = ex.Message; }
        public Rectangle CardBounds { get { return new Rectangle(toCard, lay.Card); } }   // where the card ends up (client coordinates)
        public Rectangle NextBounds { get { return Offset(lay.Next); } }
        public Rectangle BackBounds { get { return Offset(lay.Back); } }
        public Rectangle SkipBounds { get { return Offset(lay.Skip); } }
        public string FocusedButton { get { return focus.ToString(); } }
        public string Spoken { get { return spoken; } }   // what the last step announcement said (tests)
        Rectangle Offset(Rectangle r) { if (r.IsEmpty) return r; r.Offset(toCard); return r; }
        static int P(float v) { return Theme.S(v); }

        // ---- showing and hiding
        public void Attach(Form owner)
        {
            Owner = owner;
            detached = false;
            if (!filterOn) { Application.AddMessageFilter(this); filterOn = true; }
        }
        public void Detach()
        {
            detached = true;
            if (filterOn) { Application.RemoveMessageFilter(this); filterOn = false; }
            anim.Stop();
        }
        protected override void OnFormClosed(FormClosedEventArgs e) { Detach(); base.OnFormClosed(e); }
        protected override void Dispose(bool disposing)
        {
            if (disposing) { Detach(); anim.Dispose(); if (content != null) { content.Dispose(); content = null; } }
            FreeSurface();
            base.Dispose(disposing);
        }

        // keys and wheel turns aimed at the owner window or at this one are handled here and never reach the owner
        public bool PreFilterMessage(ref Message m)
        {
            int msg = m.Msg;
            bool key = msg >= 0x0100 && msg <= 0x0103;   // WM_KEYDOWN, WM_KEYUP, WM_CHAR, WM_DEADCHAR (Alt combinations stay with Windows)
            bool wheel = msg == 0x020A;
            if (!key && !wheel) return false;
            if (IsDisposed || !Visible || Owner == null || !Owner.IsHandleCreated) return false;
            IntPtr o = Owner.Handle;
            if (m.HWnd != o && m.HWnd != Handle && !IsChild(o, m.HWnd)) return false;
            try
            {
                if (msg == 0x0100)
                {
                    Keys k = (Keys)(int)(long)m.WParam & Keys.KeyCode;
                    if (k == Keys.Tab) MoveFocus((ModifierKeys & Keys.Shift) == Keys.Shift ? -1 : 1);
                    else if (k == Keys.Enter || k == Keys.Space) Press(Usable(focus) ? focus : Hit.Next);
                    else if (CoachKey != null) CoachKey(this, new KeyEventArgs(k | ModifierKeys));
                }
                if (wheel && CoachWheel != null) CoachWheel(this, new MouseEventArgs(MouseButtons.None, 0, 0, 0, (short)(((long)m.WParam >> 16) & 0xFFFF)));
            }
            catch (Exception ex) { Fail(ex); }
            return true;
        }

        // ---- keyboard focus inside the card (reading order: Skip, Back, Next)
        bool Usable(Hit h) { return h == Hit.Next || (h == Hit.Back && CanBack) || (h == Hit.Skip && SkipText.Length > 0); }
        List<Hit> Buttons() { List<Hit> l = new List<Hit>(); foreach (Hit h in new Hit[] { Hit.Skip, Hit.Back, Hit.Next }) if (Usable(h)) l.Add(h); return l; }
        public void MoveFocus(int dir)
        {
            List<Hit> b = Buttons();
            int i = b.IndexOf(focus);
            if (i < 0) i = b.Count - 1;
            i = (i + dir + b.Count) % b.Count;
            focus = b[i];
            cues = true;
            Redraw();
            NotifyFocus();
        }
        void NotifyFocus()
        {
            if (!IsHandleCreated) return;
            List<Part> parts = Parts();
            for (int i = 0; i < parts.Count; i++) if (parts[i].Hit == focus && focus != Hit.None) { AccessibilityNotifyClients(AccessibleEvents.Focus, i); break; }
        }

        // ---- card layout (all sizes follow Theme.Scale; right-to-left mirrors every rectangle)
        Font CounterFont { get { return Theme.UI(9f, FontStyle.Regular); } }
        Font TitleFont { get { return Theme.Semi(13f); } }
        Font BodyFont { get { return Theme.UI(10f, FontStyle.Regular); } }
        Font ButtonFont { get { return Theme.Semi(10f); } }
        Font NoteFont { get { return Theme.UI(9.5f, FontStyle.Regular); } }

        public Size MeasureCard()
        {
            using (Bitmap b = new Bitmap(4, 4))
            using (Graphics g = Graphics.FromImage(b)) { g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit; lay = CardLayout(g); }
            return lay.Card;
        }

        Lay CardLayout(Graphics g)
        {
            Lay l = new Lay();
            int w = P(CardWidth);
            int pad = P(20), badge = P(36), gap = P(12);
            int textX = pad + badge + gap, textW = Math.Max(P(60), w - textX - pad);
            int dot = P(6), dgap = P(5);
            int dotsW = StepCount > 1 ? StepCount * dot + (StepCount - 1) * dgap : 0;
            int counterH = Math.Max(P(16), TextRenderer.MeasureText(g, "Ag", CounterFont).Height);
            l.Counter = new Rectangle(textX, pad, Math.Max(P(40), textW - dotsW - P(10)), counterH);
            l.Dots = new Rectangle(w - pad - dotsW, pad + (counterH - dot) / 2, dotsW, dot);
            int titleH = Math.Max(P(20), Theme.MeasureWrapped(g, Title, TitleFont, textW));
            l.TitleR = new Rectangle(textX, l.Counter.Bottom + P(2), textW, titleH);
            l.Badge = new Rectangle(pad, pad + P(2), badge, badge);
            int top = Math.Max(l.Badge.Bottom, l.TitleR.Bottom) + P(12);
            int bodyW = w - pad * 2;
            int bodyH = Body.Length > 0 ? Theme.MeasureWrapped(g, Body, BodyFont, bodyW) + P(2) : 0;
            l.BodyR = new Rectangle(pad, top, bodyW, bodyH);
            int textBottom = l.BodyR.Bottom;
            if (Note.Length > 0)   // a quieter line under the text, with an info icon ("this part appears after a scan")
            {
                int iw = P(16), ig = P(6);
                int noteH = Math.Max(iw, Theme.MeasureWrapped(g, Note, NoteFont, bodyW - iw - ig) + P(2));
                l.NoteIcon = new Rectangle(pad, l.BodyR.Bottom + P(10), iw, iw);
                l.NoteR = new Rectangle(pad + iw + ig, l.BodyR.Bottom + P(10), bodyW - iw - ig, noteH);
                textBottom = l.NoteR.Bottom;
            }
            int by = textBottom + P(20), bh = P(34);
            int nextW = Math.Max(P(96), Theme.MeasureWidth(g, NextText, ButtonFont) + P(32));
            int backW = Math.Max(P(84), Theme.MeasureWidth(g, BackText, ButtonFont) + P(28));
            int skipW = Theme.MeasureWidth(g, SkipText, ButtonFont) + P(20);
            l.Next = new Rectangle(w - pad - nextW, by, nextW, bh);
            l.Back = CanBack ? new Rectangle(l.Next.X - P(8) - backW, by, backW, bh) : Rectangle.Empty;
            l.Skip = SkipText.Length > 0 ? new Rectangle(pad - P(10), by, skipW, bh) : Rectangle.Empty;
            l.Card = new Size(w, by + bh + P(18));
            if (Rtl)
            {
                l.Badge = Mirror(l.Badge, w); l.Counter = Mirror(l.Counter, w); l.Dots = Mirror(l.Dots, w); l.TitleR = Mirror(l.TitleR, w);
                l.BodyR = Mirror(l.BodyR, w); l.NoteIcon = Mirror(l.NoteIcon, w); l.NoteR = Mirror(l.NoteR, w); l.Skip = Mirror(l.Skip, w); l.Back = Mirror(l.Back, w); l.Next = Mirror(l.Next, w);
            }
            return l;
        }
        static Rectangle Mirror(Rectangle r, int w) { if (r.IsEmpty) return r; return new Rectangle(w - r.Right, r.Y, r.Width, r.Height); }

        void DrawButtonFocus(Graphics g, Rectangle r)
        {
            float i = Theme.Sf(2.5f);
            RectangleF fr = new RectangleF(r.X + i, r.Y + i, r.Width - 2 * i - 0.5f, r.Height - 2 * i - 0.5f);
            using (GraphicsPath fp = Theme.RoundRect(fr, Theme.Sf(3f)))
            using (Pen pen = new Pen(Theme.Dark ? Color.White : Color.Black, Math.Max(1.5f, Theme.Sf(1.5f)))) g.DrawPath(pen, fp);
        }

        Bitmap DrawContent()
        {
            Bitmap b;
            using (Bitmap probe = new Bitmap(4, 4))
            using (Graphics pg = Graphics.FromImage(probe)) { pg.TextRenderingHint = TextRenderingHint.AntiAliasGridFit; lay = CardLayout(pg); }
            b = new Bitmap(Math.Max(1, lay.Card.Width), Math.Max(1, lay.Card.Height), System.Drawing.Imaging.PixelFormat.Format32bppRgb);
            using (Graphics g = Graphics.FromImage(b))
            {
                g.Clear(Theme.Card);
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;   // GDI text on an off-screen bitmap is too heavy without it
                // icon badge, tinted with the accent
                using (GraphicsPath bp = Theme.RoundRect(new RectangleF(lay.Badge.X, lay.Badge.Y, lay.Badge.Width, lay.Badge.Height), Theme.Sf(9f)))
                using (SolidBrush bb = new SolidBrush(Theme.Mix(Theme.Card, Theme.Accent, Theme.Dark ? 0.22 : 0.12))) g.FillPath(bb, bp);
                Theme.DrawGlyph(g, Glyph, 18f, lay.Badge, Theme.Accent);
                // step counter and progress dots
                Theme.DrawText(g, Counter, CounterFont, lay.Counter, Theme.SubText, Rtl, Rtl, false, false);
                int dot = P(6), dgap = P(5);
                for (int i = 0; i < StepCount && StepCount > 1; i++)
                {
                    int x = Rtl ? lay.Dots.Right - (i + 1) * dot - i * dgap : lay.Dots.X + i * (dot + dgap);
                    Color c = i == StepIndex ? Theme.Accent : (i < StepIndex ? Theme.Mix(Theme.Accent, Theme.Card, 0.55) : Theme.Track);
                    using (SolidBrush db = new SolidBrush(c)) g.FillEllipse(db, x, lay.Dots.Y, dot, dot);
                }
                Theme.DrawText(g, Title, TitleFont, lay.TitleR, Theme.Text, Rtl, Rtl, false, true);
                Theme.DrawText(g, Body, BodyFont, lay.BodyR, Theme.Mix(Theme.Text, Theme.Card, 0.12), Rtl, Rtl, false, true);
                if (Note.Length > 0)
                {
                    Theme.DrawGlyph(g, "\uE946", 14f, lay.NoteIcon, Theme.Accent);
                    Theme.DrawText(g, Note, NoteFont, lay.NoteR, Theme.SubText, Rtl, Rtl, false, true);
                }
                // buttons
                if (!lay.Skip.IsEmpty)
                {
                    if (hot == Hit.Skip) using (GraphicsPath sp = Theme.RoundRect(R(lay.Skip), Theme.Sf(4f))) using (SolidBrush sb = new SolidBrush(pressed == Hit.Skip ? Theme.BtnPressed : Theme.RowHover)) g.FillPath(sb, sp);
                    Theme.DrawText(g, SkipText, ButtonFont, lay.Skip, hot == Hit.Skip ? Theme.Text : Theme.SubText, Rtl, false, true, false);
                    if (cues && focus == Hit.Skip) DrawButtonFocus(g, lay.Skip);
                }
                if (!lay.Back.IsEmpty)
                {
                    Color f = pressed == Hit.Back ? Theme.BtnPressed : (hot == Hit.Back ? Theme.BtnHover : Theme.BtnFill);
                    using (GraphicsPath p = Theme.RoundRect(R(lay.Back), Theme.Sf(4f)))
                    {
                        using (SolidBrush fb = new SolidBrush(f)) g.FillPath(fb, p);
                        using (Pen pen = new Pen(Theme.BtnBorder, 1f)) g.DrawPath(pen, p);
                    }
                    Theme.DrawText(g, BackText, ButtonFont, lay.Back, Theme.Text, Rtl, false, true, false);
                    if (cues && focus == Hit.Back) DrawButtonFocus(g, lay.Back);
                }
                Color nf = pressed == Hit.Next ? Theme.AccentPressed : (hot == Hit.Next ? Theme.AccentHover : Theme.Accent);
                using (GraphicsPath np = Theme.RoundRect(R(lay.Next), Theme.Sf(4f)))
                using (SolidBrush nb = new SolidBrush(nf)) g.FillPath(nb, np);
                Theme.DrawText(g, NextText, ButtonFont, lay.Next, Theme.AccentText, Rtl, false, true, false);
                if (cues && focus == Hit.Next) DrawButtonFocus(g, lay.Next);
            }
            return b;
        }
        static RectangleF R(Rectangle r) { return new RectangleF(r.X + 0.5f, r.Y + 0.5f, r.Width - 1f, r.Height - 1f); }

        // ---- drawing: build the card, then move (animated or not) to Hole / CardLocation
        public void Render(bool animate)
        {
            toHole = Hole; toCard = CardLocation;
            pressed = Hit.None;   // a press never carries over to another step; hover follows where the mouse really is
            hot = Hit.None;
            MeasureCard();
            if (!Usable(focus)) focus = Hit.Next;
            if (IsHandleCreated && Visible)
            {
                Point m = PointToClient(MousePosition);
                if (ClientRectangle.Contains(m)) hot = HitAt(m, toCard);
            }
            if (content != null) content.Dispose();
            content = DrawContent();
            Announce();
            if (fading) return;   // the fade-in keeps running and ends on the new targets
            if (animate && Animate && shown)
            {
                fromHole = curHole; fromCard = curCard;
                if (fromHole.IsEmpty || toHole.IsEmpty) fromHole = toHole;
                clock.Reset(); clock.Start(); anim.Start();
                Step();
            }
            else if (!anim.Enabled)
            {
                curHole = toHole; curCard = toCard;
                Frame();
            }
        }

        // the first frame after Show: fade in (when the user allows animations)
        public void Present()
        {
            curHole = toHole = Hole; curCard = toCard = CardLocation;
            if (content == null) content = DrawContent();
            shown = true;
            if (Animate) { fading = true; curAlpha = 0; fromHole = toHole; fromCard = toCard; clock.Reset(); clock.Start(); anim.Start(); }
            Frame();
            spoken = "";
            Announce();
        }

        // what a screen reader hears for the current step
        public string SpokenText(bool withCounter)
        {
            string s = withCounter && Counter.Length > 0 ? Counter + ". " : "";
            s += Title;
            if (Body.Length > 0) s += ". " + Body;
            if (Note.Length > 0) s += " " + Note;
            return s;
        }
        // tell screen readers about a new step (once per step): the dialog's name changed, the focus is on a button, and on
        // Windows 10 1709+ a UI Automation notification reads the whole card
        void Announce()
        {
            if (!shown || !IsHandleCreated) return;
            string s = SpokenText(true);
            if (s == spoken) return;
            spoken = s;
            try
            {
                AccessibilityNotifyClients(AccessibleEvents.NameChange, -1);
                AccessibilityNotifyClients(AccessibleEvents.DescriptionChange, -1);
                NotifyFocus();
            }
            catch { }
            try
            {
                if (!UiaClientsAreListening()) return;
                IntPtr p;
                if (UiaHostProviderFromHwnd(Handle, out p) == 0 && p != IntPtr.Zero)
                {
                    try { UiaRaiseNotificationEvent(p, 4, 1, s, "RamDoctorTourStep"); }   // NotificationKind_Other, ImportantMostRecent
                    finally { Marshal.Release(p); }
                }
            }
            catch (DllNotFoundException) { }
            catch (EntryPointNotFoundException) { }
            catch { }
        }

        void Step()
        {
            double t = Math.Min(1.0, clock.ElapsedMilliseconds / (double)(fading ? FadeMs : MoveMs));
            double e = 1 - Math.Pow(1 - t, 3);   // ease-out
            curHole = toHole.IsEmpty ? toHole : new Rectangle(L(fromHole.X, toHole.X, e), L(fromHole.Y, toHole.Y, e), L(fromHole.Width, toHole.Width, e), L(fromHole.Height, toHole.Height, e));
            curCard = new Point(L(fromCard.X, toCard.X, e), L(fromCard.Y, toCard.Y, e));
            if (fading) curAlpha = (byte)Math.Round(255 * e);
            if (t >= 1) { anim.Stop(); clock.Stop(); fading = false; curAlpha = 255; curHole = toHole; curCard = toCard; }
            Frame();
        }
        static int L(int a, int b, double e) { return (int)Math.Round(a + (b - a) * e); }

        void Frame()
        {
            if (!shown || !IsHandleCreated || IsDisposed || Width < 1 || Height < 1) return;   // nothing on screen before Present()
            EnsureSurface();
            if (surface == null) return;
            using (Graphics g = Graphics.FromImage(surface))
            {
                g.CompositingMode = CompositingMode.SourceCopy;
                g.Clear(Color.FromArgb(DimAlpha, 0, 0, 0));
                if (!curHole.IsEmpty)
                {
                    float rad = Theme.Sf(8f);
                    using (GraphicsPath hp = Theme.RoundRect(new RectangleF(curHole.X, curHole.Y, curHole.Width, curHole.Height), rad))
                    using (SolidBrush hb = new SolidBrush(Color.FromArgb(1, 0, 0, 0))) g.FillPath(hb, hp);   // looks clear, still catches clicks
                    g.CompositingMode = CompositingMode.SourceOver;
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    RectangleF ring = new RectangleF(curHole.X - 0.5f, curHole.Y - 0.5f, curHole.Width + 1f, curHole.Height + 1f);
                    using (GraphicsPath rp = Theme.RoundRect(ring, rad + 0.5f))
                    {
                        using (Pen glow = new Pen(Color.FromArgb(70, Theme.Accent), Theme.Sf(6f))) g.DrawPath(glow, rp);
                        using (Pen pen = new Pen(Theme.Accent, Math.Max(2f, Theme.Sf(2f)))) g.DrawPath(pen, rp);
                    }
                }
                g.CompositingMode = CompositingMode.SourceOver;
                g.SmoothingMode = SmoothingMode.AntiAlias;
                if (content != null)
                {
                    Rectangle c = new Rectangle(curCard, content.Size);
                    float rad = Theme.Sf(8f);
                    int sh = P(10);
                    for (int i = sh; i >= 1; i--)   // soft shadow, a little below the card
                        using (GraphicsPath sp = Theme.RoundRect(new RectangleF(c.X - i, c.Y - i + P(4), c.Width + 2 * i, c.Height + 2 * i), rad + i))
                        using (SolidBrush sb = new SolidBrush(Color.FromArgb(Theme.Dark ? 12 : 8, 0, 0, 0))) g.FillPath(sb, sp);
                    using (GraphicsPath cp = Theme.RoundRect(new RectangleF(c.X + 0.5f, c.Y + 0.5f, c.Width - 1f, c.Height - 1f), rad))
                    {
                        using (SolidBrush cb = new SolidBrush(Theme.Card)) g.FillPath(cb, cp);
                        using (GraphicsPath clip = Theme.RoundRect(new RectangleF(c.X + 1.5f, c.Y + 1.5f, c.Width - 3f, c.Height - 3f), rad - 1f))
                        {
                            g.SetClip(clip);
                            g.DrawImageUnscaled(content, c.X, c.Y);
                            g.ResetClip();
                        }
                        using (Pen bp = new Pen(Theme.Dark ? Theme.Mix(Theme.CardBorder, Theme.Text, 0.12) : Theme.CardBorder, 1f)) g.DrawPath(bp, cp);
                    }
                }
            }
            Push(curAlpha);
        }

        void EnsureSurface()
        {
            Size s = ClientSize;
            if (s == surfaceSize && surface != null) return;
            FreeSurface();
            if (s.Width < 1 || s.Height < 1) return;
            IntPtr screen = GetDC(IntPtr.Zero);
            try
            {
                BMI bi = new BMI();
                bi.Size = 40; bi.Width = s.Width; bi.Height = -s.Height; bi.Planes = 1; bi.Bits = 32;   // top-down 32-bit DIB
                bi.Compression = 0; bi.SizeImage = 0; bi.XPels = 0; bi.YPels = 0; bi.ClrUsed = 0; bi.ClrImportant = 0; bi.Color0 = 0;
                dib = CreateDIBSection(screen, ref bi, 0, out bits, IntPtr.Zero, 0);
                if (dib == IntPtr.Zero) return;
                memDc = CreateCompatibleDC(screen);
                oldObj = SelectObject(memDc, dib);
                surface = new Bitmap(s.Width, s.Height, s.Width * 4, System.Drawing.Imaging.PixelFormat.Format32bppPArgb, bits);
                surfaceSize = s;
            }
            finally { ReleaseDC(IntPtr.Zero, screen); }
        }

        void FreeSurface()
        {
            if (surface != null) { surface.Dispose(); surface = null; }
            if (memDc != IntPtr.Zero) { SelectObject(memDc, oldObj); DeleteDC(memDc); memDc = IntPtr.Zero; }
            if (dib != IntPtr.Zero) { DeleteObject(dib); dib = IntPtr.Zero; }
            surfaceSize = Size.Empty;
        }

        void Push(byte alpha)
        {
            if (memDc == IntPtr.Zero) return;
            IntPtr screen = GetDC(IntPtr.Zero);
            try
            {
                PT dst = new PT(Left, Top), src = new PT(0, 0);
                SZ size = new SZ(surfaceSize.Width, surfaceSize.Height);
                BLEND b = new BLEND(); b.Op = 0; b.Flags = 0; b.Alpha = alpha; b.Format = 1;   // AC_SRC_OVER, per-pixel alpha
                UpdateLayeredWindow(Handle, screen, ref dst, ref size, memDc, ref src, 0, ref b, 2);   // ULW_ALPHA
            }
            finally { ReleaseDC(IntPtr.Zero, screen); }
        }

        // ---- the mouse: only the three card buttons react
        Hit HitAt(Point p) { return HitAt(p, curCard); }
        Hit HitAt(Point p, Point card)
        {
            Point q = new Point(p.X - card.X, p.Y - card.Y);
            if (lay.Next.Contains(q)) return Hit.Next;
            if (!lay.Back.IsEmpty && lay.Back.Contains(q)) return Hit.Back;
            if (!lay.Skip.IsEmpty && lay.Skip.Contains(q)) return Hit.Skip;
            return Hit.None;
        }
        void Redraw() { try { if (content != null) content.Dispose(); content = DrawContent(); Frame(); } catch (Exception ex) { Fail(ex); } }
        protected override void OnMouseMove(MouseEventArgs e)
        {
            Hit h = HitAt(e.Location);
            if (h != hot) { hot = h; Cursor = h == Hit.None ? Cursors.Default : Cursors.Hand; Redraw(); }
            base.OnMouseMove(e);
        }
        protected override void OnMouseLeave(EventArgs e) { if (hot != Hit.None || pressed != Hit.None) { hot = Hit.None; pressed = Hit.None; Redraw(); } base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left) { pressed = HitAt(e.Location); if (pressed != Hit.None) Redraw(); }
            base.OnMouseDown(e);
        }
        protected override void OnMouseUp(MouseEventArgs e)
        {
            Hit was = pressed; pressed = Hit.None;
            Hit now = HitAt(e.Location);
            if (was != Hit.None) Redraw();
            if (e.Button == MouseButtons.Left && was != Hit.None && was == now) Press(was);
            base.OnMouseUp(e);
        }
        protected override void OnMouseWheel(MouseEventArgs e) { if (CoachWheel != null) CoachWheel(this, e); base.OnMouseWheel(e); }

        void Press(Hit h)
        {
            EventHandler ev = h == Hit.Next ? NextClick : (h == Hit.Back ? BackClick : SkipClick);
            if (ev != null) ev(this, EventArgs.Empty);
        }
        public void PerformNext() { Press(Hit.Next); }
        public void PerformBack() { if (CanBack) Press(Hit.Back); }
        public void PerformSkip() { Press(Hit.Skip); }

        // ---- what screen readers see: a dialog with the counter, the title, the text (and note) and the buttons
        struct Part { public Hit Hit; public AccessibleRole Role; public string Name; public Rectangle Rect; }
        List<Part> Parts()
        {
            List<Part> l = new List<Part>();
            Add(l, Hit.None, AccessibleRole.StaticText, Counter, lay.Counter);
            Add(l, Hit.None, AccessibleRole.StaticText, Title, lay.TitleR);
            Add(l, Hit.None, AccessibleRole.StaticText, Body, lay.BodyR);
            if (Note.Length > 0) Add(l, Hit.None, AccessibleRole.StaticText, Note, lay.NoteR);
            if (Usable(Hit.Skip)) Add(l, Hit.Skip, AccessibleRole.PushButton, SkipText, lay.Skip);
            if (Usable(Hit.Back)) Add(l, Hit.Back, AccessibleRole.PushButton, BackText, lay.Back);
            Add(l, Hit.Next, AccessibleRole.PushButton, NextText, lay.Next);
            return l;
        }
        static void Add(List<Part> l, Hit h, AccessibleRole role, string name, Rectangle r) { Part p; p.Hit = h; p.Role = role; p.Name = name ?? ""; p.Rect = r; l.Add(p); }
        Rectangle ToScreen(Rectangle cardRect) { if (!IsHandleCreated) return Rectangle.Empty; Rectangle r = cardRect; r.Offset(curCard); return RectangleToScreen(r); }

        protected override AccessibleObject CreateAccessibilityInstance() { return new CoachAccessible(this); }
        class CoachAccessible : ControlAccessibleObject
        {
            readonly FCoach c;
            public CoachAccessible(FCoach owner) : base(owner) { c = owner; }
            public override AccessibleRole Role { get { return AccessibleRole.Dialog; } }
            public override string Name { get { return c.Title; } set { } }
            public override string Description { get { return c.SpokenText(true); } }
            public override int GetChildCount() { return c.Parts().Count; }
            public override AccessibleObject GetChild(int index) { List<Part> p = c.Parts(); return (index >= 0 && index < p.Count) ? new PartAccessible(c, this, p[index]) : null; }
            public override AccessibleObject GetFocused()
            {
                foreach (Part p in c.Parts()) if (p.Hit != Hit.None && p.Hit == c.focus) return new PartAccessible(c, this, p);
                return this;
            }
            public override AccessibleObject HitTest(int x, int y)
            {
                foreach (Part p in c.Parts()) if (c.ToScreen(p.Rect).Contains(x, y)) return new PartAccessible(c, this, p);
                return base.HitTest(x, y);
            }
            public override AccessibleStates State { get { return AccessibleStates.Focusable | (c.ContainsFocus ? AccessibleStates.Focused : AccessibleStates.None); } }
        }
        class PartAccessible : AccessibleObject
        {
            readonly FCoach c; readonly AccessibleObject parent; readonly Part p;
            public PartAccessible(FCoach coach, AccessibleObject owner, Part part) { c = coach; parent = owner; p = part; }
            public override AccessibleObject Parent { get { return parent; } }
            public override AccessibleRole Role { get { return p.Role; } }
            public override string Name { get { return p.Name; } set { } }
            public override Rectangle Bounds { get { return c.ToScreen(p.Rect); } }
            public override string DefaultAction { get { return p.Hit != Hit.None ? "Press" : null; } }
            public override void DoDefaultAction() { if (p.Hit != Hit.None) c.Press(p.Hit); }
            public override AccessibleStates State
            {
                get
                {
                    if (p.Hit == Hit.None) return AccessibleStates.ReadOnly;
                    AccessibleStates s = AccessibleStates.Focusable;
                    if (p.Hit == c.focus) s |= AccessibleStates.Focused;
                    return s;
                }
            }
            public override void Select(AccessibleSelection flags) { if (p.Hit != Hit.None && (flags & AccessibleSelection.TakeFocus) != 0) { c.focus = p.Hit; c.Redraw(); } }
        }
    }
}
