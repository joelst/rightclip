using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using RightClip.Core.Media;
using RightClip.Core.Operations;

namespace RightClip.App;

public sealed class TimelineCutEventArgs : EventArgs
{
    public TimelineCutEventArgs(double position, double? originalPosition = null)
        : this(TimeSpan.FromSeconds(position), originalPosition is { } original ? TimeSpan.FromSeconds(original) : null)
    {
    }

    public TimelineCutEventArgs(TimeSpan position, TimeSpan? originalPosition = null)
    {
        Timestamp = position;
        OriginalTimestamp = originalPosition ?? position;
        Position = position.TotalSeconds;
        OriginalPosition = OriginalTimestamp.TotalSeconds;
    }

    public double Position { get; }
    public double OriginalPosition { get; }
    public TimeSpan Timestamp { get; }
    public TimeSpan OriginalTimestamp { get; }
}

public sealed class TimelineSegmentEventArgs(int index) : EventArgs
{
    public int Index { get; } = index;
}

public partial class TrimTimelineControl : UserControl
{
    public static readonly DependencyProperty SegmentsProperty = DependencyProperty.Register(
        nameof(Segments), typeof(IReadOnlyList<TrimSegment>), typeof(TrimTimelineControl),
        new PropertyMetadata(Array.Empty<TrimSegment>(), ContentChanged));
    public static readonly DependencyProperty ThumbnailsProperty = DependencyProperty.Register(
        nameof(Thumbnails), typeof(IReadOnlyList<ImageSource>), typeof(TrimTimelineControl),
        new PropertyMetadata(Array.Empty<ImageSource>(), ThumbnailsChanged));
    public static readonly DependencyProperty PositionProperty = DependencyProperty.Register(
        nameof(Position), typeof(double), typeof(TrimTimelineControl),
        new FrameworkPropertyMetadata(0d, FrameworkPropertyMetadataOptions.BindsTwoWayByDefault, PositionChanged));
    public static readonly DependencyProperty SelectedCutProperty = DependencyProperty.Register(
        nameof(SelectedCut), typeof(double?), typeof(TrimTimelineControl),
        new PropertyMetadata(null, SelectionChanged));
    public static readonly DependencyProperty ZoomLevelProperty = DependencyProperty.Register(
        nameof(ZoomLevel), typeof(double), typeof(TrimTimelineControl),
        new PropertyMetadata(1d, ZoomChanged));

    private bool _updatingPosition;
    private double _contextCutPosition;
    private CancellationTokenSource? _keyboardMoveCancellation;

    public TrimTimelineControl()
    {
        InitializeComponent();
        Viewport.SizeChanged += (_, _) => RenderTimeline();
        Unloaded += (_, _) => _keyboardMoveCancellation?.Cancel();
    }

    public IReadOnlyList<TrimSegment> Segments
    {
        get => (IReadOnlyList<TrimSegment>)GetValue(SegmentsProperty);
        set => SetValue(SegmentsProperty, value);
    }

    public IReadOnlyList<ImageSource> Thumbnails
    {
        get => (IReadOnlyList<ImageSource>)GetValue(ThumbnailsProperty);
        set => SetValue(ThumbnailsProperty, value);
    }

    public double Position
    {
        get => (double)GetValue(PositionProperty);
        set => SetValue(PositionProperty, value);
    }

    public double? SelectedCut
    {
        get => (double?)GetValue(SelectedCutProperty);
        set => SetValue(SelectedCutProperty, value);
    }

    public double ZoomLevel
    {
        get => (double)GetValue(ZoomLevelProperty);
        set => SetValue(ZoomLevelProperty, Math.Clamp(value, 1, 64));
    }

    public void ZoomIn() => ZoomBy(2);

    public void ZoomOut() => ZoomBy(0.5);

    public void FitTimeline()
    {
        ZoomLevel = 1;
        Viewport.ScrollToHorizontalOffset(0);
    }

    public event EventHandler<TimelineCutEventArgs>? CutAdded;
    public event EventHandler<TimelineCutEventArgs>? CutMoved;
    public event EventHandler<TimelineCutEventArgs>? CutRemoved;
    public event EventHandler<TimelineCutEventArgs>? CutSelected;
    public event EventHandler<TimelineSegmentEventArgs>? SegmentToggled;

    protected override AutomationPeer OnCreateAutomationPeer() => new TimelineAutomationPeer(this);

