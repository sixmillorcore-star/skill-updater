using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Web.Script.Serialization;
using CodexSkillUpdater;

internal static class AppUpdateTests
{
    private static int assertions;
    private static string testRoot;
    private static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
    private static readonly string[] Required = {
        "SkillUpdater.exe", "Backend.ps1", "Discovery.ps1", "ClaudeSupport.ps1", "Apply-AppUpdate.ps1",
        "Install.ps1", "Uninstall.ps1", "Install.cmd", "Uninstall.cmd", "settings.json",
        "app-icon.ico", "app-icon.png", "README.txt", "languages/en.json"
    };

    private static int Main(string[] args)
    {
        testRoot = args[0];
        try
        {
            Version parsed;
            foreach (string text in new[] { "0.0.0", "1.1.0", "1.10.3", "9999.9999.9999" })
                Assert(AppUpdateClient.TryParseVersion(text, out parsed), "Stable version " + text);
            foreach (string text in new[] { null, "", "1.1", "v1.1.0", "01.1.0", "1.1.00", "1.1.0-beta", "1.1.0+build", "10000.0.0", "1.2.3.4", "-1.0.0", " 1.1.0" })
                Assert(!AppUpdateClient.TryParseVersion(text, out parsed), "Reject version " + text);
            Assert(AppUpdateClient.ParseReleaseJson(ReleaseJson("1.2.3", null), "1.1.0").Version == "1.2.3", "Newer stable release found");
            Assert(AppUpdateClient.ParseReleaseJson(ReleaseJson("1.1.0", null), "1.1.0") == null, "Same version ignored");
            Assert(AppUpdateClient.ParseReleaseJson(ReleaseJson("1.0.0", null), "1.1.0") == null, "Downgrade ignored");
            Assert(AppUpdateClient.ParseReleaseJson(ReleaseJson("1.10.0", null), "1.9.0").Version == "1.10.0", "Compare versions numerically");
            Assert(AppUpdateClient.ParseReleaseJson(ReleaseJson("1.2.3", delegate(Dictionary<string, object> r) { r["draft"] = true; }), "1.1.0") == null, "Draft ignored");
            Assert(AppUpdateClient.ParseReleaseJson(ReleaseJson("1.2.3", delegate(Dictionary<string, object> r) { r["prerelease"] = true; }), "1.1.0") == null, "Prerelease ignored");
            RejectMetadata("HTTP asset", delegate(Dictionary<string, object> r) { Asset(r)["browser_download_url"] = "http://github.com/" + AppUpdateClient.Repository + "/releases/download/v1.2.3/SkillUpdater-v1.2.3-windows.zip"; });
            RejectMetadata("Wrong repository", delegate(Dictionary<string, object> r) { Asset(r)["browser_download_url"] = "https://github.com/attacker/skill-updater/releases/download/v1.2.3/SkillUpdater-v1.2.3-windows.zip"; });
            RejectMetadata("Query append", delegate(Dictionary<string, object> r) { Asset(r)["browser_download_url"] = Convert.ToString(Asset(r)["browser_download_url"]) + "?extra=true"; });
            RejectMetadata("Wrong release URL", delegate(Dictionary<string, object> r) { r["html_url"] = "https://example.com"; });
            RejectMetadata("Asset absent", delegate(Dictionary<string, object> r) { r["assets"] = new object[0]; });
            RejectMetadata("Duplicate assets", delegate(Dictionary<string, object> r) { r["assets"] = new object[] { Asset(r), Asset(r) }; });
            RejectMetadata("Missing digest", delegate(Dictionary<string, object> r) { Asset(r).Remove("digest"); });
            RejectMetadata("Invalid digest", delegate(Dictionary<string, object> r) { Asset(r)["digest"] = "sha256:not-a-hash"; });
            RejectMetadata("Wrong hash algorithm", delegate(Dictionary<string, object> r) { Asset(r)["digest"] = "sha1:" + new string('a', 64); });
            RejectMetadata("Pending upload", delegate(Dictionary<string, object> r) { Asset(r)["state"] = "new"; });
            RejectMetadata("Archive too large", delegate(Dictionary<string, object> r) { Asset(r)["size"] = AppUpdateClient.MaximumArchiveBytes + 1; });
            RejectMetadata("Archive empty", delegate(Dictionary<string, object> r) { Asset(r)["size"] = 0; });
            RejectMetadata("Unstable tag", delegate(Dictionary<string, object> r) { r["tag_name"] = "v1.2.3-beta"; });
            RejectMetadata("Missing draft flag", delegate(Dictionary<string, object> r) { r.Remove("draft"); });

            string app = Path.Combine(testRoot, "installed");
            Directory.CreateDirectory(Path.Combine(app, "data"));
            File.WriteAllText(Path.Combine(app, "settings.json"), "personal settings");
            File.WriteAllText(Path.Combine(app, "install-state.json"), "personal installation");
            File.WriteAllText(Path.Combine(app, "data", "ui-preferences.json"), "personal appearance");
            AppUpdateClient client = new AppUpdateClient(app);
            string good = BuildArchive("valid", null, null, null);
            AppRelease goodRelease = ReleaseFor(good);
            string package = client.PrepareArchive(good, goodRelease);
            Assert(package.StartsWith(Path.Combine(app, "data", "app-updates") + Path.DirectorySeparatorChar), "Package is staged under app update data folder");
            Assert(File.Exists(Path.Combine(package, "SkillUpdater.exe")), "Verified executable extracted");
            Assert(File.Exists(Path.Combine(package, AppUpdateClient.ManifestName)), "Manifest extracted");
            Assert(File.ReadAllText(Path.Combine(app, "settings.json")) == "personal settings", "Personal settings preserved");
            Assert(File.ReadAllText(Path.Combine(app, "install-state.json")) == "personal installation", "Installation state preserved");
            Assert(File.ReadAllText(Path.Combine(app, "data", "ui-preferences.json")) == "personal appearance", "Appearance preserved");
            string windowsArchive = BuildArchive("windows-separators", null, null, null, true);
            string windowsPackage = client.PrepareArchive(windowsArchive, ReleaseFor(windowsArchive));
            Assert(File.Exists(Path.Combine(windowsPackage, "languages", "en.json")), "Windows PowerShell backslash ZIP entries are accepted");
            AppRelease badHash = ReleaseFor(good); badHash.Sha256 = new string('0', 64);
            Reject(delegate { client.PrepareArchive(good, badHash); }, "Bad download checksum");
            AppRelease wrongSize = ReleaseFor(good); wrongSize.Size++;
            Reject(delegate { client.PrepareArchive(good, wrongSize); }, "Wrong download length");
            RejectArchive(client, "traversal", delegate(Dictionary<string, byte[]> f) { f["../escaped.txt"] = Bytes("bad"); }, null, null);
            RejectArchive(client, "windows-traversal", delegate(Dictionary<string, byte[]> f) { f["..\\escaped.txt"] = Bytes("bad"); }, null, null);
            RejectArchive(client, "absolute", delegate(Dictionary<string, byte[]> f) { f["C:/escaped.txt"] = Bytes("bad"); }, null, null);
            RejectArchive(client, "backslash", delegate(Dictionary<string, byte[]> f) { f["languages\\fr.json"] = Bytes("bad"); }, null, null);
            RejectArchive(client, "duplicate-case", delegate(Dictionary<string, byte[]> f) { f["BACKEND.PS1"] = Bytes("duplicate"); }, null, null);
            RejectArchive(client, "mixed-separator-duplicate", delegate(Dictionary<string, byte[]> f) { f["languages\\en.json"] = Bytes("duplicate"); }, null, null);
            RejectArchive(client, "unexpected-personal-file", delegate(Dictionary<string, byte[]> f) { f["data/ui-preferences.json"] = Bytes("bad"); }, null, null);
            RejectArchive(client, "windows-device-name", delegate(Dictionary<string, byte[]> f) { f["languages/CON.json"] = Bytes("bad"); }, null, null);
            RejectArchive(client, "empty-file", delegate(Dictionary<string, byte[]> f) { f["README.txt"] = new byte[0]; }, null, null);
            RejectArchive(client, "extra-file", delegate(Dictionary<string, byte[]> f) { f["languages/fr.json"] = Bytes("extra"); }, delegate(Dictionary<string, object> m) { ((Dictionary<string, object>)m["files"]).Remove("languages/fr.json"); }, null);
            RejectArchive(client, "missing-required", delegate(Dictionary<string, byte[]> f) { f.Remove("README.txt"); }, null, null);
            RejectArchive(client, "wrong-file-hash", null, delegate(Dictionary<string, object> m) { ((Dictionary<string, object>)m["files"])["Backend.ps1"] = new string('0', 64); }, null);
            RejectArchive(client, "wrong-manifest-version", null, delegate(Dictionary<string, object> m) { m["version"] = "1.2.4"; }, null);
            RejectArchive(client, "wrong-manifest-schema", null, delegate(Dictionary<string, object> m) { m["schemaVersion"] = 2; }, null);
            RejectArchive(client, "manifest-traversal", null, delegate(Dictionary<string, object> m) { ((Dictionary<string, object>)m["files"])["../outside"] = new string('a', 64); }, null);
            RejectArchive(client, "manifest-case-duplicate", null, delegate(Dictionary<string, object> m) { ((Dictionary<string, object>)m["files"])["BACKEND.PS1"] = ((Dictionary<string, object>)m["files"])["Backend.ps1"]; }, null);
            RejectArchive(client, "symlink", null, null, "SkillUpdater.exe");
            RejectArchive(client, "entry-size-bomb", delegate(Dictionary<string, byte[]> f) { f["app-icon.png"] = new byte[17 * 1024 * 1024]; }, null, null);
            RejectArchive(client, "entry-count-bomb", delegate(Dictionary<string, byte[]> f) { for (int i = 0; i < 130; i++) f["languages/test-" + i + ".json"] = Bytes("{}"); }, null, null);
            Assert(Directory.GetDirectories(Path.Combine(app, "data", "app-updates")).Length == 2, "Failed packages are removed and verified packages are retained");
            Assert(!File.Exists(Path.Combine(app, "data", "app-updates", "escaped.txt")), "Traversal did not write outside staging package");
            Assert(!File.Exists(Path.Combine(testRoot, "escaped.txt")), "Traversal did not write outside application folder");
            Console.WriteLine("App update engine passed " + assertions + " assertions (offline release and hostile ZIP fixtures).");
            if (args.Length > 1 && args[1] == "--live")
            {
                AppRelease live = client.Check();
                Console.WriteLine("Live GitHub release check: " + (live == null ? "installed version is current" : "new version " + live.Version));
            }
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error); return 1; }
    }

    private static void RejectMetadata(string name, Action<Dictionary<string, object>> mutate)
    {
        Reject(delegate { AppUpdateClient.ParseReleaseJson(ReleaseJson("1.2.3", mutate), "1.1.0"); }, name);
    }

    private static Dictionary<string, object> Asset(Dictionary<string, object> release)
    {
        return (Dictionary<string, object>)((object[])release["assets"])[0];
    }

    private static string ReleaseJson(string version, Action<Dictionary<string, object>> mutate)
    {
        string tag = "v" + version;
        string asset = "SkillUpdater-" + tag + "-windows.zip";
        Dictionary<string, object> r = new Dictionary<string, object>
        {
            {"draft", false}, {"prerelease", false}, {"tag_name",tag},
            {"html_url", "https://github.com/" + AppUpdateClient.Repository + "/releases/tag/" + tag},
            {"assets", new object[] { new Dictionary<string, object> {
                {"name", asset}, {"state", "uploaded"}, {"size", 100}, {"digest", "sha256:" + new string('a', 64)},
                {"browser_download_url", "https://github.com/" + AppUpdateClient.Repository + "/releases/download/" + tag + "/" + asset}
            }}}
        };
        if (mutate != null) mutate(r);
        return Json.Serialize(r);
    }

    private static AppRelease ReleaseFor(string archive)
    {
        AppRelease release = AppUpdateClient.ParseReleaseJson(ReleaseJson("1.2.3", null), "1.1.0");
        release.Size = new FileInfo(archive).Length;
        release.Sha256 = AppUpdateClient.HashFile(archive);
        return release;
    }

    private static string BuildArchive(string name, Action<Dictionary<string, byte[]>> mutateFiles, Action<Dictionary<string, object>> mutateManifest, string symlink, bool windowsSeparators = false)
    {
        Dictionary<string, byte[]> files = new Dictionary<string, byte[]>(StringComparer.Ordinal);
        foreach (string file in Required) files[file] = Bytes("fixture file " + file);
        if (mutateFiles != null) mutateFiles(files);
        Dictionary<string, object> hashes = new Dictionary<string, object>();
        foreach (KeyValuePair<string, byte[]> file in files) hashes[file.Key] = Hash(file.Value);
        Dictionary<string, object> manifest = new Dictionary<string, object> { {"schemaVersion",1}, {"version","1.2.3"}, {"files",hashes} };
        if (mutateManifest != null) mutateManifest(manifest);
        files[AppUpdateClient.ManifestName] = Bytes(Json.Serialize(manifest));
        string archive = Path.Combine(testRoot, name + ".zip");
        using (FileStream stream = new FileStream(archive, FileMode.CreateNew))
        using (ZipArchive zip = new ZipArchive(stream, ZipArchiveMode.Create, false))
        {
            foreach (KeyValuePair<string, byte[]> item in files)
            {
                string entryName = "SkillUpdater/" + item.Key;
                if (windowsSeparators) entryName = entryName.Replace('/', '\\');
                ZipArchiveEntry entry = zip.CreateEntry(entryName, CompressionLevel.Optimal);
                if (item.Key == symlink) entry.ExternalAttributes = unchecked((int)0xA1FF0000);
                using (Stream output = entry.Open()) output.Write(item.Value, 0, item.Value.Length);
            }
        }
        return archive;
    }

    private static void RejectArchive(AppUpdateClient client, string name, Action<Dictionary<string, byte[]>> files, Action<Dictionary<string, object>> manifest, string symlink)
    {
        string archive = BuildArchive(name, files, manifest, symlink);
        Reject(delegate { client.PrepareArchive(archive, ReleaseFor(archive)); }, name);
    }

    private static byte[] Bytes(string value) { return Encoding.UTF8.GetBytes(value); }
    private static string Hash(byte[] bytes)
    {
        using (SHA256 algorithm = SHA256.Create()) return BitConverter.ToString(algorithm.ComputeHash(bytes)).Replace("-", "").ToLowerInvariant();
    }
    private static void Assert(bool condition, string name)
    {
        assertions++;
        if (!condition) throw new Exception("Assertion failed: " + name);
    }
    private static void Reject(Action action, string name)
    {
        assertions++;
        try { action(); }
        catch (InvalidDataException) { return; }
        throw new Exception("Invalid update was accepted: " + name);
    }
}
