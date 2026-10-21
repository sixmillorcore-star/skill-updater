using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace CodexSkillUpdater
{
    internal sealed class AppRelease
    {
        public string Version { get; internal set; }
        public string Tag { get; internal set; }
        public string AssetName { get; internal set; }
        public string AssetUrl { get; internal set; }
        public string Sha256 { get; internal set; }
        public long Size { get; internal set; }
        public string ReleaseUrl { get; internal set; }
    }

    // Release packages are trusted only after GitHub's SHA-256 digest, the package
    // manifest and the complete file set agree. No GitHub login or token is used.
    internal sealed class AppUpdateClient
    {
        public const string CurrentVersion = "1.1.0";
        internal const string Repository = "sixmillorcore-star/skill-updater";
        internal const string ManifestName = "app-update-manifest.json";
        internal const long MaximumArchiveBytes = 32L * 1024 * 1024;
        private const long MaximumExpandedBytes = 64L * 1024 * 1024;
        private const long MaximumEntryBytes = 16L * 1024 * 1024;
        private const int MaximumEntries = 128;
        private const int MaximumMetadataBytes = 2 * 1024 * 1024;
        private readonly string appRoot;
        private static readonly Regex VersionPattern = new Regex(@"^(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})$", RegexOptions.CultureInvariant);
        private static readonly Regex HashPattern = new Regex(@"^[a-fA-F0-9]{64}$", RegexOptions.CultureInvariant);
        private static readonly Regex LanguagePathPattern = new Regex(@"^languages/[a-zA-Z0-9-]+\.json$", RegexOptions.CultureInvariant);
        private static readonly HashSet<string> RootFiles = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "SkillUpdater.exe", "Backend.ps1", "Discovery.ps1", "ClaudeSupport.ps1", "Apply-AppUpdate.ps1",
            "Install.ps1", "Uninstall.ps1", "Install.cmd", "Uninstall.cmd", "settings.json",
            "app-icon.ico", "app-icon.png", "README.txt"
        };

        public AppUpdateClient(string applicationRoot)
        {
            if (String.IsNullOrWhiteSpace(applicationRoot)) throw new ArgumentException("The application folder is required.");
            appRoot = Path.GetFullPath(applicationRoot).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        }

        public AppRelease Check()
        {
            string endpoint = "https://api.github.com/repos/" + Repository + "/releases/latest";
            using (WebResponse response = OpenHttps(new Uri(endpoint), true))
            using (Stream stream = response.GetResponseStream())
            {
                return ParseReleaseJson(Encoding.UTF8.GetString(ReadBounded(stream, MaximumMetadataBytes)), CurrentVersion);
            }
        }

        public string Prepare(AppRelease release)
        {
            ValidateRelease(release, CurrentVersion);
            string staging = CreateStagingDirectory();
            try
            {
                string archive = Path.Combine(staging, release.AssetName);
                using (WebResponse response = OpenHttps(new Uri(release.AssetUrl), false))
                {
                    if (response.ContentLength > MaximumArchiveBytes || (response.ContentLength >= 0 && response.ContentLength != release.Size))
                        throw new InvalidDataException("The update download size differs from its release metadata.");
                    using (Stream source = response.GetResponseStream())
                    using (FileStream target = new FileStream(archive, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                        CopyBounded(source, target, release.Size);
                }
                return VerifyAndExtract(archive, release, staging);
            }
            catch
            {
                DeleteFailedStaging(staging);
                throw;
            }
        }

        // Used by offline regression tests and the package validation command.
        internal string PrepareArchive(string archive, AppRelease release)
        {
            ValidateRelease(release, CurrentVersion);
            string staging = CreateStagingDirectory();
            try { return VerifyAndExtract(archive, release, staging); }
            catch { DeleteFailedStaging(staging); throw; }
        }

        internal static AppRelease ParseReleaseJson(string json, string currentVersion)
        {
            if (json == null || Encoding.UTF8.GetByteCount(json) > MaximumMetadataBytes)
                throw new InvalidDataException("The release response is too large.");
            JavaScriptSerializer serializer = new JavaScriptSerializer { MaxJsonLength = MaximumMetadataBytes, RecursionLimit = 32 };
            Dictionary<string, object> metadata = serializer.DeserializeObject(json) as Dictionary<string, object>;
            if (metadata == null) throw new InvalidDataException("GitHub returned invalid release metadata.");
            if (ReadBoolean(metadata, "draft") || ReadBoolean(metadata, "prerelease")) return null;
            string tag = ReadString(metadata, "tag_name");
            Version parsedVersion;
            if (!tag.StartsWith("v", StringComparison.Ordinal) || !TryParseVersion(tag.Substring(1), out parsedVersion))
                throw new InvalidDataException("The release does not have a supported stable version.");
            Version installed;
            if (!TryParseVersion(currentVersion, out installed)) throw new InvalidDataException("The installed app version is invalid.");
            if (parsedVersion.CompareTo(installed) <= 0) return null;
            string version = tag.Substring(1);
            string assetName = "SkillUpdater-v" + version + "-windows.zip";
            object raw;
            object[] assets = metadata.TryGetValue("assets", out raw) ? raw as object[] : null;
            if (assets == null || assets.Length > MaximumEntries) throw new InvalidDataException("The release asset list is invalid.");
            AppRelease result = null;
            foreach (object item in assets)
            {
                Dictionary<string, object> asset = item as Dictionary<string, object>;
                if (asset == null || ReadString(asset, "name") != assetName) continue;
                if (result != null) throw new InvalidDataException("The release contains duplicate update archives.");
                if (ReadString(asset, "state") != "uploaded") throw new InvalidDataException("The update archive is not ready.");
                string digest = ReadString(asset, "digest");
                if (!digest.StartsWith("sha256:", StringComparison.Ordinal) || !HashPattern.IsMatch(digest.Substring(7)))
                    throw new InvalidDataException("The release archive has no SHA-256 digest.");
                long size;
                if (!asset.TryGetValue("size", out raw) || !Int64.TryParse(Convert.ToString(raw, CultureInfo.InvariantCulture), NumberStyles.None, CultureInfo.InvariantCulture, out size))
                    throw new InvalidDataException("The release archive size is invalid.");
                result = new AppRelease
                {
                    Version = version, Tag = tag, AssetName = assetName, AssetUrl = ReadString(asset, "browser_download_url"),
                    Sha256 = digest.Substring(7).ToLowerInvariant(), Size = size, ReleaseUrl = ReadString(metadata, "html_url")
                };
            }
            if (result == null) throw new InvalidDataException("This release does not contain the Windows update archive.");
            ValidateRelease(result, currentVersion);
            return result;
        }

        internal static bool TryParseVersion(string text, out Version version)
        {
            version = null;
            return text != null && VersionPattern.IsMatch(text) && Version.TryParse(text, out version);
        }

        internal static void ValidateRelease(AppRelease release, string installedVersion)
        {
            Version offered, installed;
            if (release == null || !TryParseVersion(release.Version, out offered) || !TryParseVersion(installedVersion, out installed) || offered.CompareTo(installed) <= 0)
                throw new InvalidDataException("The update version must be newer than the installed app.");
            string expectedName = "SkillUpdater-v" + release.Version + "-windows.zip";
            string expectedTag = "v" + release.Version;
            string releaseUrl = "https://github.com/" + Repository + "/releases/tag/" + expectedTag;
            string assetUrl = "https://github.com/" + Repository + "/releases/download/" + expectedTag + "/" + expectedName;
            if (release.Tag != expectedTag || release.AssetName != expectedName || release.ReleaseUrl != releaseUrl || release.AssetUrl != assetUrl)
                throw new InvalidDataException("The update does not belong to the official Skill Updater release.");
            if (release.Size <= 0 || release.Size > MaximumArchiveBytes || release.Sha256 == null || !HashPattern.IsMatch(release.Sha256))
                throw new InvalidDataException("The update archive metadata is invalid.");
        }

        private string VerifyAndExtract(string archive, AppRelease release, string staging)
        {
            FileInfo info = new FileInfo(archive);
            if (!info.Exists || info.Length != release.Size || info.Length > MaximumArchiveBytes || !HashEquals(HashFile(archive), release.Sha256))
                throw new InvalidDataException("The update archive failed its SHA-256 integrity check.");
            string packageParent = Path.Combine(staging, "package");
            string package = Path.Combine(packageParent, "SkillUpdater");
            Directory.CreateDirectory(package);
            HashSet<string> extracted = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            using (FileStream source = File.OpenRead(archive))
            using (ZipArchive zip = new ZipArchive(source, ZipArchiveMode.Read, false))
            {
                if (zip.Entries.Count == 0 || zip.Entries.Count > MaximumEntries) throw new InvalidDataException("The update archive has too many entries.");
                long expanded = 0;
                HashSet<string> allEntries = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (ZipArchiveEntry entry in zip.Entries)
                {
                    // Windows PowerShell 5.1 Compress-Archive writes backslashes;
                    // newer ZIP tools write forward slashes. Normalize before every
                    // allowlist, duplicate and containment check.
                    string name = entry.FullName.Replace('\\', '/');
                    bool directory = name.EndsWith("/", StringComparison.Ordinal);
                    if (!name.StartsWith("SkillUpdater/", StringComparison.Ordinal) || !allEntries.Add(name.TrimEnd('/')))
                        throw new InvalidDataException("The update archive contains an invalid or duplicate path.");
                    string relative = name.Substring("SkillUpdater/".Length).TrimEnd('/');
                    int attributes = entry.ExternalAttributes;
                    if (((attributes >> 16) & 0xF000) == 0xA000 || (attributes & (int)FileAttributes.ReparsePoint) != 0)
                        throw new InvalidDataException("Links are not allowed in the update archive.");
                    if (directory)
                    {
                        if (relative.Length != 0 && relative != "languages") throw new InvalidDataException("The update archive contains an unexpected directory.");
                        continue;
                    }
                    if (!IsAllowedFile(relative, true) || entry.Length <= 0 || entry.Length > MaximumEntryBytes)
                        throw new InvalidDataException("The update archive contains an unexpected file.");
                    expanded = checked(expanded + entry.Length);
                    if (expanded > MaximumExpandedBytes) throw new InvalidDataException("The expanded update is too large.");
                    string target = Path.GetFullPath(Path.Combine(package, relative.Replace('/', Path.DirectorySeparatorChar)));
                    if (!target.StartsWith(package + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                        throw new InvalidDataException("The update path escaped its package folder.");
                    Directory.CreateDirectory(Path.GetDirectoryName(target));
                    using (Stream input = entry.Open())
                    using (FileStream output = new FileStream(target, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                        CopyBounded(input, output, entry.Length);
                    extracted.Add(relative);
                }
            }
            ValidateManifest(package, release.Version, extracted);
            return package;
        }

        internal static void ValidateManifest(string package, string version, HashSet<string> actualFiles)
        {
            string manifestPath = Path.Combine(package, ManifestName);
            if (!File.Exists(manifestPath) || new FileInfo(manifestPath).Length > 65536)
                throw new InvalidDataException("The update package manifest is missing or too large.");
            JavaScriptSerializer serializer = new JavaScriptSerializer { MaxJsonLength = 65536, RecursionLimit = 8 };
            Dictionary<string, object> manifest = serializer.DeserializeObject(File.ReadAllText(manifestPath, Encoding.UTF8)) as Dictionary<string, object>;
            object raw;
            if (manifest == null || !manifest.TryGetValue("schemaVersion", out raw) || Convert.ToString(raw, CultureInfo.InvariantCulture) != "1" || ReadString(manifest, "version") != version)
                throw new InvalidDataException("The package manifest version does not match the release.");
            Dictionary<string, object> files = manifest.TryGetValue("files", out raw) ? raw as Dictionary<string, object> : null;
            if (files == null || files.Count == 0 || files.Count >= MaximumEntries) throw new InvalidDataException("The package file manifest is invalid.");
            HashSet<string> declared = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (KeyValuePair<string, object> item in files)
            {
                string hash = item.Value as string;
                if (!IsAllowedFile(item.Key, false) || !declared.Add(item.Key) || hash == null || !HashPattern.IsMatch(hash) || !actualFiles.Contains(item.Key))
                    throw new InvalidDataException("The package file manifest contains an invalid entry.");
                string file = Path.Combine(package, item.Key.Replace('/', Path.DirectorySeparatorChar));
                if (!File.Exists(file) || !HashEquals(HashFile(file), hash)) throw new InvalidDataException("An update file failed its SHA-256 integrity check.");
            }
            foreach (string required in RootFiles)
                if (!declared.Contains(required)) throw new InvalidDataException("The update package is missing a required application file.");
            if (!declared.Contains("languages/en.json")) throw new InvalidDataException("The update package is missing its English language pack.");
            declared.Add(ManifestName);
            if (!declared.SetEquals(actualFiles)) throw new InvalidDataException("The update archive does not match its complete file manifest.");
        }

        private static bool IsAllowedFile(string relative, bool allowManifest)
        {
            if (String.IsNullOrEmpty(relative)) return false;
            if (RootFiles.Contains(relative) || (allowManifest && relative == ManifestName)) return true;
            if (!LanguagePathPattern.IsMatch(relative)) return false;
            string stem = relative.Substring("languages/".Length, relative.Length - "languages/".Length - ".json".Length);
            // Windows treats these names as devices even with a file extension.
            return !Regex.IsMatch(stem, @"^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        }

        private string CreateStagingDirectory()
        {
            string data = Path.Combine(appRoot, "data");
            string updates = Path.Combine(data, "app-updates");
            EnsureOrdinaryDirectory(data);
            EnsureOrdinaryDirectory(updates);
            string staging = Path.Combine(updates, Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(staging);
            return staging;
        }

        private static void EnsureOrdinaryDirectory(string path)
        {
            if (Directory.Exists(path) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("The app update folder cannot be a link or junction.");
            Directory.CreateDirectory(path);
        }

        private void DeleteFailedStaging(string staging)
        {
            try
            {
                string updates = Path.Combine(appRoot, "data", "app-updates") + Path.DirectorySeparatorChar;
                string path = Path.GetFullPath(staging);
                if (path.StartsWith(updates, StringComparison.OrdinalIgnoreCase) && Directory.Exists(path) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) == 0)
                    Directory.Delete(path, true);
            }
            catch { /* A failed cleanup must not hide the original update error. */ }
        }

        private static WebResponse OpenHttps(Uri uri, bool metadata)
        {
            ServicePointManager.SecurityProtocol |= (SecurityProtocolType)3072; // TLS 1.2 on .NET Framework.
            for (int redirects = 0; redirects <= 4; redirects++)
            {
                if (uri.Scheme != Uri.UriSchemeHttps || !String.IsNullOrEmpty(uri.UserInfo) || !uri.IsDefaultPort ||
                    (metadata ? uri.Host != "api.github.com" : uri.Host != "github.com" && uri.Host != "release-assets.githubusercontent.com" && uri.Host != "objects.githubusercontent.com"))
                    throw new InvalidDataException("The update download redirected outside GitHub HTTPS.");
                HttpWebRequest request = (HttpWebRequest)WebRequest.Create(uri);
                request.Method = "GET";
                request.UserAgent = "SkillUpdater/" + CurrentVersion;
                request.Accept = metadata ? "application/vnd.github+json" : "application/octet-stream";
                if (metadata) request.Headers["X-GitHub-Api-Version"] = "2022-11-28";
                request.AllowAutoRedirect = false;
                request.Timeout = 30000;
                request.ReadWriteTimeout = 30000;
                HttpWebResponse response = (HttpWebResponse)request.GetResponse();
                int status = (int)response.StatusCode;
                if (status >= 300 && status < 400)
                {
                    string location = response.Headers[HttpResponseHeader.Location];
                    response.Dispose();
                    if (metadata || redirects == 4 || String.IsNullOrWhiteSpace(location)) throw new InvalidDataException("GitHub returned an unsupported update redirect.");
                    uri = new Uri(uri, location);
                    continue;
                }
                if (status != 200) { response.Dispose(); throw new WebException("GitHub did not return the requested release file."); }
                return response;
            }
            throw new WebException("Too many update redirects.");
        }

        private static byte[] ReadBounded(Stream stream, int maximum)
        {
            using (MemoryStream memory = new MemoryStream())
            {
                byte[] buffer = new byte[16384];
                int read;
                while ((read = stream.Read(buffer, 0, buffer.Length)) != 0)
                {
                    if (memory.Length + read > maximum) throw new InvalidDataException("The release response is too large.");
                    memory.Write(buffer, 0, read);
                }
                return memory.ToArray();
            }
        }

        private static void CopyBounded(Stream source, Stream destination, long expectedBytes)
        {
            byte[] buffer = new byte[65536];
            long total = 0;
            int read;
            while ((read = source.Read(buffer, 0, buffer.Length)) != 0)
            {
                total += read;
                if (total > expectedBytes) throw new InvalidDataException("The update file is larger than expected.");
                destination.Write(buffer, 0, read);
            }
            if (total != expectedBytes) throw new InvalidDataException("The update file download is incomplete.");
        }

        internal static string HashFile(string path)
        {
            using (SHA256 algorithm = SHA256.Create())
            using (FileStream stream = File.OpenRead(path))
                return BitConverter.ToString(algorithm.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
        }

        private static bool HashEquals(string left, string right)
        {
            if (left == null || right == null || left.Length != right.Length) return false;
            int difference = 0;
            for (int i = 0; i < left.Length; i++) difference |= Char.ToLowerInvariant(left[i]) ^ Char.ToLowerInvariant(right[i]);
            return difference == 0;
        }

        private static string ReadString(Dictionary<string, object> data, string key)
        {
            object value;
            return data.TryGetValue(key, out value) && value is string ? (string)value : String.Empty;
        }

        private static bool ReadBoolean(Dictionary<string, object> data, string key)
        {
            object value;
            if (!data.TryGetValue(key, out value) || !(value is bool)) throw new InvalidDataException("The release metadata is incomplete.");
            return (bool)value;
        }
    }
}