    private sealed class TimelineAutomationPeer(TrimTimelineControl owner) : FrameworkElementAutomationPeer(owner), IInvokeProvider
    {
        public void Invoke() => owner.Dispatcher.Invoke(() =>
        {
            if (!owner.IsEnabled)
            {
                throw new ElementNotEnabledException();
            }

            owner._contextCutPosition = owner.Position;
            owner.UpdateContextCutAvailability();
            owner.Surface.ContextMenu.PlacementTarget = owner.Surface;
            owner.Surface.ContextMenu.IsOpen = true;
        });

        public override object? GetPattern(PatternInterface patternInterface) =>
            patternInterface == PatternInterface.Invoke ? this : base.GetPattern(patternInterface);
    }

    private double Duration => Segments.LastOrDefault()?.End.TotalSeconds ?? 0;

    private double TrackWidth => Math.Max(1, Viewport.ViewportWidth * ZoomLevel);

    private static void ContentChanged(DependencyObject owner, DependencyPropertyChangedEventArgs args) =>
        ((TrimTimelineControl)owner).RenderTimeline();

    private static void ThumbnailsChanged(DependencyObject owner, DependencyPropertyChangedEventArgs args)
    {
        var timeline = (TrimTimelineControl)owner;
        timeline.RenderThumbnails();
        timeline.RenderTimeline();
    }

    private static void PositionChanged(DependencyObject owner, DependencyPropertyChangedEventArgs args) =>
        ((TrimTimelineControl)owner).UpdatePlayhead();

    private static void SelectionChanged(DependencyObject owner, DependencyPropertyChangedEventArgs args) =>
        ((TrimTimelineControl)owner).UpdateCutSelection();

    private static void ZoomChanged(DependencyObject owner, DependencyPropertyChangedEventArgs args) =>
        ((TrimTimelineControl)owner).OnZoomChanged();

    private void ZoomBy(double factor)
    {
        ZoomLevel = Math.Clamp(ZoomLevel * factor, 1, 64);
    }

    private void OnZoomChanged()
    {
        if (Surface is null || Viewport is null)
        {
            return;
        }

        RenderTimeline();
        var target = Duration > 0 ? Position / Duration * TrackWidth - Viewport.ViewportWidth / 2 : 0;
        Viewport.ScrollToHorizontalOffset(Math.Clamp(target, 0, Math.Max(0, TrackWidth - Viewport.ViewportWidth)));
    }

    private void ViewportMouseWheel(object sender, MouseWheelEventArgs args)
    {
        if ((Keyboard.Modifiers & ModifierKeys.Control) != 0)
        {
            if (args.Delta > 0)
            {
                ZoomIn();
            }
            else
            {
                ZoomOut();
            }

            args.Handled = true;
        }
    }

    private void SurfaceSizeChanged(object sender, SizeChangedEventArgs e) => RenderTimeline();

    private void RenderThumbnails()
    {
        Filmstrip.Children.Clear();
        foreach (var image in Thumbnails)
        {
            Filmstrip.Children.Add(new Image { Source = image, Stretch = Stretch.UniformToFill, IsHitTestVisible = false });
        }
    }

