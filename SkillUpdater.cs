using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace CodexSkillUpdater
{
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            int testAt = Array.IndexOf(args, "--test-schedule");
            if (testAt >= 0)
            {
                DateTimeOffset testNow, testBoot;
                if (testAt + 2 >= args.Length || !DateTimeOffset.TryParse(args[testAt + 1], CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out testNow) || !DateTimeOffset.TryParse(args[testAt + 2], CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out testBoot))
                {
                    Console.WriteLine("{\"error\":\"Expected --test-schedule nowISO bootISO\"}");
                    return 2;
                }
                Console.WriteLine("{\"eligible\":" + (IsDailyEligible(testNow, testBoot) ? "true" : "false") + "}");
                return 0;
            }
            bool daily = Has(args, "--daily");
            bool smoke = Has(args, "--smoke-test");
            if (daily && !smoke)
            {
                DateTimeOffset now = DateTimeOffset.Now;
                DateTimeOffset boot = now.Subtract(TimeSpan.FromMilliseconds(GetTickCount64()));
                if (!IsDailyEligible(now, boot))
                {
                    try
                    {
                        string data = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "data");
                        Directory.CreateDirectory(data);
                        File.AppendAllText(Path.Combine(data, "schedule-guard.log"), now.ToString("o") + " skipped daily run: outside 08:00-08:09 or boot at/after 08:00; boot=" + boot.ToString("o") + Environment.NewLine, Encoding.UTF8);
                    }
                    catch { }
                    return 0;
                }
            }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            if (smoke) Application.SetUnhandledExceptionMode(UnhandledExceptionMode.ThrowException);
            string screenshot = Option(args, "--screenshot");
            string report = Option(args, "--report");
            string sid = WindowsIdentity.GetCurrent().User.Value;
            bool first;
            using (Mutex instance = new Mutex(true, "Local\\CodexSkillUpdater-" + sid + "-" + (daily ? "daily" : smoke ? "smoke" : "manual"), out first))
            {
                if (!first) return 0;
                try
                {
                    using (UpdaterForm form = new UpdaterForm(daily, smoke, screenshot, report))
                    {
                        int sizeAt = Array.IndexOf(args, "--smoke-size");
                        int width, height;
                        if (smoke && sizeAt >= 0 && sizeAt + 2 < args.Length && Int32.TryParse(args[sizeAt + 1], out width) && Int32.TryParse(args[sizeAt + 2], out height))
                            form.Size = new Size(Math.Max(form.MinimumSize.Width, width), Math.Max(form.MinimumSize.Height, height));
                        if (smoke) {
                            form.ConfigureSmoke(Option(args, "--smoke-provider"), Option(args, "--smoke-search"), Option(args, "--smoke-state"));
                            form.ConfigureAppearance(Option(args, "--ui-language"), Option(args, "--ui-font"), Option(args, "--ui-font-size"), Option(args, "--settings-screenshot"));
                        }
                        Application.Run(form);
                        return form.ResultCode;
                    }
                }
                catch (Exception ex)
                {
                    try
                    {
                        string data = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "data");
                        Directory.CreateDirectory(data);
                        File.AppendAllText(Path.Combine(data, "ui-errors.log"), DateTimeOffset.Now.ToString("o") + " " + ex.ToString() + Environment.NewLine, Encoding.UTF8);
                    }
                    catch { }
                    if (!smoke) { UiLocale errorLocale = new UiLocale(UiPreferences.Load(AppDomain.CurrentDomain.BaseDirectory).Language, AppDomain.CurrentDomain.BaseDirectory); MessageBox.Show(errorLocale.T("err.openApp", ex.Message), "Skill Updater", MessageBoxButtons.OK, MessageBoxIcon.Error); }
                    return 1;
                }
                finally { instance.ReleaseMutex(); }
            }
        }

        private static bool Has(string[] args, string key) { return Array.IndexOf(args, key) >= 0; }
        [DllImport("kernel32.dll")]
        private static extern ulong GetTickCount64();
        internal static bool IsDailyEligible(DateTimeOffset now, DateTimeOffset boot)
        {
            DateTime localNow = now.LocalDateTime;
            DateTime start = localNow.Date.AddHours(8);
            return localNow >= start && localNow < start.AddMinutes(10) && boot.LocalDateTime < start && boot <= now;
        }
        private static string Option(string[] args, string key)
        {
            int at = Array.IndexOf(args, key);
            return at >= 0 && at + 1 < args.Length ? args[at + 1] : null;
        }
    }

    internal sealed class BackendResult
    {
        internal string ReportPath;
        internal string Error;
    }

    internal sealed class DarkListView : ListView
    {
        internal DarkListView() { DoubleBuffered = true; }
    }

    internal sealed class QuietProgress : Control
    {
        private readonly System.Windows.Forms.Timer animation = new System.Windows.Forms.Timer();
        private int offset;
        internal QuietProgress()
        {
            DoubleBuffered = true;
            BackColor = Color.FromArgb(38, 38, 38);
            animation.Interval = 80;
            animation.Tick += delegate { offset = (offset + 9) % Math.Max(1, Width + 140); Invalidate(); };
        }
        internal int MarqueeAnimationSpeed
        {
            set { animation.Enabled = value > 0; if (value <= 0) offset = 0; Invalidate(); }
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.Clear(BackColor);
            if (animation.Enabled)
                using (Brush brush = new SolidBrush(Color.FromArgb(156, 156, 156))) e.Graphics.FillRectangle(brush, offset - 140, 0, 140, Height);
        }
        protected override void Dispose(bool disposing) { if (disposing) animation.Dispose(); base.Dispose(disposing); }
    }

    internal sealed partial class UpdaterForm : Form
    {
        private readonly bool daily;
        private readonly bool smoke;
        private readonly string screenshot;
        private readonly string fixtureReport;
        private readonly string appRoot = AppDomain.CurrentDomain.BaseDirectory;
        private readonly Color background = Color.FromArgb(20, 20, 20);
        private readonly Color surface = Color.FromArgb(25, 25, 25);
        private readonly Color textColor = Color.FromArgb(222, 222, 222);
        private readonly Color success = Color.FromArgb(169, 184, 171);
        private readonly Color warning = Color.FromArgb(189, 177, 155);
        private readonly Color failure = Color.FromArgb(201, 165, 155);
        private readonly Color muted = Color.FromArgb(147, 147, 147);
        private readonly Label summary = new Label();
        private readonly Label checkedAt = new Label();
        private readonly Label count = new Label();
        private readonly ListView skills = new DarkListView();
        private readonly TextBox details = new IntegralDetailsBox();
        private readonly Button update = new PrimaryActionButton();
        private readonly Button check = new Button();
        private readonly Button logs = new Button();
        private readonly Button close = new Button();
        private readonly QuietProgress progress = new QuietProgress();
        private readonly ToolTip hints = new ToolTip();
        private Font columnFont = new Font("Segoe UI", 9F);
        private UiPreferences preferences;
        private UiLocale locale;
        private readonly Dictionary<Control, string> bindings = new Dictionary<Control, string>();
        private readonly Dictionary<string, Control> boundControls = new Dictionary<string, Control>();
        private readonly Dictionary<Control, float> fontSizes = new Dictionary<Control, float>();
        private List<Font> appearanceFonts = new List<Font>();
        private readonly Button appearance = new Button();
        private CaptionButton minimize, chromeClose;
        private string lastReportPath, busyMode, settingsScreenshot;
        private readonly System.Windows.Forms.Timer refreshTimer = new System.Windows.Forms.Timer();
        private readonly TextBox searchInput = new TextBox();
        private readonly Label emptyState = new Label();
        private readonly Label schedule = new Label();
        private readonly List<Dictionary<string, object>> reportRows = new List<Dictionary<string, object>>();
        private readonly Dictionary<string, Button> providerButtons = new Dictionary<string, Button>();
        private readonly Dictionary<string, bool> detectedProviders = new Dictionary<string, bool>();
        private string selectedProvider = "ทั้งหมด";
        private string reportError = String.Empty;
        private DateTime lastCheckUtc = DateTime.MinValue;
        private bool hasReport;
        private string smokeProvider, smokeSearch, smokeStatePath;
        private Icon applicationIcon;
        private Image applicationImage;
        private bool busy;
        internal int ResultCode;

        internal UpdaterForm(bool daily, bool smoke, string screenshot, string fixtureReport)
        {
            this.daily = daily;
            this.smoke = smoke;
            this.screenshot = screenshot;
            this.fixtureReport = fixtureReport;
            preferences = UiPreferences.Load(appRoot);
            preferences.FontSize = Math.Max(9F, Math.Min(11F, preferences.FontSize));
            locale = new UiLocale(preferences.Language, appRoot);
            Text = "Skill Updater";
            Font = new Font("Segoe UI", 10F);
            BackColor = background;
            ForeColor = textColor;
            ClientSize = new Size(720, 500);
            MinimumSize = new Size(640, 460);
            FormBorderStyle = FormBorderStyle.None;
            Padding = new Padding(1);
            StartPosition = FormStartPosition.CenterScreen;
            AutoScaleMode = AutoScaleMode.Dpi;
            DoubleBuffered = true;
            LoadApplicationIcon();
            if (daily || smoke) { Opacity = 0; ShowInTaskbar = false; }
            BuildControls();
            foreach (Label label in new[] { summary, checkedAt, count, schedule, emptyState }) label.TextChanged += delegate { ReflowLayout(); };
            ApplyAppearance();
            Shown += OnShown;
            FormClosing += OnClosing;
            Activated += delegate { if (!smoke && hasReport && !busy && DateTime.UtcNow.Subtract(lastCheckUtc).TotalMinutes >= 5) StartBackend("Check"); };
            refreshTimer.Interval = 60000;
            refreshTimer.Tick += delegate { if (!smoke && Visible && WindowState == FormWindowState.Normal && hasReport && !busy && DateTime.UtcNow.Subtract(lastCheckUtc).TotalMinutes >= 5) StartBackend("Check"); };
            if (!smoke) refreshTimer.Start();
            KeyPreview = true;
            KeyDown += delegate(object sender, KeyEventArgs e) { if (e.Control && e.KeyCode == Keys.F) { searchInput.Focus(); searchInput.SelectAll(); e.Handled = true; } };
        }

        internal void ConfigureSmoke(string provider, string search, string statePath) { smokeProvider = provider; smokeSearch = search; smokeStatePath = statePath; }

        internal void ConfigureAppearance(string language, string font, string size, string settingsPath)
        {
            if (!String.IsNullOrWhiteSpace(language)) preferences.Language = language;
            if (!String.IsNullOrWhiteSpace(font)) preferences.FontFamily = font;
            float points;
            if (Single.TryParse(size, NumberStyles.Float, CultureInfo.InvariantCulture, out points) && !Single.IsNaN(points) && !Single.IsInfinity(points)) preferences.FontSize = Math.Max(9F, Math.Min(11F, points));
            settingsScreenshot = settingsPath;
            ApplyAppearance();
        }

        private string T(string key, params object[] args) { return locale.T(key, args); }
        private void Bind(Control control, string key) { bindings[control] = key; boundControls[key] = control; control.Text = T(key); }

        private void ApplyFonts(Control control, List<Font> fonts)
        {
            float original;
            if (!fontSizes.TryGetValue(control, out original)) { original = control.Font.Size; fontSizes[control] = original; }
            control.Font = CachedUiFont(Math.Max(8.5F, original + preferences.FontSize - 10F));
            foreach (Control child in control.Controls) ApplyFonts(child, fonts);
        }

        private void ApplyAppearance()
        {
            BeginPresentation();
            try
            {
                locale = new UiLocale(preferences.Language, appRoot);
                columnMinimums = null;
                ApplyFonts(this, appearanceFonts);
                columnFont.Dispose(); columnFont = UiFontCatalog.Create(preferences.FontFamily, preferences.FontSize - 1F, locale.Culture.Name, true);
                columnMinimums = null;
                foreach (KeyValuePair<Control, string> binding in bindings)
                {
                    binding.Key.Text = T(binding.Value);
                    Label label = binding.Key as Label;
                    if (label != null) { label.UseMnemonic = false; label.RightToLeft = locale.IsRightToLeft ? RightToLeft.Yes : RightToLeft.No; hints.SetToolTip(label, label.Text); }
                }
                summary.RightToLeft = emptyState.RightToLeft = locale.IsRightToLeft ? RightToLeft.Yes : RightToLeft.No;
                Text = T("app.title");
                string[] columns = { "col.skill", "col.provider", "col.version", "col.status" };
                for (int i = 0; i < skills.Columns.Count; i++) skills.Columns[i].Text = T(columns[i]);
                providerButtons["ทั้งหมด"].Text = T("filter.all");
                foreach (Button tab in providerButtons.Values) { hints.SetToolTip(tab, tab.Text); tab.AccessibleName = tab.Text; }
                appearance.Text = "Aa"; appearance.AccessibleName = T("action.settings");
                minimize.AccessibleName = T("action.minimize"); chromeClose.AccessibleName = T("action.close");
                details.AccessibleName = T("details.title"); skills.AccessibleName = T("col.skill"); searchInput.AccessibleName = T("search.label");
                hints.SetToolTip(appearance, T("settings.title")); hints.SetToolTip(update, T("action.updateHint"));
                hints.SetToolTip(searchInput, T("search.hint")); hints.SetToolTip(schedule, T("schedule.hint"));
                foreach (Button button in new[] { update, check, logs, close }) { button.RightToLeft = locale.IsRightToLeft ? RightToLeft.Yes : RightToLeft.No; hints.SetToolTip(button, button == update ? T("action.updateHint") : button.Text); }
                searchInput.RightToLeft = locale.IsRightToLeft ? RightToLeft.Yes : RightToLeft.No;
                if (searchInput.IsHandleCreated) SendMessageText(searchInput.Handle, 0x1501, new IntPtr(1), T("search.placeholder"));
                if (hasReport && currentReport != null) { DateTime checkedBefore = lastCheckUtc; PresentReport(currentReport); lastCheckUtc = checkedBefore; }
                else { RebuildDisplayRows(); summary.Text = T("busy.preparing"); details.Text = T("details.hint"); schedule.Text = T("schedule.default"); }
                if (busy) { summary.Text = T(busyMode == "Update" ? "busy.updating" : "busy.checking"); details.Text = T(busyMode == "Update" ? "busy.updateDetail" : "busy.checkDetail"); }
                ReflowLayout();
            }
            finally { EndPresentation(); }
            Invalidate(true);
        }

        private void LayoutFooter()
        {
            ReflowLayout();
        }

        private void OpenAppearance()
        {
            using (AppearanceDialog dialog = new AppearanceDialog(preferences, locale, appRoot))
                if (dialog.ShowDialog(this) == DialogResult.OK)
                {
                    UiPreferences next = dialog.Selection;
                    try { next.Save(appRoot); preferences = next; ApplyAppearance(); }
                    catch (Exception ex) { MessageBox.Show(this, ex.Message, T("settings.title"), MessageBoxButtons.OK, MessageBoxIcon.Information); }
                }
        }

        private void LoadApplicationIcon()
        {
            string iconPath = Path.Combine(appRoot, "app-icon.ico");
            string imagePath = Path.Combine(appRoot, "app-icon.png");
            try
            {
                if (File.Exists(iconPath))
                {
                    using (Icon sourceIcon = new Icon(iconPath)) applicationIcon = (Icon)sourceIcon.Clone();
                    Icon = applicationIcon;
                }
                else Icon = SystemIcons.Application;
                if (File.Exists(imagePath))
                    using (Image sourceImage = Image.FromFile(imagePath)) applicationImage = new Bitmap(sourceImage);
                else applicationImage = Icon.ToBitmap();
            }
            catch { Icon = SystemIcons.Application; applicationImage = Icon.ToBitmap(); }
        }
        private void BuildControls()
        {
            TableLayoutPanel layout = new TableLayoutPanel();
            mainLayout = layout;
            layout.Dock = DockStyle.Fill;
            layout.ColumnCount = 1;
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            layout.RowCount = 7;
            layout.Margin = Padding.Empty;
            layout.Padding = Padding.Empty;
            layout.BackColor = background;
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 28));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 52));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 36));
            layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 96));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 62));
            Controls.Add(layout);

            Panel chrome = new Panel { Dock = DockStyle.Fill, BackColor = background, Margin = Padding.Empty, Size = new Size(718, 28) };
            Label chromeTitle = new Label { Text = "SKILLS", Font = new Font("Segoe UI", 8F), ForeColor = Color.FromArgb(106, 106, 106), Location = new Point(19, 6), AutoSize = true };
            Panel captionHost = new Panel { Dock = DockStyle.Right, Width = 72, RightToLeft = RightToLeft.No };
            minimize = new CaptionButton { Glyph = CaptionGlyph.Minimize, Dock = DockStyle.Left, Width = 36 };
            chromeClose = new CaptionButton { Glyph = CaptionGlyph.Close, Dock = DockStyle.Right, Width = 36 };
            captionHost.Controls.Add(minimize); captionHost.Controls.Add(chromeClose);
            appearance.Text = "Aa"; appearance.SetBounds(596, 0, 40, 28); appearance.Anchor = AnchorStyles.Top | AnchorStyles.Right; appearance.TabIndex = 10;
            StyleButton(appearance, false); appearance.FlatAppearance.BorderSize = 0; appearance.Click += delegate { OpenAppearance(); };
            minimize.Click += delegate { WindowState = FormWindowState.Minimized; };
            chromeClose.Click += delegate { Close(); };
            MouseEventHandler drag = delegate(object sender, MouseEventArgs e) { if (e.Button == MouseButtons.Left) { ReleaseCapture(); SendMessage(Handle, 0x00A1, new IntPtr(2), IntPtr.Zero); } };
            chrome.MouseDown += drag; chromeTitle.MouseDown += drag;
            chrome.DoubleClick += delegate { MaximizedBounds = Screen.FromControl(this).WorkingArea; WindowState = WindowState == FormWindowState.Maximized ? FormWindowState.Normal : FormWindowState.Maximized; };
            chrome.Controls.Add(chromeTitle); chrome.Controls.Add(appearance); chrome.Controls.Add(captionHost);
            layout.Controls.Add(chrome, 0, 0);

            Panel header = new Panel { Dock = DockStyle.Fill, BackColor = background, Margin = Padding.Empty, Size = new Size(718, 52) };
            Label title = new Label { Text = "Skill Updater", Font = new Font("Segoe UI", 17F, FontStyle.Regular), ForeColor = textColor, Location = new Point(55, 2), AutoSize = true };
            Label subtitle = new Label { Text = "Codex + Claude Code · ตรวจจับ Skill อัตโนมัติ", Font = new Font("Segoe UI", 9F), ForeColor = muted, Location = new Point(20, 32), AutoSize = true };
            Label tag = new Label { Text = daily ? "อัตโนมัติ · 08:00" : "อัปเดตด้วยตนเอง", TextAlign = ContentAlignment.MiddleRight, BackColor = background, ForeColor = muted, Font = new Font("Segoe UI", 9F), Size = new Size(160, 24), Anchor = AnchorStyles.Top | AnchorStyles.Right, Location = new Point(538, 9) };
            subtitle.AutoSize = false; subtitle.Size = new Size(678, 20); subtitle.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right; subtitle.AutoEllipsis = true; tag.AutoEllipsis = true;
            Bind(title, "app.title"); Bind(subtitle, "subtitle"); Bind(tag, daily ? "mode.auto" : "mode.manual");
            PictureBox mark = new PictureBox { Location = new Point(20, 6), Size = new Size(26, 26), SizeMode = PictureBoxSizeMode.Zoom, TabStop = false, Image = applicationImage };
            header.Controls.Add(mark); header.Controls.Add(title); header.Controls.Add(subtitle); header.Controls.Add(tag);
            layout.Controls.Add(header, 0, 1);

            Panel status = new Panel { Dock = DockStyle.Fill, BackColor = background, Margin = Padding.Empty, Size = new Size(718, 48) };
            summary.Text = "กำลังเตรียมตรวจสอบ...";
            summary.Font = new Font("Segoe UI", 10F, FontStyle.Regular);
            summary.AutoEllipsis = true;
            summary.Location = new Point(20, 0);
            summary.Size = new Size(678, 24);
            summary.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
            checkedAt.ForeColor = muted; checkedAt.Font = new Font("Segoe UI", 9F); checkedAt.Location = new Point(21, 25); checkedAt.Size = new Size(480, 21); checkedAt.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
            count.ForeColor = muted; count.Font = new Font("Segoe UI", 9F); count.TextAlign = ContentAlignment.MiddleRight; count.Anchor = AnchorStyles.Top | AnchorStyles.Right; count.Location = new Point(578, 25); count.Size = new Size(120, 21);
            status.Controls.Add(summary); status.Controls.Add(checkedAt); status.Controls.Add(count);
            layout.Controls.Add(status, 0, 2);
            layout.Controls.Add(BuildFilterBar(), 0, 3);

            Panel listPanel = new Panel { Dock = DockStyle.Fill, BackColor = background, Margin = Padding.Empty, Padding = new Padding(20, 0, 20, 10) };
            skills.Dock = DockStyle.Fill; skills.View = View.Details; skills.FullRowSelect = true; skills.HideSelection = false;
            skills.MultiSelect = false; skills.BorderStyle = BorderStyle.None; skills.BackColor = surface; skills.ForeColor = textColor; skills.OwnerDraw = true;
            skills.HeaderStyle = ColumnHeaderStyle.Nonclickable; skills.ShowItemToolTips = true;
            skills.Columns.Add("Skill", 220);
            skills.Columns.Add("โปรแกรม", 106);
            skills.Columns.Add("รุ่นที่ติดตั้ง", 116);
            skills.Columns.Add("สถานะ", 190);
            ImageList rowSpacing = new ImageList(); rowSpacing.ImageSize = new Size(1, 28); skills.SmallImageList = rowSpacing;
            skills.HandleCreated += delegate { ApplyDarkTheme(skills.Handle); };
            skills.DrawColumnHeader += delegate(object sender, DrawListViewColumnHeaderEventArgs e)
            {
                using (Brush brush = new SolidBrush(Color.FromArgb(33, 33, 33))) e.Graphics.FillRectangle(brush, e.Bounds);
                Rectangle bounds = new Rectangle(e.Bounds.X + 9, e.Bounds.Y, Math.Max(0, e.Bounds.Width - 16), e.Bounds.Height);
                TextRenderer.DrawText(e.Graphics, e.Header.Text, columnFont, bounds, muted, RowTextFlags(e.ColumnIndex));
            };
            skills.DrawItem += delegate(object sender, DrawListViewItemEventArgs e) { e.DrawDefault = false; };
            skills.DrawSubItem += delegate(object sender, DrawListViewSubItemEventArgs e)
            {
                Color fill = e.Item.Selected ? Color.FromArgb(39, 39, 39) : surface;
                using (Brush brush = new SolidBrush(fill)) e.Graphics.FillRectangle(brush, e.Bounds);
                Color foreground = e.ColumnIndex == 3 ? e.Item.ForeColor : e.ColumnIndex == 0 ? textColor : Color.FromArgb(172, 172, 172);
                Rectangle bounds = new Rectangle(e.Bounds.X + 9, e.Bounds.Y, Math.Max(0, e.Bounds.Width - 16), e.Bounds.Height);
                TextRenderer.DrawText(e.Graphics, e.SubItem.Text, skills.Font, bounds, foreground, RowTextFlags(e.ColumnIndex));
            };
            skills.SelectedIndexChanged += delegate
            {
                if (skills.SelectedItems.Count > 0)
                {
                    Dictionary<string, object> row = skills.SelectedItems[0].Tag as Dictionary<string, object>;
                    ShowDetails(row);
                }
            };
            skills.Resize += delegate { FitColumns(); };
            skills.ClientSizeChanged += delegate { QueueColumnFit(); };
            skills.VisibleChanged += delegate { QueueColumnFit(); };
            listPanel.Controls.Add(skills);
            Panel headerCap = new Panel { BackColor = Color.FromArgb(33, 33, 33), TabStop = false };
            Action placeHeaderCap = delegate
            {
                int headerHeight = 24;
                if (skills.IsHandleCreated)
                {
                    IntPtr nativeHeader = SendMessage(skills.Handle, 0x101F, IntPtr.Zero, IntPtr.Zero);
                    NativeRectangle rectangle;
                    if (nativeHeader != IntPtr.Zero && GetClientRect(nativeHeader, out rectangle)) headerHeight = rectangle.Bottom - rectangle.Top;
                }
                int capWidth = SystemInformation.VerticalScrollBarWidth + 6;
                headerCap.Bounds = new Rectangle(skills.Right - capWidth, skills.Top, capWidth, headerHeight);
                headerCap.BringToFront();
            };
            listPanel.Controls.Add(headerCap);
            skills.SizeChanged += delegate { placeHeaderCap(); };
            skills.LocationChanged += delegate { placeHeaderCap(); };
            skills.HandleCreated += delegate { placeHeaderCap(); };
            skills.VisibleChanged += delegate { headerCap.Visible = skills.Visible; };
            placeHeaderCap();
            emptyState.BackColor = surface; emptyState.ForeColor = muted; emptyState.TextAlign = ContentAlignment.MiddleCenter; emptyState.Visible = false; emptyState.AutoEllipsis = true; emptyState.Font = new Font("Segoe UI", 10F);
            listPanel.Controls.Add(emptyState);
            Action placeEmpty = delegate {
                Padding padding = listPanel.Padding;
                emptyState.Bounds = new Rectangle(padding.Left, padding.Top, Math.Max(1, listPanel.ClientSize.Width - padding.Horizontal), Math.Max(1, listPanel.ClientSize.Height - padding.Vertical));
                emptyState.BringToFront(); headerCap.BringToFront();
            };
            skills.SizeChanged += delegate { placeEmpty(); }; skills.LocationChanged += delegate { placeEmpty(); }; placeEmpty();
            listPanel.Layout += delegate { placeEmpty(); };
            layout.Controls.Add(listPanel, 0, 4);

            Panel detailPanel = new Panel { Dock = DockStyle.Fill, BackColor = background, Margin = Padding.Empty, Padding = new Padding(21, 0, 21, 8) };
            Label detailTitle = new Label { Text = "รายละเอียด", Dock = DockStyle.Top, Height = 22, ForeColor = muted, Font = new Font("Segoe UI", 9F) };
            Bind(detailTitle, "details.title");
            details.Dock = DockStyle.Fill; details.Multiline = true; details.ReadOnly = true; details.BorderStyle = BorderStyle.None; details.BackColor = background; details.ForeColor = Color.FromArgb(180, 180, 180); details.ScrollBars = ScrollBars.Vertical;
            details.HandleCreated += delegate { ApplyDarkTheme(details.Handle); };
            details.Text = "เลือกแถวเพื่อดูรายละเอียด แหล่งที่มา และผลการอัปเดต";
            details.TabIndex = 5; details.AccessibleName = "รายละเอียด Skill และที่อยู่ไฟล์";
            detailPanel.Controls.Add(details); detailPanel.Controls.Add(detailTitle); layout.Controls.Add(detailPanel, 0, 5);

            Panel footer = new Panel { Dock = DockStyle.Fill, BackColor = background, Margin = Padding.Empty, Size = new Size(718, 62) };
            progress.Dock = DockStyle.Top; progress.Height = 1; progress.MarqueeAnimationSpeed = 0;
            footer.Controls.Add(progress);
            update.Text = "อัปเดตทั้งหมด"; update.Size = new Size(118, 32); update.Location = new Point(20, 8); StyleButton(update, true); update.Enabled = false; update.TabIndex = 6;
            update.EnabledChanged += delegate { StylePrimaryAction(); }; StylePrimaryAction();
            hints.SetToolTip(update, "อัปเดตทุกรายการที่พร้อม รวมรายการที่ซ่อนด้วยตัวกรอง เฉพาะ Skill ที่มีต้นทางรองรับ");
            update.Click += delegate { StartBackend("Update"); };
            check.Text = "ตรวจสอบใหม่"; check.Size = new Size(118, 32); check.Location = new Point(148, 8); StyleButton(check, false); check.TabIndex = 7; check.Click += delegate { StartBackend("Check"); };
            logs.Text = "บันทึก"; logs.Size = new Size(64, 32); logs.Location = new Point(276, 8); StyleButton(logs, false); logs.TabIndex = 8; logs.FlatAppearance.BorderSize = 0; logs.Click += delegate { OpenLogs(); };
            close.Text = "ปิด"; close.Size = new Size(64, 32); close.Location = new Point(634, 8); close.Anchor = AnchorStyles.Top | AnchorStyles.Right; StyleButton(close, false); close.TabIndex = 9; close.FlatAppearance.BorderSize = 0; close.Click += delegate { Close(); };
            schedule.Text = "08:00 อัปเดตอัตโนมัติ · ตอนเข้า Windows เลือกอัปเดตเอง"; schedule.ForeColor = Color.FromArgb(130, 130, 130); schedule.Location = new Point(21, 42); schedule.Size = new Size(677, 19); schedule.AutoEllipsis = true; schedule.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right; schedule.Font = new Font("Segoe UI", 9F);
            footer.Controls.Add(update); footer.Controls.Add(check); footer.Controls.Add(logs); footer.Controls.Add(close); footer.Controls.Add(schedule);
            Bind(update, "action.update"); Bind(check, "action.check"); Bind(logs, "action.logs"); Bind(close, "action.close");
            footer.Resize += delegate { LayoutFooter(); };
            layout.Controls.Add(footer, 0, 6);
            layout.SizeChanged += delegate { ReflowLayout(); };
            layout.Layout += delegate { QueueColumnFit(); };
        }

        private Panel BuildFilterBar()
        {
            Panel bar = new Panel { Dock = DockStyle.Fill, Margin = Padding.Empty, Padding = new Padding(20, 2, 20, 5), BackColor = background };
            Panel tabs = new Panel { Dock = DockStyle.Left, Width = 230, BackColor = background };
            string[] names = { "ทั้งหมด", "Codex", "Claude Code" };
            int[] widths = { 60, 65, 99 }; int left = 0;
            for (int i = 0; i < names.Length; i++)
            {
                string provider = names[i];
                Button button = new Button { Text = provider, Location = new Point(left, 0), Size = new Size(widths[i], 28), TabIndex = i, AccessibleName = "แสดง Skill " + provider };
                StyleButton(button, false); button.FlatAppearance.BorderSize = 0;
                button.Click += delegate { SelectProvider(provider); };
                providerButtons.Add(provider, button); tabs.Controls.Add(button); left += widths[i] + 3;
            }
            Panel searchBox = new Panel { Dock = DockStyle.Fill, Padding = new Padding(9, 3, 7, 2), BackColor = surface };
            searchInput.Dock = DockStyle.Fill; searchInput.BorderStyle = BorderStyle.None; searchInput.BackColor = surface; searchInput.ForeColor = textColor; searchInput.Font = new Font("Segoe UI", 10F); searchInput.TabIndex = 3; searchInput.AccessibleName = "ค้นหา Skill";
            searchInput.TextChanged += delegate { ApplyFilters(); };
            searchInput.KeyDown += delegate(object sender, KeyEventArgs e) { if (e.KeyCode == Keys.Escape) { searchInput.Clear(); e.SuppressKeyPress = true; } };
            searchInput.HandleCreated += delegate { ApplyDarkTheme(searchInput.Handle); SendMessageText(searchInput.Handle, 0x1501, new IntPtr(1), T("search.placeholder")); };
            hints.SetToolTip(searchInput, "ค้นหาจากชื่อ Skill โปรแกรม ต้นทาง หรือที่อยู่ไฟล์ · Ctrl+F");
            searchBox.Controls.Add(searchInput);
            Label searchLabel = new Label { Text = "ค้นหา", Dock = DockStyle.Left, Width = 45, ForeColor = muted, BackColor = surface, Font = new Font("Segoe UI", 9F), TextAlign = ContentAlignment.MiddleLeft };
            searchLabel.Width = 60; Bind(searchLabel, "search.label");
            searchBox.Controls.Add(searchLabel);
            bar.Controls.Add(searchBox); bar.Controls.Add(tabs);
            foreach (KeyValuePair<string, Button> pair in providerButtons) pair.Value.BackColor = pair.Key == selectedProvider ? Color.FromArgb(43, 43, 43) : background;
            skills.TabIndex = 4; skills.AccessibleName = "รายการ Skill ที่ตรวจพบ";
            return bar;
        }

        private void SelectProvider(string provider)
        {
            if (!providerButtons.ContainsKey(provider)) return;
            selectedProvider = provider;
            foreach (KeyValuePair<string, Button> pair in providerButtons) { pair.Value.BackColor = pair.Key == provider ? Color.FromArgb(43, 43, 43) : background; pair.Value.ForeColor = pair.Key == provider ? textColor : muted; }
            ApplyFilters();
        }

        private TextFormatFlags RowTextFlags(int column)
        {
            TextFormatFlags flags = TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix;
            if (locale.IsRightToLeft && column != 2) flags |= TextFormatFlags.RightToLeft | TextFormatFlags.Right;
            return flags;
        }

        private void StyleButton(Button button, bool primary)
        {
            button.FlatStyle = FlatStyle.Flat;
            button.UseVisualStyleBackColor = false;
            button.BackColor = primary ? Color.FromArgb(222, 222, 216) : background;
            button.ForeColor = primary ? Color.FromArgb(28, 28, 28) : Color.FromArgb(184, 184, 184);
            button.FlatAppearance.BorderColor = primary ? Color.FromArgb(222, 222, 216) : Color.FromArgb(54, 54, 54);
            button.FlatAppearance.BorderSize = primary ? 0 : 1;
            button.FlatAppearance.MouseOverBackColor = primary ? Color.FromArgb(237, 237, 232) : Color.FromArgb(36, 36, 36);
            button.FlatAppearance.MouseDownBackColor = primary ? Color.FromArgb(191, 191, 186) : Color.FromArgb(46, 46, 46);
        }

        private void FitColumns()
        {
            if (fittingColumns || skills.Columns.Count < 4) return;
            fittingColumns = true;
            try {
            NativeRectangle bounds;
            int width = skills.IsHandleCreated && GetClientRect(skills.Handle, out bounds) ? Math.Max(1, bounds.Right - bounds.Left) : Math.Max(1, skills.ClientSize.Width - SystemInformation.VerticalScrollBarWidth);
            width = Math.Max(1, width - 2);
            int[] measured = (int[])ColumnMinimums().Clone();
            measured[0] = Math.Max(Math.Max(120, measured[0]), width - measured[1] - measured[2] - measured[3]);
            for (int i = 0; i < 4; i++) if (skills.Columns[i].Width > measured[i]) skills.Columns[i].Width = measured[i];
            for (int i = 0; i < 4; i++) if (skills.Columns[i].Width != measured[i]) skills.Columns[i].Width = measured[i];
            NativeScrollInfo scroll = new NativeScrollInfo(); scroll.Size = Marshal.SizeOf(typeof(NativeScrollInfo)); scroll.Mask = 3;
            int total = measured[0] + measured[1] + measured[2] + measured[3];
            if (skills.IsHandleCreated && GetScrollInfo(skills.Handle, 0, ref scroll) && scroll.Page > 0 && total <= scroll.Page && scroll.Maximum - scroll.Minimum + 1 > scroll.Page)
            {
                // The native control can retain its old extent across hidden/empty transitions.
                // A real width change recalculates that extent; the final widths stay measured.
                skills.Columns[3].Width = Math.Max(1, measured[3] - 1);
                skills.Columns[3].Width = measured[3];
            }
            } finally { fittingColumns = false; }
        }

        [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
        private static extern int SetWindowTheme(IntPtr window, string subAppName, string subIdList);
        [DllImport("user32.dll")]
        private static extern bool ReleaseCapture();
        [DllImport("user32.dll")]
        private static extern IntPtr SendMessage(IntPtr window, int message, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll", EntryPoint = "SendMessageW", CharSet = CharSet.Unicode)]
        private static extern IntPtr SendMessageText(IntPtr window, int message, IntPtr wParam, string text);
        [StructLayout(LayoutKind.Sequential)]
        private struct NativeRectangle { internal int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)]
        private struct NativeScrollInfo { internal int Size, Mask, Minimum, Maximum; internal uint Page; internal int Position, TrackPosition; }
        [DllImport("user32.dll")]
        private static extern bool GetScrollInfo(IntPtr window, int bar, ref NativeScrollInfo info);
        [DllImport("user32.dll")]
        private static extern bool GetClientRect(IntPtr window, out NativeRectangle rectangle);
        private static void ApplyDarkTheme(IntPtr handle)
        {
            try { SetWindowTheme(handle, "DarkMode_Explorer", null); } catch (DllNotFoundException) { } catch (EntryPointNotFoundException) { }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            using (Pen border = new Pen(Color.FromArgb(49, 49, 49))) e.Graphics.DrawRectangle(border, 0, 0, Width - 1, Height - 1);
        }

        protected override void WndProc(ref Message message)
        {
            if (message.Msg == 0x0084 && WindowState == FormWindowState.Normal)
            {
                long coordinates = message.LParam.ToInt64();
                Point point = PointToClient(new Point((short)(coordinates & 0xffff), (short)((coordinates >> 16) & 0xffff)));
                bool left = point.X < 6, right = point.X >= ClientSize.Width - 6, top = point.Y < 6, bottom = point.Y >= ClientSize.Height - 6;
                int hit = top && left ? 13 : top && right ? 14 : bottom && left ? 16 : bottom && right ? 17 : left ? 10 : right ? 11 : top ? 12 : bottom ? 15 : 0;
                if (hit != 0) { message.Result = new IntPtr(hit); return; }
            }
            base.WndProc(ref message);
        }

        protected override void Dispose(bool disposing)
        {
            base.Dispose(disposing);
            if (disposing) { refreshTimer.Dispose(); hints.Dispose(); columnFont.Dispose(); foreach (Font font in appearanceFonts) font.Dispose(); if (applicationImage != null) applicationImage.Dispose(); if (applicationIcon != null) applicationIcon.Dispose(); }
        }

        private void OnShown(object sender, EventArgs e)
        {
            if (smoke)
            {
                BeginInvoke((MethodInvoker)delegate
                {
                    try
                    {
                        if (!String.IsNullOrWhiteSpace(fixtureReport)) RenderReport(fixtureReport);
                        else
                        {
                            summary.Text = T("smoke.ready");
                            checkedAt.Text = T("smoke.note");
                        }
                        if (!String.IsNullOrWhiteSpace(smokeProvider)) SelectProvider(smokeProvider);
                        if (!String.IsNullOrEmpty(smokeSearch)) searchInput.Text = smokeSearch;
                        PerformLayout();
                        FitColumns();
                        if (!String.IsNullOrWhiteSpace(settingsScreenshot))
                            using (AppearanceDialog dialog = new AppearanceDialog(preferences, locale, appRoot))
                            {
                                dialog.Show(this); dialog.PerformLayout();
                                using (Bitmap bitmap = new Bitmap(dialog.Width, dialog.Height)) { dialog.DrawToBitmap(bitmap, dialog.ClientRectangle); bitmap.Save(settingsScreenshot, System.Drawing.Imaging.ImageFormat.Png); }
                                dialog.Close();
                            }
                        if (!String.IsNullOrWhiteSpace(screenshot))
                        {
                            string destination = Path.GetFullPath(screenshot);
                            Directory.CreateDirectory(Path.GetDirectoryName(destination));
                            using (Bitmap bitmap = new Bitmap(Width, Height)) { DrawToBitmap(bitmap, new Rectangle(0, 0, Width, Height)); bitmap.Save(destination, System.Drawing.Imaging.ImageFormat.Png); }
                        }
                        if (!String.IsNullOrWhiteSpace(smokeStatePath))
                        {
                            Dictionary<string, object> state = new Dictionary<string, object>();
                            state["language"] = locale.LanguageCode; state["requestedLanguage"] = preferences.Language; state["translated"] = locale.HasTranslation; state["font"] = skills.Font.Name; state["fontSize"] = skills.Font.Size; state["rtl"] = locale.IsRightToLeft; state["closeBounds"] = chromeClose.Bounds.ToString();
                            state["visibleCount"] = skills.Items.Count; state["totalRows"] = reportRows.Count; state["selectedProvider"] = selectedProvider; state["search"] = searchInput.Text; state["summary"] = summary.Text; state["providerHealth"] = checkedAt.Text; state["updateEnabled"] = update.Enabled; state["emptyState"] = emptyState.Visible ? emptyState.Text : "";
                            List<string> names = new List<string>(); foreach (ListViewItem item in skills.Items) names.Add(item.Text); state["visibleNames"] = names;
                            string destination = Path.GetFullPath(smokeStatePath); Directory.CreateDirectory(Path.GetDirectoryName(destination)); File.WriteAllText(destination, new JavaScriptSerializer().Serialize(state), Encoding.UTF8);
                        }
                    }
                    catch (Exception ex) { ResultCode = 1; Console.Error.WriteLine(ex.Message); }
                    Close();
                });
                return;
            }
            if (daily) Hide();
            StartBackend(daily ? "Update" : "Check");
        }

        private void StartBackend(string mode)
        {
            if (busy) return;
            busy = true; busyMode = mode; update.Enabled = false; check.Enabled = false;
            progress.MarqueeAnimationSpeed = 28;
            summary.ForeColor = textColor;
            summary.Text = T(mode == "Update" ? "busy.updating" : "busy.checking");
            details.Text = T(mode == "Update" ? "busy.updateDetail" : "busy.checkDetail");
            BackgroundWorker worker = new BackgroundWorker();
            worker.DoWork += delegate(object sender, DoWorkEventArgs ev) { ev.Result = RunBackend(mode); };
            worker.RunWorkerCompleted += delegate(object sender, RunWorkerCompletedEventArgs ev)
            {
                busy = false; check.Enabled = true; progress.MarqueeAnimationSpeed = 0;
                BackendResult result = ev.Error == null ? ev.Result as BackendResult : new BackendResult { Error = ev.Error.Message };
                try
                {
                    if (result != null && !String.IsNullOrWhiteSpace(result.ReportPath) && File.Exists(result.ReportPath)) RenderReport(result.ReportPath);
                    else throw new InvalidOperationException(result == null ? T("err.noResult") : result.Error ?? T("err.noReport"));
                    if (result != null && !String.IsNullOrWhiteSpace(result.Error)) { summary.ForeColor = warning; details.Text = result.Error; }
                }
                catch (Exception ex)
                {
                    summary.Text = T("err.failed");
                    summary.ForeColor = failure;
                    details.Text = ex.Message;
                    checkedAt.Text = T("err.network");
                    ResultCode = 1;
                }
                SetActionState();
                if (daily)
                {
                    ShowInTaskbar = true; Opacity = 1; Show(); WindowState = FormWindowState.Normal; Activate();
                }
                worker.Dispose();
            };
            worker.RunWorkerAsync();
        }

        private BackendResult RunBackend(string mode)
        {
            string backend = Path.Combine(appRoot, "Backend.ps1");
            if (!File.Exists(backend)) return new BackendResult { Error = T("err.missingBackend") };
            string data = Path.Combine(appRoot, "data"); Directory.CreateDirectory(data);
            string path = Path.Combine(data, "report-" + mode.ToLowerInvariant() + "-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + "-" + Guid.NewGuid().ToString("N") + ".json");
            string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
            ProcessStartInfo start = new ProcessStartInfo();
            start.FileName = powershell;
            start.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(backend) + " -Mode " + mode + " -OutputPath " + Quote(path);
            start.WorkingDirectory = appRoot; start.UseShellExecute = false; start.CreateNoWindow = true; start.WindowStyle = ProcessWindowStyle.Hidden;
            start.RedirectStandardOutput = true; start.RedirectStandardError = true;
            StringBuilder output = new StringBuilder(); object outputLock = new object();
            using (Process process = new Process())
            {
                process.StartInfo = start;
                DataReceivedEventHandler capture = delegate(object sender, DataReceivedEventArgs e)
                {
                    if (e.Data == null) return;
                    lock (outputLock) { if (output.Length < 10000) output.AppendLine(e.Data); }
                };
                process.OutputDataReceived += capture; process.ErrorDataReceived += capture;
                process.Start(); process.BeginOutputReadLine(); process.BeginErrorReadLine();
                if (!process.WaitForExit(1800000))
                {
                    // The backend owns its child-process timeouts and update lock. Keep it
                    // alive rather than interrupting an atomic skill replacement.
                    return new BackendResult { Error = T("err.longRunning") };
                }
                process.WaitForExit();
                string error = process.ExitCode == 0 ? null : T("err.backendCode", process.ExitCode) + Environment.NewLine + output.ToString();
                return new BackendResult { ReportPath = File.Exists(path) ? path : null, Error = error };
            }
        }

        private void RenderReport(string path)
        {
            JavaScriptSerializer serializer = new JavaScriptSerializer(); serializer.MaxJsonLength = 8 * 1024 * 1024;
            Dictionary<string, object> report = serializer.DeserializeObject(File.ReadAllText(path, Encoding.UTF8)) as Dictionary<string, object>;
            if (report == null) throw new InvalidDataException(T("err.report"));
            currentReport = report; lastReportPath = path;
            PresentReport(report);
        }

        private void PresentReport(Dictionary<string, object> report)
        {
            BeginPresentation();
            try
            {
            reportRows.Clear();
            object rawRows;
            IEnumerable rows = report.TryGetValue("rows", out rawRows) ? rawRows as IEnumerable : null;
            if (rows != null)
            {
                foreach (object rawRow in rows)
                {
                    Dictionary<string, object> row = rawRow as Dictionary<string, object>; if (row == null) continue;
                    reportRows.Add(row);
                }
            }
            RebuildDisplayRows();
            string found = Get(report, "detectedSkillCount"); if (String.IsNullOrWhiteSpace(found)) found = reportRows.Count.ToString();
            summary.Text = T("summary", found, EmptyZero(Get(report, "availableCount")), EmptyZero(Get(report, "updatedCount")), EmptyZero(Get(report, "errorCount")));
            hints.SetToolTip(summary, Get(report, "summary"));
            reportError = Get(report, "error");
            summary.ForeColor = String.IsNullOrWhiteSpace(reportError) ? textColor : failure;
            detectedProviders.Clear();
            List<string> health = new List<string>(); List<string> healthDetails = new List<string>();
            object rawStats;
            IEnumerable stats = report.TryGetValue("providerStats", out rawStats) ? rawStats as IEnumerable : null;
            if (stats != null)
                foreach (object rawStat in stats)
                {
                    Dictionary<string, object> stat = rawStat as Dictionary<string, object>; if (stat == null) continue;
                    string name = Get(stat, "name"); bool detected = Get(stat, "detected").Equals("True", StringComparison.OrdinalIgnoreCase);
                    detectedProviders[name] = detected;
                    health.Add(name + ": " + (detected ? T("health.count", EmptyZero(Get(stat, "skillCount"))) : T("health.notFound")));
                    healthDetails.Add(name + ": " + locale.Status(Get(stat, "status")) + " " + Get(stat, "detail"));
                }
            if (health.Count == 0)
            {
                int codex = 0, claude = 0;
                foreach (Dictionary<string, object> row in reportRows) { List<string> providers = RowProviders(row); if (providers.Contains("Codex")) codex++; if (providers.Contains("Claude Code")) claude++; }
                detectedProviders["Codex"] = codex > 0; detectedProviders["Claude Code"] = claude > 0;
                health.Add("Codex: " + T("health.count", codex)); health.Add("Claude Code: " + (claude > 0 ? T("health.count", claude) : T("health.noData")));
            }
            List<string> scanWarnings = new List<string>(); object rawWarnings;
            if (report.TryGetValue("warnings", out rawWarnings) && rawWarnings != null)
            {
                if (rawWarnings is string) { if (!String.IsNullOrWhiteSpace((string)rawWarnings)) scanWarnings.Add((string)rawWarnings); }
                else { IEnumerable warningValues = rawWarnings as IEnumerable; if (warningValues != null) foreach (object value in warningValues) { string message = Convert.ToString(value); if (!String.IsNullOrWhiteSpace(message)) scanWarnings.Add(message); } }
            }
            string healthText = String.Join("   ·   ", health.ToArray());
            if (scanWarnings.Count > 0) healthText = T("health.partial", scanWarnings.Count) + " · " + healthText;
            checkedAt.Text = String.IsNullOrWhiteSpace(reportError) ? healthText : T("health.incomplete", reportError);
            checkedAt.AutoEllipsis = false; checkedAt.ForeColor = !String.IsNullOrWhiteSpace(reportError) ? failure : scanWarnings.Count > 0 ? warning : muted;
            string healthTip = String.Join(Environment.NewLine, healthDetails.ToArray());
            if (scanWarnings.Count > 0) healthTip += Environment.NewLine + T("health.warnings") + Environment.NewLine + String.Join(Environment.NewLine, scanWarnings.ToArray());
            if (!String.IsNullOrWhiteSpace(reportError)) healthTip = reportError + Environment.NewLine + healthTip;
            hints.SetToolTip(checkedAt, healthTip);
            string when = Get(report, "checkedAt"); DateTimeOffset parsed;
            schedule.Text = T("schedule.last", DateTimeOffset.TryParse(when, out parsed) ? parsed.ToLocalTime().ToString("g", locale.Culture) : when);
            hints.SetToolTip(schedule, T("schedule.hint"));
            hasReport = true; lastCheckUtc = DateTime.UtcNow;
            ApplyFilters(); SetActionState();
            }
            finally { EndPresentation(); }
        }

        private void ApplyFilters()
        {
            if (!hasReport) return;
            BeginPresentation();
            try
            {
                string identity = skills.SelectedItems.Count > 0 ? RowIdentity(skills.SelectedItems[0].Tag as Dictionary<string, object>) : String.Empty;
                string search = searchInput.Text.Trim();
                ListViewItem selected = null;
                skills.BeginUpdate();
                try
                {
                    skills.Items.Clear();
                    foreach (RowDisplay row in displayRows)
                    {
                        if (selectedProvider != "ทั้งหมด" && !row.Providers.Contains(selectedProvider)) continue;
                        if (search.Length > 0 && row.Search.IndexOf(search, StringComparison.OrdinalIgnoreCase) < 0) continue;
                        ListViewItem item = new ListViewItem(new[] { row.Name, row.Provider, row.Current, row.Status });
                        item.Tag = row.Raw; item.ToolTipText = row.Details; item.ForeColor = row.Color;
                        skills.Items.Add(item);
                        if (row.Identity == identity) selected = item;
                    }
                }
                finally { skills.EndUpdate(); }
                count.Text = T("count.shown", skills.Items.Count, reportRows.Count);
                emptyState.Visible = skills.Items.Count == 0; skills.Visible = skills.Items.Count > 0;
                if (skills.Items.Count == 0)
                {
                    bool providerFound; bool missing = selectedProvider != "ทั้งหมด" && detectedProviders.TryGetValue(selectedProvider, out providerFound) && !providerFound;
                    emptyState.Text = search.Length > 0 ? T("empty.search") : missing ? T("empty.provider", selectedProvider) : T("empty.all");
                    details.Text = String.IsNullOrWhiteSpace(reportError) ? emptyState.Text : reportError;
                }
                else { if (selected == null) selected = skills.Items[0]; selected.Selected = true; ShowDetails(selected.Tag as Dictionary<string, object>); }
            }
            finally { EndPresentation(); }
        }

        private void SetActionState() { update.Enabled = !busy && readyToUpdate; check.Enabled = !busy; }
        private void ShowDetails(Dictionary<string, object> row)
        {
            RowDisplay view; string value = row != null && rowDisplayLookup.TryGetValue(row, out view) ? view.Details : FullDetails(row);
            if (details.Text != value) details.Text = value;
        }
        private string FullDetails(Dictionary<string, object> row)
        {
            string path = Get(row, "skillPath");
            return Get(row, "name") + " · " + String.Join(" + ", RowProviders(row).ToArray()) + (Get(row, "scope").Length > 0 ? " · " + locale.TranslateScope(Get(row, "scope")) : "") + Environment.NewLine +
                (path.Length > 0 ? path + Environment.NewLine : "") +
                T("value.version", locale.DisplayValue(Get(row, "current")), locale.DisplayValue(Get(row, "latest")), locale.Status(Get(row, "status"))) + Environment.NewLine + Get(row, "detail");
        }
        private static string RowIdentity(Dictionary<string, object> row)
        {
            string identity = Get(row, "identity");
            return !String.IsNullOrWhiteSpace(identity) ? identity : Get(row, "skillPath") + "\u001f" + String.Join("+", RowProviders(row).ToArray()) + "\u001f" + Get(row, "scope") + "\u001f" + Get(row, "ownerKey") + "\u001f" + Get(row, "ownerId") + "\u001f" + Get(row, "name");
        }
        private static List<string> RowProviders(Dictionary<string, object> row)
        {
            List<string> providers = new List<string>(); object raw;
            if (row != null && row.TryGetValue("providers", out raw) && raw != null)
            {
                if (raw is string) { if (!String.IsNullOrWhiteSpace((string)raw)) providers.Add((string)raw); }
                else { IEnumerable values = raw as IEnumerable; if (values != null) foreach (object value in values) { string name = Convert.ToString(value); if (!String.IsNullOrWhiteSpace(name) && !providers.Contains(name)) providers.Add(name); } }
            }
            if (providers.Count == 0) { string provider = Get(row, "provider"); providers.Add(String.IsNullOrWhiteSpace(provider) ? "Codex" : provider); }
            return providers;
        }
        private static bool IsTrue(Dictionary<string, object> row, string key) { return Get(row, key).Equals("True", StringComparison.OrdinalIgnoreCase); }

        private void OpenLogs()
        {
            try { string data = Path.Combine(appRoot, "data"); Directory.CreateDirectory(data); Process.Start(new ProcessStartInfo { FileName = data, UseShellExecute = true }); }
            catch (Exception ex) { MessageBox.Show(this, ex.Message, T("err.logs"), MessageBoxButtons.OK, MessageBoxIcon.Information); }
        }

        private void OnClosing(object sender, FormClosingEventArgs e)
        {
            if (busy && e.CloseReason == CloseReason.UserClosing)
            {
                e.Cancel = true;
                summary.Text = T("busy.close");
            }
        }

        private static string Get(Dictionary<string, object> dictionary, string key)
        {
            object value; return dictionary != null && dictionary.TryGetValue(key, out value) && value != null ? Convert.ToString(value) : String.Empty;
        }
        private static string EmptyDash(string text) { return String.IsNullOrWhiteSpace(text) ? "—" : text; }
        private static string EmptyZero(string text) { return String.IsNullOrWhiteSpace(text) ? "0" : text; }
        private static string Quote(string argument)
        {
            StringBuilder quoted = new StringBuilder("\""); int slashes = 0;
            foreach (char c in argument)
            {
                if (c == '\\') { slashes++; continue; }
                if (c == '"') quoted.Append('\\', slashes * 2 + 1).Append('"');
                else { quoted.Append('\\', slashes).Append(c); }
                slashes = 0;
            }
            quoted.Append('\\', slashes * 2).Append('"'); return quoted.ToString();
        }
    }
}
