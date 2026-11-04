using System.Diagnostics;
using System.IO;
using System.Windows;
using RightClip.Core.Media;

namespace RightClip.App;

public partial class OperationResultWindow : Window
{
    private readonly string? _lastOutput;

    public OperationResultWindow(IReadOnlyList<FileOperationResult> results)
    {
        InitializeComponent();
        var successes = results.Where(result => result.Succeeded).ToArray();
        var outputs = successes.SelectMany(result => result.OutputPaths).ToArray();
        var failures = results.Where(result => !result.Succeeded).ToArray();
        _lastOutput = outputs.LastOrDefault();
        ResultTitle.Text = failures.Length == 0 ? "Completed" : outputs.Length > 0 ? "Completed with errors" :
            failures.All(result => result.Cancelled) ? "Cancelled" : "Could not complete";
        ResultSummary.Text = $"{successes.Length} files completed · {outputs.Length} new outputs · {failures.Length} failed or cancelled. Originals were not changed.";
        Outputs.ItemsSource = outputs;
        Failures.ItemsSource = failures.Select(result => $"{Path.GetFileName(result.SourcePath)}: {result.Error}").ToArray();
        Outputs.Visibility = outputs.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        Failures.Visibility = failures.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    private void OpenOutputClick(object sender, RoutedEventArgs e)
    {
        if (_lastOutput is not null)
        {
            Process.Start(new ProcessStartInfo { FileName = "explorer.exe", Arguments = $"/select,\"{_lastOutput}\"", UseShellExecute = true });
        }
    }

    private void CloseClick(object sender, RoutedEventArgs e) => Close();
}
