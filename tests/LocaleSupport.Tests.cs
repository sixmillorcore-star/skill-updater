using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace CodexSkillUpdater
{
    internal static class LocaleSupportTests
    {
        private static int checks;
        private static void Check(bool condition, string label)
        {
            if (!condition) throw new Exception("FAILED: " + label);
            checks++;
        }
        private static string Placeholders(string text)
        {
            return String.Join(",", Regex.Matches(text, @"\{\d+\}").Cast<Match>().Select(match => match.Value).OrderBy(value => value).ToArray());
        }
        private static Dictionary<string, string> Read(string path)
        {
            return new JavaScriptSerializer().Deserialize<Dictionary<string, string>>(File.ReadAllText(path, Encoding.UTF8));
        }
        private static int Main(string[] args)
        {
            try
            {
                string appRoot = Path.GetFullPath(args[0]);
                string testRoot = Path.GetFullPath(args[1]);
                Directory.CreateDirectory(testRoot);
                Dictionary<string, string> baseline = Read(Path.Combine(appRoot, "languages", "en.json"));
                foreach (string path in Directory.GetFiles(Path.Combine(appRoot, "languages"), "*.json"))
                {
                    Dictionary<string, string> pack = Read(path);
                    Check(pack.Count == baseline.Count, Path.GetFileName(path) + " key count");
                    foreach (KeyValuePair<string, string> item in baseline)
                    {
                        Check(pack.ContainsKey(item.Key), Path.GetFileName(path) + ": " + item.Key);
                        Check(!String.IsNullOrWhiteSpace(pack[item.Key]), "nonempty " + item.Key);
                        Check(Placeholders(item.Value) == Placeholders(pack[item.Key]), "placeholders " + item.Key);
                        if (Path.GetFileNameWithoutExtension(path) != "th" && item.Key != "settings.preview")
                            Check(!Regex.IsMatch(pack[item.Key], "[ก-๙]"), "no stray Thai " + item.Key);
                    }
                }
                UiLocale english = new UiLocale("en", appRoot);
                UiLocale thai = new UiLocale("th-TH", appRoot);
                Check(english.HasTranslation && thai.HasTranslation, "English and Thai complete");
                Check(english.T("summary", 8, 2, 1, 0) == "8 skills · Ready 2 · Updated 1 · Issues 0", "formatted summary");
                Check(thai.T("action.close") == "ปิด", "Thai string");
                Check(english.T("missing.key") == "missing.key", "missing key predictable");
                Check(english.Status("อัปเดตไม่สำเร็จ") == "Update failed", "status mapping");
                Check(english.Status("Unknown external diagnostic") == "Unknown external diagnostic", "diagnostics preserved");
                Check(english.DisplayValue("ไม่ระบุ") == "Not specified", "version value mapping");
                Check(english.TranslateScope("project") == "Project", "scope mapping");
                Check(new UiLocale("ja-JP", appRoot).LanguageCode == "ja", "Japanese culture mapping");
                Check(new UiLocale("zh-TW", appRoot).LanguageCode == "zh-Hant", "Traditional Chinese mapping");
                Check(new UiLocale("zh-CN", appRoot).LanguageCode == "zh-Hans", "Simplified Chinese mapping");
                Check(new UiLocale("zh-HK", appRoot).LanguageCode == "zh-Hant", "Hong Kong mapping");
                foreach (string code in new[] { "he", "fa", "ur" })
                {
                    UiLocale fallback = new UiLocale(code, appRoot);
                    Check(fallback.IsRightToLeft && !fallback.HasTranslation, "RTL fallback " + code);
                    Check(fallback.T("action.close") == "Close", "English fallback " + code);
                }
                Check(new UiLocale("ar", appRoot).IsRightToLeft, "Arabic direction");
                Check(!english.IsRightToLeft, "English direction");
                Check(new UiLocale("invalid-locale-name", appRoot).Culture.Name == "en", "invalid locale recovery");
                UiLocale embedded = new UiLocale("en", testRoot);
                Check(embedded.HasTranslation && embedded.T("schedule.hint") == baseline["schedule.hint"], "complete embedded fallback");
                CultureInfo previous = CultureInfo.CurrentUICulture;
                try
                {
                    System.Threading.Thread.CurrentThread.CurrentUICulture = CultureInfo.GetCultureInfo("th-TH");
                    Check(new UiLocale("auto", appRoot).LanguageCode == "th", "Windows culture auto");
                }
                finally { System.Threading.Thread.CurrentThread.CurrentUICulture = previous; }
                List<UiLanguageChoice> choices = UiLocale.LanguageChoices(appRoot);
                Check(choices[0].Code == "auto", "auto choice first");
                Check(choices.Single(choice => choice.Code == "he").DisplayName.Contains("English fallback"), "fallback disclosed");
                Check(choices.Single(choice => choice.Code == "th").HasTranslation, "translated Thai choice");
                Check(choices.Single(choice => choice.Code == "zh-Hant").HasTranslation, "Traditional Chinese choice");
                Check(choices.Single(choice => choice.Code == "zh-Hans").HasTranslation, "Simplified Chinese choice");

                string dataFolder = Path.Combine(testRoot, "data");
                Directory.CreateDirectory(dataFolder);
                string preferencesPath = Path.Combine(dataFolder, "ui-preferences.json");
                string updaterSettingsPath = Path.Combine(testRoot, "settings.json");
                const string updaterSettings = "{\"updateAt\":\"08:00\",\"doNotChange\":true}";
                File.WriteAllText(updaterSettingsPath, updaterSettings, Encoding.UTF8);
                UiPreferences preferences = UiPreferences.Load(testRoot);
                Check(preferences.Language == "auto" && preferences.FontFamily == "auto" && preferences.FontSize == 10F, "default preferences");
                Check(!File.Exists(preferencesPath), "load does not write missing preferences");
                preferences.Language = "ja-JP";
                preferences.FontFamily = "Segoe UI";
                preferences.FontSize = 12F;
                preferences.Save(testRoot);
                UiPreferences reloaded = UiPreferences.Load(testRoot);
                Check(reloaded.Language == "ja-JP" && reloaded.FontFamily == "Segoe UI" && reloaded.FontSize == 12F, "preferences persist");
                preferences.Language = "th";
                preferences.Save(testRoot);
                Check(UiPreferences.Load(testRoot).Language == "th", "atomic overwrite works");
                Check(File.ReadAllText(updaterSettingsPath, Encoding.UTF8) == updaterSettings, "updater settings untouched");
                File.WriteAllText(preferencesPath, "{invalid JSON", Encoding.UTF8);
                Check(UiPreferences.Load(testRoot).Language == "auto", "invalid JSON recovery");
                Check(File.ReadAllText(preferencesPath, Encoding.UTF8) == "{invalid JSON", "read does not mutate invalid file");
                File.WriteAllText(preferencesPath, "{\"language\":\"../../outside\",\"fontFamily\":\"bad\\nfont\",\"fontSize\":100}", Encoding.UTF8);
                preferences = UiPreferences.Load(testRoot);
                Check(preferences.Language == "auto" && preferences.FontFamily == "auto" && preferences.FontSize == 14F, "invalid fields sanitized");
                preferences.FontSize = Single.NaN;
                preferences.Save(testRoot);
                Check(UiPreferences.Load(testRoot).FontSize == 10F, "NaN preference recovery");
                Check(UiFontCatalog.InstalledNames().Count > 0, "installed fonts discovered");
                Check(!UiFontCatalog.InstalledNames().Any(name => name == "Marlett" || name.StartsWith("Wingdings")), "symbol fonts excluded");
                foreach (string language in new[] { "en", "th", "ja", "ko", "zh-Hans", "zh-Hant", "ar", "hi" })
                    using (Font font = UiFontCatalog.Create("auto", 10F, language, true))
                        Check(font.SizeInPoints == 10F && font.Style == FontStyle.Regular, "regular font " + language);
                using (Font font = UiFontCatalog.Create("unknown font", Single.NaN, "th", true))
                    Check(font.SizeInPoints == 10F, "invalid font recovery");
                Console.WriteLine("PASS: " + checks + " assertions; " + Directory.GetFiles(Path.Combine(appRoot, "languages"), "*.json").Length + " packs; " + baseline.Count + " keys per pack.");
                Console.WriteLine("Preference test data: " + testRoot);
                return 0;
            }
            catch (Exception error)
            {
                Console.Error.WriteLine(error);
                return 1;
            }
        }
    }
}
