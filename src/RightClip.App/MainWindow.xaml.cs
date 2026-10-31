using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Input;
using Microsoft.Win32;

namespace RightClip.App;

public partial class MainWindow : Window
{
    public MainWindow(MainViewModel viewModel)
    {
        InitializeComponent();
        ViewModel = viewModel;
        DataContext = viewModel;
    }

    public MainViewModel ViewModel { get; }

    private void AddClick(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog
        {
            Title = "Select videos",
            Multiselect = true,
            Filter = "Videos (*.mp4;*.mov;*.mkv;*.webm)|*.mp4;*.mov;*.mkv;*.webm|All files (*.*)|*.*"
        };
        if (dialog.ShowDialog(this) == true)
        {
            ViewModel.AddPaths(dialog.FileNames);
        }
    }

    private void RemoveClick(object sender, RoutedEventArgs e)
    {
        ViewModel.RemoveFiles(FilesGrid.SelectedItems.Cast<MediaFileItem>());
    }

    private void SettingsClick(object sender, RoutedEventArgs e)
    {
        var current = new UserSettings(ViewModel.SettingsFFmpegDirectory, ViewModel.SceneSensitivity);
        var dialog = new SettingsWindow(current) { Owner = this };
        if (dialog.ShowDialog() != true || dialog.Result is not { } settings)
        {
            return;
        }

        try
        {
            SettingsStore.Save(settings);
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
    }

    private void WindowDragOver(object sender, DragEventArgs e)
    {
        e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop) ? DragDropEffects.Copy : DragDropEffects.None;
        e.Handled = true;
    }

    private void WindowDrop(object sender, DragEventArgs e)
    {
        if (e.Data.GetData(DataFormats.FileDrop) is string[] paths)
        {
            ViewModel.AddPaths(paths);
        }
    }
}
