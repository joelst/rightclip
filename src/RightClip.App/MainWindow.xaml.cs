using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Input;
using Microsoft.Win32;

namespace RightClip.App;

public partial class MainWindow : Window
{
    private PreviewWindow? _previewWindow;

    public MainWindow(MainViewModel viewModel)
    {
        InitializeComponent();
        ViewModel = viewModel;
        DataContext = viewModel;
        viewModel.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(MainViewModel.IsTrimAction) && !viewModel.IsTrimAction)
            {
                _previewWindow?.Close();
            }
        };
    }

    public MainViewModel ViewModel { get; }

    public void CloseDetachedPreview() => _previewWindow?.Close();

    private void WindowSizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (DataContext is MainViewModel viewModel)
        {
            viewModel.IsCompactLayout = ActualHeight < 820;
            viewModel.IsShortLayout = ActualHeight < 720;
            Dispatcher.BeginInvoke(new Action(UpdatePreviewHeightBound), System.Windows.Threading.DispatcherPriority.Loaded);
        }
    }

    private void TrimContentLayoutUpdated(object? sender, EventArgs e) => UpdatePreviewHeightBound();

    private void UpdatePreviewHeightBound()
    {
        if (DataContext is not MainViewModel viewModel || !TrimTabs.IsAncestorOf(TrimContent))
        {
            return;
        }

        var currentHeight = InlinePreviewFrame.ActualHeight;
        var requiredAdvancedHeight = Math.Max(TrimContent.RowDefinitions[4].MinHeight,
            AdvancedTrimOptions.IsExpanded ? AdvancedTrimOptions.DesiredSize.Height : 0);
        var occupiedHeight = TrimContent.RowDefinitions.Take(4).Sum(row => row.ActualHeight);
        var contentTop = TrimContent.TransformToAncestor(TrimTabs).Transform(new Point()).Y;
        var availableHeight = TrimTabs.ActualHeight - contentTop - TrimContent.Margin.Bottom;
        viewModel.MaxPreviewHeight = currentHeight + availableHeight - occupiedHeight - requiredAdvancedHeight;
    }

    private void AddClick(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog
        {
            Title = "Open video",
            Multiselect = false,
            Filter = "Videos (*.mp4;*.mov;*.mkv;*.webm)|*.mp4;*.mov;*.mkv;*.webm|All files (*.*)|*.*"
        };
        if (dialog.ShowDialog(this) == true)
        {
            ViewModel.OpenPath(dialog.FileName);
        }
    }

    private void TimelineCutAdded(object sender, TimelineCutEventArgs e) => ViewModel.AddTimelineCut(e.Position);

    private void TimelineCutMoved(object sender, TimelineCutEventArgs e) => ViewModel.MoveTimelineCut(e.OriginalTimestamp, e.Timestamp);

    private void TimelineCutRemoved(object sender, TimelineCutEventArgs e) => ViewModel.RemoveTimelineCut(e.Timestamp);

    private void TimelineCutSelected(object sender, TimelineCutEventArgs e) => ViewModel.SelectTimelineCut(e.Timestamp);

    private void TimelineSegmentToggled(object sender, TimelineSegmentEventArgs e) => ViewModel.ToggleTimelineSegment(e.Index);

    private void TimelineZoomOutClick(object sender, RoutedEventArgs e) => Timeline.ZoomOut();

    private void TimelineZoomInClick(object sender, RoutedEventArgs e) => Timeline.ZoomIn();

    private void TimelineFitClick(object sender, RoutedEventArgs e) => Timeline.FitTimeline();

    private void PreviewResizeDragDelta(object sender, System.Windows.Controls.Primitives.DragDeltaEventArgs e)
    {
        ViewModel.PreviewHeight += e.VerticalChange;
    }

    private void PopOutPreviewClick(object sender, RoutedEventArgs e)
    {
        if (_previewWindow is { } existing)
        {
            existing.Activate();
            return;
        }

        var preview = new PreviewWindow(ViewModel.PreviewAspectRatio) { DataContext = ViewModel, Owner = this };
        _previewWindow = preview;
        InlinePreviewArea.Visibility = Visibility.Collapsed;
        preview.Closed += (_, _) =>
        {
            _previewWindow = null;
            InlinePreviewArea.Visibility = Visibility.Visible;
        };
        preview.Show();
    }

    private void SettingsClick(object sender, RoutedEventArgs e)
    {
        var dialog = new SettingsWindow(ViewModel.CurrentSettings) { Owner = this };
        if (dialog.ShowDialog() != true || dialog.Result is not { } settings)
        {
            return;
        }

        try
        {
            ViewModel.UpdateSettings(settings);
        }
        catch (Exception exception)
        {
            MessageBox.Show(this, exception.Message, "Could not save settings", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void AddSubtitleClick(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog
        {
            Title = "Add soft subtitles",
            Multiselect = true,
            Filter = "Subtitles (*.srt;*.ass;*.ssa;*.vtt;*.mks)|*.srt;*.ass;*.ssa;*.vtt;*.mks|All files (*.*)|*.*"
        };
        if (dialog.ShowDialog(this) == true)
        {
            foreach (var path in dialog.FileNames)
            {
                if (!ViewModel.AddedSubtitles.Any(subtitle => string.Equals(subtitle.Path, path, StringComparison.OrdinalIgnoreCase)))
                {
                    ViewModel.AddedSubtitles.Add(new SubtitleRow(path));
                }
            }
        }
    }

    private void RemoveSubtitleClick(object sender, RoutedEventArgs e)
    {
        foreach (var row in SubtitlesGrid.SelectedItems.Cast<SubtitleRow>().ToArray())
        {
            ViewModel.AddedSubtitles.Remove(row);
        }
    }

    private void AddTagClick(object sender, RoutedEventArgs e)
    {
        ViewModel.Tags.Add(new TagRow());
    }

    private void AddChapterClick(object sender, RoutedEventArgs e)
    {
        ViewModel.Chapters.Add(new ChapterRow("00:00:00.000", "00:00:05.000"));
    }

    private void RemoveChapterClick(object sender, RoutedEventArgs e)
    {
        foreach (var row in ChaptersGrid.SelectedItems.Cast<ChapterRow>().ToArray())
        {
            ViewModel.Chapters.Remove(row);
        }
    }

    private void OpenOutputClick(object sender, RoutedEventArgs e)
    {
        if (ViewModel.LastOutput is not { } output)
        {
            return;
        }

        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = "explorer.exe",
                Arguments = $"/select,\"{output}\"",
                UseShellExecute = true
            });
        }
        catch (Exception exception)
        {
            MessageBox.Show(this, exception.Message, "Could not open the output folder", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void WindowClosing(object sender, System.ComponentModel.CancelEventArgs e)
    {
        if (ViewModel is { IsBusy: true })
        {
            e.Cancel = true;
            ViewModel.CancelCommand.Execute(null);
            ViewModel.BusyStatus = "Cancelling; close again when the current process stops";
        }
        else
        {
            ViewModel.StopPreviews();
        }
    }

    private void WindowDragOver(object sender, DragEventArgs e)
    {
        e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop) ? DragDropEffects.Copy : DragDropEffects.None;
        e.Handled = true;
    }

    private void WindowDrop(object sender, DragEventArgs e)
    {
        if (e.Data.GetData(DataFormats.FileDrop) is not string[] paths)
        {
            return;
        }

        if (paths.Length != 1)
        {
            ViewModel.Summary = "Open one video per RightClip window.";
            return;
        }

        ViewModel.OpenPath(paths[0]);
    }
}
