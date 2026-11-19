using System.Diagnostics;
using System.Windows;
using RightClip.Core.Launch;

namespace RightClip.App;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        try
        {
            var arguments = WorkerArguments.Parse(e.Args);
            if (arguments.Paths.Count > 1)
            {
                var executable = Environment.ProcessPath ?? throw new InvalidOperationException("The RightClip executable path is unavailable.");
                foreach (var path in arguments.Paths)
                {
                    var startInfo = new ProcessStartInfo { FileName = executable, UseShellExecute = false };
                    startInfo.ArgumentList.Add("--action");
                    startInfo.ArgumentList.Add(arguments.Action);
                    startInfo.ArgumentList.Add("--path");
                    startInfo.ArgumentList.Add(path);
                    Process.Start(startInfo);
                }

                Shutdown();
                return;
            }

            var settings = SettingsStore.Load();
            if (arguments.Action == "remove-metadata")
            {
                var progressWindow = new MetadataRemovalWindow(arguments.Paths, settings);
                MainWindow = progressWindow;
                progressWindow.Show();
                return;
            }

            var window = new MainWindow(new MainViewModel(settings));
            window.ViewModel.SelectedActionIndex = arguments.Action switch
            {
                "tracks" => 1,
                "details" => 2,
                _ => 0
            };
            MainWindow = window;
            window.Show();
            if (arguments.Paths.Count > 0)
            {
                window.ViewModel.OpenPath(arguments.Paths[0]);
            }
        }
        catch (Exception exception)
        {
            MessageBox.Show(exception.ToString(), "RightClip could not start", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown(1);
        }
    }
}
