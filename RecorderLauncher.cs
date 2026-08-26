using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("JH Camera錄影程式")]
[assembly: AssemblyProduct("JH Camera錄影程式")]
[assembly: AssemblyCompany("JH Camera")]

internal static class RecorderLauncher
{
    [STAThread]
    private static void Main()
    {
        string applicationDirectory = AppDomain.CurrentDomain.BaseDirectory;
        string recorderScript = Path.Combine(applicationDirectory, "recorder.ps1");
        if (!File.Exists(recorderScript))
        {
            MessageBox.Show(
                "找不到 recorder.ps1，請將 " + BuildVersion.LauncherName + " 保留在程式資料夾內。",
                "無法啟動錄影程式",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return;
        }

        var startInfo = new ProcessStartInfo {
            FileName = "powershell.exe",
            Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " + Quote(recorderScript),
            WorkingDirectory = applicationDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden
        };

        try
        {
            Process.Start(startInfo);
        }
        catch (Exception exception)
        {
            MessageBox.Show(
                "無法在背景啟動錄影程式：\r\n" + exception.Message,
                "啟動失敗",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
    }

    private static string Quote(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }
}
