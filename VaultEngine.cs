using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Net;
using System.Net.Sockets;
using System.Security.AccessControl;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;

namespace FolderLock {
    public sealed class VaultInfo {
        public int Version = 2;
        public string Id;
        public string Salt;
        public string State = "initializing";
        public string FilenameEncoding;
    }
    public sealed class NameStep { public string Source; public string Destination; public bool Directory; }
    public sealed class NameMigration { public int Next; public List<NameStep> Steps = new List<NameStep>(); }
    public sealed class Work {
        public volatile string Message = "准备中…";
        public volatile bool CancelRequested;
        public volatile bool Done;
        public string Error;
        public Mount OpenedMount;
        public void Run(Action action) {
            Task.Factory.StartNew(() => {
                try { action(); } catch (Exception e) { Error = e.Message; }
                finally { Done = true; }
            });
        }
    }
    // rclone owns the cryptographic format. No passwords or obscured passwords are persisted.
    public sealed class VaultEngine {
        public const string InternalName = ".folderlock";
        readonly string exe;
        static JavaScriptSerializer Json { get { return new JavaScriptSerializer { MaxJsonLength = 67108864 }; } }
        public VaultEngine(string rclone) { exe = Path.GetFullPath(rclone); }
        static FileStream Gate(string root) {
            using (Portal.Guard(root)) return new FileStream(Path.Combine(Store(root), "operation.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        }
        internal static string Store(string root) { return Portal.Configured(root) ? Portal.Storage(root) : Path.Combine(root, InternalName); }
        public static string StoragePath(string root) { return Store(root); }
        internal static string Long(string path) { return !path.StartsWith(@"\\?\") ? @"\\?\" + path : path; }
        internal static string Unlong(string path) { return path.StartsWith(@"\\?\") ? path.Substring(4) : path; }
        static string InfoFile(string root) { return Path.Combine(Store(root), "vault.json"); }
        internal static void AtomicJson(string path, object value) {
            string temp = path + ".new";
            using (var f = new FileStream(temp, FileMode.Create, FileAccess.Write, FileShare.None)) {
                byte[] data = Encoding.UTF8.GetBytes(Json.Serialize(value)); f.Write(data, 0, data.Length); f.Flush(true);
            }
            if (File.Exists(path)) File.Replace(temp, path, null); else File.Move(temp, path);
        }
        public static VaultInfo Read(string root) {
            CheckStorage(root);
            var info = Json.Deserialize<VaultInfo>(File.ReadAllText(InfoFile(root), Encoding.UTF8));
            if (info == null || (info.Version != 1 && info.Version != 2) || String.IsNullOrEmpty(info.Id) ||
                String.IsNullOrEmpty(info.Salt) || !new[] {"initializing", "converting", "ready"}.Contains(info.State))
                throw new IOException("保险箱配置损坏或版本不受支持。请勿删除原目录中的 .folderlock。");
            return info;
        }
        public static bool HasWriteCache(string root) {
            string cache = Path.Combine(Store(root), "write-cache");
            return File.Exists(Path.Combine(Store(root), "session.json")) || (Directory.Exists(Long(cache)) && Directory.GetFiles(Long(cache), "*", SearchOption.AllDirectories).Length != 0);
        }
        static void ValidateRecoveryCache(string cache) {
            string data = Path.Combine(cache, "vfs"), meta = Path.Combine(cache, "vfsMeta");
            if (!Directory.Exists(Long(data))) return;
            foreach (string name in Directory.GetFiles(Long(data), "*", SearchOption.AllDirectories).Select(Unlong)) {
                string info = Path.Combine(meta, name.Substring(data.Length + 1));
                if (!File.Exists(Long(info))) throw new IOException("恢复缓存缺少元数据，已原样保留。请勿手动清理 .folderlock/write-cache。");
                var state = Json.Deserialize<Dictionary<string,object>>(File.ReadAllText(Long(info), Encoding.UTF8));
                if (state == null || !state.ContainsKey("Dirty") || !state.ContainsKey("Rs") || !state.ContainsKey("Size"))
                    throw new IOException("恢复缓存元数据损坏，已原样保留，未启动可能清理缓存的挂载服务。");
            }
        }
        void RecoverCompleteWrites(string root, Dictionary<string,string> env, Work work) {
            string cache = Path.Combine(Store(root), "write-cache"), sessionFile = Path.Combine(Store(root), "session.json");
            if (!File.Exists(sessionFile)) return;
            var session = Json.Deserialize<Dictionary<string,object>>(File.ReadAllText(sessionFile, Encoding.UTF8));
            if (!session.ContainsKey("DataRoot") || !session.ContainsKey("MetaRoot")) return;
            string data = Path.Combine(cache, (string)session["DataRoot"]), meta = Path.Combine(cache, (string)session["MetaRoot"]);
            foreach (string candidate in new[] {data, meta})
                if (!Path.GetFullPath(candidate).StartsWith(cache + "\\", StringComparison.OrdinalIgnoreCase) || candidate.Contains("..")) throw new IOException("恢复缓存路径不合法。");
            if (!Directory.Exists(Long(data))) return;
            var names = ExistingCacheNames(env);
            foreach (string file in Directory.GetFiles(Long(data), "*", SearchOption.AllDirectories).Select(Unlong)) {
                string relative = file.Substring(data.Length + 1), metadata = Path.Combine(meta, relative);
                var state = Json.Deserialize<Dictionary<string,object>>(File.ReadAllText(Long(metadata), Encoding.UTF8));
                if (!System.Convert.ToBoolean(state["Dirty"])) continue;
                using (var source = File.Open(Long(file), FileMode.Open, FileAccess.Read, FileShare.Read)) {
                    long size = source.Length;
                    var sequence = state["Rs"] as System.Collections.IEnumerable;
                    var ranges = sequence == null ? new object[0] : sequence.Cast<object>().ToArray();
                    bool full = size == 0;
                    if (ranges.Length == 1) {
                        var range = (Dictionary<string,object>)ranges[0];
                        full = System.Convert.ToInt64(range["Pos"]) == 0 && System.Convert.ToInt64(range["Size"]) == size;
                    }
                    // A newly-created file has no remote bytes to fill: sparse holes are zero.
                    // Existing partial caches are left to rclone to merge with untouched ciphertext.
                    if (!full && !String.IsNullOrEmpty(System.Convert.ToString(state["Fingerprint"]))) continue;
                    string logical = ResolveCacheName(relative, names);
                    work.Message = "恢复未提交修改并验证：" + logical;
                    byte[] hash; using (var sha = SHA256.Create()) hash = sha.ComputeHash(source);
                    WriteEncryptedFile(source, "fldata:" + logical, env);
                    VerifyContent("fldata:" + logical, env, hash, size);
                    FlushCipher(root, logical, env, File.GetLastWriteTimeUtc(Long(file)));
                }
                File.Delete(Long(file)); File.Delete(Long(metadata));
            }
        }
        public static bool HasPlaintext(string root) { return Portal.Configured(root) ? Portal.HasUnexpected(root) : Scan(root, false).Count != 0 || Scan(root, true).Count != 0; }
        static void CheckStorage(string root) {
            CheckStorageAt(Store(root), Portal.Configured(root));
        }
        static void CheckStorageAt(string store, bool portal) {
            if (!Directory.Exists(store)) return;
            var pending = new Stack<string>(); pending.Push(store);
            while (pending.Count > 0) {
                string path = pending.Pop();
                if (portal && path.Equals(Path.Combine(store, "view"), StringComparison.OrdinalIgnoreCase)) continue;
                if ((File.GetAttributes(Long(path)) & FileAttributes.ReparsePoint) != 0) throw new IOException("保险箱存储包含链接，已停止访问。");
                if (Directory.Exists(Long(path))) foreach (string child in Directory.GetFileSystemEntries(Long(path))) pending.Push(Unlong(child));
            }
        }
        static void Save(string root, VaultInfo info) {
            AtomicJson(InfoFile(root), info);
        }
        public static string Normalize(string input) {
            string root = Path.GetFullPath(input.Trim().Trim('"')).TrimEnd(Path.DirectorySeparatorChar);
            bool portal = Portal.Configured(root);
            if ((!Directory.Exists(root) && !portal) || root.StartsWith(@"\\") || root.Length <= 3)
                throw new IOException("请选择本机存在的普通文件夹，不能选择磁盘根目录或网络路径。");
            for (var d = new DirectoryInfo(root); d != null; d = d.Parent) {
                if (d.Name.EndsWith(".folderlock", StringComparison.OrdinalIgnoreCase) && File.Exists(Path.Combine(d.FullName, "vault.json")))
                    throw new IOException("请选择原访问目录，不能直接加密或挂载密文存储目录及其子目录。");
                if (d.FullName.Equals(root, StringComparison.OrdinalIgnoreCase) && portal) { Portal.ValidateRoot(root); }
                else if ((d.Attributes & FileAttributes.ReparsePoint) != 0)
                    throw new IOException("不支持链接、联接点或其下的目录。");
                else if (d.FullName != root && File.Exists(InfoFile(d.FullName))) throw new IOException("不能加密已有保险箱的子目录。");
            }
            ValidateLocation(root);
            return root;
        }
        static void ValidateLocation(string root) {
            string[] blocked = { Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), AppDomain.CurrentDomain.BaseDirectory };
            foreach (string b in blocked.Where(x => !String.IsNullOrEmpty(x))) {
                string p = Path.GetFullPath(b).TrimEnd('\\');
                bool exactOrAncestor = p.Equals(root, StringComparison.OrdinalIgnoreCase) || p.StartsWith(root + "\\", StringComparison.OrdinalIgnoreCase);
                bool systemChild = b != Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) && root.StartsWith(p + "\\", StringComparison.OrdinalIgnoreCase);
                if (exactOrAncestor || systemChild) throw new IOException("不能加密系统、配置、程序目录或其上级目录。");
            }
        }
        static List<string> Scan(string root, bool directories) {
            if (Portal.Configured(root)) { Portal.ValidateRoot(root); return new List<string>(); }
            var result = new List<string>(); var stack = new Stack<string>(); stack.Push(root);
            while (stack.Count != 0) {
                string dir = stack.Pop();
                foreach (string entry in Directory.GetFileSystemEntries(Long(dir))) {
                    string path = Unlong(entry);
                    if (dir == root && Path.GetFileName(path).Equals(InternalName, StringComparison.OrdinalIgnoreCase)) continue;
                    if (Path.GetFileName(path).Equals(InternalName, StringComparison.OrdinalIgnoreCase)) throw new IOException("目录内部含有另一个保险箱或保留名称 .folderlock。");
                    var attr = File.GetAttributes(Long(path));
                    if ((attr & FileAttributes.Directory) != 0 && Path.GetFileName(path).EndsWith(".folderlock", StringComparison.OrdinalIgnoreCase) && File.Exists(Path.Combine(path, "vault.json")))
                        throw new IOException("目录内部含有另一个保险箱存储目录，已停止。");
                    if ((attr & (FileAttributes.ReparsePoint | FileAttributes.Encrypted)) != 0)
                        throw new IOException("不支持链接、云占位文件或 EFS 文件：" + path);
                    if ((attr & FileAttributes.Directory) != 0) { stack.Push(path); if (directories) result.Add(path); }
                    else if (!directories) result.Add(path);
                }
            }
            return result;
        }
        static string Rel(string root, string path) { return path.Substring(root.Length + 1).Replace('\\', '/'); }
        // VFS cache paths use encoder.OS, whereas crypt remote paths use encoder.Standard.
        // Match rclone 1.75.2 lib/encoder/{os_windows,standard,encoder}.go, per component.
        // Keep Windows-only escapes out of the logical name (e.g. cache "\u201b？" -> "？").
        internal static string CacheStandardPath(string relative) {
            return String.Join("/", relative.Split('\\').Select(CacheStandardName));
        }
        static string DecodeCacheName(string name, bool windows) {
            const char quote = '\u201b';
            string raw;
            if (name == "．" || name == "．．") raw = name.Replace('．', '.');
            else if (name == "\u201b．" || name == "\u201b．\u201b．") raw = name.Replace("\u201b", "");
            else {
                string suffix = "";
                if (windows && (name.EndsWith("␠") || name.EndsWith("．"))) {
                    char last = name[name.Length - 1]; name = name.Substring(0, name.Length - 1);
                    if (name.EndsWith(quote.ToString())) { suffix = last.ToString(); name = name.Substring(0, name.Length - 1); }
                    else suffix = last == '␠' ? " " : ".";
                }
                var decoded = new StringBuilder(); bool quoted = false;
                for (int i = 0; i < name.Length; i++) {
                    char c = name[i];
                    if (c == quote && !quoted) { quoted = true; continue; }
                    if (c == quote || c == '␀' || (c > '␀' && c <= '␟') || c == '／' || (!windows && c == '␡') || (windows && "＜＞：＂＼｜？＊".IndexOf(c) >= 0)) {
                        decoded.Append(quoted ? c : c >= '␀' && c <= '␟' ? (char)(c - '␀') : c == '␡' ? (char)0x7f : (char)(c - 0xfee0));
                    } else {
                        // Invalid UTF-8 cache byte escapes cannot be represented by .NET paths.
                        // Retain such cache instead of silently substituting a different name.
                        byte ignored;
                        if (windows && quoted && i + 1 < name.Length && Byte.TryParse(name.Substring(i, 2), System.Globalization.NumberStyles.HexNumber, System.Globalization.CultureInfo.InvariantCulture, out ignored))
                            throw new IOException("缓存文件名含有无法恢复的字节编码，缓存已保留。");
                        if (quoted) decoded.Append(quote);
                        decoded.Append(c);
                    }
                    quoted = false;
                }
                if (quoted) decoded.Append(quote);
                raw = decoded.ToString() + suffix;
            }
            return raw;
        }
        static string CacheStandardName(string name) { return EncodeStandardName(DecodeCacheName(name, true)); }
        static string EncodeStandardName(string raw) {
            const char quote = '\u201b';
            if (raw == "." || raw == "..") return raw.Replace('.', '．');
            if (raw == "．" || raw == "．．") return String.Concat(raw.Select(c => quote.ToString() + c));
            var standard = new StringBuilder();
            foreach (char c in raw) {
                if (c == quote || c >= '␀' && c <= '␟' || c == '␡' || c == '／') standard.Append(quote);
                standard.Append(c <= 0x1f ? (char)('␀' + c) : c == 0x7f ? '␡' : c == '/' ? '／' : c);
            }
            return standard.ToString();
        }
        // A remote may contain a non-canonical Standard spelling (older conversion used
        // native names literally). Match its canonical form to retain the original name.
        internal Dictionary<string,string> ExistingCacheNames(Dictionary<string,string> env) {
            var names = new Dictionary<string,string>(StringComparer.Ordinal);
            var entries = Json.Deserialize<object[]>(Command(new[] {"lsjson", "fldata:", "--recursive", "--files-only", "--no-modtime", "--no-mimetype"}, env, null));
            foreach (Dictionary<string,object> entry in entries) {
                string original = (string)entry["Path"];
                string key = String.Join("/", original.Split('/').Select(n => EncodeStandardName(DecodeCacheName(n, false))));
                if (names.ContainsKey(key) && names[key] != original) throw new IOException("文件名的缓存编码存在冲突，已保留缓存，停止自动清理。");
                names[key] = original;
            }
            return names;
        }
        internal static string ResolveCacheName(string relative, Dictionary<string,string> names) {
            string canonical = CacheStandardPath(relative), original;
            return names.TryGetValue(canonical, out original) ? original : canonical;
        }
        public static string Quote(string value) {
            // CommandLineToArgvW escaping; never invoke a shell.
            var b = new StringBuilder("\""); int slashes = 0;
            foreach (char c in value) {
                if (c == '\\') { slashes++; continue; }
                if (c == '"') b.Append('\\', slashes * 2 + 1); else b.Append('\\', slashes);
                b.Append(c); slashes = 0;
            }
            b.Append('\\', slashes * 2); return b.Append('"').ToString();
        }
        Process Start(string[] args, Dictionary<string,string> env, bool input) {
            var psi = new ProcessStartInfo(exe) {
                Arguments = String.Join(" ", args.Concat(new[] {"--config", "", "--ask-password=false", "--log-level", "ERROR", "--retries", "1"}).Select(Quote)),
                UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = input,
                StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8
            };
            foreach (string k in psi.EnvironmentVariables.Keys.Cast<string>().ToArray())
                if (k.StartsWith("RCLONE_", StringComparison.OrdinalIgnoreCase)) psi.EnvironmentVariables.Remove(k);
            if (env != null) foreach (var kv in env) psi.EnvironmentVariables[kv.Key] = kv.Value;
            return Process.Start(psi);
        }
        public string Command(string[] args, Dictionary<string,string> env, string input) {
            using (var p = Start(args, env, input != null)) {
                var output = p.StandardOutput.ReadToEndAsync(); var errors = p.StandardError.ReadToEndAsync();
                if (input != null) { p.StandardInput.Write(input); p.StandardInput.Close(); }
                p.WaitForExit(); string error = errors.Result;
                if (p.ExitCode != 0) throw new IOException("rclone 操作失败：" + error);
                return output.Result.TrimEnd('\r', '\n');
            }
        }
        // Paths found by Windows are native names. Passing them back to rclone's local
        // backend can reinterpret fullwidth punctuation (e.g. U+FF1F) as escaped ASCII.
        // Stream the already-locked handle instead; only the logical encrypted destination
        // is passed as a path. This also covers recovery of native write-cache filenames.
        void WriteEncryptedFile(Stream source, string remote, Dictionary<string,string> env) {
            source.Position = 0;
            using (var p = Start(new[] {"rcat", remote, "--size", source.Length.ToString(System.Globalization.CultureInfo.InvariantCulture), "--local-no-preallocate"}, env, true)) {
                var output = p.StandardOutput.ReadToEndAsync(); var errors = p.StandardError.ReadToEndAsync();
                Exception inputError = null;
                try { source.CopyTo(p.StandardInput.BaseStream, 1024 * 1024); }
                catch (Exception e) { inputError = e; }
                finally { try { p.StandardInput.Close(); } catch (IOException e) { if (inputError == null) inputError = e; } }
                p.WaitForExit();
                if (p.ExitCode != 0) throw new IOException("密文写入失败，源文件已保留：" + errors.Result, inputError);
                if (inputError != null) throw new IOException("读取源文件或传输中断，源文件已保留。", inputError);
                // Drain both redirected streams before disposing the process.
                string ignored = output.Result;
            }
        }
        Dictionary<string,string> EnvironmentFor(string root, string password, VaultInfo info) {
            return EnvironmentForStore(Store(root), password, info);
        }
        Dictionary<string,string> EnvironmentForStore(string store, string password, VaultInfo info) {
            string secret = Command(new[] {"obscure", "-"}, null, password);
            string salt = Command(new[] {"obscure", "-"}, null, info.Salt);
            var env = new Dictionary<string,string>();
            foreach (string name in new[] {"FLDATA", "FLMETA"}) {
                string prefix = "RCLONE_CONFIG_" + name + "_";
                env[prefix + "TYPE"] = "crypt";
                env[prefix + "REMOTE"] = Path.Combine(store, name == "FLDATA" ? "data" : "keycheck");
                env[prefix + "PASSWORD"] = secret; env[prefix + "PASSWORD2"] = salt;
                env[prefix + "FILENAME_ENCRYPTION"] = "standard";
                env[prefix + "DIRECTORY_NAME_ENCRYPTION"] = "true";
                // The key-check remains base32 for compatibility with 2.0 vaults.
                env[prefix + "FILENAME_ENCODING"] = name == "FLDATA" ? (info.FilenameEncoding ?? "base32") : "base32";
            }
            return env;
        }
        static void ValidateEncoded(string encoded, string display) {
            if (encoded.Split('/').Any(x => x.Length > 255)) throw new IOException("加密后的单个文件名仍超过 NTFS 限制，请缩短此名称；源文件未改动：" + display);
        }
        static string DataPath(string root, string relative, string area = "data") {
            string[] components = relative.Split(new[] {'/', '\\'});
            if (components.Any(x => x.Length == 0 || x == "." || x == ".." || x.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)) throw new IOException("密文路径校验失败。");
            return Path.Combine(Path.Combine(Store(root), area), String.Join("\\", components));
        }
        // Change only the text encoding of existing encrypted names. Contents and keys
        // stay identical. Persist a resumable, bottom-up rename journal before each change.
        void UpgradeNames(string root, string password, VaultInfo info, Work work) {
            string journal = Path.Combine(Store(root), "name-migration.json");
            if (info.FilenameEncoding == "base32768" && !File.Exists(journal)) return;
            if (HasWriteCache(root)) throw new IOException("旧保险箱含写入恢复缓存，不能转换文件名编码。");
            NameMigration plan;
            if (File.Exists(journal)) plan = Json.Deserialize<NameMigration>(File.ReadAllText(journal, Encoding.UTF8));
            else {
                plan = new NameMigration();
                string data = Path.Combine(Store(root), "data");
                if (Directory.Exists(data)) {
                    var oldEnv = EnvironmentFor(root, password, info);
                    var newInfo = new VaultInfo { Id = info.Id, Salt = info.Salt, FilenameEncoding = "base32768" };
                    var newEnv = EnvironmentFor(root, password, newInfo);
                    foreach (string path in Directory.GetFileSystemEntries(Long(data), "*", SearchOption.AllDirectories).Select(Unlong).OrderByDescending(x => x.Count(c => c == '\\'))) {
                        string leaf = Path.GetFileName(path);
                        string clear = Command(new[] {"backend", "decode", "fldata:", leaf}, oldEnv, null);
                        string encoded = Command(new[] {"backend", "encode", "fldata:", clear}, newEnv, null);
                        ValidateEncoded(encoded, "已有密文");
                        string relative = path.Substring(data.Length + 1);
                        string parent = Path.GetDirectoryName(relative);
                        string target = String.IsNullOrEmpty(parent) ? encoded : Path.Combine(parent, encoded);
                        if (relative != target) plan.Steps.Add(new NameStep { Source = relative, Destination = target, Directory = Directory.Exists(Long(path)) });
                    }
                }
                AtomicJson(journal, plan);
            }
            while (plan.Next < plan.Steps.Count) {
                var step = plan.Steps[plan.Next];
                string src = DataPath(root, step.Source), dst = DataPath(root, step.Destination);
                work.Message = "升级文件名兼容性：" + (plan.Next + 1) + "/" + plan.Steps.Count;
                bool srcExists = step.Directory ? Directory.Exists(Long(src)) : File.Exists(Long(src));
                bool dstExists = step.Directory ? Directory.Exists(Long(dst)) : File.Exists(Long(dst));
                if (srcExists && dstExists) throw new IOException("文件名升级遇到目标冲突，已停止且未覆盖数据。");
                if (srcExists) { if (step.Directory) Directory.Move(Long(src), Long(dst)); else File.Move(Long(src), Long(dst)); }
                else if (!dstExists) throw new IOException("文件名升级记录与磁盘不符，请保留整个保险箱。");
                plan.Next++; AtomicJson(journal, plan);
            }
            info.Version = 2; info.FilenameEncoding = "base32768"; Save(root, info); File.Delete(journal);
        }
        public void Authenticate(string root, string password) {
            var info = Read(root); VerifyKey(info, EnvironmentFor(root, password, info));
        }
        void VerifyKey(VaultInfo info, Dictionary<string,string> env) {
            if (Command(new[] {"cat", "flmeta:check"}, env, null) != "FolderLock:" + info.Id)
                throw new IOException("密码不正确或保险箱校验文件损坏。");
        }
        public Work BeginConvert(string path, string password) {
            var job = new Work(); job.Run(() => Convert(path, password, job)); return job;
        }
        public Work BeginConvert(string path, string password, string launcher) {
            var job = new Work(); job.Run(() => {
                string root = Normalize(path); Convert(root, password, job);
                if (!job.CancelRequested && Read(root).State == "ready") {
                    using (var transition = Portal.Guard(root)) {
                        using (var check = new FileStream(Path.Combine(Store(root), "operation.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None)) { }
                        if (HasWriteCache(root)) throw new IOException("存在待恢复写缓存，请先解锁恢复。");
                        Portal.Prepare(root, launcher);
                    }
                }
            }); return job;
        }
        public void Convert(string path, string password, Work job) {
            string root = Normalize(path);
            if (String.IsNullOrEmpty(password) || password.Length < 8) throw new IOException("密码至少需要 8 个字符。");
            // A per-directory lock also prevents a second app instance from converting/mounting this vault.
            bool existing = File.Exists(InfoFile(root));
            if (!existing && Directory.Exists(Store(root))) throw new IOException("目录已含有 .folderlock，请先检查其内容，程序不会覆盖它。");
            var files = Scan(root, false); var dirs = Scan(root, true);
            // Preflight every file before modifying any source.
            foreach (string file in files) using (var source = OpenSource(file)) using (var origin = OpenDownloadOrigin(file)) { }
            Directory.CreateDirectory(Store(root));
            using (var gate = Gate(root)) {
                VaultInfo info;
                existing = File.Exists(InfoFile(root));
                if (existing) info = Read(root);
                else {
                    byte[] salt = new byte[32]; using (var rng = RandomNumberGenerator.Create()) rng.GetBytes(salt);
                    info = new VaultInfo { Id = Guid.NewGuid().ToString("N"), Salt = System.Convert.ToBase64String(salt), FilenameEncoding = "base32768" };
                    Save(root, info);
                }
                if (info.State == "ready") throw new IOException("该目录已经加密。请使用解锁，或在挂载盘中添加文件。");
                var env = EnvironmentFor(root, password, info);
                if (info.State == "initializing") {
                    Command(new[] {"rcat", "flmeta:check"}, env, "FolderLock:" + info.Id);
                    VerifyKey(info, env); info.State = "converting"; Save(root, info);
                } else VerifyKey(info, env);
                UpgradeNames(root, password, info, job);
                env = EnvironmentFor(root, password, info);
                // Check all names before deleting the first source file.
                foreach (string pathToCheck in files.Concat(dirs)) ValidateEncoded(Command(new[] {"backend", "encode", "fldata:", Rel(root, pathToCheck)}, env, null), pathToCheck);
                // Empty directories need explicit creation; the root itself always exists.
                Command(new[] {"mkdir", "fldata:"}, env, null);
                foreach (string dir in dirs) {
                    if (job.CancelRequested) return;
                    job.Message = "保留目录：" + Rel(root, dir);
                    Command(new[] {"mkdir", "fldata:" + Rel(root, dir)}, env, null);
                }
                int index = 0;
                foreach (string file in files) {
                    if (job.CancelRequested) return;
                    job.Message = String.Format("加密 {0}/{1}：{2}", ++index, files.Count, Rel(root, file));
                    using (var source = OpenSource(file)) using (var origin = OpenDownloadOrigin(file)) {
                        long size = source.Length;
                        long needed = checked(size + (size / 65536 + 1) * 16 + 32 + 1048576);
                        if (new DriveInfo(Path.GetPathRoot(root)).AvailableFreeSpace < needed)
                            throw new IOException("空间不足：需额外容纳当前文件的密文及少量余量。原文件未删除：" + file);
                        byte[] expected; using (var sha = SHA256.Create()) expected = sha.ComputeHash(source);
                        WriteEncryptedFile(source, "fldata:" + Rel(root, file), env);
                        job.Message = "解密回读校验：" + Rel(root, file);
                        VerifyContent("fldata:" + Rel(root, file), env, expected, size);
                        // A download mark is not video content. Preserve its exact bytes in
                        // the separately encrypted metadata tree before deleting the NTFS file.
                        if (origin != null) SaveDownloadOrigin(root, Rel(root, file), source, expected, origin, env);
                        // Flush underlying ciphertext before deleting the original by its still-locked handle.
                        string encoded = Command(new[] {"backend", "encode", "fldata:", Rel(root, file)}, env, null);
                        string cipherPath = DataPath(root, encoded);
                        File.SetLastWriteTimeUtc(Long(cipherPath), File.GetLastWriteTimeUtc(Long(file)));
                        using (var cipher = new FileStream(Long(cipherPath), FileMode.Open, FileAccess.ReadWrite, FileShare.Read)) cipher.Flush(true);
                        if (job.CancelRequested) return;
                        if (ValidateStreams(file) != (origin != null)) throw new IOException("转换期间备用数据流发生变化，原文件已保留：" + file);
                        var disposition = new Disposition { Delete = true };
                        if (!SetFileInformationByHandle(source.SafeFileHandle, 4, ref disposition, 1))
                            throw new Win32Exception(Marshal.GetLastWin32Error(), "密文已验证，但删除原文件失败；可继续加密重试。");
                    }
                }
                foreach (string dir in dirs.OrderByDescending(x => x.Length)) {
                    if (Directory.Exists(Long(dir)) && Directory.GetFileSystemEntries(Long(dir)).Length == 0) Directory.Delete(Long(dir));
                }
                if (Scan(root, false).Count != 0 || Scan(root, true).Count != 0)
                    throw new IOException("转换期间目录内容发生变化。仍有明文，请关闭其他软件后继续加密。");
                info.State = "ready"; Save(root, info); job.Message = "已加密并逐文件验证。";
            }
        }
        public void VerifyContent(string remote, Dictionary<string,string> env, byte[] expected, long size) {
            using (var p = Start(new[] {"cat", remote}, env, false)) {
                var errors = p.StandardError.ReadToEndAsync(); byte[] hash;
                long count = 0; byte[] buffer = new byte[1024 * 1024];
                using (var sha = SHA256.Create()) {
                    int n; while ((n = p.StandardOutput.BaseStream.Read(buffer, 0, buffer.Length)) != 0) { sha.TransformBlock(buffer, 0, n, null, 0); count += n; }
                    sha.TransformFinalBlock(new byte[0], 0, 0); hash = sha.Hash;
                }
                p.WaitForExit();
                if (p.ExitCode != 0 || count != size || !hash.SequenceEqual(expected))
                    throw new IOException("密文回读验证失败，原文件已保留。" + errors.Result);
            }
        }
        internal void FlushCipher(string root, string relative, Dictionary<string,string> env, DateTime? modified = null) {
            string encoded = Command(new[] {"backend", "encode", "fldata:", relative}, env, null);
            if (modified.HasValue) File.SetLastWriteTimeUtc(Long(DataPath(root, encoded)), modified.Value);
            using (var stream = new FileStream(Long(DataPath(root, encoded)), FileMode.Open, FileAccess.ReadWrite, FileShare.Read)) stream.Flush(true);
        }
        static bool IsMedia(string path) {
            return new[] {".webm", ".mp4", ".mkv", ".mov", ".avi", ".m4v", ".mpeg", ".mpg", ".ts", ".m2ts", ".mp3", ".m4a", ".aac", ".wav", ".flac", ".ogg", ".opus"}.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase);
        }
        static bool ValidateStreams(string path) {
            StreamData stream; bool origin = false;
            IntPtr find = FindFirstStreamW(Long(path), 0, out stream, 0);
            if (find == new IntPtr(-1)) {
                int error = Marshal.GetLastWin32Error(); if (error != 38) throw new Win32Exception(error);
                return false;
            }
            try {
                do {
                    if (stream.Name == "::$DATA") continue;
                    if (stream.Name.Equals(":Zone.Identifier:$DATA", StringComparison.OrdinalIgnoreCase) && IsMedia(path) && stream.Size <= 1048576) origin = true;
                    else throw new IOException("文件含有暂不支持的备用数据流 " + stream.Name + "，已停止且保留原文件，避免丢失数据：" + path);
                } while (FindNextStreamW(find, out stream));
                int error = Marshal.GetLastWin32Error(); if (error != 38) throw new Win32Exception(error);
            } finally { FindClose(find); }
            return origin;
        }
        static FileStream OpenDownloadOrigin(string path) {
            if (!ValidateStreams(path)) return null;
            // Share delete with the held main-file handle, but disallow stream writers.
            SafeFileHandle handle = CreateFile(Long(path) + ":Zone.Identifier", 0x80000000, 5, IntPtr.Zero, 3, 0x00200000, IntPtr.Zero);
            if (handle.IsInvalid) { int error = Marshal.GetLastWin32Error(); handle.Dispose(); throw new Win32Exception(error, "无法读取下载来源标记，原文件已保留：" + path); }
            return new FileStream(handle, FileAccess.Read, 4096, false);
        }
        void SaveDownloadOrigin(string root, string relative, FileStream source, byte[] hash, FileStream origin, Dictionary<string,string> env) {
            if (origin.Length > 1048576) throw new IOException("下载来源标记过大，原文件已保留。");
            byte[] data = new byte[(int)origin.Length]; int offset = 0;
            while (offset < data.Length) { int count = origin.Read(data, offset, data.Length - offset); if (count == 0) throw new EndOfStreamException("下载来源标记读取不完整，原文件已保留。"); offset += count; }
            var record = new Dictionary<string,object> { {"Version",1}, {"Path",relative}, {"Stream","Zone.Identifier"}, {"Size",source.Length}, {"SHA256",BitConverter.ToString(hash).Replace("-", "")}, {"Data",System.Convert.ToBase64String(data)} };
            byte[] json = Encoding.UTF8.GetBytes(Json.Serialize(record)); string id;
            using (var sha = SHA256.Create()) id = BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(relative))).Replace("-", "").ToLowerInvariant();
            string name = "download-origins/" + id + ".json";
            using (var memory = new MemoryStream(json)) WriteEncryptedFile(memory, "flmeta:" + name, env);
            byte[] expected; using (var sha = SHA256.Create()) expected = sha.ComputeHash(json);
            VerifyContent("flmeta:" + name, env, expected, json.Length);
            string encoded = Command(new[] {"backend", "encode", "flmeta:", name}, env, null);
            using (var cipher = new FileStream(Long(DataPath(root, encoded, "keycheck")), FileMode.Open, FileAccess.ReadWrite, FileShare.Read)) cipher.Flush(true);
        }
        public void ExportDownloadOrigins(string root, string password, string destination) {
            root = Normalize(root);
            using (var gate = Gate(root)) {
                var info = Read(root); var env = EnvironmentFor(root, password, info); VerifyKey(info, env);
                string target = Path.GetFullPath(destination);
                if (File.Exists(target) || Directory.Exists(target)) throw new IOException("请选择尚不存在的导出目录，避免覆盖数据。");
                if (target.StartsWith(root + "\\", StringComparison.OrdinalIgnoreCase) || target.StartsWith(Store(root) + "\\", StringComparison.OrdinalIgnoreCase)) throw new IOException("请导出到保险箱之外的新目录。");
                Command(new[] {"copy", "flmeta:download-origins", target}, env, null);
            }
        }
        static FileStream OpenSource(string path) {
            SafeFileHandle handle = CreateFile(Long(path), 0x80010000, 1, IntPtr.Zero, 3, 0x00200000, IntPtr.Zero);
            if (handle.IsInvalid) { handle.Dispose(); throw new Win32Exception(Marshal.GetLastWin32Error(), "文件被占用、只读或无删除权限：" + path); }
            try {
                FileInformation info;
                if (!GetFileInformationByHandle(handle, out info)) throw new Win32Exception(Marshal.GetLastWin32Error());
                if (info.Links != 1 || (info.Attributes & (uint)(FileAttributes.ReparsePoint | FileAttributes.Directory | FileAttributes.Encrypted)) != 0)
                    throw new IOException("不支持硬链接、链接或 EFS 文件：" + path);
                ValidateStreams(path);
                return new FileStream(handle, FileAccess.Read, 1024 * 1024, false);
            } catch { handle.Dispose(); throw; }
        }
        public Work BeginOpen(string root, string password, string drive) {
            var work = new Work(); work.Run(() => work.OpenedMount = OpenCore(root, password, drive, work)); return work;
        }
        public Mount Open(string root, string password, string drive) { return OpenCore(root, password, drive, new Work()); }
        public Work BeginOpenOriginal(string root, string password, string launcher) {
            var work = new Work(); work.Run(() => work.OpenedMount = OpenCore(root, password, "@original", work, launcher)); return work;
        }
        public Mount OpenOriginal(string root, string password, string launcher) { return OpenCore(root, password, "@original", new Work(), launcher); }
        public static bool RestoreEntry(string root, string launcher) {
            root = Path.GetFullPath(root.Trim().Trim('"')).TrimEnd('\\');
            if (!Portal.Configured(root)) return false;
            root = Normalize(root);
            using (var gate = Gate(root)) {
                if (Read(root).State != "ready") return false;
                Portal.Prepare(root, launcher); // Repairs the locked shell only; no key is loaded.
                return true;
            }
        }
        public static string ImportRoot(string storage) {
            storage = Path.GetFullPath(storage.Trim().Trim('"')).TrimEnd('\\');
            const string suffix = ".folderlock";
            if (storage.StartsWith(@"\\") || !storage.EndsWith(suffix, StringComparison.OrdinalIgnoreCase) || !File.Exists(Path.Combine(storage, "vault.json")))
                throw new IOException("请选择复制来的完整密文存储目录，例如 Private.folderlock；保持 .folderlock 后缀。");
            string root = storage.Substring(0, storage.Length - suffix.Length);
            if (root.Length <= 3 || Path.GetFileName(root).Length == 0) throw new IOException("密文目录名称不合法。");
            ValidateLocation(root);
            for (var d = new DirectoryInfo(storage); d != null; d = d.Parent)
                if ((d.Attributes & FileAttributes.ReparsePoint) != 0) throw new IOException("导入目录或其上级包含链接，已停止。");
            return root;
        }
        public Work BeginImportOriginal(string storage, string password, string launcher) {
            var work = new Work(); work.Run(() => work.OpenedMount = ImportOriginal(storage, password, launcher)); return work;
        }
        public Mount ImportOriginal(string storage, string password, string launcher) {
            string root = ImportRoot(storage); storage = Portal.Storage(root);
            using (Portal.Guard(root)) using (var gate = new FileStream(Path.Combine(storage, "operation.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None)) {
                CheckStorageAt(storage, true);
                var info = Json.Deserialize<VaultInfo>(File.ReadAllText(Path.Combine(storage, "vault.json"), Encoding.UTF8));
                if (info == null || (info.Version != 1 && info.Version != 2) || info.State != "ready" || String.IsNullOrEmpty(info.Id) || String.IsNullOrEmpty(info.Salt))
                    throw new IOException("密文配置无效或尚未完成加密，请先在原电脑完成加密并安全锁定。");
                if (File.Exists(Path.Combine(storage, "session.json")) || (Directory.Exists(Path.Combine(storage, "write-cache")) && Directory.GetFiles(Long(Path.Combine(storage, "write-cache")), "*", SearchOption.AllDirectories).Length != 0))
                    throw new IOException("副本包含未提交写缓存。请先在原电脑安全锁定，再完整复制密文目录。");
                VerifyKey(info, EnvironmentForStore(storage, password, info));
                // Authentication succeeds before any old machine path or shortcut is changed.
                Portal.Rebind(root, launcher);
            }
            return OpenOriginal(root, password, launcher);
        }
        Mount OpenCore(string root, string password, string drive, Work work, string launcher = null) {
            root = Normalize(root); var info = Read(root);
            if (info.State != "ready") throw new IOException("尚未完成加密，请先继续加密。");
            bool original = drive == "@original";
            if (!original && (drive.Length != 2 || drive[1] != ':' || drive[0] < 'D' || drive[0] > 'Z' || Directory.Exists(drive + "\\")))
                throw new IOException("请选择空闲盘符 D: 到 Z:。");
            if (Scan(root, false).Count != 0 || Scan(root, true).Count != 0)
                throw new IOException("原目录出现了额外的明文。请先处理这些文件，不会把此目录显示为已安全锁定。");
            var gate = Gate(root);
            try {
                var env = EnvironmentFor(root, password, info); VerifyKey(info, env);
                UpgradeNames(root, password, info, work); env = EnvironmentFor(root, password, info);
                if (original) {
                    if (!Portal.Configured(root) && HasWriteCache(root)) throw new IOException("请先用旧版解锁并安全锁定，完成旧写缓存恢复，再启用原路径访问。");
                    using (Portal.Guard(root)) {
                        // Windows cannot rename a directory with an open child lock. The
                        // stable sibling guard bridges that rename and prevents a second app.
                        gate.Dispose();
                        try { Portal.Prepare(root, launcher); }
                        finally { gate = new FileStream(Path.Combine(Store(root), "operation.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
                    }
                    env = EnvironmentFor(root, password, info);
                }
                string cache = Path.Combine(Store(root), "write-cache"); Directory.CreateDirectory(cache);
                ValidateRecoveryCache(cache);
                RecoverCompleteWrites(root, env, work);
                var security = new DirectorySecurity(); security.SetAccessRuleProtection(true, false);
                foreach (var sid in new[] { WindowsIdentity.GetCurrent().User, new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null) })
                    security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
                Directory.SetAccessControl(cache, security);
                var listener = new TcpListener(IPAddress.Loopback, 0); listener.Start();
                int port = ((IPEndPoint)listener.LocalEndpoint).Port; listener.Stop();
                string rcSecret = Guid.NewGuid().ToString("N") + Guid.NewGuid().ToString("N");
                env["RCLONE_RC_PASS"] = rcSecret;
                work.Message = "正在挂载可读写磁盘…";
                var process = Start(new[] {"rcd", "--rc-addr", "127.0.0.1:" + port, "--rc-user", "folderlock", "--cache-dir", cache}, env, false);
                var mount = new Mount(this, process, gate, root, env, original ? root : drive, port, rcSecret, cache, original ? Portal.View(root) : drive);
                try { mount.Initialize(); return mount; } catch { mount.Abort(); throw; }
            } catch { try { if (original && Portal.Configured(root)) Portal.Restore(root); } finally { gate.Dispose(); } throw; }
        }
        [StructLayout(LayoutKind.Sequential)] struct FileInformation {
            public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write;
            public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }
        [StructLayout(LayoutKind.Sequential)] struct Disposition { [MarshalAs(UnmanagedType.U1)] public bool Delete; }
        [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct StreamData { public long Size; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=296)] public string Name; }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInformation info);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetFileInformationByHandle(SafeFileHandle handle, int type, ref Disposition info, uint size);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr FindFirstStreamW(string path, int level, out StreamData data, uint flags);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool FindNextStreamW(IntPtr handle, out StreamData data);
        [DllImport("kernel32.dll")] static extern bool FindClose(IntPtr handle);
    }
    // A permanent junction keeps the public path fail-closed even if the mount process
    // dies: its target lives in the sidecar, so downloaders cannot recreate a plaintext
    // directory at the public path while WinFsp is absent.
    internal static class Portal {
        internal const string Entry = "解锁文件夹.lnk";
        internal static string Storage(string root) { return root + ".folderlock"; }
        internal static string View(string root) { return Path.Combine(Storage(root), "view"); }
        static string ConfigFile(string root) { return Path.Combine(Storage(root), "portal.json"); }
        internal static IDisposable Guard(string root) {
            // Kernel mutexes recover after process death/reboot without stale disk lock files.
            // This guard is held and released on one worker thread; the long-lived file gate
            // continues to protect mounts across UI/worker threads.
            string id; using (var sha = SHA256.Create()) id = Convert.ToBase64String(sha.ComputeHash(Encoding.UTF8.GetBytes(Path.GetFullPath(root).ToUpperInvariant()))).Replace('/', '_');
            return new TransitionGuard("Local\\FolderLockTransition-" + id);
        }
        sealed class TransitionGuard : IDisposable {
            readonly Mutex mutex;
            internal TransitionGuard(string name) {
                mutex = new Mutex(false, name); bool acquired;
                try { acquired = mutex.WaitOne(0); } catch (AbandonedMutexException) { acquired = true; }
                if (!acquired) { mutex.Dispose(); throw new IOException("另一个 FolderLock 操作正在切换此目录，请稍后重试。"); }
            }
            public void Dispose() { mutex.ReleaseMutex(); mutex.Dispose(); }
        }
        static Dictionary<string,string> Config(string root) {
            return new JavaScriptSerializer().Deserialize<Dictionary<string,string>>(File.ReadAllText(VaultEngine.Long(ConfigFile(root)), Encoding.UTF8));
        }
        internal static bool Configured(string root) {
            if (!File.Exists(VaultEngine.Long(ConfigFile(root)))) return false;
            var config = Config(root);
            if (config == null || !config.ContainsKey("Root") || !config["Root"].Equals(root, StringComparison.OrdinalIgnoreCase))
                throw new IOException("原路径入口记录不匹配，请保留相邻的 .folderlock 存储目录。");
            return true;
        }
        static bool Exists(string path) { try { File.GetAttributes(VaultEngine.Long(path)); return true; } catch (FileNotFoundException) { return false; } catch (DirectoryNotFoundException) { return false; } }
        static bool Linked(string path) { return Exists(path) && (File.GetAttributes(VaultEngine.Long(path)) & FileAttributes.ReparsePoint) != 0; }
        internal static void ValidateRoot(string root) {
            if (Linked(root)) {
                if (!Target(root).Equals(View(root), StringComparison.OrdinalIgnoreCase)) throw new IOException("原路径入口已被替换，停止访问。");
            } else if (Exists(root) && Directory.GetFileSystemEntries(VaultEngine.Long(root)).Length != 0)
                throw new IOException("原路径出现了额外文件，已保留，不能覆盖或建立入口。");
        }
        static string Hash(string path) { using (var f = File.OpenRead(VaultEngine.Long(path))) using (var sha = SHA256.Create()) return Convert.ToBase64String(sha.ComputeHash(f)); }
        static void Access(string path, bool writable) {
            var acl = new DirectorySecurity(); acl.SetAccessRuleProtection(true, false);
            acl.AddAccessRule(new FileSystemAccessRule(WindowsIdentity.GetCurrent().User, writable ? FileSystemRights.FullControl : FileSystemRights.ReadAndExecute,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            acl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), FileSystemRights.FullControl,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            Directory.SetAccessControl(VaultEngine.Long(path), acl);
        }
        internal static void Prepare(string root, string launcher) {
            if (String.IsNullOrEmpty(launcher) || !File.Exists(launcher)) throw new IOException("找不到 FolderLock.exe，无法创建目录解锁入口。请使用完整解压的新版程序。");
            launcher = Path.GetFullPath(launcher);
            if (!Configured(root)) {
                string source = Path.Combine(root, VaultEngine.InternalName), destination = Storage(root);
                if (Exists(destination)) throw new IOException("相邻 .folderlock 路径已存在，已停止，程序不会覆盖它。");
                VaultEngine.AtomicJson(Path.Combine(source, "portal.json"), new Dictionary<string,string> { {"Root",root}, {"Launcher",launcher}, {"EntryHash",""} });
                Directory.Move(source, destination); // Same-volume rename: no file contents are copied.
            }
            File.SetAttributes(Storage(root), File.GetAttributes(Storage(root)) | FileAttributes.Hidden | FileAttributes.System);
            ValidateRoot(root);
            var config = Config(root);
            if (Exists(View(root))) RemoveView(root);
            string template = Path.Combine(Storage(root), ".entry-template.dat"), temporary = Path.Combine(Storage(root), ".entry-" + Guid.NewGuid().ToString("N") + ".lnk");
            string oldHash = config["EntryHash"];
            object shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell")); object shortcut = null;
            try {
                shortcut = shell.GetType().InvokeMember("CreateShortcut", System.Reflection.BindingFlags.InvokeMethod, null, shell, new object[] {temporary});
                string brandIcon = Path.Combine(Path.GetDirectoryName(launcher), "FolderLock-brand-v1.ico");
                foreach (var kv in new Dictionary<string,string> { {"TargetPath",launcher}, {"Arguments","--open " + VaultEngine.Quote(root)}, {"WorkingDirectory",Path.GetDirectoryName(launcher)}, {"IconLocation",(File.Exists(brandIcon) ? brandIcon : launcher) + ",0"}, {"Description","输入密码解锁此文件夹"} })
                    shortcut.GetType().InvokeMember(kv.Key, System.Reflection.BindingFlags.SetProperty, null, shortcut, new object[] {kv.Value});
                shortcut.GetType().InvokeMember("Save", System.Reflection.BindingFlags.InvokeMethod, null, shortcut, null);
            } finally { if (shortcut != null) Marshal.FinalReleaseComObject(shortcut); Marshal.FinalReleaseComObject(shell); }
            try {
                if (File.Exists(template)) File.Replace(temporary, template, null); else File.Move(temporary, template);
            } finally { if (File.Exists(temporary)) File.Delete(temporary); }
            File.SetAttributes(template, FileAttributes.Hidden | FileAttributes.System);
            config["Launcher"] = launcher; config["EntryHash"] = Hash(template); VaultEngine.AtomicJson(ConfigFile(root), config);
            string legacy = Path.Combine(Storage(root), "open.lnk");
            if (File.Exists(legacy) && Hash(legacy) == oldHash) File.Delete(legacy);
            Restore(root);
        }
        internal static void Rebind(string root, string launcher) {
            ValidateRoot(root); // Refuse to replace an unrelated folder/junction on the new PC.
            if (Exists(View(root))) RemoveView(root);
            var config = File.Exists(ConfigFile(root)) ? Config(root) : new Dictionary<string,string> { {"EntryHash", ""} };
            config["Root"] = root; config["Launcher"] = launcher;
            VaultEngine.AtomicJson(ConfigFile(root), config);
            Prepare(root, launcher);
        }
        internal static void RemoveView(string root) {
            string view = View(root);
            if (!Exists(view)) return;
            if (Linked(view) && RemoveStaleMount(root)) return;
            if (Linked(view)) throw new IOException("原路径挂载仍被占用，请先安全锁定，不能重复挂载。");
            var config = Config(root);
            foreach (string entry in Directory.GetFileSystemEntries(VaultEngine.Long(view))) {
                string path = VaultEngine.Unlong(entry);
                if (!Path.GetFileName(path).Equals(Entry, StringComparison.Ordinal) || Linked(path) || !File.Exists(entry) || Hash(path) != config["EntryHash"])
                    throw new IOException("锁定入口含有未知文件，已保留，停止挂载以避免丢失数据。");
            }
            Access(view, true);
            string link = Path.Combine(view, Entry); if (File.Exists(VaultEngine.Long(link))) File.Delete(VaultEngine.Long(link));
            Directory.Delete(VaultEngine.Long(view)); // Only the verified, empty portal is removed.
        }
        internal static bool HasUnexpected(string root) {
            ValidateRoot(root);
            string view = View(root);
            if (!Exists(view) || Linked(view)) return false;
            var config = Config(root);
            return Directory.GetFileSystemEntries(VaultEngine.Long(view)).Any(entry =>
                Path.GetFileName(entry) != Entry || Linked(VaultEngine.Unlong(entry)) || !File.Exists(entry) || Hash(VaultEngine.Unlong(entry)) != config["EntryHash"]);
        }
        internal static void Restore(string root) {
            ValidateRoot(root);
            string view = View(root);
            if (Linked(view)) RemoveStaleMount(root);
            for (int i = 0; i < 50 && Linked(view); i++) Thread.Sleep(100);
            if (Linked(view)) throw new IOException("挂载尚未释放，写缓存已保留；请稍后重新打开 FolderLock。");
            if (Exists(view)) RemoveView(root);
            Directory.CreateDirectory(VaultEngine.Long(view));
            Access(view, true);
            string template = Path.Combine(Storage(root), ".entry-template.dat");
            if (!File.Exists(template)) template = Path.Combine(Storage(root), "open.lnk"); // 2.2 repair compatibility.
            if (!File.Exists(VaultEngine.Long(template)) || Hash(template) != Config(root)["EntryHash"]) throw new IOException("解锁快捷方式损坏，请从 FolderLock.exe 重新解锁以修复。");
            File.Copy(VaultEngine.Long(template), VaultEngine.Long(Path.Combine(view, Entry)));
            File.SetAttributes(VaultEngine.Long(Path.Combine(view, Entry)), FileAttributes.Normal);
            Access(view, false); // Locked downloads fail instead of creating unencrypted files.
            if (!Exists(root)) Directory.CreateDirectory(VaultEngine.Long(root));
            if (!Linked(root)) SetJunction(root, view);
        }
        internal static string MountTarget(string root) { return Target(View(root)); }
        static bool RemoveStaleMount(string root) {
            string view = View(root), sessionFile = Path.Combine(Storage(root), "session.json");
            if (!File.Exists(sessionFile)) return false;
            var session = new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(File.ReadAllText(sessionFile, Encoding.UTF8));
            if (session == null || !session.ContainsKey("State") || Convert.ToString(session["State"]) != "active") return false;
            string target = Target(view);
            bool recorded = session.ContainsKey("ViewTarget") && String.Equals(Convert.ToString(session["ViewTarget"]), target, StringComparison.OrdinalIgnoreCase);
            string[] parts = target.Split(new[] {'\\'}, StringSplitOptions.RemoveEmptyEntries); Guid volume;
            bool legacyVolume = parts.Length == 2 && parts[0].Equals("Device", StringComparison.OrdinalIgnoreCase) &&
                parts[1].StartsWith("Volume{", StringComparison.OrdinalIgnoreCase) && Guid.TryParse(parts[1].Substring(6), out volume);
            if (!recorded && !legacyVolume) return false;
            try { Directory.GetFileSystemEntries(VaultEngine.Long(view)); return false; }
            catch (IOException) {
                // Only remove this managed junction object, never recurse into its target.
                // All ciphertext, session and write-cache files stay untouched for recovery.
                try { Directory.Delete(VaultEngine.Long(view)); } catch (DirectoryNotFoundException) { } catch (FileNotFoundException) { }
                return true;
            }
        }
        static string Target(string path) {
            using (var handle = Open(path, 0)) {
                byte[] buffer = new byte[16384]; int returned;
                if (!DeviceIoControl(handle, 0x900a8, null, 0, buffer, buffer.Length, out returned, IntPtr.Zero) || BitConverter.ToUInt32(buffer, 0) != 0xa0000003)
                    throw new IOException("目录入口不是预期的 NTFS 联接点。");
                string target = Encoding.Unicode.GetString(buffer, 16 + BitConverter.ToUInt16(buffer, 8), BitConverter.ToUInt16(buffer, 10));
                return target.StartsWith(@"\??\") ? target.Substring(4) : target;
            }
        }
        static SafeFileHandle Open(string path, uint access) {
            var handle = CreateFile(VaultEngine.Long(path), access, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
            if (handle.IsInvalid) { handle.Dispose(); throw new Win32Exception(Marshal.GetLastWin32Error(), "无法操作目录入口。"); } return handle;
        }
        static void SetJunction(string path, string target) {
            if (Directory.GetFileSystemEntries(VaultEngine.Long(path)).Length != 0) throw new IOException("入口目录非空，已停止。");
            byte[] substitute = Encoding.Unicode.GetBytes(@"\??\" + target), print = Encoding.Unicode.GetBytes(target);
            var buffer = new byte[16 + substitute.Length + print.Length + 4];
            Array.Copy(BitConverter.GetBytes(0xa0000003u), 0, buffer, 0, 4);
            Array.Copy(BitConverter.GetBytes((ushort)(buffer.Length - 8)), 0, buffer, 4, 2);
            Array.Copy(BitConverter.GetBytes((ushort)substitute.Length), 0, buffer, 10, 2);
            Array.Copy(BitConverter.GetBytes((ushort)(substitute.Length + 2)), 0, buffer, 12, 2);
            Array.Copy(BitConverter.GetBytes((ushort)print.Length), 0, buffer, 14, 2);
            Array.Copy(substitute, 0, buffer, 16, substitute.Length); Array.Copy(print, 0, buffer, 18 + substitute.Length, print.Length);
            using (var handle = Open(path, 0x40000000)) {
                int returned; if (!DeviceIoControl(handle, 0x900a4, buffer, buffer.Length, null, 0, out returned, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error(), "无法创建原路径入口，密文已保留。");
            }
        }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool DeviceIoControl(SafeFileHandle handle, uint control, byte[] input, int inputSize, byte[] output, int outputSize, out int returned, IntPtr overlapped);
    }
    public sealed class Mount : IDisposable {
        readonly Process process; readonly FileStream gate; readonly Task<string> errors; readonly Task<string> output;
        readonly SafeFileHandle job;
        readonly VaultEngine engine;
        readonly string root, cache, address, authorization, mountPoint;
        readonly Dictionary<string,string> environment;
        string dataPath, metaPath;
        public bool Attached { get; private set; }
        int disposed;
        public readonly string Drive;
        public bool Closed { get { return disposed != 0; } }
        public bool Alive { get { return !Closed && !process.HasExited; } }
        public string Failure { get { return !Closed && process.HasExited ? errors.Result : ""; } }
        internal Mount(VaultEngine e, Process p, FileStream g, string r, Dictionary<string,string> env, string drive, int port, string secret, string cachePath, string point) {
            engine = e; root = r; environment = env; cache = cachePath;
            mountPoint = point;
            address = "http://127.0.0.1:" + port + "/";
            authorization = "Basic " + Convert.ToBase64String(Encoding.UTF8.GetBytes("folderlock:" + secret));
            process = p; gate = g; Drive = drive; errors = p.StandardError.ReadToEndAsync(); output = p.StandardOutput.ReadToEndAsync();
            // Kill the mount if the UI crashes or is terminated, rather than leaving an orphan unlocked drive.
            job = CreateJobObject(IntPtr.Zero, null);
            try {
                var limits = new ExtendedLimits(); limits.Basic.Flags = 0x2000;
                if (job.IsInvalid || !SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf(limits)) ||
                    !AssignProcessToJobObject(job, process.Handle)) throw new Win32Exception(Marshal.GetLastWin32Error(), "无法设置挂载进程退出保护。");
            } catch { job.Dispose(); if (!process.HasExited) process.Kill(); process.Dispose(); throw; }
        }
        internal void Initialize() {
            var deadline = DateTime.UtcNow.AddSeconds(15);
            while (true) {
                if (!Alive) throw new IOException("挂载服务退出：" + Failure);
                try { Rpc("core/version", new {}); break; }
                catch (WebException) { if (DateTime.UtcNow > deadline) throw; Thread.Sleep(100); }
            }
            string sessionFile = Path.Combine(VaultEngine.Store(root), "session.json");
            if (!File.Exists(sessionFile)) VaultEngine.AtomicJson(sessionFile, new { State = "active", Cache = "write-cache" });
            if (mountPoint != Drive) Portal.RemoveView(root);
            Rpc("mount/mount", new {
                fs = "fldata:", mountPoint = mountPoint, mountType = "cmount",
                vfsOpt = new { CacheMode = 2, WriteBack = 5000000000L, CacheMaxAge = 31536000000000000L, CachePollInterval = 60000000000L, FilePerms = 384, DirPerms = 448 },
                mountOpt = new { VolumeName = "FolderLock", NetworkMode = false }
            });
            Attached = true;
            var stats = Rpc("vfs/stats", new {});
            var disk = (Dictionary<string,object>)stats["diskCache"];
            dataPath = CachePath((string)disk["path"]); metaPath = CachePath((string)disk["pathMeta"]);
            VaultEngine.AtomicJson(Path.Combine(VaultEngine.Store(root), "session.json"), new { State = "active", Cache = "write-cache", DataRoot = dataPath.Substring(cache.Length + 1), MetaRoot = metaPath.Substring(cache.Length + 1), ViewTarget = mountPoint != Drive ? Portal.MountTarget(root) : null });
            string mode = Convert.ToString(((Dictionary<string,object>)stats["opt"])["CacheMode"]);
            if (mode != "2" && mode != "writes")
                throw new IOException("写入缓存未启用，已停止挂载，防止不完整写入。");
        }
        Dictionary<string,object> Rpc(string method, object body) {
            var request = (HttpWebRequest)WebRequest.Create(address + method);
            request.Proxy = null; request.Method = "POST"; request.ContentType = "application/json";
            request.Headers["Authorization"] = authorization; request.Timeout = 30000; request.ReadWriteTimeout = 30000;
            byte[] bytes = Encoding.UTF8.GetBytes(new JavaScriptSerializer().Serialize(body)); request.ContentLength = bytes.Length;
            using (var stream = request.GetRequestStream()) stream.Write(bytes, 0, bytes.Length);
            using (var response = request.GetResponse()) using (var reader = new StreamReader(response.GetResponseStream(), Encoding.UTF8))
                return new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(reader.ReadToEnd());
        }
        string CachePath(string path) {
            string full = Path.GetFullPath(VaultEngine.Unlong(path.Replace('/', '\\')));
            if (!full.StartsWith(cache + "\\", StringComparison.OrdinalIgnoreCase)) throw new IOException("写入缓存路径超出保险箱。");
            return full;
        }
        IEnumerable<string> CachedFiles() {
            if (dataPath == null || !Directory.Exists(VaultEngine.Long(dataPath))) return new string[0];
            return Directory.GetFiles(VaultEngine.Long(dataPath), "*", SearchOption.AllDirectories).Select(VaultEngine.Unlong).ToArray();
        }
        Dictionary<string,object> CacheInfo(string file) {
            string relative = file.Substring(dataPath.Length + 1);
            return new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(File.ReadAllText(VaultEngine.Long(Path.Combine(metaPath, relative)), Encoding.UTF8));
        }
        bool ReadyToLock() {
            var stats = Rpc("vfs/stats", new {});
            var disk = (Dictionary<string,object>)stats["diskCache"];
            if (Convert.ToBoolean(disk["outOfSpace"]) || Convert.ToInt32(disk["erroredFiles"]) != 0)
                throw new IOException("写入缓存空间不足或写回失败。请释放空间、关闭编辑软件后重试，缓存会保留。");
            if (Convert.ToInt32(disk["uploadsInProgress"]) != 0 || Convert.ToInt32(disk["uploadsQueued"]) != 0) return false;
            foreach (string file in CachedFiles()) {
                try {
                    using (var exclusive = File.Open(VaultEngine.Long(file), FileMode.Open, FileAccess.Read, FileShare.None)) { }
                    if (Convert.ToBoolean(CacheInfo(file)["Dirty"])) return false;
                } catch (IOException) { return false; }
            }
            return true;
        }
        void VerifyCache(Work work) {
            var names = engine.ExistingCacheNames(environment);
            foreach (string file in CachedFiles()) {
                var info = CacheInfo(file);
                if (Convert.ToBoolean(info["Dirty"])) throw new IOException("卸载时检测到新修改，缓存尚未写回；已保留，需再次解锁恢复。");
                long size = Convert.ToInt64(info["Size"]);
                // Clean partial read caches contain no uncommitted writes. Full cached files
                // are compared with decrypted durable ciphertext before any cache is removed.
                var sequence = info["Rs"] as System.Collections.IEnumerable;
                var ranges = sequence == null ? null : sequence.Cast<object>().ToArray();
                bool full = size == 0;
                if (ranges != null && ranges.Length == 1) {
                    var range = (Dictionary<string,object>)ranges[0];
                    full = Convert.ToInt64(range["Pos"]) == 0 && Convert.ToInt64(range["Size"]) == size;
                }
                if (!full) continue;
                string relative = VaultEngine.ResolveCacheName(file.Substring(dataPath.Length + 1), names);
                work.Message = "锁定前验证已保存内容：" + relative;
                byte[] hash;
                using (var stream = File.Open(VaultEngine.Long(file), FileMode.Open, FileAccess.Read, FileShare.None))
                using (var sha = SHA256.Create()) hash = sha.ComputeHash(stream);
                engine.VerifyContent("fldata:" + relative, environment, hash, size);
                engine.FlushCipher(root, relative, environment);
            }
        }
        public Work BeginLock() {
            var work = new Work(); work.Run(() => Lock(work, 300)); return work;
        }
        public static Work BeginLockAll(Mount[] mounts) {
            var work = new Work(); work.Run(() => { foreach (var mount in mounts) mount.Lock(work, 300); }); return work;
        }
        public void Lock(Work work, int timeoutSeconds) {
            if (disposed != 0) return;
            if (!Alive) throw new IOException("挂载进程已停止，不能确认修改已保存；写入缓存已保留，请重新解锁恢复。");
            if (Attached) {
                work.Message = "等待编辑软件/ffmpeg 关闭文件，并将修改加密保存…";
                var deadline = DateTime.UtcNow.AddSeconds(timeoutSeconds);
                while (!ReadyToLock()) {
                    if (work.CancelRequested) throw new OperationCanceledException("已取消锁定，挂载仍可访问。");
                    if (DateTime.UtcNow > deadline) throw new IOException("文件仍被编辑软件占用或正在写回，尚未锁定。请关闭文件后重试。");
                    Thread.Sleep(200);
                }
                if (work.CancelRequested) throw new OperationCanceledException("已取消锁定。");
                Rpc("mount/unmount", new { mountPoint = mountPoint }); Attached = false;
            }
            // A writer can race the final readiness check. Never throw away its cache.
            VerifyCache(work);
            work.Message = "清理已验证的临时写缓存…";
            Rpc("core/quit", new {});
            if (!process.WaitForExit(5000)) process.Kill();
            // Cache is a fixed child of this explicitly selected vault. Check boundaries and
            // reject links before the only recursive removal in this component.
            string expected = Path.Combine(VaultEngine.Store(root), "write-cache");
            if (!Path.GetFullPath(cache).Equals(expected, StringComparison.OrdinalIgnoreCase)) throw new IOException("缓存清理路径不合法。");
            var paths = new Stack<string>(); paths.Push(cache);
            while (paths.Count != 0) {
                string path = paths.Pop();
                if ((File.GetAttributes(VaultEngine.Long(path)) & FileAttributes.ReparsePoint) != 0) throw new IOException("缓存中发现链接，停止清理。");
                if (Directory.Exists(VaultEngine.Long(path))) foreach (string child in Directory.GetFileSystemEntries(VaultEngine.Long(path))) paths.Push(VaultEngine.Unlong(child));
            }
            Directory.Delete(VaultEngine.Long(cache), true);
            File.Delete(Path.Combine(VaultEngine.Store(root), "session.json"));
            Abort(); work.Message = "已锁定：修改已加密保存，临时写缓存已清理。";
        }
        public void Dispose() {
            if (disposed == 0) Lock(new Work(), 30);
        }
        // Emergency release retains all cache and its recovery marker; never call it a lock.
        public void Abort() {
            if (Interlocked.Exchange(ref disposed, 1) != 0) return;
            try {
                if (!process.HasExited) {
                    try { process.Kill(); } catch (InvalidOperationException) { if (!process.HasExited) throw; }
                    process.WaitForExit();
                }
            } finally {
                try { job.Dispose(); process.Dispose(); if (mountPoint != Drive) Portal.Restore(root); }
                finally { gate.Dispose(); }
            }
        }
        [StructLayout(LayoutKind.Sequential)] struct BasicLimits {
            public long ProcessTime, JobTime; public uint Flags; public UIntPtr MinWorkingSet, MaxWorkingSet;
            public uint ActiveProcesses; public UIntPtr Affinity; public uint Priority, Scheduling;
        }
        [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong ReadOperations, WriteOperations, OtherOperations, ReadBytes, WriteBytes, OtherBytes; }
        [StructLayout(LayoutKind.Sequential)] struct ExtendedLimits {
            public BasicLimits Basic; public IoCounters Io; public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
        }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern SafeFileHandle CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(SafeFileHandle job, int type, ref ExtendedLimits limits, uint length);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(SafeFileHandle job, IntPtr process);
    }
}
