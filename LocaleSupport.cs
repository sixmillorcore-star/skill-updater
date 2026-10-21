using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Text;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Web.Script.Serialization;

namespace CodexSkillUpdater
{
    internal sealed class UiPreferences
    {
        public string Language { get; set; }
        public string FontFamily { get; set; }
        public float FontSize { get; set; }
        internal UiPreferences() { Language = "auto"; FontFamily = "auto"; FontSize = 10F; }
        internal static UiPreferences Load(string appRoot)
        {
            UiPreferences result = new UiPreferences();
            try
            {
                string path = Path.Combine(appRoot, "data", "ui-preferences.json");
                if (!File.Exists(path) || new FileInfo(path).Length > 65536) return result;
                Dictionary<string, object> data = new JavaScriptSerializer().DeserializeObject(File.ReadAllText(path, Encoding.UTF8)) as Dictionary<string, object>;
                object value;
                if (data != null && data.TryGetValue("language", out value) && value != null) result.Language = NormalizeLanguage(Convert.ToString(value));
                if (data != null && data.TryGetValue("fontFamily", out value) && value != null)
                {
                    string font = Convert.ToString(value).Trim();
                    if (font.Length > 0 && font.Length <= 128 && !font.Any(Char.IsControl)) result.FontFamily = font;
                }
                if (data != null && data.TryGetValue("fontSize", out value))
                {
                    float point;
                    if (Single.TryParse(Convert.ToString(value, CultureInfo.InvariantCulture), NumberStyles.Float, CultureInfo.InvariantCulture, out point) && !Single.IsNaN(point) && !Single.IsInfinity(point)) result.FontSize = Math.Max(9F, Math.Min(14F, point));
                }
            }
            catch { }
            return result;
        }
        internal void Save(string appRoot)
        {
            Language = NormalizeLanguage(Language);
            if (String.IsNullOrWhiteSpace(FontFamily) || FontFamily.Length > 128 || FontFamily.Any(Char.IsControl)) FontFamily = "auto";
            if (Single.IsNaN(FontSize) || Single.IsInfinity(FontSize)) FontSize = 10F;
            FontSize = Math.Max(9F, Math.Min(14F, FontSize));
            string folder = Path.Combine(appRoot, "data");
            Directory.CreateDirectory(folder);
            string destination = Path.Combine(folder, "ui-preferences.json");
            string temporary = destination + "." + Guid.NewGuid().ToString("N") + ".tmp";
            Dictionary<string, object> data = new Dictionary<string, object> { {"language", Language}, {"fontFamily", FontFamily}, {"fontSize", FontSize} };
            File.WriteAllText(temporary, new JavaScriptSerializer().Serialize(data), new UTF8Encoding(false));
            try
            {
                if (File.Exists(destination)) File.Replace(temporary, destination, null);
                else File.Move(temporary, destination);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
        private static string NormalizeLanguage(string value)
        {
            if (String.IsNullOrWhiteSpace(value) || value.Equals("auto", StringComparison.OrdinalIgnoreCase)) return "auto";
            try { return CultureInfo.GetCultureInfo(value.Trim()).Name; } catch { return "auto"; }
        }
    }

    internal sealed class UiLanguageChoice
    {
        public string Code { get; internal set; }
        public string NativeName { get; internal set; }
        public string DisplayName { get; internal set; }
        public bool HasTranslation { get; internal set; }
        public override string ToString() { return DisplayName; }
    }

    internal sealed class UiLocale
    {
        private readonly string appRoot;
        private readonly Dictionary<string, string> english;
        private readonly Dictionary<string, string> translated;
        internal string RequestedCode { get; private set; }
        internal string LanguageCode { get; private set; }
        internal string ResolvedCode { get { return LanguageCode; } }
        internal CultureInfo Culture { get; private set; }
        internal bool IsRightToLeft { get { return Culture.TextInfo.IsRightToLeft; } }
        internal bool HasTranslation { get; private set; }
        internal UiLocale(string languageCode, string appRoot)
        {
            this.appRoot = appRoot;
            RequestedCode = String.IsNullOrWhiteSpace(languageCode) ? "auto" : languageCode;
            try { Culture = RequestedCode.Equals("auto", StringComparison.OrdinalIgnoreCase) ? CultureInfo.CurrentUICulture : CultureInfo.GetCultureInfo(RequestedCode); }
            catch { Culture = CultureInfo.GetCultureInfo("en"); }
            if (String.IsNullOrWhiteSpace(Culture.Name)) Culture = CultureInfo.GetCultureInfo("en");
            LanguageCode = ResolvePackCode(Culture.Name);
            english = EnglishBaseline(appRoot);
            translated = LanguageCode == "en" ? english : LoadPack(appRoot, LanguageCode);
            HasTranslation = IsCompletePack(translated, english);
            if (!HasTranslation) translated = null;
        }
        internal string T(string key, params object[] args)
        {
            string result;
            if (translated == null || !translated.TryGetValue(key, out result))
                if (!english.TryGetValue(key, out result)) result = key;
            try { return args == null || args.Length == 0 ? result : String.Format(Culture, result, args); }
            catch (FormatException) { return result; }
        }
        internal string Status(string raw)
        {
            if (raw == null) return String.Empty;
            string key;
            return StatusKeys.TryGetValue(raw.Trim(), out key) ? T(key) : raw;
        }
        internal string TranslateStatus(string raw) { return Status(raw); }
        internal string DisplayValue(string value)
        {
            if (String.IsNullOrWhiteSpace(value)) return "—";
            if (value == "ไม่ระบุ") return T("value.unknown");
            if (value == "ตามแอป") return T("value.app");
            return value;
        }
        internal string TranslateScope(string value)
        {
            if (String.IsNullOrWhiteSpace(value)) return String.Empty;
            string key = "scope." + value.ToLowerInvariant();
            string result = T(key);
            return result == key ? value : result;
        }
        internal List<UiLanguageChoice> GetLanguageChoices() { return LanguageChoices(appRoot); }
        internal static List<UiLanguageChoice> LanguageChoices(string appRoot)
        {
            Dictionary<string, CultureInfo> cultures = new Dictionary<string, CultureInfo>(StringComparer.OrdinalIgnoreCase);
            foreach (CultureInfo culture in CultureInfo.GetCultures(CultureTypes.NeutralCultures))
                if (!String.IsNullOrWhiteSpace(culture.Name) && culture.Name != "zh" && culture.Name != "zh-CHS" && culture.Name != "zh-CHT") cultures[culture.Name] = culture;
            foreach (string code in new[] { "en", "th", "zh-Hans", "zh-Hant" })
                try { cultures[code] = CultureInfo.GetCultureInfo(code); } catch { }
            Dictionary<string, string> baseline = EnglishBaseline(appRoot);
            List<UiLanguageChoice> choices = new List<UiLanguageChoice>();
            foreach (CultureInfo culture in cultures.Values)
            {
                string resolved = ResolvePackCode(culture.Name);
                Dictionary<string, string> pack = resolved == "en" ? baseline : LoadPack(appRoot, resolved);
                bool translated = IsCompletePack(pack, baseline);
                string label = culture.NativeName + " (" + culture.Name + ")" + (translated ? String.Empty : " — English fallback");
                choices.Add(new UiLanguageChoice { Code = culture.Name, NativeName = culture.NativeName, DisplayName = label, HasTranslation = translated });
            }
            choices.Sort(delegate(UiLanguageChoice a, UiLanguageChoice b)
            {
                int available = b.HasTranslation.CompareTo(a.HasTranslation);
                return available != 0 ? available : StringComparer.CurrentCultureIgnoreCase.Compare(a.NativeName, b.NativeName);
            });
            choices.Insert(0, new UiLanguageChoice { Code = "auto", NativeName = "Auto", DisplayName = "Auto — Windows", HasTranslation = new UiLocale("auto", appRoot).HasTranslation });
            return choices;
        }
        private static string ResolvePackCode(string code)
        {
            string lower = code.ToLowerInvariant();
            if (lower.StartsWith("zh")) return lower.Contains("hant") || lower.EndsWith("tw") || lower.EndsWith("hk") || lower.EndsWith("mo") ? "zh-Hant" : "zh-Hans";
            try { return CultureInfo.GetCultureInfo(code).TwoLetterISOLanguageName; } catch { return "en"; }
        }
        private static Dictionary<string, string> LoadPack(string appRoot, string code)
        {
            try
            {
                if (code.Any(c => !(Char.IsLetterOrDigit(c) || c == '-'))) return null;
                string path = Path.Combine(appRoot, "languages", code + ".json");
                if (!File.Exists(path) || new FileInfo(path).Length > 1048576) return null;
                return new JavaScriptSerializer().Deserialize<Dictionary<string, string>>(File.ReadAllText(path, Encoding.UTF8));
            }
            catch { return null; }
        }
        private static bool IsCompletePack(Dictionary<string, string> pack, Dictionary<string, string> baseline)
        {
            return pack != null && baseline.Keys.All(key => pack.ContainsKey(key) && !String.IsNullOrWhiteSpace(pack[key]));
        }
        private static Dictionary<string, string> EnglishBaseline(string appRoot)
        {
            Dictionary<string, string> baseline = EmbeddedEnglish();
            Dictionary<string, string> external = LoadPack(appRoot, "en");
            if (external != null)
                foreach (KeyValuePair<string, string> entry in external)
                    if (!String.IsNullOrWhiteSpace(entry.Value)) baseline[entry.Key] = entry.Value;
            return baseline;
        }
        private static Dictionary<string, string> EmbeddedEnglish()
        {
            return new Dictionary<string, string>
            {
                { "app.title", "Skill Updater" },
                { "subtitle", "Codex + Claude Code · Automatic skill discovery" },
                { "mode.auto", "Automatic · 08:00" },
                { "mode.manual", "Manual update" },
                { "busy.preparing", "Preparing…" },
                { "busy.checking", "Checking skills…" },
                { "busy.updating", "Updating skills…" },
                { "busy.checkDetail", "Checking installed skills and update sources." },
                { "busy.updateDetail", "Updating supported skills. Please wait." },
                { "busy.close", "Please wait for the current operation to finish." },
                { "col.skill", "Skill" },
                { "col.provider", "App" },
                { "col.version", "Installed" },
                { "col.status", "Status" },
                { "details.title", "Details" },
                { "details.hint", "Select a skill to view its source, path and update result." },
                { "action.update", "Update ready" },
                { "action.check", "Check again" },
                { "action.logs", "Logs" },
                { "action.close", "Close" },
                { "action.settings", "Appearance" },
                { "action.minimize", "Minimize" },
                { "action.updateHint", "Update all supported ready skills, including rows hidden by filters." },
                { "filter.all", "All" },
                { "search.label", "Search" },
                { "search.placeholder", "Name / file path" },
                { "search.hint", "Search name, app, source or path · Ctrl+F" },
                { "summary", "{0} skills · Ready {1} · Updated {2} · Issues {3}" },
                { "health.notFound", "Not found on this computer" },
                { "health.noData", "No data" },
                { "health.count", "{0} skills" },
                { "health.partial", "Partial scan ({0})" },
                { "health.incomplete", "Incomplete: {0}" },
                { "health.warnings", "Scan warnings:" },
                { "count.shown", "{0} / {1}" },
                { "empty.search", "No matching skills" },
                { "empty.provider", "{0} or its skills were not found on this computer." },
                { "empty.all", "No skills found in the scanned locations." },
                { "value.shared", "Shared" },
                { "value.version", "Version: {0} → {1} · {2}" },
                { "value.unknown", "Not specified" },
                { "value.app", "App managed" },
                { "schedule.last", "Checked {0} · Auto 08:00" },
                { "schedule.default", "Auto at 08:00 · Choose updates at sign-in" },
                { "schedule.hint", "Automatic updates at 08:00 while the computer is on. Choose updates at Windows sign-in. New skills are checked every 5 minutes while this window is open." },
                { "err.openApp", "Unable to open the app: {0}" },
                { "err.noResult", "No result was returned." },
                { "err.noReport", "The report file was not found." },
                { "err.failed", "Could not finish. Check again to retry." },
                { "err.network", "Check your connection and try again." },
                { "err.missingBackend", "Backend.ps1 was not found beside the app." },
                { "err.longRunning", "This operation is taking longer than usual. Check the logs before trying again." },
                { "err.backendCode", "Backend exited with code {0}" },
                { "err.report", "Invalid report format." },
                { "err.logs", "Cannot open logs" },
                { "smoke.ready", "Ready · Window check passed" },
                { "smoke.note", "Preview only. No skills are checked or updated." },
                { "settings.title", "Language & font" },
                { "settings.language", "Language" },
                { "settings.font", "Font" },
                { "settings.fontSize", "Text size" },
                { "settings.auto", "System default" },
                { "settings.save", "Apply" },
                { "settings.cancel", "Cancel" },
                { "settings.fallback", "This language uses English for untranslated interface text." },
                { "settings.restart", "Changes apply immediately." },
                { "settings.preview", "Readable text · ภาษาไทย · 日本語 · العربية" },
                { "status.current", "Matches source" },
                { "status.available", "Update available" },
                { "status.updated", "Updated" },
                { "status.failed", "Update failed" },
                { "status.unknown", "Cannot verify" },
                { "status.manual", "Manual" },
                { "status.modified", "Locally edited" },
                { "status.managed", "App managed" },
                { "status.runtime", "Matches runtime" },
                { "status.unsupported", "Unsupported version" },
                { "status.disabled", "Disabled" },
                { "status.claude", "Check in Claude" },
                { "status.claudeCli", "Claude CLI required" },
                { "status.source", "Source managed" },
                { "status.catalog", "Matches catalog" },
                { "status.unchanged", "No change" },
                { "scope.user", "User" },
                { "scope.project", "Project" },
                { "scope.local", "Local" },
                { "scope.plugin", "Plugin" },
                { "scope.system", "System" },
                { "scope.synced", "Synced" },
                { "scope.admin", "Admin" },
                { "scope.enterprise", "Enterprise" },
                { "scope.managed", "Managed" }
            };
        }
        private static readonly Dictionary<string, string> StatusKeys = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            {"ตรงกับต้นทาง","status.current"}, {"มีอัปเดต","status.available"}, {"อัปเดตแล้ว","status.updated"}, {"อัปเดตไม่สำเร็จ","status.failed"},
            {"ตรวจไม่ได้","status.unknown"}, {"ดูแลเอง","status.manual"}, {"มีการแก้ไขเอง","status.modified"}, {"แอปดูแล","status.managed"},
            {"ตรงกับ runtime","status.runtime"}, {"ข้ามรุ่นที่ไม่รองรับ","status.unsupported"}, {"ปิดใช้งาน","status.disabled"}, {"ตรวจผ่าน Claude","status.claude"},
            {"ต้องใช้ Claude CLI","status.claudeCli"}, {"ดูแลต้นทาง","status.source"}, {"Claude ดูแล","status.managed"}, {"ตรงกับ catalog","status.catalog"}, {"ไม่มีการเปลี่ยนแปลง","status.unchanged"}
        };
    }

