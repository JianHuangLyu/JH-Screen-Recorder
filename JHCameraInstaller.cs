using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: AssemblyTitle("JH Camera錄影程式安裝程式")]
[assembly: AssemblyProduct("JH Camera錄影程式")]
[assembly: AssemblyCompany("JH Camera")]

internal static class InstallerProgram
{
    internal const string ProductName = "JH Camera錄影程式";
    internal const string ProductVersion = BuildVersion.ProductVersion;
    internal const string MarkerName = ".jh-camera-install";
    internal const string LauncherName = BuildVersion.LauncherName;
    internal const string UninstallerName = "解除安裝.exe";
    internal const string RegistryKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\JHCameraRecorder";
    internal const string RecorderMutexName = @"Local\FFmpegHighQualityRecorder_SingleInstance";

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool MoveFileEx(string existingFileName, string newFileName, int flags);

    [DllImport("shell32.dll")]
    private static extern void SHChangeNotify(uint eventId, uint flags, IntPtr item1, IntPtr item2);

    [STAThread]
    private static void Main(string[] args)
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        if (args.Length >= 1 && String.Equals(args[0], "/cleanup", StringComparison.OrdinalIgnoreCase))
        {
            RunCleanup(args);
            return;
        }

        bool uninstallRequested = args.Length >= 1 && String.Equals(args[0], "/uninstall", StringComparison.OrdinalIgnoreCase);
        bool installedUninstaller = String.Equals(Path.GetFileName(Application.ExecutablePath), UninstallerName, StringComparison.OrdinalIgnoreCase);
        if (uninstallRequested || installedUninstaller)
        {
            RunUninstall();
            return;
        }

