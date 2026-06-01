using System.Diagnostics;
using System.Reflection;
using System.Windows.Forms;

namespace SafeEject.Launcher;

internal static class Program
{
    [STAThread]
    private static int Main()
    {
        ApplicationConfiguration.Initialize();

        try
        {
            var scriptPath = ExtractScript();
            using var process = Process.Start(new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = $"-NoProfile -ExecutionPolicy Bypass -STA -File \"{scriptPath}\"",
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            });

            process?.WaitForExit();
            return process?.ExitCode ?? 0;
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                "SafeEject could not start.\n\n" + ex.Message,
                "SafeEject",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return 1;
        }
    }

    private static string ExtractScript()
    {
        var assembly = Assembly.GetExecutingAssembly();
        const string resourceName = "SafeEject.ps1";

        using var resource = assembly.GetManifestResourceStream(resourceName)
            ?? throw new InvalidOperationException("Embedded SafeEject.ps1 resource was not found.");

        var targetDir = Path.Combine(Path.GetTempPath(), "SafeEject");
        Directory.CreateDirectory(targetDir);

        var targetPath = Path.Combine(targetDir, "SafeEject.ps1");
        using var file = File.Create(targetPath);
        resource.CopyTo(file);
        return targetPath;
    }
}
