using System.Windows;

namespace RightClip.App;

public partial class SettingsWindow : Window
{
    public SettingsWindow(UserSettings settings)
    {
        InitializeComponent();
        DirectoryBox.Text = settings.FFmpegDirectory ?? string.Empty;
        SensitivitySlider.Value = settings.SceneSensitivity;
    }

    public UserSettings? Result { get; private set; }

    private void BrowseClick(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.OpenFolderDialog
        {
            Title = "Choose the folder containing ffmpeg.exe and ffprobe.exe"
        };
        if (dialog.ShowDialog(this) == true)
        {
            DirectoryBox.Text = dialog.FolderName;
        }
    }

    private void SaveClick(object sender, RoutedEventArgs e)
    {
        Result = new UserSettings(string.IsNullOrWhiteSpace(DirectoryBox.Text) ? null : DirectoryBox.Text.Trim(), (int)SensitivitySlider.Value);
        DialogResult = true;
    }

    private void CancelClick(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
    }
}
