using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace CodexSkillUpdater
{
    internal enum CaptionGlyph { Minimize, Close }

    // Caption symbols use geometry, so their position never depends on a font's baseline.
    internal sealed class CaptionButton : Button
    {
        private bool hovered;
        private bool pressed;
        private CaptionGlyph glyph;

        internal CaptionButton()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            FlatStyle = FlatStyle.Flat;
            FlatAppearance.BorderSize = 0;
            UseVisualStyleBackColor = false;
            BackColor = Color.FromArgb(20, 20, 20);
            ForeColor = Color.FromArgb(190, 190, 190);
            Size = new Size(36, 28);
            Margin = Padding.Empty;
            Padding = Padding.Empty;
            Text = String.Empty;
            TabStop = true;
            AccessibleRole = AccessibleRole.PushButton;
        }

        internal CaptionGlyph Glyph
        {
            get { return glyph; }
            set { glyph = value; Invalidate(); }
        }

        protected override void OnMouseEnter(EventArgs e) { hovered = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hovered = false; pressed = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e) { if (e.Button == MouseButtons.Left) { pressed = true; Invalidate(); } base.OnMouseDown(e); }
        protected override void OnMouseUp(MouseEventArgs e) { pressed = false; Invalidate(); base.OnMouseUp(e); }
        protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
        protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }
        protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }

        protected override void OnPaint(PaintEventArgs e)
        {
            Color fill = BackColor;
            if (Enabled && hovered)
                fill = glyph == CaptionGlyph.Close ? Color.FromArgb(75, 43, 43) : Color.FromArgb(38, 38, 38);
            if (Enabled && pressed)
                fill = glyph == CaptionGlyph.Close ? Color.FromArgb(94, 49, 49) : Color.FromArgb(48, 48, 48);
            e.Graphics.Clear(fill);
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            e.Graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
            float scale = Math.Max(0.75F, e.Graphics.DpiX / 96F);
            float half = Math.Min(4.5F * scale, Math.Min(ClientSize.Width, ClientSize.Height) * 0.23F);
            float centerX = (ClientSize.Width - 1) * 0.5F;
            float centerY = (ClientSize.Height - 1) * 0.5F;
            using (Pen pen = new Pen(Enabled ? ForeColor : Color.FromArgb(100, 100, 100), Math.Max(1F, 1.15F * scale)))
            {
                pen.StartCap = LineCap.Round;
                pen.EndCap = LineCap.Round;
                if (glyph == CaptionGlyph.Close)
                {
                    e.Graphics.DrawLine(pen, centerX - half, centerY - half, centerX + half, centerY + half);
                    e.Graphics.DrawLine(pen, centerX + half, centerY - half, centerX - half, centerY + half);
                }
                else e.Graphics.DrawLine(pen, centerX - half, centerY, centerX + half, centerY);
            }
            if (Focused && ShowFocusCues)
            {
                Rectangle focus = ClientRectangle;
                focus.Inflate(-4, -4);
                ControlPaint.DrawFocusRectangle(e.Graphics, focus, ForeColor, fill);
            }
        }
    }
}
