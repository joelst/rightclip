using System.IO;
using System.Windows;
using RightClip.Core;
using RightClip.Core.Media;

namespace RightClip.App;

public partial class MetadataRemovalWindow : Window
{
    private readonly IReadOnlyList<string> _paths;
    private readonly RightClipServices _services;
    private readonly CancellationTokenSource _cancellation = new();
    private bool _busy = true;
    private bool _closeRequested;

    public MetadataRemovalWindow(IReadOnlyList<string> paths, UserSettings settings)
    {
        InitializeComponent();
        _paths = paths;
        _services = new RightClipServices(settings.FFmpegDirectory);
    }

    private async void WindowLoaded(object sender, RoutedEventArgs e)
    {
        try
        {
            var progress = new Progress<OperationProgress>(update =>
            {
                if (_busy)
                {
                    CurrentFileText.Text = $"{Path.GetFileName(update.SourcePath)} - {update.Status}";
                    OperationProgress.IsIndeterminate = update.Fraction is null;
                    OperationProgress.Value = update.Fraction ?? 0;
                }
            });
            var results = await _services.RemoveMetadataAsync(_paths, progress, _cancellation.Token);
            var outputs = results.Where(result => result.Succeeded).SelectMany(result => result.OutputPaths).ToArray();
            var failures = results.Where(result => !result.Succeeded).ToArray();
            StatusText.Text = failures.Length == 0 ? "Completed" : outputs.Length > 0 ? "Completed with errors" :
                failures.All(result => result.Cancelled) ? "Cancelled" : "Could not remove metadata";
            var messages = new List<string>();
            if (outputs.Length > 0)
            {
                messages.Add((outputs.Length == 1 ? "Completed file is in:" : "Completed files are in:") +
                    Environment.NewLine + string.Join(Environment.NewLine, outputs));
            }
            messages.AddRange(failures.Select(result => $"{Path.GetFileName(result.SourcePath)}: {result.Error}"));
            ResultText.Text = string.Join(Environment.NewLine + Environment.NewLine, messages);
        }
        catch (OperationCanceledException)
        {
            StatusText.Text = "Cancelled";
            ResultText.Text = "No metadata removal completed.";
        }
        catch (Exception exception)
        {
            StatusText.Text = "Could not remove metadata";
            ResultText.Text = exception.Message;
        }
        finally
        {
            _busy = false;
            _cancellation.Dispose();
            CurrentFileText.Text = string.Empty;
            OperationProgress.Visibility = Visibility.Collapsed;
            if (_closeRequested)
            {
                Close();
            }
        }
    }

    private void WindowClosing(object sender, System.ComponentModel.CancelEventArgs e)
    {
        if (_busy)
        {
            e.Cancel = true;
            _closeRequested = true;
            _cancellation.Cancel();
            StatusText.Text = "Cancelling";
        }
    }
}
