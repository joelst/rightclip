using System.Diagnostics;
using System.Windows;

namespace RightClip.Setup;

public partial class MainWindow : Window
{
    private readonly bool _portable;
    private bool _busy;
    private bool _completed;

    public MainWindow(InstallerOptions options)
    {
        InitializeComponent();
        _portable = options.Portable;
        DirectoryBox.Text = options.InstallDirectory;
        ExplorerBox.IsChecked = options.RegisterExplorer;
        ModernMenuBox.IsChecked = options.ModernMenu;
        TrustCertificateBox.IsChecked = options.TrustPackageCertificate;
        TrustCertificateBox.Visibility = Installer.IsProductionSignedPayload() ? Visibility.Collapsed : Visibility.Visible;
        ShortcutBox.IsChecked = options.CreateStartMenuShortcut;
    }

    private void BrowseClick(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.OpenFolderDialog { Title = "Choose the RightClip install location" };
        if (dialog.ShowDialog(this) == true)
        {
            DirectoryBox.Text = dialog.FolderName;
        }
    }

    private async void InstallClick(object sender, RoutedEventArgs e)
    {
        if (_completed)
        {
            Close();
            return;
        }

        SetBusy(true);
        try
        {
            var options = new InstallerOptions(DirectoryBox.Text, Portable: _portable,
                RegisterExplorer: ExplorerBox.IsChecked == true, CreateStartMenuShortcut: ShortcutBox.IsChecked == true,
                ModernMenu: ModernMenuBox.IsChecked == true, TrustPackageCertificate: TrustCertificateBox.IsChecked == true);
            var progress = new Progress<string>(message => StatusText.Text = message);
            await Installer.InstallAsync(options, progress);
            _completed = true;
            _busy = false;
            StatusText.Text = $"RightClip is installed in {options.InstallDirectory}. Right-click a supported video to start. If an upgrade still shows the old commands, restart Explorer—not Windows.";
            ContentScrollViewer.ScrollToEnd();
            InstallButton.Content = "Close";
            InstallButton.IsEnabled = true;
            CancelButton.IsEnabled = false;
            InstallProgress.Visibility = Visibility.Collapsed;
            LogButton.Visibility = Visibility.Visible;
        }
        catch (OperationCanceledException exception)
        {
            StatusText.Text = exception.Message;
            ContentScrollViewer.ScrollToEnd();
            LogButton.Visibility = Visibility.Visible;
            SetBusy(false);
        }
        catch (Exception exception)
        {
            StatusText.Text = exception.Message;
            ContentScrollViewer.ScrollToEnd();
            LogButton.Visibility = Visibility.Visible;
            MessageBox.Show(this, exception.Message, "RightClip Setup could not install", MessageBoxButton.OK, MessageBoxImage.Error);
            SetBusy(false);
        }
    }

    private void LogClick(object sender, RoutedEventArgs e)
    {
        if (InstallerLog.LogPath is { } path)
        {
            Process.Start(new ProcessStartInfo { FileName = "notepad.exe", Arguments = $"\"{path}\"", UseShellExecute = true });
        }
    }

    private void CancelClick(object sender, RoutedEventArgs e)
    {
        Close();
    }

    private void WindowClosing(object sender, System.ComponentModel.CancelEventArgs e)
    {
        e.Cancel = _busy;
    }

    private void SetBusy(bool busy)
    {
        _busy = busy;
        InstallButton.IsEnabled = !busy;
        CancelButton.IsEnabled = !busy;
        BrowseButton.IsEnabled = !busy;
        DirectoryBox.IsEnabled = !busy;
        ExplorerBox.IsEnabled = !busy;
        ModernMenuBox.IsEnabled = !busy;
        TrustCertificateBox.IsEnabled = !busy;
        ShortcutBox.IsEnabled = !busy;
        InstallProgress.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
    }
}
