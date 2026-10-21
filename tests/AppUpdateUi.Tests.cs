using System;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

namespace CodexSkillUpdater
{
    internal static class AppUpdateUiTests
    {
        private static int assertions;
        [STAThread]
        private static int Main(string[] args)
        {
            try
            {
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                string root = args[0];
                foreach (string pack in Directory.GetFiles(Path.Combine(root, "languages"), "*.json"))
                {
                    string language = Path.GetFileNameWithoutExtension(pack);
                    foreach (float size in new[] { 9F, 9.5F, 10F, 10.5F, 11F })
                    {
                        UiPreferences preferences = new UiPreferences { Language = language, FontFamily = "auto", FontSize = size };
                        UiLocale locale = new UiLocale(language, root);
                        using (AppUpdateDialog dialog = new AppUpdateDialog(preferences, locale))
                        {
                            AppRelease release = new AppRelease { Version = "1.2.0" };
                            dialog.SetState(release, locale.T("appUpdate.ready"), false, false, false);
                            AssertGeometry(dialog, language + "/" + size);
                            Assert(dialog.ClientSize.Width <= 520 && dialog.ClientSize.Height <= 500, "Compact dialog: " + language);
                            Button update = (Button)dialog.Controls["InstallAppUpdate"];
                            Button check = (Button)dialog.Controls["CheckAppUpdate"];
                            Button close = (Button)dialog.Controls["CloseAppUpdate"];
                            Assert(update.Enabled && check.Enabled && close.Enabled, "Ready actions");
                            dialog.SetState(release, locale.T("appUpdate.busy"), false, false, true);
                            Assert(!update.Enabled && check.Enabled && close.Enabled, "Skill operation blocks installation only");
                            dialog.SetState(release, locale.T("appUpdate.downloading"), false, true, false);
                            Assert(!update.Enabled && !check.Enabled && !close.Enabled, "Download action state");
                            FormClosingEventArgs closing = new FormClosingEventArgs(CloseReason.UserClosing, false);
                            typeof(Form).GetMethod("OnFormClosing", BindingFlags.Instance | BindingFlags.NonPublic).Invoke(dialog, new object[] { closing });
                            Assert(closing.Cancel, "Download prevents close");
                            dialog.AllowCloseForUpdate();
                            closing = new FormClosingEventArgs(CloseReason.UserClosing, false);
                            typeof(Form).GetMethod("OnFormClosing", BindingFlags.Instance | BindingFlags.NonPublic).Invoke(dialog, new object[] { closing });
                            Assert(!closing.Cancel, "Prepared update can close");
                            dialog.SetState(null, locale.T("appUpdate.currentStatus"), false, false, false);
                            Assert(!update.Enabled && check.Enabled && close.Enabled, "Latest release state");
                            AssertGeometry(dialog, language + "/latest");
                        }
                    }
                }
                using (UpdaterForm form = new UpdaterForm(false, true, null, null))
                {
                    form.Size = new Size(640, 460);
                    form.PerformLayout();
                    Button version = Field<Button>(form, "appVersion");
                    Control appearance = Field<Control>(form, "appearance");
                    Assert(version.Right < appearance.Left, "Version control clear of appearance at minimum size");
                    SetField(form, "readyToUpdate", true);
                    Invoke(form, "SetActionState");
                    Assert(Field<Button>(form, "update").Enabled, "Normal skill update enabled");
                    SetField(form, "appUpdateBusy", true);
                    Invoke(form, "SetActionState");
                    Assert(!Field<Button>(form, "update").Enabled && !Field<Button>(form, "check").Enabled, "App preparation blocks backend actions");
                    Invoke(form, "StartBackend", "Check");
                    Assert(!Field<bool>(form, "busy"), "Backend cannot start during app preparation");
                    FormClosingEventArgs closing = new FormClosingEventArgs(CloseReason.UserClosing, false);
                    Invoke(form, "OnClosing", null, closing);
                    Assert(closing.Cancel, "Main window cannot close during preparation");
                    SetField(form, "appUpdateHandoff", true);
                    closing = new FormClosingEventArgs(CloseReason.UserClosing, false);
                    Invoke(form, "OnClosing", null, closing);
                    Assert(!closing.Cancel, "Main window closes after helper handoff");
                }
                Console.WriteLine("App update UI: " + assertions + " assertions passed; 20 languages x 5 font sizes, no network or displayed windows.");
                return 0;
            }
            catch (Exception ex) { Console.Error.WriteLine(ex); return 1; }
        }

        private static void AssertGeometry(AppUpdateDialog dialog, string context)
        {
            foreach (Control control in dialog.Controls)
            {
                Assert(control.Left >= 0 && control.Top >= 0 && control.Right <= dialog.ClientSize.Width && control.Bottom <= dialog.ClientSize.Height, "Control stays inside: " + control.Name + " " + context);
                Label label = control as Label;
                if (label != null)
                {
                    Size measured = TextRenderer.MeasureText(label.Text, label.Font, new Size(label.Width, 32767), TextFormatFlags.WordBreak | TextFormatFlags.TextBoxControl | TextFormatFlags.NoPrefix);
                    Assert(measured.Height <= label.Height, "Complete label text: " + label.Name + " " + context);
                }
                Button button = control as Button;
                if (button != null && !(button is CaptionButton))
                {
                    Size measured = TextRenderer.MeasureText(button.Text, button.Font, new Size(button.Width - 16, 32767), TextFormatFlags.WordBreak | TextFormatFlags.TextBoxControl | TextFormatFlags.NoPrefix);
                    Assert(measured.Height + 6 <= button.Height, "Complete button text: " + button.Name + " " + context);
                }
            }
            Control[] buttons = { dialog.Controls["CheckAppUpdate"], dialog.Controls["InstallAppUpdate"], dialog.Controls["CloseAppUpdate"] };
            for (int i = 0; i < buttons.Length; i++) for (int j = i + 1; j < buttons.Length; j++) Assert(!buttons[i].Bounds.IntersectsWith(buttons[j].Bounds), "Buttons do not overlap: " + context);
        }

        private static T Field<T>(object target, string name) { return (T)target.GetType().GetField(name, BindingFlags.Instance | BindingFlags.NonPublic).GetValue(target); }
        private static void SetField(object target, string name, object value) { target.GetType().GetField(name, BindingFlags.Instance | BindingFlags.NonPublic).SetValue(target, value); }
        private static void Invoke(object target, string name, params object[] args) { target.GetType().GetMethod(name, BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.DeclaredOnly).Invoke(target, args); }
        private static void Assert(bool value, string message) { assertions++; if (!value) throw new Exception(message); }
    }
}