    private void RenderTimeline()
    {
        if (Surface is null)
        {
            return;
        }

        var focusedCut = Marks.Children.OfType<TimelineCutThumb>().FirstOrDefault(thumb => thumb.IsKeyboardFocused)?.TimestampTicks;
        int? focusedClipIndex = null;
        for (var index = 0; index < Clips.Children.Count; index++)
        {
            if (Clips.Children[index] is ToggleButton { IsKeyboardFocused: true })
            {
                focusedClipIndex = index;
                break;
            }
        }
        Clips.Children.Clear();
        ExcludedRegions.Children.Clear();
        Marks.Children.Clear();
        Ruler.Children.Clear();
        PlayheadSlider.Maximum = Duration;
        Surface.Width = TrackWidth;
        if (Duration <= 0)
        {
            return;
        }

        for (var index = 0; index < Segments.Count; index++)
        {
            var segment = Segments[index];
            var segmentIndex = index;
            var content = new Grid();
            if (Thumbnails.Count > 0)
            {
                var midpoint = segment.Start.TotalSeconds + segment.Duration.TotalSeconds / 2;
                var thumbnailIndex = Math.Clamp((int)Math.Floor(midpoint / Duration * Thumbnails.Count), 0, Thumbnails.Count - 1);
                content.Children.Add(new Image
                {
                    Source = Thumbnails[thumbnailIndex],
                    Stretch = Stretch.UniformToFill,
                    Opacity = segment.IsSelected ? 0.55 : 0.18,
                    IsHitTestVisible = false
                });
            }

            content.Children.Add(new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(180, 0, 0, 0)),
                CornerRadius = new CornerRadius(4),
                Padding = new Thickness(6, 2, 6, 2),
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
                Child = new TextBlock
                {
                    Text = segment.IsSelected ? $"✓ {index + 1}" : $"✕ {index + 1}",
                    Foreground = Brushes.White,
                    FontWeight = FontWeights.Bold
                }
            });
            var button = new ToggleButton
            {
                Width = Math.Max(1, segment.Duration.TotalSeconds / Duration * TrackWidth),
                Height = 42,
                IsChecked = segment.IsSelected,
                Content = content,
                ToolTip = $"{MediaTime.Display(segment.Start)} — {MediaTime.Display(segment.End)} · click to include or exclude",
                Style = (Style)Resources["ClipStyle"]
            };
            AutomationProperties.SetAutomationId(button, $"TimelineClip{index + 1}");
            AutomationProperties.SetName(button, $"Clip {index + 1}, {MediaTime.Display(segment.Start)} to {MediaTime.Display(segment.End)}");
            button.Checked += (_, _) => SegmentToggled?.Invoke(this, new TimelineSegmentEventArgs(segmentIndex));
            button.Unchecked += (_, _) => SegmentToggled?.Invoke(this, new TimelineSegmentEventArgs(segmentIndex));
            Canvas.SetLeft(button, segment.Start.TotalSeconds / Duration * TrackWidth);
            Clips.Children.Add(button);
            if (!segment.IsSelected)
            {
                var excluded = new Border
                {
                    Width = Math.Max(1, segment.Duration.TotalSeconds / Duration * TrackWidth),
                    Height = 64,
                    Background = new SolidColorBrush(Color.FromArgb(180, 11, 17, 24)),
                    IsHitTestVisible = false,
                    Child = new TextBlock
                    {
                        Text = "✕",
                        Foreground = Brushes.White,
                        FontSize = 24,
                        FontWeight = FontWeights.Bold,
                        HorizontalAlignment = HorizontalAlignment.Center,
                        VerticalAlignment = VerticalAlignment.Center
                    }
                };
                Canvas.SetLeft(excluded, segment.Start.TotalSeconds / Duration * TrackWidth);
                ExcludedRegions.Children.Add(excluded);
            }

