using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Windows.Forms;

[assembly: AssemblyTitle("FolderLock")]
[assembly: AssemblyDescription("Windows folder access lock")]
[assembly: AssemblyCompany("VectorScience")]
[assembly: AssemblyProduct("FolderLock")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

internal static class Launcher
{
    [STAThread]
    private static int Main()
    {
        try
        {
            string appDirectory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "FolderLock", "app");
            Directory.CreateDirectory(appDirectory);

            string scriptPath = Path.Combine(appDirectory, "FolderLock.ps1");
            string iconPath = Path.Combine(appDirectory, "FolderLock.ico");
            ExtractResource("FolderLock.ps1", scriptPath);
            ExtractResource("FolderLock.ico", iconPath);

            string powershell = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                @"System32\WindowsPowerShell\v1.0\powershell.exe");
            if (!File.Exists(powershell))
                throw new FileNotFoundException("未找到 Windows PowerShell 5.1。", powershell);

            var process = new ProcessStartInfo(powershell)
            {
                Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + scriptPath + "\"",
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
            MessageBox.Show("FolderLock 启动失败：\n" + error.Message,
                "FolderLock", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
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
