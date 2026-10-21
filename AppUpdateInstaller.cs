using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

namespace CodexSkillUpdater
{
    internal static class AppUpdateInstaller
    {
        internal static bool IsInstalling(string root)
        {
            string path = Path.Combine(root, "data", "app-update.lock");
            if (!File.Exists(path)) return false;
            try
            {
                using (File.Open(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None)) { }
                return false;
            }
            catch (IOException) { return true; }
            catch (UnauthorizedAccessException) { return true; }
        }

        internal static void Launch(string root, string preparedDirectory, string version)
        {
            root = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar);
            string package = Path.GetFullPath(preparedDirectory).TrimEnd(Path.DirectorySeparatorChar);
            string updatesRoot = Path.Combine(root, "data", "app-updates") + Path.DirectorySeparatorChar;
            if (!package.StartsWith(updatesRoot, StringComparison.OrdinalIgnoreCase) ||
                !String.Equals(Path.GetFileName(package), "SkillUpdater", StringComparison.Ordinal) ||
                !String.Equals(Path.GetFileName(Path.GetDirectoryName(package)), "package", StringComparison.Ordinal))
                throw new InvalidOperationException("The prepared update directory is invalid.");
            string stage = Path.GetDirectoryName(Path.GetDirectoryName(package));
            Guid stageId;
            if (!Guid.TryParseExact(Path.GetFileName(stage), "N", out stageId))
                throw new InvalidOperationException("The prepared update directory is invalid.");
            if (!System.Text.RegularExpressions.Regex.IsMatch(version ?? "", @"^\d+\.\d+\.\d+$"))
                throw new InvalidOperationException("The update version is invalid.");
            AssertNoReparse(root);
            AssertNoReparse(Path.Combine(root, "data"));
            AssertNoReparse(Path.Combine(root, "data", "app-updates"));
            AssertNoReparse(stage);
            AssertNoReparse(Path.Combine(stage, "package"));
            AssertNoReparse(package);
            if (!File.Exists(Path.Combine(package, "app-update-manifest.json")))
                throw new InvalidOperationException("The prepared update manifest is missing.");
            if (IsInstalling(root)) throw new InvalidOperationException("Another application update is running.");
            string executable = Path.Combine(root, "SkillUpdater.exe");
            int currentId = Process.GetCurrentProcess().Id;
            foreach (Process process in Process.GetProcessesByName("SkillUpdater"))
            {
                using (process)
                {
                    if (process.Id == currentId) continue;
                    try
                    {
                        if (String.Equals(process.MainModule.FileName, executable, StringComparison.OrdinalIgnoreCase))
                            throw new InvalidOperationException("Close the other Skill Updater window before updating the application.");
                    }
                    catch (System.ComponentModel.Win32Exception)
                    { throw new InvalidOperationException("Another Skill Updater process could not be checked. Close it before updating."); }
                    catch (InvalidOperationException)
                    {
                        if (!process.HasExited) throw;
                    }
                }
            }
            string data = Path.Combine(root, "data");
            Directory.CreateDirectory(data);
            if (File.Exists(Path.Combine(data, "operation.lock"))) AssertNoReparse(Path.Combine(data, "operation.lock"));
            if (File.Exists(Path.Combine(data, "app-update.lock"))) AssertNoReparse(Path.Combine(data, "app-update.lock"));
            try
            {
                using (File.Open(Path.Combine(data, "operation.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None)) { }
            }
            catch (IOException) { throw new InvalidOperationException("A skill check or update is still running. Wait for it to finish."); }
            string probe = Path.Combine(root, ".app-update-write-" + Guid.NewGuid().ToString("N"));
            try { using (File.Create(probe)) { } }
            finally { if (File.Exists(probe)) File.Delete(probe); }

            string sourceHelper = Path.Combine(root, "Apply-AppUpdate.ps1");
            string helper = Path.Combine(stage, "Apply-AppUpdate.ps1");
            AssertNoReparse(sourceHelper);
            if (File.Exists(helper)) AssertNoReparse(helper);
            File.Copy(sourceHelper, helper, false);
            DateTime start;
            using (Process current = Process.GetCurrentProcess()) start = current.StartTime.ToUniversalTime();
            var request = new Dictionary<string, object> {
                { "installRoot", root }, { "packageRoot", package }, { "version", version },
                { "ownerProcessId", currentId }, { "ownerStartUtcTicks", start.Ticks.ToString(CultureInfo.InvariantCulture) },
                { "noRestart", false }
            };
            string requestPath = Path.Combine(stage, "install-request.json");
            File.WriteAllText(requestPath, new JavaScriptSerializer().Serialize(request), new UTF8Encoding(false));
            string readyPath = Path.Combine(stage, "installer-ready.json");
            var info = new ProcessStartInfo {
                FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe"),
                Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(helper) + " -RequestPath " + Quote(requestPath),
                WorkingDirectory = stage, UseShellExecute = false, CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };
            using (Process installer = Process.Start(info))
            {
                DateTime deadline = DateTime.UtcNow.AddSeconds(10);
                while (!File.Exists(readyPath))
                {
                    if (installer.HasExited)
                        throw new InvalidOperationException("The update installer could not start. See data/app-update-result.json for details.");
                    if (DateTime.UtcNow >= deadline)
                    {
                        File.WriteAllText(Path.Combine(stage, "cancel-install"), "cancel", new UTF8Encoding(false));
                        throw new InvalidOperationException("The update installer did not become ready. The application has stayed open.");
                    }
                    Thread.Sleep(50);
                }
            }
        }

        private static void AssertNoReparse(string path)
        {
            if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
                throw new InvalidOperationException("Linked update files or directories are not supported.");
        }

        private static string Quote(string value)
        {
            return "\"" + System.Text.RegularExpressions.Regex.Replace(
                System.Text.RegularExpressions.Regex.Replace(value, @"(\\*)""", "$1$1\\\""), @"(\\+)$", "$1$1") + "\"";
        }
    }
}