            if (index < Segments.Count - 1)
            {
                AddMark(index, segment);
            }
        }

        for (var index = 0; index <= 4; index++)
        {
            var timestamp = Duration * index / 4;
            var text = new TextBlock
            {
                Text = MediaTime.Display(TimeSpan.FromSeconds(timestamp)),
                FontSize = 11,
                Foreground = Brushes.SlateGray
            };
            text.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            Canvas.SetLeft(text, Math.Clamp(timestamp / Duration * TrackWidth - text.DesiredSize.Width / 2,
                0, Math.Max(0, TrackWidth - text.DesiredSize.Width)));
            Canvas.SetTop(text, 4);
            Ruler.Children.Add(text);
        }

        var startBracket = new TextBlock { Text = "[", Foreground = Brushes.White, FontSize = 28, FontWeight = FontWeights.Bold, IsHitTestVisible = false };
        var endBracket = new TextBlock { Text = "]", Foreground = Brushes.White, FontSize = 28, FontWeight = FontWeights.Bold, IsHitTestVisible = false };
        Canvas.SetTop(startBracket, 12);
        Canvas.SetTop(endBracket, 12);
        Canvas.SetLeft(startBracket, 4);
        Canvas.SetLeft(endBracket, TrackWidth - 12);
        Marks.Children.Add(startBracket);
        Marks.Children.Add(endBracket);
        UpdateCutSelection();
        UpdatePlayhead();
        if (focusedCut is { } focusedTimestamp)
        {
            FocusCut(focusedTimestamp);
        }
        if (focusedClipIndex is { } focusedIndex && focusedIndex < Clips.Children.Count &&
            Clips.Children[focusedIndex] is ToggleButton focusedClip)
        {
            Keyboard.Focus(focusedClip);
        }
    }

    private void AddMark(int index, TrimSegment segment)
    {
        var originalTimestamp = segment.End;
        var original = originalTimestamp.TotalSeconds;
        var lower = segment.Start.TotalSeconds;
        var upper = Segments[index + 1].End.TotalSeconds;
        var margin = Math.Min(0.001, (upper - lower) / 4);
        var thumb = new TimelineCutThumb
        {
            Timestamp = original,
            TimestampTicks = originalTimestamp.Ticks,
            Minimum = lower + margin,
            Maximum = upper - margin,
            Width = 18,
            Height = 106,
            Template = (ControlTemplate)Resources["CutMarkTemplate"],
            Tag = segment.IsSelected && !Segments[index + 1].IsSelected ? "]" :
                !segment.IsSelected && Segments[index + 1].IsSelected ? "[" :
                segment.IsSelected ? "⋮" : "✕",
            Cursor = Cursors.SizeWE,
            Focusable = true,
            ToolTip = $"Cut at {MediaTime.Display(segment.End)} · drag to move · Delete to remove"
        };
        AutomationProperties.SetAutomationId(thumb, $"TimelineCut{index + 1}");
        AutomationProperties.SetName(thumb, $"Cut {index + 1}");
        Canvas.SetLeft(thumb, original / Duration * TrackWidth - 9);
        var moving = original;
        thumb.MoveRequested += (_, value) =>
        {
            CutMoved?.Invoke(this, new TimelineCutEventArgs(TimeSpan.FromSeconds(value), originalTimestamp));
            SetCurrentValue(PositionProperty, value);
        };
        thumb.DragStarted += (_, _) =>
        {
            thumb.Focus();
            CutSelected?.Invoke(this, new TimelineCutEventArgs(originalTimestamp));
        };
        thumb.DragDelta += (_, args) =>
        {
            moving = Math.Clamp(moving + args.HorizontalChange / TrackWidth * Duration, thumb.Minimum, thumb.Maximum);
            Canvas.SetLeft(thumb, moving / Duration * TrackWidth - 9);
            SetCurrentValue(PositionProperty, moving);
        };
        thumb.DragCompleted += (_, args) =>
        {
            if (!args.Canceled)
            {
                CutMoved?.Invoke(this, new TimelineCutEventArgs(TimeSpan.FromSeconds(moving), originalTimestamp));
            }
            else
            {
                RenderTimeline();
            }
        };
        thumb.KeyDown += (_, args) =>
        {
            if (args.Key is Key.Delete or Key.Back)
            {
                CutRemoved?.Invoke(this, new TimelineCutEventArgs(originalTimestamp));
                args.Handled = true;
            }
            else if (args.Key is Key.Left or Key.Right)
            {
                var offset = args.Key == Key.Left ? -0.04 : 0.04;
                moving = Math.Clamp(moving + offset, thumb.Minimum, thumb.Maximum);
                Canvas.SetLeft(thumb, moving / Duration * TrackWidth - 9);
                SetCurrentValue(PositionProperty, moving);
                args.Handled = true;
            }
        };
        thumb.KeyUp += (_, args) =>
        {
            if (args.Key is Key.Left or Key.Right)
            {
                _keyboardMoveCancellation?.Cancel();
                _keyboardMoveCancellation = new CancellationTokenSource();
                _ = CommitKeyboardMoveAsync(Segments, originalTimestamp, moving, _keyboardMoveCancellation);
                args.Handled = true;
            }
        };
        thumb.GotKeyboardFocus += (_, _) => CutSelected?.Invoke(this, new TimelineCutEventArgs(originalTimestamp));
        var remove = new MenuItem { Header = "Remove cut" };
        remove.Click += (_, _) => CutRemoved?.Invoke(this, new TimelineCutEventArgs(originalTimestamp));
        thumb.ContextMenu = new ContextMenu();
        thumb.ContextMenu.Items.Add(remove);
        Marks.Children.Add(thumb);
    }

    private async Task CommitKeyboardMoveAsync(IReadOnlyList<TrimSegment> segments, TimeSpan original, double value, CancellationTokenSource cancellation)
    {
        try
        {
            await Task.Delay(120, cancellation.Token);
            if (!ReferenceEquals(Segments, segments))
            {
                return;
            }

            var updated = TimeSpan.FromSeconds(value);
            CutMoved?.Invoke(this, new TimelineCutEventArgs(updated, original));
            await Dispatcher.InvokeAsync(() => FocusCut(updated.Ticks), System.Windows.Threading.DispatcherPriority.Background);
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
        }
        finally
        {
            if (ReferenceEquals(_keyboardMoveCancellation, cancellation))
            {
                _keyboardMoveCancellation = null;
            }
            cancellation.Dispose();
        }
    }

    private void FocusCut(long timestampTicks)
    {
        var thumb = Marks.Children.OfType<TimelineCutThumb>()
            .FirstOrDefault(candidate => candidate.TimestampTicks == timestampTicks);
        if (thumb is not null)
        {
            Keyboard.Focus(thumb);
        }
    }

    private void UpdateCutSelection()
    {
        if (Marks is not null)
        {
            foreach (var thumb in Marks.Children.OfType<TimelineCutThumb>())
            {
                thumb.Background = thumb.Timestamp == SelectedCut ? Brushes.DarkOrange : (Brush)Application.Current.Resources["AccentBrush"];
            }
        }
    }

    private void UpdatePlayhead()
    {
        if (PlayheadSlider is null)
        {
            return;
        }

        _updatingPosition = true;
        PlayheadSlider.Value = Math.Clamp(Position, 0, Duration);
        Playhead.X1 = Playhead.X2 = Duration > 0 ? Position / Duration * TrackWidth : 0;
        _updatingPosition = false;
    }

    private void PlayheadValueChanged(object sender, RoutedPropertyChangedEventArgs<double> args)
    {
        if (!_updatingPosition)
        {
            SetCurrentValue(PositionProperty, args.NewValue);
        }
    }

    private void FilmstripMouseDown(object sender, MouseButtonEventArgs args)
    {
        if (Duration <= 0)
        {
            return;
        }

        var position = Math.Clamp(args.GetPosition(Surface).X / TrackWidth * Duration, 0, Duration);
        SetCurrentValue(PositionProperty, position);
        if (args.ClickCount == 2)
        {
            CutAdded?.Invoke(this, new TimelineCutEventArgs(position));
        }
        args.Handled = true;
    }

    private void TimelineRightButtonDown(object sender, MouseButtonEventArgs args)
    {
        _contextCutPosition = Math.Clamp(args.GetPosition(Surface).X / TrackWidth * Duration, 0, Duration);
        SetCurrentValue(PositionProperty, _contextCutPosition);
    }

    private void TimelineContextMenuOpening(object sender, ContextMenuEventArgs args)
    {
        if (args.CursorLeft < 0)
        {
            _contextCutPosition = Position;
        }

        UpdateContextCutAvailability();
    }

    private void UpdateContextCutAvailability()
    {
        var timestamp = TimeSpan.FromSeconds(_contextCutPosition);
        AddContextCut.IsEnabled = IsEnabled && Segments.Any(segment => timestamp > segment.Start && timestamp < segment.End);
    }

    private void AddContextCutClick(object sender, RoutedEventArgs args)
    {
        Surface.ContextMenu.IsOpen = false;
        CutAdded?.Invoke(this, new TimelineCutEventArgs(_contextCutPosition));
    }
}