    internal static class UiFontCatalog
    {
        private static readonly List<string> names = ReadNames();
        private static List<string> ReadNames()
        {
            List<string> result = new List<string>();
            using (InstalledFontCollection fonts = new InstalledFontCollection())
                foreach (FontFamily family in fonts.Families)
                    if (!result.Contains(family.Name) && family.Name != "Marlett" && !family.Name.StartsWith("Wingdings", StringComparison.OrdinalIgnoreCase) && family.Name != "Webdings") result.Add(family.Name);
            result.Sort(StringComparer.CurrentCultureIgnoreCase);
            return result;
        }
        internal static List<string> InstalledNames() { return new List<string>(names); }
        internal static List<string> GetChoices() { List<string> result = InstalledNames(); result.Insert(0, "auto"); return result; }
        internal static string ResolveFamily(string preferred, string languageCode)
        {
            string chosen = names.Find(n => n.Equals(preferred ?? String.Empty, StringComparison.OrdinalIgnoreCase));
            if (chosen != null) return chosen;
            string language = (languageCode ?? "en").ToLowerInvariant();
            string[] candidates;
            if (language.StartsWith("th")) candidates = new[] { "Noto Sans Thai", "Leelawadee UI", "Tahoma", "Segoe UI" };
            else if (language.StartsWith("ja")) candidates = new[] { "Yu Gothic UI", "Meiryo", "Noto Sans CJK JP", "Segoe UI" };
            else if (language.StartsWith("ko")) candidates = new[] { "Malgun Gothic", "Noto Sans CJK KR", "Segoe UI" };
            else if (language.StartsWith("zh-hant") || language.EndsWith("tw") || language.EndsWith("hk") || language.EndsWith("mo")) candidates = new[] { "Microsoft JhengHei UI", "Microsoft JhengHei", "Noto Sans CJK TC", "Segoe UI" };
            else if (language.StartsWith("zh")) candidates = new[] { "Microsoft YaHei UI", "Microsoft YaHei", "Noto Sans CJK SC", "Segoe UI" };
            else if (language.StartsWith("hi") || language.StartsWith("bn") || language.StartsWith("ta") || language.StartsWith("te")) candidates = new[] { "Nirmala UI", "Noto Sans", "Segoe UI" };
            else candidates = new[] { "Segoe UI Variable Text", "Segoe UI", "Noto Sans", "Tahoma" };
            foreach (string candidate in candidates)
            {
                chosen = names.Find(n => n.Equals(candidate, StringComparison.OrdinalIgnoreCase));
                if (chosen != null) return chosen;
            }
            return FontFamily.GenericSansSerif.Name;
        }
        internal static Font Create(string preferred, float point, string languageCode, bool light)
        {
            if (Single.IsNaN(point) || Single.IsInfinity(point)) point = 10F;
            string family = ResolveFamily(preferred, languageCode);
            if (light)
            {
                string alternate = names.Find(n => n.Equals(family + " Semilight", StringComparison.OrdinalIgnoreCase)) ?? names.Find(n => n.Equals(family + " Light", StringComparison.OrdinalIgnoreCase));
                if (alternate != null) family = alternate;
            }
            return new Font(family, Math.Max(8F, Math.Min(24F, point)), FontStyle.Regular, GraphicsUnit.Point);
        }
        internal static Font Create(string preferred, string languageCode, float point, FontStyle style) { return Create(preferred, point, languageCode, style == FontStyle.Regular); }
    }
}
