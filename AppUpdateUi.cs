using System;
using System.ComponentModel;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace CodexSkillUpdater
{
    internal sealed partial class UpdaterForm
    {
        private readonly Button appVersion = new Button();
        private readonly System.Windows.Forms.Timer appUpdateTimer = new System.Windows.Forms.Timer();
        private readonly System.Windows.Forms.Timer appNoticeTimer = new System.Windows.Forms.Timer();
        private NotifyIcon appUpdateNotice;
        private AppUpdateDialog appUpdateDialog;
        private AppRelease availableAppRelease;
        private DateTime appCheckedUtc = DateTime.MinValue;
        private string appUpdateMessageKey = "appUpdate.initial";
        private string appUpdateError;
        private string notifiedAppVersion;
        private string appUpdateResult;
        private bool appCheckBusy, appUpdateBusy, appUpdateHandoff;

        private void BuildAppUpdateControl(Panel chrome)
        {
            appVersion.Name = "AppUpdateVersion";
            appVersion.SetBounds(82, 0, 112, 28);
            appVersion.TabIndex = 11;
            appVersion.Font = CachedUiFont(8.5F);
            StyleButton(appVersion, false);
            appVersion.FlatAppearance.BorderSize = 0;
            appVersion.Click += delegate { OpenAppUpdate(); };
            chrome.Controls.Add(appVersion);
            appUpdateTimer.Interval = 60000;
            appUpdateTimer.Tick += delegate
            {
                if (!smoke && Visible && WindowState == FormWindowState.Normal && DateTime.UtcNow.Subtract(appCheckedUtc).TotalHours >= 6) CheckAppUpdate(false);
            };
            appNoticeTimer.Interval = 15000;
            appNoticeTimer.Tick += delegate { appNoticeTimer.Stop(); if (appUpdateNotice != null) appUpdateNotice.Visible = false; };
        }

        private void StartAppUpdates()
        {
            if (smoke) return;
            appUpdateTimer.Start();
            ReadAppUpdateResult();
            CheckAppUpdate(false);
        }

        private void RefreshAppUpdateUi()
        {
            appVersion.Text = (availableAppRelease == null ? "v" + AppUpdateClient.CurrentVersion : "\u2191 v" + availableAppRelease.Version);
            appVersion.ForeColor = availableAppRelease == null ? muted : success;
            appVersion.Width = TextRenderer.MeasureText(appVersion.Text, appVersion.Font).Width + 22;
            appVersion.AccessibleName = availableAppRelease == null ? T("appUpdate.title") : T("appUpdate.notice", availableAppRelease.Version);
            hints.SetToolTip(appVersion, availableAppRelease == null ? T("appUpdate.check") : T("appUpdate.notice", availableAppRelease.Version));
            if (appUpdateDialog != null && !appUpdateDialog.IsDisposed)
            {
                string message = String.IsNullOrEmpty(appUpdateError) ? (appUpdateResult ?? T(appUpdateMessageKey)) : T("appUpdate.failed", appUpdateError);
                if (busy && availableAppRelease != null && !appUpdateBusy && !appCheckBusy) message += Environment.NewLine + Environment.NewLine + T("appUpdate.busy");
                appUpdateDialog.SetState(availableAppRelease, message, appCheckBusy, appUpdateBusy, busy);
            }
        }

        private void CheckAppUpdate(bool manual)
        {
            if (smoke || appCheckBusy || appUpdateBusy || IsDisposed || Disposing) return;
            appCheckBusy = true;
            if (manual) appUpdateResult = null;
            appCheckedUtc = DateTime.UtcNow;
            if (manual || availableAppRelease == null) { appUpdateMessageKey = "appUpdate.checking"; appUpdateError = null; }
            RefreshAppUpdateUi();
            BackgroundWorker worker = new BackgroundWorker();
            worker.DoWork += delegate(object sender, DoWorkEventArgs e) { e.Result = new AppUpdateClient(appRoot).Check(); };
            worker.RunWorkerCompleted += delegate(object sender, RunWorkerCompletedEventArgs e)
            {
                worker.Dispose();
                if (IsDisposed || Disposing) return;
                appCheckBusy = false;
                if (e.Error == null)
                {
                    availableAppRelease = e.Result as AppRelease;
                    appUpdateMessageKey = availableAppRelease == null ? "appUpdate.currentStatus" : "appUpdate.ready";
                    appUpdateError = null;
                    if (availableAppRelease != null) NotifyAppUpdate();
                }
                else if (manual || appUpdateDialog != null)
                {
                    appUpdateError = e.Error.Message;
                    appUpdateMessageKey = "appUpdate.initial";
                }
                else if (availableAppRelease == null) appUpdateMessageKey = "appUpdate.initial";
                RefreshAppUpdateUi();
            };
            worker.RunWorkerAsync();
        }

        private void ReadAppUpdateResult()
        {
            string resultPath = Path.Combine(appRoot, "data", "app-update-result.json");
            try
            {
                if (!File.Exists(resultPath) || new FileInfo(resultPath).Length > 16384) return;
                Dictionary<string, object> result = new JavaScriptSerializer().DeserializeObject(File.ReadAllText(resultPath, Encoding.UTF8)) as Dictionary<string, object>;
                if (result == null) return;
                string state = Get(result, "status");
                if (state == "success") appUpdateResult = T("appUpdate.updated", Get(result, "version"));
                else if (state == "failed") appUpdateResult = T("appUpdate.failed", Get(result, "message"));
                else return;
                File.Delete(resultPath);
                BeginInvoke((MethodInvoker)delegate { if (!IsDisposed && !Disposing) OpenAppUpdate(); });
            }
            catch { /* An unreadable result never prevents the skill updater from opening. */ }
        }

        private void NotifyAppUpdate()
        {
            if (availableAppRelease == null || notifiedAppVersion == availableAppRelease.Version) return;
            notifiedAppVersion = availableAppRelease.Version;
            if (appUpdateDialog != null) return;
            try
            {
                if (appUpdateNotice == null)
                {
                    appUpdateNotice = new NotifyIcon { Icon = Icon, Text = "Skill Updater" };
                    appUpdateNotice.BalloonTipClicked += delegate { OpenAppUpdate(); };
                    appUpdateNotice.DoubleClick += delegate { OpenAppUpdate(); };
                }
                appUpdateNotice.BalloonTipTitle = T("appUpdate.title");
                appUpdateNotice.BalloonTipText = T("appUpdate.notice", availableAppRelease.Version);
                appUpdateNotice.BalloonTipIcon = ToolTipIcon.Info;
                appUpdateNotice.Visible = true;
                appUpdateNotice.ShowBalloonTip(10000);
                appNoticeTimer.Start();
            }
            catch { /* The persistent version button also exposes the notification. */ }
        }

        private void OpenAppUpdate()
        {
            if (IsDisposed || Disposing || appUpdateHandoff) return;
            if (appUpdateDialog != null) { appUpdateDialog.Activate(); return; }
            if (appUpdateNotice != null) appUpdateNotice.Visible = false;
            if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
            using (AppUpdateDialog dialog = new AppUpdateDialog(preferences, locale))
            {
                appUpdateDialog = dialog;
                dialog.CheckRequested += delegate { CheckAppUpdate(true); };
                dialog.UpdateRequested += delegate { InstallAppUpdate(); };
                RefreshAppUpdateUi();
                try { dialog.ShowDialog(this); }
                finally { appUpdateDialog = null; }
            }
            if (appUpdateHandoff) Close();
        }

        private void InstallAppUpdate()
        {
            if (appUpdateBusy || appCheckBusy || availableAppRelease == null) return;
            if (busy) { appUpdateMessageKey = "appUpdate.busy"; RefreshAppUpdateUi(); return; }
            AppRelease release = availableAppRelease;
            appUpdateBusy = true;
            appUpdateResult = null;
            appUpdateMessageKey = "appUpdate.downloading";
            appUpdateError = null;
            SetActionState();
            RefreshAppUpdateUi();
            BackgroundWorker worker = new BackgroundWorker();
            worker.DoWork += delegate(object sender, DoWorkEventArgs e)
            {
                string preparedDirectory = new AppUpdateClient(appRoot).Prepare(release);
                AppUpdateInstaller.Launch(appRoot, preparedDirectory, release.Version);
            };
            worker.RunWorkerCompleted += delegate(object sender, RunWorkerCompletedEventArgs e)
            {
                worker.Dispose();
                if (IsDisposed || Disposing) return;
                try
                {
                    if (e.Error != null) throw e.Error;
                    appUpdateMessageKey = "appUpdate.installing";
                    RefreshAppUpdateUi();
                    appUpdateHandoff = true;
                    appUpdateBusy = false;
                    if (appUpdateDialog != null) { appUpdateDialog.AllowCloseForUpdate(); appUpdateDialog.Close(); }
                    else Close();
                }
                catch (Exception ex)
                {
                    appUpdateBusy = false;
                    appUpdateError = ex.Message;
                    appUpdateMessageKey = "appUpdate.ready";
                    SetActionState();
                    RefreshAppUpdateUi();
                }
            };
            worker.RunWorkerAsync();
        }

        private void DisposeAppUpdates()
        {
            appUpdateTimer.Dispose(); appNoticeTimer.Dispose();
            if (appUpdateNotice != null) { appUpdateNotice.Visible = false; appUpdateNotice.Dispose(); }
        }
    }

    internal sealed class AppUpdateDialog : Form
    {
        private readonly UiLocale locale;
        private readonly Label heading = new Label(), versions = new Label(), note = new Label();
        private readonly TextBox status = new TextBox();
        private readonly Button check = new PrimaryActionButton(), install = new PrimaryActionButton(), close = new PrimaryActionButton();
        private readonly CaptionButton captionClose = new CaptionButton();
        private readonly QuietProgress progress = new QuietProgress();
        private readonly Font bodyFont, titleFont;
        private bool busy, allowClose;
        internal event EventHandler CheckRequested, UpdateRequested;

        internal AppUpdateDialog(UiPreferences preferences, UiLocale locale)
        {
            this.locale = locale;
            Name = "AppUpdateDialog";
            Text = locale.T("appUpdate.title");
            bodyFont = UiFontCatalog.Create(preferences.FontFamily, preferences.FontSize, locale.Culture.Name, true);
            titleFont = UiFontCatalog.Create(preferences.FontFamily, preferences.FontSize + 3F, locale.Culture.Name, true);
            Font = bodyFont;
            BackColor = Color.FromArgb(20, 20, 20); ForeColor = Color.FromArgb(222, 222, 222);
            ClientSize = new Size(500, 330);
            FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false;
            StartPosition = FormStartPosition.CenterParent; AutoScaleMode = AutoScaleMode.Dpi;
            Padding = new Padding(1); DoubleBuffered = true;
            heading.Name = "AppUpdateHeading"; heading.Text = Text; heading.Font = titleFont; heading.UseMnemonic = false;
            captionClose.Name = "CloseAppUpdateCaption"; captionClose.Glyph = CaptionGlyph.Close; captionClose.AccessibleName = locale.T("action.close");
            captionClose.Click += delegate { Close(); };
            versions.Name = "AppUpdateVersions"; versions.ForeColor = Color.FromArgb(163, 163, 163); versions.UseMnemonic = false;
            status.Name = "AppUpdateStatus"; status.Multiline = true; status.ReadOnly = true; status.WordWrap = true; status.ScrollBars = ScrollBars.Vertical;
            status.BorderStyle = BorderStyle.None; status.BackColor = Color.FromArgb(25, 25, 25); status.ForeColor = ForeColor;
            status.HandleCreated += delegate { try { SetWindowTheme(status.Handle, "DarkMode_Explorer", null); } catch (DllNotFoundException) { } catch (EntryPointNotFoundException) { } };
            status.AccessibleName = locale.T("appUpdate.title");
            note.Name = "AppUpdateRestartNote"; note.Text = locale.T("appUpdate.restart"); note.ForeColor = Color.FromArgb(147, 147, 147); note.UseMnemonic = false;
            ConfigureButton(check, "CheckAppUpdate", locale.T("appUpdate.check"), false);
            ConfigureButton(install, "InstallAppUpdate", locale.T("appUpdate.update"), true);
            ConfigureButton(close, "CloseAppUpdate", locale.T("action.close"), false);
            check.Click += delegate { if (CheckRequested != null) CheckRequested(this, EventArgs.Empty); };
            install.Click += delegate { if (UpdateRequested != null) UpdateRequested(this, EventArgs.Empty); };
            close.Click += delegate { Close(); };
            check.TabIndex = 0; install.TabIndex = 1; close.TabIndex = 2; captionClose.TabIndex = 3; status.TabIndex = 4;
            Controls.Add(heading); Controls.Add(captionClose); Controls.Add(versions); Controls.Add(status); Controls.Add(note);
            Controls.Add(progress); Controls.Add(check); Controls.Add(install); Controls.Add(close);
            foreach (Control control in new Control[] { heading, versions, status, note, check, install, close }) control.RightToLeft = locale.IsRightToLeft ? RightToLeft.Yes : RightToLeft.No;
            heading.MouseDown += DragWindow; MouseDown += DragWindow;
            FormClosing += delegate(object sender, FormClosingEventArgs e) { if (busy && !allowClose) e.Cancel = true; };
            KeyPreview = true;
            KeyDown += delegate(object sender, KeyEventArgs e) { if (e.KeyCode == Keys.Escape && !busy) { Close(); e.Handled = true; } };
            SetState(null, locale.T("appUpdate.initial"), false, false, false);
        }

        internal void AllowCloseForUpdate() { allowClose = true; }

        internal void SetState(AppRelease release, string message, bool checking, bool installing, bool skillBusy)
        {
            busy = installing;
            versions.Text = locale.T("appUpdate.current", AppUpdateClient.CurrentVersion) + (release == null ? "" : Environment.NewLine + locale.T("appUpdate.latest", release.Version));
            status.Text = message;
            check.Enabled = !checking && !installing;
            install.Enabled = release != null && !checking && !installing && !skillBusy;
            close.Enabled = captionClose.Enabled = !installing;
            install.BackColor = install.Enabled ? Color.FromArgb(215, 215, 208) : Color.FromArgb(25, 25, 25);
            install.ForeColor = install.Enabled ? Color.FromArgb(28, 28, 28) : Color.FromArgb(147, 147, 147);
            progress.MarqueeAnimationSpeed = checking || installing ? 28 : 0;
            Reflow();
        }

        private static void ConfigureButton(Button button, string name, string text, bool primary)
        {
            button.Name = name; button.Text = text; button.FlatStyle = FlatStyle.Flat; button.UseVisualStyleBackColor = false;
            button.BackColor = Color.FromArgb(20, 20, 20); button.ForeColor = Color.FromArgb(184, 184, 184);
            button.FlatAppearance.BorderSize = 1; button.FlatAppearance.BorderColor = Color.FromArgb(54, 54, 54);
            button.FlatAppearance.MouseOverBackColor = primary ? Color.FromArgb(237, 237, 232) : Color.FromArgb(36, 36, 36);
            button.FlatAppearance.MouseDownBackColor = primary ? Color.FromArgb(191, 191, 186) : Color.FromArgb(46, 46, 46);
            button.AutoEllipsis = false;
        }

        private int TextHeight(Control control, int width)
        {
            return TextRenderer.MeasureText(control.Text.Length == 0 ? "Ag" : control.Text, control.Font, new Size(width, 32767), TextFormatFlags.WordBreak | TextFormatFlags.TextBoxControl | TextFormatFlags.NoPrefix).Height + 3;
        }

        private void Reflow()
        {
            int width = ClientSize.Width, content = width - 40;
            int headingHeight = Math.Max(30, TextHeight(heading, content - 32));
            heading.SetBounds(20, 11, content - 32, headingHeight);
            captionClose.SetBounds(width - 37, 1, 36, 36);
            int top = heading.Bottom + 10;
            versions.SetBounds(20, top, content, TextHeight(versions, content));
            top = versions.Bottom + 12;
            int statusHeight = Math.Max(74, bodyFont.Height * 4 + 6);
            status.SetBounds(20, top, content, statusHeight);
            progress.SetBounds(20, status.Bottom + 2, content, 1);
            note.SetBounds(20, progress.Bottom + 12, content, TextHeight(note, content));
            int x = 20, y = note.Bottom + 16, rowHeight = 0;
            foreach (Button button in new[] { check, install, close })
            {
                int natural = TextRenderer.MeasureText(button.Text, button.Font, new Size(32767, 32767), TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine).Width + 24;
                int buttonWidth = Math.Min(content, Math.Max(button == close ? 70 : 118, natural));
                int buttonHeight = Math.Max(32, TextHeight(button, buttonWidth - 16) + 10);
                if (x > 20 && x + buttonWidth > width - 20) { x = 20; y += rowHeight + 7; rowHeight = 0; }
                button.SetBounds(x, y, buttonWidth, buttonHeight);
                x += buttonWidth + 8; rowHeight = Math.Max(rowHeight, buttonHeight);
            }
            int nextHeight = y + rowHeight + 18;
            if (ClientSize.Height != nextHeight) ClientSize = new Size(width, nextHeight);
        }

        [DllImport("user32.dll")]
        private static extern bool ReleaseCapture();
        [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
        private static extern int SetWindowTheme(IntPtr window, string subAppName, string subIdList);
        [DllImport("user32.dll")]
        private static extern IntPtr SendMessage(IntPtr window, int message, IntPtr wparam, IntPtr lparam);
        private void DragWindow(object sender, MouseEventArgs e) { if (e.Button == MouseButtons.Left) { ReleaseCapture(); SendMessage(Handle, 0x00A1, new IntPtr(2), IntPtr.Zero); } }
        protected override void OnPaint(PaintEventArgs e) { base.OnPaint(e); using (Pen border = new Pen(Color.FromArgb(48, 48, 48))) e.Graphics.DrawRectangle(border, 0, 0, Width - 1, Height - 1); }
        protected override void Dispose(bool disposing) { base.Dispose(disposing); if (disposing) { bodyFont.Dispose(); titleFont.Dispose(); } }
    }
}
