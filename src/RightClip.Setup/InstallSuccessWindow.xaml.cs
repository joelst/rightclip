using System.Windows;

namespace RightClip.Setup;

public partial class InstallSuccessWindow : Window
{
    public InstallSuccessWindow(string installDirectory)
    {
        InitializeComponent();
        LocationText.Text = $"RightClip is ready to use. Installed in {installDirectory}";
    }

    public event EventHandler? ViewLogRequested;

    private void ViewLogClick(object sender, RoutedEventArgs e) => ViewLogRequested?.Invoke(this, EventArgs.Empty);

    private void ExitClick(object sender, RoutedEventArgs e) => Close();
}
