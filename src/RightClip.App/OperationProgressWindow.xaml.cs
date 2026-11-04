using System.IO;
using System.Windows;
using RightClip.Core.Media;

namespace RightClip.App;

public partial class OperationProgressWindow : Window
{
    private bool _allowClose;

    public OperationProgressWindow(string description, bool suppressCompletionNotification)
    {
        InitializeComponent();
        OperationText.Text = description;
        CurrentFileText.Text = "Preparing output files";
        SkipNotification.IsChecked = suppressCompletionNotification;
        Progress.IsIndeterminate = true;
    }

    public event EventHandler? HideRequested;

    public event EventHandler? CancelRequested;

    public event EventHandler? NotificationPreferenceChanged;

    public bool SuppressCompletionNotification => SkipNotification.IsChecked == true;

    public void Update(OperationProgress update)
    {
        CurrentFileText.Text = $"{Path.GetFileName(update.SourcePath)} · {update.Status}";
        Progress.IsIndeterminate = update.Fraction is null;
        Progress.Value = update.Fraction ?? 0;
        PercentText.Text = update.Fraction is { } fraction ? $"{fraction:P0}" : string.Empty;
    }

    public void Complete()
    {
        _allowClose = true;
        Close();
    }

    private void CancelClick(object sender, RoutedEventArgs e) => CancelRequested?.Invoke(this, EventArgs.Empty);

    private void HideClick(object sender, RoutedEventArgs e)
    {
        Hide();
        HideRequested?.Invoke(this, EventArgs.Empty);
    }

    private void WindowClosing(object sender, System.ComponentModel.CancelEventArgs e)
    {
        if (!_allowClose)
        {
            e.Cancel = true;
            Hide();
            HideRequested?.Invoke(this, EventArgs.Empty);
        }
    }

    private void SkipChanged(object sender, RoutedEventArgs e)
    {
        try
        {
            var settings = SettingsStore.Load();
            SettingsStore.Save(settings with { SuppressCompletionNotification = SuppressCompletionNotification });
            NotificationPreferenceChanged?.Invoke(this, EventArgs.Empty);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            ToolTip = "The notification preference could not be saved.";
        }
    }
}
