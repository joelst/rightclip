namespace RightClip.Core.Operations;

public sealed record TrimSegment(TimeSpan Start, TimeSpan End, bool IsSelected = true)
{
    public TimeSpan Duration => End - Start;
}

public sealed class TrimTimeline
{
    private readonly List<TrimSegment> _segments;

    public TrimTimeline(TimeSpan duration)
    {
        if (duration <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(duration), "The video must have a positive duration.");
        }

        Duration = duration;
        _segments = [new TrimSegment(TimeSpan.Zero, duration)];
    }

    public TimeSpan Duration { get; }

    public IReadOnlyList<TrimSegment> Segments => _segments.ToArray();

    public void AddCut(TimeSpan position)
    {
        var index = _segments.FindIndex(segment => position > segment.Start && position < segment.End);
        if (index < 0)
        {
            throw new InvalidOperationException("Place a cut inside the video and away from existing cut marks.");
        }

        var segment = _segments[index];
        _segments[index] = segment with { End = position };
        _segments.Insert(index + 1, segment with { Start = position });
    }

    public void MoveCut(TimeSpan originalPosition, TimeSpan position)
    {
        var index = FindCut(originalPosition);
        if (position <= _segments[index].Start || position >= _segments[index + 1].End)
        {
            throw new InvalidOperationException("A cut must stay between its neighboring cut marks.");
        }

        _segments[index] = _segments[index] with { End = position };
        _segments[index + 1] = _segments[index + 1] with { Start = position };
    }

    public void RemoveCut(TimeSpan position)
    {
        var index = FindCut(position);
        var left = _segments[index];
        var right = _segments[index + 1];
        _segments[index] = left with { End = right.End, IsSelected = left.IsSelected && right.IsSelected };
        _segments.RemoveAt(index + 1);
    }

    public void ToggleSegment(int index)
    {
        if (index < 0 || index >= _segments.Count)
        {
            throw new ArgumentOutOfRangeException(nameof(index));
        }

        _segments[index] = _segments[index] with { IsSelected = !_segments[index].IsSelected };
    }

    public void Reset()
    {
        _segments.Clear();
        _segments.Add(new TrimSegment(TimeSpan.Zero, Duration));
    }

    private int FindCut(TimeSpan position)
    {
        var index = _segments.FindIndex(segment => segment.End == position);
        if (index < 0 || index == _segments.Count - 1)
        {
            throw new InvalidOperationException("Select an existing interior cut mark.");
        }

        return index;
    }
}
