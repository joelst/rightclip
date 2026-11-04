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
                window.ViewModel.AddPaths(arguments.Paths);
            }
        }
        catch (Exception exception)
        {
            MessageBox.Show(exception.ToString(), "RightClip could not start", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown(1);
        }
    }
}