        Application.Run(new InstallerForm());
    }

    internal static string DefaultInstallPath()
    {
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", ProductName);
    }

    internal static string DesktopShortcutPath()
    {
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), ProductName + ".lnk");
    }

    internal static string StartMenuFolder()
    {
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), ProductName);
    }

    internal static bool IsProtectedInstallPath(string path)
    {
        string full;
        try { full = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar); }
        catch { return true; }
        if (String.IsNullOrWhiteSpace(full)) return true;
        string root = Path.GetPathRoot(full).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        if (String.Equals(full, root, StringComparison.OrdinalIgnoreCase)) return true;

        string[] protectedPaths = new string[] {
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),
            Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
            Environment.GetFolderPath(Environment.SpecialFolder.MyVideos),
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData)
        };
        foreach (string protectedPath in protectedPaths)
        {
            if (!String.IsNullOrWhiteSpace(protectedPath) && String.Equals(full, Path.GetFullPath(protectedPath).TrimEnd(Path.DirectorySeparatorChar), StringComparison.OrdinalIgnoreCase))
                return true;
        }
        return false;
    }

    internal static void CreateShortcut(string shortcutPath, string targetPath, string workingDirectory, string description)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(shortcutPath));
        if (File.Exists(shortcutPath)) File.Delete(shortcutPath);
        Type shellType = Type.GetTypeFromProgID("WScript.Shell");
        if (shellType == null) throw new InvalidOperationException("Windows 捷徑元件無法使用。");
        object shellObject = Activator.CreateInstance(shellType);
        object shortcutObject = null;
        try
        {
            dynamic shell = shellObject;
            dynamic shortcut = shell.CreateShortcut(shortcutPath);
            shortcutObject = shortcut;
            shortcut.TargetPath = targetPath;
            shortcut.WorkingDirectory = workingDirectory;
            shortcut.Description = description;
            string applicationIcon = Path.Combine(workingDirectory, "assets", "jh-camera-icon.ico");
            shortcut.IconLocation = (File.Exists(applicationIcon) ? applicationIcon : targetPath) + ",0";
            shortcut.Save();
        }
        finally
        {
            if (shortcutObject != null && Marshal.IsComObject(shortcutObject)) Marshal.FinalReleaseComObject(shortcutObject);
            if (shellObject != null && Marshal.IsComObject(shellObject)) Marshal.FinalReleaseComObject(shellObject);
        }
    }

    internal static void RefreshShellIcons()
    {
        // SHCNE_ASSOCCHANGED asks Explorer and the Start menu to invalidate
        // cached icon associations after shortcuts are recreated.
        SHChangeNotify(0x08000000, 0, IntPtr.Zero, IntPtr.Zero);
    }

    internal static void RegisterUninstaller(string installPath)
    {
        string uninstaller = Path.Combine(installPath, UninstallerName);
        string launcher = Path.Combine(installPath, LauncherName);
        string displayIcon = Path.Combine(installPath, "assets", "jh-camera-icon.ico");
        long totalBytes = 0;
        foreach (string file in Directory.GetFiles(installPath, "*", SearchOption.AllDirectories))
        {
            try { totalBytes += new FileInfo(file).Length; } catch { }
        }
        using (RegistryKey key = Registry.CurrentUser.CreateSubKey(RegistryKeyPath))
        {
            key.SetValue("DisplayName", ProductName);
            key.SetValue("DisplayVersion", ProductVersion);
            key.SetValue("Publisher", "JH Camera");
            key.SetValue("InstallLocation", installPath);
            key.SetValue("DisplayIcon", File.Exists(displayIcon) ? displayIcon : launcher);
            key.SetValue("UninstallString", "\"" + uninstaller + "\" /uninstall");
            key.SetValue("NoModify", 1, RegistryValueKind.DWord);
            key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
            key.SetValue("EstimatedSize", (int)Math.Min(Int32.MaxValue, Math.Max(1, totalBytes / 1024)), RegistryValueKind.DWord);
            key.SetValue("InstallDate", DateTime.Now.ToString("yyyyMMdd"));
        }
    }

    private static void RunUninstall()
    {
        string installPath = Path.GetDirectoryName(Application.ExecutablePath);
        string marker = Path.Combine(installPath, MarkerName);
        if (IsProtectedInstallPath(installPath) || !File.Exists(marker))
        {
            MessageBox.Show("找不到有效的 JH Camera 安裝標記，已取消解除安裝。", "無法解除安裝", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }
        if (IsRecorderRunning())
        {
            MessageBox.Show("錄影程式仍在背景執行。\r\n\r\n請先停止錄影並關閉 JH Camera錄影程式，再重新執行解除安裝。", "請先關閉錄影程式", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }
        DialogResult answer = MessageBox.Show("確定要解除安裝 JH Camera錄影程式嗎？\r\n\r\n使用者錄製的影片不會被刪除。", "解除安裝", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
        if (answer != DialogResult.Yes) return;

        try
        {
            string cleanupCopy = Path.Combine(Path.GetTempPath(), "JHCameraCleanup_" + Guid.NewGuid().ToString("N") + ".exe");
            File.Copy(Application.ExecutablePath, cleanupCopy, true);
            ProcessStartInfo info = new ProcessStartInfo();
            info.FileName = cleanupCopy;
            info.Arguments = "/cleanup \"" + installPath.Replace("\"", "\\\"") + "\" " + Process.GetCurrentProcess().Id;
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            Process.Start(info);
        }
        catch (Exception exception)
        {
            MessageBox.Show("無法啟動解除安裝清理程序：\r\n" + exception.Message, "解除安裝失敗", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    private static void RunCleanup(string[] args)
    {
        if (args.Length < 3) return;
        string installPath = args[1];
        int parentId;
        if (!Int32.TryParse(args[2], out parentId)) return;
        if (IsProtectedInstallPath(installPath) || !File.Exists(Path.Combine(installPath, MarkerName))) return;

        try
        {
            try { Process.GetProcessById(parentId).WaitForExit(10000); } catch { }
            if (IsRecorderRunning())
            {
                MessageBox.Show("錄影程式仍在背景執行，因此尚未移除任何安裝資料。\r\n\r\n請先停止錄影並關閉程式，再重新執行解除安裝。", "請先關閉錄影程式", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            string detachedPath;
            Exception lastError;
            bool removed = TryDetachInstallDirectory(installPath, out detachedPath, out lastError);
            if (removed)
            {
                RemoveRegistrationAndShortcuts();
                if (!String.IsNullOrWhiteSpace(detachedPath)) TryDeleteDetachedDirectory(detachedPath);
                MessageBox.Show("JH Camera錄影程式已解除安裝。\r\n使用者錄製的影片均已保留。", "解除安裝完成", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            else
                MessageBox.Show("部分程式檔案仍在使用中，無法完全移除：\r\n" + lastError.Message, "解除安裝未完成", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
        finally
        {
            MoveFileEx(Application.ExecutablePath, null, 4);
        }
    }

    internal static bool IsRecorderRunning()
    {
        try
        {
            using (Mutex recorderMutex = Mutex.OpenExisting(RecorderMutexName)) return true;
        }
        catch (WaitHandleCannotBeOpenedException) { return false; }
        catch (UnauthorizedAccessException) { return true; }
    }

    internal static bool TryDetachInstallDirectory(string installPath, out string detachedPath, out Exception lastError)
    {
        detachedPath = null;
        lastError = null;
        string parentPath = Path.GetDirectoryName(installPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
        string removalPath = Path.Combine(parentPath, ".JHCameraRemoval_" + Guid.NewGuid().ToString("N"));

        for (int attempt = 0; attempt < 40; attempt++)
        {
            if (!Directory.Exists(installPath)) return true;
            try
            {
                Directory.Move(installPath, removalPath);
                detachedPath = removalPath;
                return !Directory.Exists(installPath);
            }
            catch (Exception exception)
            {
                lastError = exception;
                Thread.Sleep(250);
            }
        }
        return !Directory.Exists(installPath);
    }

    private static void TryDeleteDetachedDirectory(string detachedPath)
    {
        for (int attempt = 0; attempt < 40; attempt++)
        {
            try
            {
                if (!Directory.Exists(detachedPath)) return;
                Directory.Delete(detachedPath, true);
                return;
            }
            catch { Thread.Sleep(250); }
        }

        try
        {
            string[] files = Directory.GetFiles(detachedPath, "*", SearchOption.AllDirectories);
            foreach (string file in files) MoveFileEx(file, null, 4);
            string[] directories = Directory.GetDirectories(detachedPath, "*", SearchOption.AllDirectories);
            Array.Sort<string>(directories, delegate(string left, string right) { return right.Length.CompareTo(left.Length); });
            foreach (string directory in directories) MoveFileEx(directory, null, 4);
            MoveFileEx(detachedPath, null, 4);
        }
        catch { }
    }

    private static void RemoveRegistrationAndShortcuts()
    {
        TryDeleteFile(DesktopShortcutPath());
        string startMenu = StartMenuFolder();
        try { if (Directory.Exists(startMenu)) Directory.Delete(startMenu, true); } catch { }
        try { Registry.CurrentUser.DeleteSubKeyTree(RegistryKeyPath, false); } catch { }
    }

    private static void TryDeleteFile(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { }
    }
}

internal sealed class InstallerForm : Form
{
    private readonly TextBox destination;
    private readonly CheckBox desktopShortcut;
    private readonly CheckBox startMenuShortcut;
    private readonly ProgressBar progress;
    private readonly Label status;
    private readonly Button installButton;
    private readonly Button closeButton;

    internal InstallerForm()
    {
        Text = "JH Camera錄影程式安裝程式 v" + InstallerProgram.ProductVersion;
        try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        ClientSize = new Size(620, 330);
        Font = new Font("Microsoft JhengHei UI", 10F);

        Label title = new Label();
        title.Text = "JH Camera錄影程式 v" + InstallerProgram.ProductVersion;
        title.Font = new Font("Microsoft JhengHei UI", 19F, FontStyle.Bold);
        title.Location = new Point(24, 20);
        title.Size = new Size(560, 42);
        Controls.Add(title);

        Label description = new Label();
        description.Text = "安裝螢幕錄影、系統聲音與麥克風錄製功能（已包含 FFmpeg）。";
        description.ForeColor = Color.DimGray;
        description.Location = new Point(27, 66);
        description.Size = new Size(565, 28);
        Controls.Add(description);

        Label pathLabel = new Label();
        pathLabel.Text = "安裝位置";
        pathLabel.Location = new Point(27, 108);
        pathLabel.Size = new Size(100, 25);
        Controls.Add(pathLabel);

        destination = new TextBox();
        destination.Location = new Point(27, 136);
        destination.Size = new Size(470, 29);
        destination.Text = InstallerProgram.DefaultInstallPath();
        Controls.Add(destination);

        Button browse = new Button();
        browse.Text = "瀏覽…";
        browse.Location = new Point(507, 133);
        browse.Size = new Size(88, 34);
        browse.Click += BrowseClicked;
        Controls.Add(browse);

        desktopShortcut = new CheckBox();
        desktopShortcut.Text = "建立桌面捷徑";
        desktopShortcut.Checked = true;
        desktopShortcut.Location = new Point(28, 180);
        desktopShortcut.Size = new Size(160, 28);
        Controls.Add(desktopShortcut);

        startMenuShortcut = new CheckBox();
        startMenuShortcut.Text = "建立開始功能表捷徑";
        startMenuShortcut.Checked = false;
        startMenuShortcut.Location = new Point(215, 180);
        startMenuShortcut.Size = new Size(210, 28);
        Controls.Add(startMenuShortcut);

        progress = new ProgressBar();
        progress.Location = new Point(27, 218);
        progress.Size = new Size(568, 24);
        progress.Minimum = 0;
        progress.Maximum = 100;
        Controls.Add(progress);

        status = new Label();
        status.Text = "準備安裝。";
        status.ForeColor = Color.DimGray;
        status.Location = new Point(28, 248);
        status.Size = new Size(565, 28);
        Controls.Add(status);

        installButton = new Button();
        installButton.Text = "安裝";
        installButton.Font = new Font("Microsoft JhengHei UI", 10F, FontStyle.Bold);
        installButton.Location = new Point(399, 282);
        installButton.Size = new Size(95, 36);
        installButton.Click += InstallClicked;
        Controls.Add(installButton);

        closeButton = new Button();
        closeButton.Text = "取消";
        closeButton.Location = new Point(500, 282);
        closeButton.Size = new Size(95, 36);
        closeButton.Click += delegate { Close(); };
        Controls.Add(closeButton);
        AcceptButton = installButton;
        CancelButton = closeButton;
    }

    private void BrowseClicked(object sender, EventArgs e)
    {
        using (FolderBrowserDialog dialog = new FolderBrowserDialog())
        {
            dialog.Description = "選擇 JH Camera錄影程式的專用安裝資料夾";
            dialog.SelectedPath = destination.Text;
            if (dialog.ShowDialog(this) == DialogResult.OK) destination.Text = dialog.SelectedPath;
        }
    }

    private void InstallClicked(object sender, EventArgs e)
    {
        string target;
        try { target = Path.GetFullPath(destination.Text.Trim()); }
        catch (Exception exception)
        {
            MessageBox.Show(this, "安裝位置無效：\r\n" + exception.Message, "無法安裝", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }
        if (InstallerProgram.IsProtectedInstallPath(target))
        {
            MessageBox.Show(this, "請選擇一個專用的子資料夾，不能直接安裝到磁碟根目錄或使用者主要資料夾。", "安裝位置不安全", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }
        if (Directory.Exists(target) && !File.Exists(Path.Combine(target, InstallerProgram.MarkerName)))
        {
            try
            {
                if (Directory.GetFileSystemEntries(target).Length > 0)
                {
                    MessageBox.Show(this, "選取的資料夾已有其他檔案。請選擇空白資料夾，或使用預設位置。", "請選擇專用資料夾", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }
            }
            catch (Exception exception)
            {
                MessageBox.Show(this, "無法檢查安裝位置：\r\n" + exception.Message, "無法安裝", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }
        }

        string temporaryRoot = Path.Combine(Path.GetTempPath(), "JHCameraInstall_" + Guid.NewGuid().ToString("N"));
        string zipPath = Path.Combine(temporaryRoot, "payload.zip");
        string stagingPath = Path.Combine(temporaryRoot, "payload");
        SetBusy(true);
        try
        {
            Directory.CreateDirectory(temporaryRoot);
            Directory.CreateDirectory(stagingPath);
            status.Text = "正在讀取安裝檔案…";
            progress.Value = 5;
            Application.DoEvents();

            using (Stream resource = Assembly.GetExecutingAssembly().GetManifestResourceStream("JHCamera.Payload.zip"))
            {
                if (resource == null) throw new InvalidOperationException("安裝程式內缺少 payload 資料。");
                using (FileStream output = new FileStream(zipPath, FileMode.Create, FileAccess.Write, FileShare.None))
                {
                    byte[] buffer = new byte[1024 * 1024];
                    long copied = 0;
                    int read;
                    while ((read = resource.Read(buffer, 0, buffer.Length)) > 0)
                    {
                        output.Write(buffer, 0, read);
                        copied += read;
                        progress.Value = Math.Min(35, 5 + (int)(copied * 30L / Math.Max(1L, resource.Length)));
                        Application.DoEvents();
                    }
                }
            }

            status.Text = "正在解壓縮 FFmpeg 與錄影程式…";
            progress.Value = 40;
            Application.DoEvents();
            ZipFile.ExtractToDirectory(zipPath, stagingPath);

            Directory.CreateDirectory(target);
            string[] directories = Directory.GetDirectories(stagingPath, "*", SearchOption.AllDirectories);
            foreach (string directory in directories)
            {
                string relative = directory.Substring(stagingPath.Length).TrimStart(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                Directory.CreateDirectory(Path.Combine(target, relative));
            }

            string[] files = Directory.GetFiles(stagingPath, "*", SearchOption.AllDirectories);
            for (int index = 0; index < files.Length; index++)
            {
                string relative = files[index].Substring(stagingPath.Length).TrimStart(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                string outputPath = Path.Combine(target, relative);
                Directory.CreateDirectory(Path.GetDirectoryName(outputPath));
                File.Copy(files[index], outputPath, true);
                progress.Value = Math.Min(90, 45 + (int)((index + 1) * 45L / Math.Max(1, files.Length)));
                status.Text = "正在安裝：" + relative;
                Application.DoEvents();
            }

            // The launcher filename includes the release number. Remove an
            // older versioned/unversioned launcher after the new payload is
            // safely copied so shortcuts cannot keep pointing at stale code.
            foreach (string launcherPattern in new string[] { "錄製專用*.exe", "JH錄影*.exe" })
            {
                foreach (string oldLauncher in Directory.GetFiles(target, launcherPattern, SearchOption.TopDirectoryOnly))
                {
                    if (!String.Equals(Path.GetFileName(oldLauncher), InstallerProgram.LauncherName, StringComparison.OrdinalIgnoreCase))
                    {
                        try { File.Delete(oldLauncher); } catch { }
                    }
                }
            }

            File.WriteAllText(Path.Combine(target, InstallerProgram.MarkerName), "JH Camera " + InstallerProgram.ProductVersion, new UTF8Encoding(false));
            string installedUninstaller = Path.Combine(target, InstallerProgram.UninstallerName);
            // The payload contains a small standalone uninstaller. Keep the
            // full installer only as a compatibility fallback for old builds.
            if (!File.Exists(installedUninstaller))
                File.Copy(Application.ExecutablePath, installedUninstaller, true);
            string launcher = Path.Combine(target, InstallerProgram.LauncherName);

            if (desktopShortcut.Checked)
                InstallerProgram.CreateShortcut(InstallerProgram.DesktopShortcutPath(), launcher, target, InstallerProgram.ProductName);
            else
            {
                try { if (File.Exists(InstallerProgram.DesktopShortcutPath())) File.Delete(InstallerProgram.DesktopShortcutPath()); } catch { }
            }

            string startMenu = InstallerProgram.StartMenuFolder();
            if (startMenuShortcut.Checked)
            {
                InstallerProgram.CreateShortcut(Path.Combine(startMenu, InstallerProgram.ProductName + ".lnk"), launcher, target, InstallerProgram.ProductName);
                InstallerProgram.CreateShortcut(Path.Combine(startMenu, "解除安裝 " + InstallerProgram.ProductName + ".lnk"), Path.Combine(target, InstallerProgram.UninstallerName), target, "解除安裝 " + InstallerProgram.ProductName);
            }
            else
            {
                try { if (Directory.Exists(startMenu)) Directory.Delete(startMenu, true); } catch { }
            }

            InstallerProgram.RegisterUninstaller(target);
            InstallerProgram.RefreshShellIcons();
            progress.Value = 100;
            status.Text = "安裝完成。";
            Application.DoEvents();

            DialogResult launch = MessageBox.Show(this, "JH Camera錄影程式已安裝完成。\r\n\r\n要現在開啟程式嗎？", "安裝完成", MessageBoxButtons.YesNo, MessageBoxIcon.Information);
            if (launch == DialogResult.Yes) Process.Start(launcher);
            Close();
        }
        catch (Exception exception)
        {
            status.Text = "安裝失敗。";
            MessageBox.Show(this, "安裝未完成。請先關閉正在執行的舊版錄影程式後再試一次。\r\n\r\n" + exception.Message, "安裝失敗", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
        finally
        {
            try { if (Directory.Exists(temporaryRoot)) Directory.Delete(temporaryRoot, true); } catch { }
            SetBusy(false);
        }
    }

    private void SetBusy(bool busy)
    {
        destination.Enabled = !busy;
        desktopShortcut.Enabled = !busy;
        startMenuShortcut.Enabled = !busy;
        installButton.Enabled = !busy;
        closeButton.Enabled = !busy;
        UseWaitCursor = busy;
    }
}
