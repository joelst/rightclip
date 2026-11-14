using System.Windows;

namespace RightClip.Setup;

public partial class InstallSuccessWindow : Window
{
    public InstallSuccessWindow(string installDirectory)
    {
        InitializeComponent();
        LocationText.Text = $"RightClip is ready to use. Installed in {installDirectory}";
    }

    private void ExitClick(object sender, RoutedEventArgs e) => Close();
}
