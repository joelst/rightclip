using System.Windows;

namespace RightClip.Setup;

public partial class App : Application
{
    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        try
        {
            var options = InstallerOptions.Parse(e.Args);
            if (options.Silent)
            {
                try
                {
                    await Installer.InstallAsync(options);
                    Shutdown(0);
                }
                catch (Exception exception)
                {
                    Console.Error.WriteLine(exception.Message);
                    Shutdown(1);
                }

                return;
            }

            var window = new MainWindow(options);
            MainWindow = window;
            window.Show();
        }
        catch (Exception exception)
        {
            MessageBox.Show(exception.Message, "RightClip Setup", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown(1);
        }
    }
}
