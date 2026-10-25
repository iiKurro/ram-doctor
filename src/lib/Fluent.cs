// Fluent.cs - small owner-drawn control kit that gives the WinForms window a Windows 11 (Fluent) look.
// Pure GDI+/WinForms, no third-party code. Everything mirrors correctly for RightToLeft (Arabic).
// Compiled at start-up by Add-Type (Windows PowerShell 5.1 => C# 5: no string interpolation, no ?., no expression bodies).
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

    // ------------------------------------------------------------------ palette / fonts / drawing helpers
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

        public static Font UI(float pt, FontStyle st) { return Get(UiFamily, pt, st, GraphicsUnit.Point); }
        public static Font Semi(float pt) { return Get(SemiFamily, pt, FontStyle.Regular, GraphicsUnit.Point); }
        public static Font Icons(float px) { return Get(IconFamily, px, FontStyle.Regular, GraphicsUnit.Pixel); }
        public static Font Mono(float pt) { return Get(HasFont("Cascadia Mono") ? "Cascadia Mono" : "Consolas", pt, FontStyle.Regular, GraphicsUnit.Point); }

        static Font Get(string fam, float size, FontStyle st, GraphicsUnit u)
        {
            string k = fam + "|" + size + "|" + (int)st + "|" + (int)u;
            Font f;
            if (!cache.TryGetValue(k, out f))
            {
                try { f = new Font(fam, size, st, u); }
                catch { f = new Font("Segoe UI", size, st, u); }
                cache[k] = f;
            }
            return f;
        }

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

        public static void DrawGlyph(Graphics g, string glyph, float px, Rectangle r, Color c)
        {
            if (string.IsNullOrEmpty(glyph)) return;
            TextRenderer.DrawText(g, glyph, Icons(px), r, c, TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
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
                        g.DrawString(glyph, Theme.Icons(34f), tb, new RectangleF(0, 1, 64, 64), sf);
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
            using (GraphicsPath p = Theme.RoundRect(new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f), Radius))
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

        protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hover = false; down = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e) { if (e.Button == MouseButtons.Left) { down = true; Focus(); Invalidate(); } base.OnMouseDown(e); }
        protected override void OnMouseUp(MouseEventArgs e) { down = false; Invalidate(); base.OnMouseUp(e); }
        protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
        protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }
        protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
        protected override void OnTextChanged(EventArgs e) { Invalidate(); base.OnTextChanged(e); }
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

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Theme.Backdrop(this));
            bool rtl = RightToLeft == RightToLeft.Yes;
            Color fill, border, fore;
            Colors(out fill, out border, out fore);
            RectangleF r = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
            using (GraphicsPath p = Theme.RoundRect(r, 4f))
            {
                if (fill.A > 0) using (SolidBrush b = new SolidBrush(fill)) g.FillPath(b, p);
                if (border.A > 0) using (Pen pen = new Pen(border, 1f)) g.DrawPath(pen, p);
                if (Focused && ShowFocusCues && Enabled)
                {
                    RectangleF fr = new RectangleF(2.5f, 2.5f, Width - 5.5f, Height - 5.5f);
                    using (GraphicsPath fp = Theme.RoundRect(fr, 3f))
                    using (Pen pen = new Pen(Theme.Dark ? Color.White : Color.Black, 1.5f)) g.DrawPath(pen, fp);
                }
            }

            string t = Text ?? "";
            bool hasG = glyph.Length > 0;
            int gw = hasG ? 18 : 0;
            int gap = (hasG && t.Length > 0) ? 8 : 0;
            int avail = Width - 20 - gw - gap;
            int tw = Math.Min(Theme.MeasureWidth(g, t, Font), Math.Max(10, avail));
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
        public int Value { get { return value; } set { this.value = Math.Max(0, Math.Min(100, value)); Invalidate(); } }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Theme.Backdrop(this));
            bool rtl = RightToLeft == RightToLeft.Yes;
            float h = Math.Min(6f, Height);
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
        public int ReserveEnd;   // pixels kept free at the far end (right, or left when right-to-left) for buttons placed on the bar

        public FInfoBar()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            Size = new Size(400, 64);
        }

        public FLevel Level { get { return level; } set { level = value; Invalidate(); } }
        public string Title { get { return title; } set { title = value ?? ""; Fit(); Invalidate(); } }
        public string Message { get { return message; } set { message = (value ?? "").Replace("\r\n", "\n").Replace("\n", "\r\n"); Fit(); Invalidate(); } }

        void Fit() { if (AutoFit && Width > 120) FitHeight(); }

        protected override void OnSizeChanged(EventArgs e) { base.OnSizeChanged(e); Fit(); }

        const int Pad = 16;
        const int IconCol = 36;

        public int FitHeight()
        {
            using (Graphics g = CreateGraphics())
            {
                int tw = Math.Max(60, Width - Pad * 2 - IconCol - ReserveEnd);
                int th = Math.Max(20, Theme.MeasureWrapped(g, title, Theme.Semi(11.5f), tw));
                int mh = message.Length > 0 ? Theme.MeasureWrapped(g, message, Theme.UI(10f, FontStyle.Regular), tw) : 0;
                int h = (Pad - 2) + th + (mh > 0 ? 6 + mh : 0) + (Pad - 2);
                h = Math.Max(56, h);
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
            using (GraphicsPath p = Theme.RoundRect(new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f), 6f))
            {
                using (SolidBrush b = new SolidBrush(bg)) g.FillPath(b, p);
                using (Pen pen = new Pen(border, 1f)) g.DrawPath(pen, p);
            }
            int tw = Math.Max(60, Width - Pad * 2 - IconCol - ReserveEnd);
            int tx = rtl ? Pad + ReserveEnd : Pad + IconCol;
            int ix = rtl ? Width - Pad - 22 : Pad;
            Font tf = Theme.Semi(11.5f), mf = Theme.UI(10f, FontStyle.Regular);
            int th = Math.Max(20, Theme.MeasureWrapped(g, title, tf, tw));
            Theme.DrawGlyph(g, glyph, 20f, new Rectangle(ix, Pad - 2, 22, 22), ic);
            Theme.DrawText(g, title, tf, new Rectangle(tx, Pad - 2, tw, th), Theme.Text, rtl, rtl, false, true);
            if (message.Length > 0)
            {
                int mh = Theme.MeasureWrapped(g, message, mf, tw);
                Theme.DrawText(g, message, mf, new Rectangle(tx, Pad - 2 + th + 6, tw, mh + 2), Theme.Mix(Theme.Text, bg, 0.22), rtl, rtl, false, true);
            }
        }
    }

    // ------------------------------------------------------------------ icon badge
    public class FBadge : Control
    {
        public string Glyph = "";
        public bool Filled = true;
        public float GlyphPx = 22f;
        public int Radius = 12;
        public Color GlyphColor = Color.Empty;

        public FBadge()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            Size = new Size(48, 48);
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Theme.Backdrop(this));
            Color c;
            if (Filled)
            {
                using (GraphicsPath p = Theme.RoundRect(new RectangleF(0, 0, Width - 0.5f, Height - 0.5f), Radius))
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
        public void Toggle() { Expanded = !Expanded; Invalidate(); if (Toggled != null) Toggled(this, EventArgs.Empty); }
        protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hover = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnClick(EventArgs e) { base.OnClick(e); Toggle(); }
        protected override void OnKeyDown(KeyEventArgs e) { if (e.KeyCode == Keys.Space || e.KeyCode == Keys.Enter) { Toggle(); e.Handled = true; } base.OnKeyDown(e); }
        protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
        protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }
        protected override void OnTextChanged(EventArgs e) { Invalidate(); base.OnTextChanged(e); }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Theme.Backdrop(this));
            bool rtl = RightToLeft == RightToLeft.Yes;
            if (hover || Focused)
                using (GraphicsPath p = Theme.RoundRect(new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f), 6f))
                using (SolidBrush b = new SolidBrush(Theme.RowHover)) g.FillPath(b, p);
            int pad = 14;
            Rectangle gr = rtl ? new Rectangle(Width - pad - 24, 0, 24, Height) : new Rectangle(pad, 0, 24, Height);
            Rectangle cr = rtl ? new Rectangle(pad, 0, 24, Height) : new Rectangle(Width - pad - 24, 0, 24, Height);
            Rectangle tr = new Rectangle(pad + 32, 0, Math.Max(40, Width - pad * 2 - 36 - 32), Height);
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
            set { if (isChecked != value) { isChecked = value; Invalidate(); if (CheckedChanged != null) CheckedChanged(this, EventArgs.Empty); } }
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
            Rectangle cb = new Rectangle(rtl ? Width - 20 - 2 : 2, (Height - 20) / 2, 20, 20);
            using (GraphicsPath cp = Theme.RoundRect(new RectangleF(cb.X + 0.5f, cb.Y + 0.5f, cb.Width - 1, cb.Height - 1), 5f))
            {
                if (isChecked)
                {
                    using (SolidBrush ab = new SolidBrush(Theme.Accent)) g.FillPath(ab, cp);
                    Theme.DrawGlyph(g, "\uE73E", 12f, cb, Theme.AccentText);
                }
                else
                {
                    if (hover) using (SolidBrush hb = new SolidBrush(Theme.RowHover)) g.FillPath(hb, cp);
                    using (Pen pen = new Pen(Theme.SubText, 1.4f)) g.DrawPath(pen, cp);
                }
                if (Focused && ShowFocusCues)
                    using (Pen fp = new Pen(Theme.Dark ? Color.White : Color.Black, 1.2f))
                        g.DrawRectangle(fp, cb.X - 3, cb.Y - 3, cb.Width + 5, cb.Height + 5);
            }
            Rectangle tr = rtl ? new Rectangle(0, 0, Width - 20 - 12, Height) : new Rectangle(20 + 12, 0, Width - 20 - 12, Height);
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

        protected override void OnLayout(LayoutEventArgs e)
        {
            base.OnLayout(e);
            int h = tb.PreferredHeight;
            tb.SetBounds(12, (Height - h) / 2, Math.Max(20, Width - 24), h);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Theme.Backdrop(this));
            RectangleF r = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
            using (GraphicsPath p = Theme.RoundRect(r, 4f))
            {
                using (SolidBrush b = new SolidBrush(Theme.BtnFill)) g.FillPath(b, p);
                using (Pen pen = new Pen(Theme.BtnBorder, 1f)) g.DrawPath(pen, p);
            }
            if (focused)
            {
                // accent underline, clipped to the rounded shape
                using (GraphicsPath cp = Theme.RoundRect(r, 4f))
                {
                    g.SetClip(cp);
                    using (SolidBrush ab = new SolidBrush(Theme.Accent)) g.FillRectangle(ab, 0, Height - 3, Width, 2);
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
        public int RowHeight = 64;
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
        public void Add(FItem it) { items.Add(it); Invalidate(); }
        public void Clear() { items.Clear(); scroll = 0; hot = -1; cur = -1; Invalidate(); }
        public int CheckedCount { get { int n = 0; foreach (FItem i in items) if (i.Checked) n++; return n; } }
        public FItem[] GetChecked() { List<FItem> l = new List<FItem>(); foreach (FItem i in items) if (i.Checked) l.Add(i); return l.ToArray(); }

        int ContentHeight { get { return items.Count * RowHeight; } }
        void ClampScroll() { int max = Math.Max(0, ContentHeight - Height); scroll = Math.Max(0, Math.Min(max, scroll)); }
        int IndexAt(Point p) { int idx = (p.Y + scroll) / RowHeight; return (idx >= 0 && idx < items.Count && p.Y >= 0 && p.Y < Height) ? idx : -1; }

        public void Toggle(int i)
        {
            if (i < 0 || i >= items.Count) return;
            items[i].Checked = !items[i].Checked;
            Invalidate();
            if (ItemChecked != null) ItemChecked(this, EventArgs.Empty);
        }

        protected override void OnMouseMove(MouseEventArgs e) { int h = IndexAt(e.Location); if (h != hot) { hot = h; Invalidate(); } base.OnMouseMove(e); }
        protected override void OnMouseLeave(EventArgs e) { hot = -1; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e)
        {
            int i = IndexAt(e.Location);
            if (i >= 0) { Focus(); cur = i; Toggle(i); }
            base.OnMouseDown(e);
        }
        protected override void OnMouseWheel(MouseEventArgs e) { scroll -= (e.Delta / 120) * (RowHeight / 2); ClampScroll(); Invalidate(); base.OnMouseWheel(e); }
        protected override bool IsInputKey(Keys k) { return k == Keys.Up || k == Keys.Down || base.IsInputKey(k); }
        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (items.Count > 0)
            {
                if (e.KeyCode == Keys.Down) { cur = Math.Min(items.Count - 1, cur + 1); EnsureVisible(cur); Invalidate(); e.Handled = true; }
                else if (e.KeyCode == Keys.Up) { cur = Math.Max(0, cur - 1); EnsureVisible(cur); Invalidate(); e.Handled = true; }
                else if (e.KeyCode == Keys.Space && cur >= 0) { Toggle(cur); e.Handled = true; }
            }
            base.OnKeyDown(e);
        }
        protected override void OnGotFocus(EventArgs e) { if (cur < 0 && items.Count > 0) cur = 0; Invalidate(); base.OnGotFocus(e); }
        protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }
        void EnsureVisible(int i)
        {
            int top = i * RowHeight, bottom = top + RowHeight;
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
                Theme.DrawGlyph(g, EmptyGlyph, 28f, new Rectangle(0, Height / 2 - 40, Width, 40), Theme.SubText);
                Theme.DrawText(g, EmptyText, Theme.UI(10f, FontStyle.Regular), new Rectangle(12, Height / 2 + 4, Width - 24, 26), Theme.SubText, rtl, false, true, false);
                return;
            }
            ClampScroll();
            bool bar = ContentHeight > Height;
            int rowW = Width - (bar ? 12 : 0);
            int rowX = (rtl && bar) ? 12 : 0;
            Font nf = Theme.Semi(10.5f), rf = Theme.UI(9.5f, FontStyle.Regular), pf = Theme.Semi(9f);

            for (int i = 0; i < items.Count; i++)
            {
                int y = i * RowHeight - scroll;
                if (y + RowHeight < 0 || y > Height) continue;
                FItem it = items[i];
                Rectangle row = new Rectangle(rowX, y, rowW, RowHeight);
                if (i == hot || (i == cur && Focused))
                    using (GraphicsPath hp = Theme.RoundRect(new RectangleF(row.X + 2, row.Y + 3, row.Width - 4, row.Height - 6), 6f))
                    using (SolidBrush hb = new SolidBrush(Theme.RowHover)) g.FillPath(hb, hp);
                if (i < items.Count - 1 && i != hot && i != hot - 1)
                    using (Pen dp = new Pen(Theme.Divider, 1f)) g.DrawLine(dp, row.X + 14, row.Bottom - 1, row.Right - 14, row.Bottom - 1);

                int pad = 14;
                // checkbox
                int cbx = rtl ? row.Right - pad - 20 : row.X + pad;
                Rectangle cb = new Rectangle(cbx, row.Y + (RowHeight - 20) / 2, 20, 20);
                using (GraphicsPath cp = Theme.RoundRect(new RectangleF(cb.X + 0.5f, cb.Y + 0.5f, cb.Width - 1, cb.Height - 1), 5f))
                {
                    if (it.Checked)
                    {
                        using (SolidBrush ab = new SolidBrush(Theme.Accent)) g.FillPath(ab, cp);
                        Theme.DrawGlyph(g, "\uE73E", 12f, cb, Theme.AccentText);
                    }
                    else using (Pen cpn = new Pen(Theme.SubText, 1.4f)) g.DrawPath(cpn, cp);
                }
                // risk pill
                Color pbg, pfg;
                PillColors(it.Level, out pbg, out pfg);
                int pw = Math.Max(58, Theme.MeasureWidth(g, it.Risk, pf) + 22);
                int px = rtl ? row.X + pad : row.Right - pad - pw;       // pill sits at the far end of the row
                Rectangle pill = new Rectangle(px, row.Y + (RowHeight - 24) / 2, pw, 24);
                using (GraphicsPath pp = Theme.RoundRect(pill, 12f))
                using (SolidBrush pb = new SolidBrush(pbg)) g.FillPath(pb, pp);
                Theme.DrawText(g, it.Risk, pf, pill, pfg, rtl, false, true, false);
                // texts: between the checkbox and the pill
                int tx0 = rtl ? pill.Right + 16 : cb.Right + 14;
                int tx1 = rtl ? cb.X - 14 : pill.X - 16;
                Rectangle nr = new Rectangle(tx0, row.Y + 10, Math.Max(40, tx1 - tx0), 22);
                Rectangle rr = new Rectangle(tx0, row.Y + 33, Math.Max(40, tx1 - tx0), 20);
                Theme.DrawText(g, it.Name, nf, nr, Theme.Text, false, rtl, false, false);
                Theme.DrawText(g, it.Reason, rf, rr, Theme.SubText, rtl, rtl, false, false);
            }
            if (bar)
            {
                float th = Math.Max(24f, Height * (float)Height / ContentHeight);
                float ty = (Height - th) * (ContentHeight - Height == 0 ? 0 : (float)scroll / (ContentHeight - Height));
                float tx = rtl ? 2f : Width - 7f;
                using (GraphicsPath sp = Theme.RoundRect(new RectangleF(tx, ty + 2, 4f, th - 4), 2f))
                using (SolidBrush sb = new SolidBrush(Theme.Track)) g.FillPath(sb, sp);
            }
        }
    }

    // ------------------------------------------------------------------ coach marks (the guided tour, see lib\Tour.ps1)
    // A borderless per-pixel-alpha ("layered") window that the tour lays exactly over the main window's client area. It dims
    // the window, keeps a lit hole with an accent ring around one control, and draws the tour card (step counter, title,
    // text, Back / Next / Skip). It never takes the focus (WS_EX_NOACTIVATE). While it is shown, a message filter swallows
    // the keys and the mouse wheel meant for the main window and reports them through CoachKey / CoachWheel, so nothing
    // underneath can be typed into; the hole is painted with alpha 1 (invisible, but it still catches clicks), so nothing
    // underneath can be clicked either. The tour logic (steps, texts, where the card goes) lives in PowerShell.
    public class FCoach : Form, IMessageFilter
    {
        [DllImport("user32.dll")] static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref PT dst, ref SZ size, IntPtr hdcSrc, ref PT src, int key, ref BLEND blend, int flags);
        [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr hwnd);
        [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);
        [DllImport("user32.dll")] static extern bool IsChild(IntPtr parent, IntPtr child);
        [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
        [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
        [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
        [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr obj);
        [DllImport("gdi32.dll")] static extern IntPtr CreateDIBSection(IntPtr dc, ref BMI info, uint usage, out IntPtr bits, IntPtr section, uint offset);

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
        public int CardWidth = 384;                // at 96 dpi; multiplied by Scale
        public bool Animate = SystemInformation.UIEffectsEnabled;
        public byte DimAlpha;

        public event EventHandler NextClick, BackClick, SkipClick;
        public event KeyEventHandler CoachKey;
        public event MouseEventHandler CoachWheel;

        enum Hit { None, Skip, Back, Next }
        struct Lay { public Size Card; public Rectangle Badge, Counter, Dots, TitleR, BodyR, NoteIcon, NoteR, Skip, Back, Next; }

        float scale = 1f;
        bool filterOn, shown;
        Hit hot = Hit.None, pressed = Hit.None;
        Lay lay;
        Bitmap content;                        // the card, drawn opaque (ClearType text needs an opaque surface)
        IntPtr memDc = IntPtr.Zero, dib = IntPtr.Zero, oldObj = IntPtr.Zero, bits = IntPtr.Zero;
        Bitmap surface;                        // premultiplied ARGB view of the DIB that UpdateLayeredWindow shows
        Size surfaceSize = Size.Empty;
        readonly Timer anim = new Timer();
        readonly System.Diagnostics.Stopwatch clock = new System.Diagnostics.Stopwatch();
        Rectangle curHole = Rectangle.Empty, fromHole = Rectangle.Empty, toHole = Rectangle.Empty;
        Point curCard, fromCard, toCard;
        byte curAlpha = 255;
        bool fading;
        const int MoveMs = 190, FadeMs = 160;

        public FCoach()
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            DimAlpha = Theme.Dark ? (byte)150 : (byte)120;
            anim.Interval = 15;
            anim.Tick += delegate { try { Step(); } catch (Exception ex) { Fail(ex); } };
        }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x00080000 | 0x08000000 | 0x00000080;   // WS_EX_LAYERED | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW
                return cp;
            }
        }
        protected override bool ShowWithoutActivation { get { return true; } }
        protected override void OnPaintBackground(PaintEventArgs e) { }   // a layered window shows what UpdateLayeredWindow gave it
        protected override void OnPaint(PaintEventArgs e) { }
        protected override void WndProc(ref Message m)
        {
            if (m.Msg == 0x0021) { m.Result = (IntPtr)3; return; }   // WM_MOUSEACTIVATE -> MA_NOACTIVATE: a click never steals the focus
            base.WndProc(ref m);
        }
        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            try { using (Graphics g = CreateGraphics()) scale = Math.Max(1f, g.DpiX / 96f); } catch { scale = 1f; }
        }

        public float DpiScale { get { return scale; } }
        public string LastError = "";   // set when drawing failed on a timer or mouse event (nothing to throw to there); the tour then closes
        void Fail(Exception ex) { anim.Stop(); LastError = ex.Message; }
        public Rectangle CardBounds { get { return new Rectangle(toCard, lay.Card); } }   // where the card ends up (client coordinates)
        public Rectangle NextBounds { get { return Offset(lay.Next); } }
        public Rectangle BackBounds { get { return Offset(lay.Back); } }
        public Rectangle SkipBounds { get { return Offset(lay.Skip); } }
        Rectangle Offset(Rectangle r) { if (r.IsEmpty) return r; r.Offset(toCard); return r; }
        int P(float v) { return (int)Math.Round(v * scale); }

        // ---- showing and hiding
        public void Attach(Form owner)
        {
            Owner = owner;
            if (!filterOn) { Application.AddMessageFilter(this); filterOn = true; }
        }
        public void Detach()
        {
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

        // keys and wheel turns aimed at the owner window (or at this one) are reported here and never reach the owner
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
                if (msg == 0x0100 && CoachKey != null) CoachKey(this, new KeyEventArgs(((Keys)(int)(long)m.WParam & Keys.KeyCode) | ModifierKeys));
                if (wheel && CoachWheel != null) CoachWheel(this, new MouseEventArgs(MouseButtons.None, 0, 0, 0, (short)(((long)m.WParam >> 16) & 0xFFFF)));
            }
            catch { }
            return true;
        }

        // ---- card layout (all sizes follow Scale; right-to-left mirrors every rectangle)
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
                using (GraphicsPath bp = Theme.RoundRect(new RectangleF(lay.Badge.X, lay.Badge.Y, lay.Badge.Width, lay.Badge.Height), P(9)))
                using (SolidBrush bb = new SolidBrush(Theme.Mix(Theme.Card, Theme.Accent, Theme.Dark ? 0.22 : 0.12))) g.FillPath(bb, bp);
                Theme.DrawGlyph(g, Glyph, P(18), lay.Badge, Theme.Accent);
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
                    Theme.DrawGlyph(g, "\uE946", P(14), lay.NoteIcon, Theme.Accent);
                    Theme.DrawText(g, Note, NoteFont, lay.NoteR, Theme.SubText, Rtl, Rtl, false, true);
                }
                // buttons
                if (!lay.Skip.IsEmpty)
                {
                    if (hot == Hit.Skip) using (GraphicsPath sp = Theme.RoundRect(R(lay.Skip), P(4))) using (SolidBrush sb = new SolidBrush(pressed == Hit.Skip ? Theme.BtnPressed : Theme.RowHover)) g.FillPath(sb, sp);
                    Theme.DrawText(g, SkipText, ButtonFont, lay.Skip, hot == Hit.Skip ? Theme.Text : Theme.SubText, Rtl, false, true, false);
                }
                if (!lay.Back.IsEmpty)
                {
                    Color f = pressed == Hit.Back ? Theme.BtnPressed : (hot == Hit.Back ? Theme.BtnHover : Theme.BtnFill);
                    using (GraphicsPath p = Theme.RoundRect(R(lay.Back), P(4)))
                    {
                        using (SolidBrush fb = new SolidBrush(f)) g.FillPath(fb, p);
                        using (Pen pen = new Pen(Theme.BtnBorder, 1f)) g.DrawPath(pen, p);
                    }
                    Theme.DrawText(g, BackText, ButtonFont, lay.Back, Theme.Text, Rtl, false, true, false);
                }
                Color nf = pressed == Hit.Next ? Theme.AccentPressed : (hot == Hit.Next ? Theme.AccentHover : Theme.Accent);
                using (GraphicsPath np = Theme.RoundRect(R(lay.Next), P(4)))
                using (SolidBrush nb = new SolidBrush(nf)) g.FillPath(nb, np);
                Theme.DrawText(g, NextText, ButtonFont, lay.Next, Theme.AccentText, Rtl, false, true, false);
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
            if (IsHandleCreated && Visible)
            {
                Point m = PointToClient(MousePosition);
                if (ClientRectangle.Contains(m)) hot = HitAt(m, toCard);
            }
            if (content != null) content.Dispose();
            content = DrawContent();
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
                    float rad = P(8);
                    using (GraphicsPath hp = Theme.RoundRect(new RectangleF(curHole.X, curHole.Y, curHole.Width, curHole.Height), rad))
                    using (SolidBrush hb = new SolidBrush(Color.FromArgb(1, 0, 0, 0))) g.FillPath(hb, hp);   // looks clear, still catches clicks
                    g.CompositingMode = CompositingMode.SourceOver;
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    RectangleF ring = new RectangleF(curHole.X - 0.5f, curHole.Y - 0.5f, curHole.Width + 1f, curHole.Height + 1f);
                    using (GraphicsPath rp = Theme.RoundRect(ring, rad + 0.5f))
                    {
                        using (Pen glow = new Pen(Color.FromArgb(70, Theme.Accent), P(6))) g.DrawPath(glow, rp);
                        using (Pen pen = new Pen(Theme.Accent, Math.Max(2f, P(2)))) g.DrawPath(pen, rp);
                    }
                }
                g.CompositingMode = CompositingMode.SourceOver;
                g.SmoothingMode = SmoothingMode.AntiAlias;
                if (content != null)
                {
                    Rectangle c = new Rectangle(curCard, content.Size);
                    float rad = P(8);
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
    }
}
