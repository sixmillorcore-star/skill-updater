using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace CodexSkillUpdater
{
    internal sealed class AppearanceDialog : Form
    {
        private readonly string appRoot;
        private readonly UiLocale locale;
        private readonly ComboBox language = new DarkChoiceBox();
        private readonly ComboBox font = new DarkChoiceBox();
        private readonly ComboBox size = new DarkChoiceBox();
        private readonly Label preview = new Label();
        private readonly Panel previewViewport = new Panel();
        private readonly Label notice = new Label();
        private readonly ToolTip hints = new ToolTip();
        private readonly List<Font> ownedFonts = new List<Font>();
        private Font previewFont;
        private bool initializing = true;
        internal UiPreferences Selection { get; private set; }

        internal AppearanceDialog(UiPreferences current, UiLocale locale, string appRoot)
        {
            this.appRoot = appRoot;
            this.locale = locale;
            Selection = new UiPreferences { Language = current.Language, FontFamily = current.FontFamily, FontSize = current.FontSize };
            Text = locale.T("settings.title");
            Name = "AppearanceDialog";
            ClientSize = new Size(500, 352);
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.CenterParent;
            AutoScaleMode = AutoScaleMode.Dpi;
            BackColor = Color.FromArgb(20, 20, 20);
            ForeColor = Color.FromArgb(222, 222, 222);
            Font = OwnFont(9.5F);
            DoubleBuffered = true;
            Padding = new Padding(1);
            RightToLeft = RightToLeft.No;
            ShowInTaskbar = false;

            Label heading = new Label { Name = "AppearanceHeading", Text = Text, UseMnemonic = false, AutoEllipsis = false, Location = new Point(20, 11), Size = new Size(422, 28), Font = OwnFont(13F) };
            SetReadingOrder(heading, locale);
            heading.MouseDown += DragWindow;
            CaptionButton captionClose = new CaptionButton { Glyph = CaptionGlyph.Close, Location = new Point(463, 1), Size = new Size(36, 36), Anchor = AnchorStyles.Top | AnchorStyles.Right, AccessibleName = locale.T("action.close") };
            captionClose.Click += delegate { DialogResult = DialogResult.Cancel; Close(); };
            Controls.Add(heading); Controls.Add(captionClose);
            MouseDown += DragWindow;

            Label languageLabel = MakeLabel("settings.language", new Rectangle(20, 50, 460, 20));
            ConfigureCombo(language, "LanguageChoice", new Rectangle(20, 72, 460, 29));
            foreach (UiLanguageChoice choice in UiLocale.LanguageChoices(appRoot)) language.Items.Add(choice);
            Label fontLabel = MakeLabel("settings.font", new Rectangle(20, 114, 326, 20));
            ConfigureCombo(font, "FontChoice", new Rectangle(20, 136, 326, 29));
            font.Items.Add("auto");
            foreach (string family in UiFontCatalog.InstalledNames()) font.Items.Add(family);
            Label sizeLabel = MakeLabel("settings.fontSize", new Rectangle(360, 114, 120, 20));
            ConfigureCombo(size, "FontSizeChoice", new Rectangle(360, 136, 120, 29));
            foreach (float point in new[] { 9F, 9.5F, 10F, 10.5F, 11F }) size.Items.Add(point);
            Controls.Add(languageLabel); Controls.Add(fontLabel); Controls.Add(sizeLabel);
            Controls.Add(language); Controls.Add(font); Controls.Add(size);

            preview.Name = "FontPreview";
            previewViewport.Name = "FontPreviewViewport";
            previewViewport.Location = new Point(20, 181); previewViewport.Size = new Size(460, 61);
            previewViewport.BackColor = Color.FromArgb(28, 28, 28); previewViewport.AutoScroll = true;
            preview.BackColor = previewViewport.BackColor; preview.TextAlign = ContentAlignment.TopLeft;
            preview.AutoEllipsis = false; preview.UseCompatibleTextRendering = false;
            previewViewport.Controls.Add(preview); Controls.Add(previewViewport);
            notice.Name = "LanguageNotice";
            notice.Location = new Point(20, 251); notice.Size = new Size(460, 38);
            notice.ForeColor = Color.FromArgb(146, 146, 146);
            notice.Font = OwnFont(9F);
            SetReadingOrder(notice, locale);
            Controls.Add(notice);

            Button apply = MakeButton(locale.T("settings.save"), new Rectangle(365, 305, 115, 31), true);
            apply.Name = "ApplyAppearance";
            apply.Click += delegate
            {
                Selection = ReadSelection();
                DialogResult = DialogResult.OK;
                Close();
            };
            Button cancel = MakeButton(locale.T("settings.cancel"), new Rectangle(240, 305, 115, 31), false);
            cancel.Name = "CancelAppearance"; cancel.DialogResult = DialogResult.Cancel;
            Controls.Add(apply); Controls.Add(cancel);
            AcceptButton = apply; CancelButton = cancel;
            language.TabIndex = 0; font.TabIndex = 1; size.TabIndex = 2; apply.TabIndex = 3; cancel.TabIndex = 4; captionClose.TabIndex = 5;
            language.SelectedIndexChanged += delegate { UpdatePreview(); };
            font.SelectedIndexChanged += delegate { UpdatePreview(); };
            size.SelectedIndexChanged += delegate { UpdatePreview(); };
            SelectPreview(current.Language, current.FontFamily, current.FontSize);
            initializing = false;
            UpdatePreview();
        }

        internal void SelectPreview(string languageCode, string fontFamily, float point)
        {
            int languageIndex = 0;
            string neutral = languageCode ?? "auto";
            try
            {
                UiLocale requested = new UiLocale(neutral, appRoot);
                if (!neutral.Equals("auto", StringComparison.OrdinalIgnoreCase)) neutral = requested.LanguageCode;
            }
            catch { neutral = "auto"; }
            for (int index = 0; index < language.Items.Count; index++)
            {
                UiLanguageChoice choice = language.Items[index] as UiLanguageChoice;
                if (choice != null && (choice.Code.Equals(languageCode ?? "auto", StringComparison.OrdinalIgnoreCase) || choice.Code.Equals(neutral, StringComparison.OrdinalIgnoreCase))) { languageIndex = index; break; }
            }
            language.SelectedIndex = languageIndex;
            int fontIndex = 0;
            for (int index = 0; index < font.Items.Count; index++) if (String.Equals(Convert.ToString(font.Items[index]), fontFamily, StringComparison.OrdinalIgnoreCase)) { fontIndex = index; break; }
            font.SelectedIndex = fontIndex;
            float normalized = Math.Max(9F, Math.Min(11F, Single.IsNaN(point) || Single.IsInfinity(point) ? 10F : point));
            normalized = (float)(Math.Round(normalized * 2F) / 2F);
            size.SelectedItem = normalized;
            if (size.SelectedIndex < 0) size.SelectedIndex = 2;
            if (!initializing) UpdatePreview();
        }

        private UiPreferences ReadSelection()
        {
            UiLanguageChoice chosen = language.SelectedItem as UiLanguageChoice;
            return new UiPreferences { Language = chosen == null ? "auto" : chosen.Code, FontFamily = font.SelectedItem as string ?? "auto", FontSize = size.SelectedItem is float ? (float)size.SelectedItem : 10F };
        }

        private void UpdatePreview()
        {
            if (initializing) return;
            UiPreferences selected = ReadSelection();
            UiLocale selectedLocale = new UiLocale(selected.Language, appRoot);
            Font nextFont = UiFontCatalog.Create(selected.FontFamily, selected.FontSize, selectedLocale.LanguageCode, true);
            Font previous = previewFont;
            previewFont = nextFont;
            // WinForms can retain an equal Font object instead of replacing it.
            // Keep that object alive when previewing the same choice repeatedly.
            if (previous != null && previous.Equals(nextFont)) { nextFont.Dispose(); previewFont = previous; }
            else { preview.Font = nextFont; if (previous != null) previous.Dispose(); }
            preview.Text = selectedLocale.T("settings.preview");
            SetReadingOrder(preview, selectedLocale);
            previewViewport.AutoScrollPosition = Point.Empty;
            int previewWidth = previewViewport.ClientSize.Width - 24 - SystemInformation.VerticalScrollBarWidth;
            Size measured = TextRenderer.MeasureText(preview.Text, preview.Font, new Size(previewWidth, Int32.MaxValue), TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix);
            preview.Bounds = new Rectangle(12, 8, previewWidth, Math.Max(measured.Height + 2, previewViewport.ClientSize.Height - 16));
            previewViewport.AutoScrollMinSize = new Size(0, preview.Bottom + 8);
            notice.Text = locale.T(selectedLocale.HasTranslation ? "settings.restart" : "settings.fallback");
            UpdateChoiceHints();
        }

        private Font OwnFont(float point)
        {
            Font result = UiFontCatalog.Create("auto", point, locale.LanguageCode, true);
            ownedFonts.Add(result); return result;
        }

        private Label MakeLabel(string key, Rectangle bounds)
        {
            Label result = new Label { Name = key, Text = locale.T(key), UseMnemonic = false, Bounds = bounds, ForeColor = Color.FromArgb(165, 165, 165), AutoEllipsis = false };
            SetReadingOrder(result, locale); return result;
        }

        private static void SetReadingOrder(Control control, UiLocale value) { control.RightToLeft = value.IsRightToLeft ? RightToLeft.Yes : RightToLeft.No; }

        private void ConfigureCombo(ComboBox control, string name, Rectangle bounds)
        {
            control.Name = name; control.Bounds = bounds;
            control.DropDownStyle = ComboBoxStyle.DropDownList;
            control.DrawMode = DrawMode.OwnerDrawFixed;
            control.FlatStyle = FlatStyle.Flat;
            control.ItemHeight = 23;
            control.IntegralHeight = false;
            control.DropDownHeight = 264;
            control.DropDownWidth = Math.Max(bounds.Width, name == "LanguageChoice" ? 460 : 326);
            control.BackColor = Color.FromArgb(31, 31, 31);
            control.ForeColor = Color.FromArgb(214, 214, 214);
            SetReadingOrder(control, locale);
            control.AccessibleName = name == "LanguageChoice" ? locale.T("settings.language") : name == "FontChoice" ? locale.T("settings.font") : locale.T("settings.fontSize");
            DarkChoiceBox dark = control as DarkChoiceBox;
            if (dark != null) dark.FormatText = delegate(object item)
            {
                if (item == null) return String.Empty;
                string value = item is float ? ((float)item).ToString("0.#", locale.Culture) + " pt" : item.ToString();
                UiLanguageChoice choice = item as UiLanguageChoice;
                if (choice != null && choice.Code == "auto") return locale.T("settings.auto") + " · Windows";
                return value == "auto" ? locale.T("settings.auto") : value;
            };
            control.DrawItem += delegate(object sender, DrawItemEventArgs e)
            {
                if (e.Index < 0) return;
                bool selected = (e.State & DrawItemState.Selected) != 0;
                using (Brush brush = new SolidBrush(selected ? Color.FromArgb(53, 53, 53) : Color.FromArgb(31, 31, 31))) e.Graphics.FillRectangle(brush, e.Bounds);
                object item = control.Items[e.Index];
                string text = item is float ? ((float)item).ToString("0.#", locale.Culture) + " pt" : item.ToString();
                if (text == "auto") text = locale.T("settings.auto");
                UiLanguageChoice choice = item as UiLanguageChoice;
                if (choice != null && choice.Code == "auto") text = locale.T("settings.auto") + " · Windows";
                Rectangle textBounds = new Rectangle(e.Bounds.X + 7, e.Bounds.Y, e.Bounds.Width - 14, e.Bounds.Height);
                TextFormatFlags flags = TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix;
                if (locale.IsRightToLeft) flags |= TextFormatFlags.RightToLeft | TextFormatFlags.Right;
                TextRenderer.DrawText(e.Graphics, text, control.Font, textBounds, control.ForeColor, flags);
            };
            control.DropDown += delegate
            {
                int width = control.Width;
                foreach (object item in control.Items)
                {
                    string text = dark == null || dark.FormatText == null ? control.GetItemText(item) : dark.FormatText(item);
                    width = Math.Max(width, TextRenderer.MeasureText(text, control.Font).Width + 30);
                }
                int minimumWidth = control == size ? control.Width : Math.Max(460, control.Width);
                control.DropDownWidth = Math.Min(Math.Max(minimumWidth, width), Math.Max(minimumWidth, Screen.FromControl(this).WorkingArea.Width - 40));
            };
        }

        private void UpdateChoiceHints()
        {
            foreach (ComboBox choice in new[] { language, font, size })
            {
                DarkChoiceBox dark = choice as DarkChoiceBox;
                string fullText = dark == null || dark.FormatText == null ? choice.GetItemText(choice.SelectedItem) : dark.FormatText(choice.SelectedItem);
                hints.SetToolTip(choice, fullText);
            }
        }

        private Button MakeButton(string text, Rectangle bounds, bool primary)
        {
            Button result = new Button { Text = text, Bounds = bounds, FlatStyle = FlatStyle.Flat, UseVisualStyleBackColor = false };
            result.BackColor = primary ? Color.FromArgb(222, 222, 216) : BackColor;
            result.ForeColor = primary ? Color.FromArgb(28, 28, 28) : Color.FromArgb(184, 184, 184);
            result.FlatAppearance.BorderColor = Color.FromArgb(54, 54, 54);
            result.FlatAppearance.BorderSize = primary ? 0 : 1;
            result.FlatAppearance.MouseOverBackColor = primary ? Color.FromArgb(237, 237, 232) : Color.FromArgb(36, 36, 36);
            SetReadingOrder(result, locale); return result;
        }

        [DllImport("user32.dll")] private static extern bool ReleaseCapture();
        [DllImport("user32.dll")] private static extern IntPtr SendMessage(IntPtr window, int message, IntPtr wParam, IntPtr lParam);
        private void DragWindow(object sender, MouseEventArgs e) { if (e.Button == MouseButtons.Left) { ReleaseCapture(); SendMessage(Handle, 0x00A1, new IntPtr(2), IntPtr.Zero); } }
        protected override void OnPaint(PaintEventArgs e) { base.OnPaint(e); using (Pen border = new Pen(Color.FromArgb(57, 57, 57))) e.Graphics.DrawRectangle(border, 0, 0, Width - 1, Height - 1); }
        protected override void Dispose(bool disposing)
        {
            base.Dispose(disposing);
            if (disposing) { hints.Dispose(); if (previewFont != null) previewFont.Dispose(); foreach (Font value in ownedFonts) value.Dispose(); ownedFonts.Clear(); }
        }

        // Keep native keyboard, accessibility and dropdown behavior while painting
        // the collapsed field without the light border from older Windows themes.
        private sealed class DarkChoiceBox : ComboBox
        {
            internal Func<object, string> FormatText;
            internal DarkChoiceBox() { SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true); }
            protected override void OnPaint(PaintEventArgs e)
            {
                    Graphics graphics = e.Graphics;
                    graphics.Clear(BackColor);
                    float scale = graphics.DpiX / 96F;
                    int arrowWidth = Math.Max(18, (int)(18 * scale));
                    bool rightToLeft = RightToLeft == RightToLeft.Yes;
                    Rectangle arrow = new Rectangle(rightToLeft ? 1 : Width - arrowWidth - 1, 1, arrowWidth, Height - 2);
                    using (Pen border = new Pen(Color.FromArgb(60, 60, 60))) graphics.DrawRectangle(border, 0, 0, Width - 1, Height - 1);
                    string text = FormatText == null ? GetItemText(SelectedItem) : FormatText(SelectedItem);
                    TextFormatFlags flags = TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix;
                    if (rightToLeft) flags |= TextFormatFlags.RightToLeft | TextFormatFlags.Right;
                    TextRenderer.DrawText(graphics, text, Font, new Rectangle(rightToLeft ? arrowWidth + 7 : 7, 1, Width - arrowWidth - 14, Height - 2), ForeColor, flags);
                    float x = arrow.Left + arrow.Width / 2F, y = (Height - 1) / 2F;
                    using (Pen pen = new Pen(Color.FromArgb(162, 162, 162), Math.Max(1F, scale)))
                    { graphics.DrawLine(pen, x - 3 * scale, y - scale, x, y + 2 * scale); graphics.DrawLine(pen, x, y + 2 * scale, x + 3 * scale, y - scale); }
                    if (Focused && ShowFocusCues) ControlPaint.DrawFocusRectangle(graphics, new Rectangle(rightToLeft ? arrowWidth + 3 : 3, 3, Width - arrowWidth - 6, Height - 6), ForeColor, BackColor);
            }
        }
    }
}
