using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Windows.Forms;
using System.Threading;
using System.Security.Principal;
using System.Text;

[assembly: AssemblyTitle("FolderLock")]
[assembly: AssemblyDescription("Windows folder encryption")]
[assembly: AssemblyCompany("VectorScience")]
[assembly: AssemblyProduct("FolderLock")]
[assembly: AssemblyVersion("2.4.2.0")]
[assembly: AssemblyFileVersion("2.4.2.0")]

internal static class Launcher
{
    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            string appDirectory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "FolderLock", "app-v2");
            Directory.CreateDirectory(appDirectory);
            string openPath = "";
            bool restore = args.Length == 1 && args[0] == "--restore-entries";
            if (args.Length != 0 && !restore) {
                if (args.Length != 2 || (args[0] != "--open" && args[0] != "--encrypt")) throw new ArgumentException("用法：FolderLock.exe --open 或 --encrypt 文件夹路径");
                openPath = Path.GetFullPath(args[1]).TrimEnd('\\');
            }
            try {
                using (var running = Mutex.OpenExisting("Local\\FolderLock2UI-" + WindowsIdentity.GetCurrent().User.Value)) {
                    if (restore) return 0;
                    string requests = Path.Combine(appDirectory, "open-requests"); Directory.CreateDirectory(requests);
                    string request = Path.Combine(requests, Guid.NewGuid().ToString("N") + (args.Length == 2 && args[0] == "--encrypt" ? ".encrypt.request" : ".request"));
                    File.WriteAllText(request + ".new", openPath, new UTF8Encoding(false)); File.Move(request + ".new", request);
                    return 0;
                }
            } catch (WaitHandleCannotBeOpenedException) { }

            string scriptPath = Path.Combine(appDirectory, "FolderLock.ps1");
            string iconPath = Path.Combine(appDirectory, "FolderLock.ico");
            ExtractResource("FolderLock.ps1", scriptPath);
            ExtractResource("FolderLock.ico", iconPath);
            ExtractResource("VaultEngine.cs", Path.Combine(appDirectory, "VaultEngine.cs"));
            ExtractResource("Legacy-FolderLock.ps1", Path.Combine(appDirectory, "Legacy-FolderLock.ps1"));
            ExtractResource("Prepare-Dependencies.ps1", Path.Combine(appDirectory, "Prepare-Dependencies.ps1"));
            string rclone = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "rclone.exe");
            if (!File.Exists(rclone)) throw new FileNotFoundException("请解压完整 ZIP，FolderLock.exe 同级需要 rclone.exe。", rclone);

            string powershell = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                @"System32\WindowsPowerShell\v1.0\powershell.exe");
            if (!File.Exists(powershell))
                throw new FileNotFoundException("未找到 Windows PowerShell 5.1。", powershell);

            var process = new ProcessStartInfo(powershell)
            {
                Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File " + Quote(scriptPath) + " -RclonePath " + Quote(rclone) + " -LauncherPath " + Quote(Assembly.GetExecutingAssembly().Location) + (restore ? " -RestoreEntries" : openPath.Length == 0 ? "" : (args[0] == "--encrypt" ? " -EncryptPath " : " -OpenPath ") + Quote(openPath)),
                WorkingDirectory = appDirectory,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };
            Process.Start(process);
            return 0;
        }
        catch (Exception error)
        {
            if (args.Length == 1 && args[0] == "--restore-entries") return 1; // Startup recovery stays silent.
            MessageBox.Show("FolderLock 启动失败：\n" + error.Message,
                "FolderLock", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    private static string Quote(string value) {
        var result = new StringBuilder("\""); int slashes = 0;
        foreach (char c in value) {
            if (c == '\\') { slashes++; continue; }
            result.Append('\\', c == '"' ? slashes * 2 + 1 : slashes); result.Append(c); slashes = 0;
        }
        result.Append('\\', slashes * 2); return result.Append('"').ToString();
    }

    private static void ExtractResource(string name, string destination)
    {
        using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(name))
        {
            if (stream == null)
                throw new InvalidOperationException("安装包缺少资源：" + name);

            byte[] bytes = new byte[stream.Length];
            int offset = 0;
            while (offset < bytes.Length)
            {
                int count = stream.Read(bytes, offset, bytes.Length - offset);
                if (count == 0) throw new EndOfStreamException(name);
                offset += count;
            }

            if (File.Exists(destination) && SameHash(destination, bytes)) return;

            string temporary = destination + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                File.WriteAllBytes(temporary, bytes);
                if (File.Exists(destination))
                    File.Replace(temporary, destination, null);
                else
                    File.Move(temporary, destination);
            }
            finally
            {
                if (File.Exists(temporary)) File.Delete(temporary);
            }
        }
    }

    private static bool SameHash(string path, byte[] expected)
    {
        using (var sha = SHA256.Create())
        using (var file = File.OpenRead(path))
        {
            byte[] actualHash = sha.ComputeHash(file);
            byte[] expectedHash = sha.ComputeHash(expected);
            if (actualHash.Length != expectedHash.Length) return false;
            int difference = 0;
            for (int i = 0; i < actualHash.Length; i++)
                difference |= actualHash[i] ^ expectedHash[i];
            return difference == 0;
        }
    }
}
