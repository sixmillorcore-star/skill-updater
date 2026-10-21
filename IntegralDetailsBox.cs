using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace CodexSkillUpdater
{
    // Keep the native EDIT selection, copying, wrapping and scrolling, while its
    // formatting area admits whole lines only. The unused pixels stay as padding.
    internal sealed class IntegralDetailsBox : TextBox
    {
        private bool updatingRectangle;
        private bool hasInsets;
        private int leftInset, topInset, rightInset;
        private int lineHeight;
        private Rectangle contentRectangle;

        internal int LineHeight { get { return lineHeight > 0 ? lineHeight : Math.Max(1, Font.Height); } }
        internal int VisibleLineCount { get { return Math.Max(0, contentRectangle.Height / LineHeight); } }
        internal Rectangle ContentRectangle { get { return contentRectangle; } }
        internal int DesiredClientHeight(int lines) { return topInset + Math.Max(1, lines) * LineHeight; }

        internal IntegralDetailsBox()
        {
            Multiline = true;
            ReadOnly = true;
            WordWrap = true;
            BorderStyle = BorderStyle.None;
            ScrollBars = ScrollBars.Vertical;
            AutoSize = false;
            HideSelection = false;
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            hasInsets = false;
            lineHeight = 0;
            RefreshFormattingRectangle();
        }

        protected override void OnHandleDestroyed(EventArgs e)
        {
            hasInsets = false;
            lineHeight = 0;
            base.OnHandleDestroyed(e);
        }

        protected override void OnFontChanged(EventArgs e)
        {
            base.OnFontChanged(e);
            lineHeight = 0;
            RefreshFormattingRectangle();
        }

        protected override void OnClientSizeChanged(EventArgs e)
        {
            base.OnClientSizeChanged(e);
            RefreshFormattingRectangle();
        }

        protected override void OnTextChanged(EventArgs e)
        {
            base.OnTextChanged(e);
            RefreshFormattingRectangle();
        }

        protected override void WndProc(ref Message message)
        {
            int kind = message.Msg;
            base.WndProc(ref message);
            // Native EDIT can reset its format area while changing font or size.
            if (kind == 0x0005 || kind == 0x0030 || kind == 0x02E0)
            {
                if (kind == 0x0030 || kind == 0x02E0) lineHeight = 0;
                RefreshFormattingRectangle();
            }
        }

        internal void RefreshFormattingRectangle()
        {
            if (updatingRectangle || !IsHandleCreated || IsDisposed || !Multiline) return;
            updatingRectangle = true;
            try
            {
                if (!hasInsets)
                {
                    NativeRectangle original = new NativeRectangle();
                    SendRectangle(Handle, 0x00B2, IntPtr.Zero, ref original);
                    leftInset = Math.Max(0, original.Left);
                    topInset = Math.Max(0, original.Top);
                    rightInset = Math.Max(0, ClientSize.Width - original.Right);
                    hasInsets = true;
                }
                if (lineHeight <= 0) lineHeight = ReadLineHeight();
                int available = Math.Max(0, ClientSize.Height - topInset);
                int lines = available / Math.Max(1, lineHeight);
                Rectangle target = Rectangle.FromLTRB(leftInset, topInset,
                    Math.Max(leftInset + 1, ClientSize.Width - rightInset), topInset + lines * lineHeight);
                NativeRectangle current = new NativeRectangle();
                SendRectangle(Handle, 0x00B2, IntPtr.Zero, ref current);
                contentRectangle = target;
                if (current.Left == target.Left && current.Top == target.Top && current.Right == target.Right && current.Bottom == target.Bottom) return;
                NativeRectangle format = new NativeRectangle { Left = target.Left, Top = target.Top, Right = target.Right, Bottom = target.Bottom };
                SendRectangle(Handle, 0x00B4, IntPtr.Zero, ref format);
                Invalidate();
            }
            finally { updatingRectangle = false; }
        }

        private int ReadLineHeight()
        {
            IntPtr dc = GetDC(Handle);
            if (dc == IntPtr.Zero) return Math.Max(1, Font.Height);
            IntPtr previous = IntPtr.Zero;
            try
            {
                IntPtr nativeFont = SendMessage(Handle, 0x0031, IntPtr.Zero, IntPtr.Zero);
                if (nativeFont != IntPtr.Zero) previous = SelectObject(dc, nativeFont);
                NativeTextMetric metrics;
                return GetTextMetrics(dc, out metrics) && metrics.Height > 0 ? metrics.Height : Math.Max(1, Font.Height);
            }
            finally
            {
                if (previous != IntPtr.Zero && previous != new IntPtr(-1)) SelectObject(dc, previous);
                ReleaseDC(Handle, dc);
            }
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct NativeRectangle { internal int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct NativeTextMetric
        {
            internal int Height, Ascent, Descent, InternalLeading, ExternalLeading, AverageCharacterWidth, MaximumCharacterWidth, Weight, Overhang, DigitizedAspectX, DigitizedAspectY;
            internal char FirstCharacter, LastCharacter, DefaultCharacter, BreakCharacter;
            internal byte Italic, Underlined, StruckOut, PitchAndFamily, CharacterSet;
        }
        [DllImport("user32.dll", EntryPoint = "SendMessageW")]
        private static extern IntPtr SendRectangle(IntPtr window, int message, IntPtr wParam, ref NativeRectangle rectangle);
        [DllImport("user32.dll", EntryPoint = "SendMessageW")]
        private static extern IntPtr SendMessage(IntPtr window, int message, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")]
        private static extern IntPtr GetDC(IntPtr window);
        [DllImport("user32.dll")]
        private static extern int ReleaseDC(IntPtr window, IntPtr dc);
        [DllImport("gdi32.dll")]
        private static extern IntPtr SelectObject(IntPtr dc, IntPtr value);
        [DllImport("gdi32.dll", EntryPoint = "GetTextMetricsW", CharSet = CharSet.Unicode)]
        private static extern bool GetTextMetrics(IntPtr dc, out NativeTextMetric metric);
    }
}
