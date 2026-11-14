using System.Diagnostics;
using System.IO;
using System.Windows;
using RightClip.Core.Media;

namespace RightClip.App;

public partial class OperationProgressWindow : Window
{
    private bool _allowClose;
    private string? _lastOutput;

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

    public event EventHandler? ReturnRequested;

    public event EventHandler? CloseApplicationRequested;

    public bool SuppressCompletionNotification => SkipNotification.IsChecked == true;

    public bool IsComplete { get; private set; }

    public void Update(OperationProgress update)
    {
        CurrentFileText.Text = $"{Path.GetFileName(update.SourcePath)} · {update.Status}";
        Progress.IsIndeterminate = update.Fraction is null;
        Progress.Value = update.Fraction ?? 0;
        PercentText.Text = update.Fraction is { } fraction ? $"{fraction:P0}" : string.Empty;
    }

    public void ShowCompletion(IReadOnlyList<FileOperationResult> results)
    {
        var successes = results.Where(result => result.Succeeded).ToArray();
        var outputs = successes.SelectMany(result => result.OutputPaths).ToArray();
        var failures = results.Where(result => !result.Succeeded).ToArray();
        _lastOutput = outputs.LastOrDefault();
        IsComplete = true;
        OperationText.Text = failures.Length == 0 ? "Writing completed" : outputs.Length > 0 ? "Writing completed with errors" :
            failures.All(result => result.Cancelled) ? "Writing cancelled" : "Writing could not complete";
        ResultSummary.Text = $"{successes.Length} files completed · {outputs.Length} new outputs · {failures.Length} failed or cancelled. Originals were not changed.";
        Outputs.ItemsSource = outputs;
        Failures.ItemsSource = failures.Select(result => $"{Path.GetFileName(result.SourcePath)}: {result.Error}").ToArray();
        Outputs.Visibility = outputs.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        Failures.Visibility = failures.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        OpenOutputButton.IsEnabled = outputs.Length > 0;
        CurrentFileText.Visibility = Visibility.Collapsed;
        Progress.Visibility = Visibility.Collapsed;
        PercentText.Visibility = Visibility.Collapsed;
        SkipNotification.Visibility = Visibility.Collapsed;
        WorkingButtons.Visibility = Visibility.Collapsed;
        ResultSummary.Visibility = Visibility.Visible;
        CompletionItems.Visibility = outputs.Length + failures.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        CompletionButtons.Visibility = Visibility.Visible;
    }

    public void Dismiss()
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

    private void ReturnToAppClick(object sender, RoutedEventArgs e) => ReturnRequested?.Invoke(this, EventArgs.Empty);

    private void CloseApplicationClick(object sender, RoutedEventArgs e) => CloseApplicationRequested?.Invoke(this, EventArgs.Empty);

    private void OpenOutputClick(object sender, RoutedEventArgs e)
    {
        if (_lastOutput is not null)
        {
            Process.Start(new ProcessStartInfo { FileName = "explorer.exe", Arguments = $"/select,\"{_lastOutput}\"", UseShellExecute = true });
        }
    }

    private void WindowClosing(object sender, System.ComponentModel.CancelEventArgs e)
    {
        if (_allowClose)
        {
            return;
        }

        e.Cancel = true;
        if (IsComplete)
        {
            Dispatcher.BeginInvoke(new System.Action(() => ReturnRequested?.Invoke(this, EventArgs.Empty)));
        }
        else
        {
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
