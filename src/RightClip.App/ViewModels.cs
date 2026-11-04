using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Runtime.CompilerServices;
using System.Windows.Input;
using System.Windows.Media;
using RightClip.Core.Media;

namespace RightClip.App;

public abstract class ObservableObject : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? propertyName = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value))
        {
            return false;
        }

        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
        return true;
    }

    protected void Changed([CallerMemberName] string? propertyName = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
}

public sealed class AsyncRelayCommand : ObservableObject, ICommand
{
    private readonly Func<Task> _execute;
    private readonly Func<bool>? _canExecute;
    private bool _isRunning;

    public AsyncRelayCommand(Func<Task> execute, Func<bool>? canExecute = null)
    {
        _execute = execute;
        _canExecute = canExecute;
    }

    public event EventHandler? CanExecuteChanged;

    public bool IsRunning
    {
        get => _isRunning;
        set
        {
            if (Set(ref _isRunning, value))
            {
                CanExecuteChanged?.Invoke(this, EventArgs.Empty);
            }
        }
    }

    public bool CanExecute(object? parameter) => !IsRunning && (_canExecute?.Invoke() ?? true);

    public async void Execute(object? parameter)
    {
        IsRunning = true;
        try
        {
            await _execute();
        }
        finally
        {
            IsRunning = false;
        }
    }

    public void RaiseCanExecuteChanged() => CanExecuteChanged?.Invoke(this, EventArgs.Empty);
}

public sealed class RelayCommand : ICommand
{
    private readonly Action _execute;
    private readonly Func<bool>? _canExecute;

    public RelayCommand(Action execute, Func<bool>? canExecute = null)
    {
        _execute = execute;
        _canExecute = canExecute;
    }

    public event EventHandler? CanExecuteChanged;

    public bool CanExecute(object? parameter) => _canExecute?.Invoke() ?? true;

    public void Execute(object? parameter) => _execute();

    public void RaiseCanExecuteChanged() => CanExecuteChanged?.Invoke(this, EventArgs.Empty);
}

public sealed class MediaFileItem : ObservableObject
{
    private string _status = "Reading media information";
    private double _progress;
    private string _outputs = string.Empty;
    private MediaInfo? _media;

    public MediaFileItem(string sourcePath)
    {
        SourcePath = sourcePath;
    }

    public string SourcePath { get; }

    public string FileName => Path.GetFileName(SourcePath);

    public MediaInfo? Media { get => _media; set => Set(ref _media, value); }

    public string Status { get => _status; set => Set(ref _status, value); }

    public double Progress { get => _progress; set => Set(ref _progress, value); }

    public string Outputs { get => _outputs; set => Set(ref _outputs, value); }
}

public sealed class TrackRow : ObservableObject
{
    private bool _keep;
    private string _title;

    public TrackRow(MediaStream stream)
    {
        CodecType = stream.CodecType;
        Ordinal = stream.Ordinal;
        DisplayName = stream.DisplayName;
        _keep = true;
        _title = stream.Title ?? string.Empty;
    }

    public string CodecType { get; }

    public int Ordinal { get; }

    public string DisplayName { get; }

    public bool Keep { get => _keep; set => Set(ref _keep, value); }

    public string Title { get => _title; set => Set(ref _title, value); }
}

public sealed class SubtitleRow : ObservableObject
{
    private string _title = string.Empty;
    private string _language = string.Empty;

    public SubtitleRow(string path)
    {
        Path = path;
    }

    public string Path { get; }

    public string FileName => System.IO.Path.GetFileName(Path);

    public string Title { get => _title; set => Set(ref _title, value); }

    public string Language { get => _language; set => Set(ref _language, value); }
}

public sealed class TagRow : ObservableObject
{
    private string _key = string.Empty;
    private string _value = string.Empty;

    public TagRow(string key = "", string value = "")
    {
        _key = key;
        _value = value;
    }

    public string Key { get => _key; set => Set(ref _key, value); }

    public string Value { get => _value; set => Set(ref _value, value); }
}

public sealed class ChapterRow : ObservableObject
{
    private string _start;
    private string _end;
    private string _title;

    public ChapterRow(string start, string end, string title = "")
    {
        _start = start;
        _end = end;
        _title = title;
    }

    public string Start { get => _start; set => Set(ref _start, value); }

    public string End { get => _end; set => Set(ref _end, value); }

    public string Title { get => _title; set => Set(ref _title, value); }
}

public sealed class ReviewItem
{
    public ImageSource? Thumbnail { get; init; }

    public string Title { get; init; } = string.Empty;

    public string Timing { get; init; } = string.Empty;

    public string OutputPath { get; init; } = string.Empty;
}

public sealed class ReviewGroup
{
    public string FileName { get; init; } = string.Empty;

    public string Summary { get; init; } = string.Empty;

    public IReadOnlyList<ReviewItem> Items { get; init; } = [];
}