internal sealed class TimelineCutThumb : Thumb
{
    public double Timestamp { get; init; }
    public long TimestampTicks { get; init; }
    public double Minimum { get; init; }
    public double Maximum { get; init; }
    public event EventHandler<double>? MoveRequested;

    public void RequestMove(double value)
    {
        if (!IsEnabled)
        {
            throw new ElementNotEnabledException();
        }
        if (!double.IsFinite(value) || value < Minimum || value > Maximum)
        {
            throw new ArgumentOutOfRangeException(nameof(value), "Keep the cut between its neighboring marks.");
        }

        MoveRequested?.Invoke(this, value);
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new CutAutomationPeer(this);

    private sealed class CutAutomationPeer(TimelineCutThumb owner) : ThumbAutomationPeer(owner), IRangeValueProvider
    {
        public bool IsReadOnly => !owner.IsEnabled;
        public double LargeChange => 1;
        public double SmallChange => 0.04;
        public double Maximum => owner.Maximum;
        public double Minimum => owner.Minimum;
        public double Value => owner.Timestamp;
        public void SetValue(double value) => owner.Dispatcher.Invoke(() => owner.RequestMove(value));
        public override object? GetPattern(PatternInterface patternInterface) =>
            patternInterface == PatternInterface.RangeValue ? this : base.GetPattern(patternInterface);
    }
}
