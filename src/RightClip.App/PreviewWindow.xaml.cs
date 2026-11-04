using System.Windows;

namespace RightClip.App;

public partial class PreviewWindow : Window
{
    public PreviewWindow(double aspectRatio)
    {
        InitializeComponent();
        var ratio = double.IsFinite(aspectRatio) && aspectRatio > 0 ? aspectRatio : 16d / 9d;
        var contentHeight = 540d;
        var contentWidth = contentHeight * ratio;
        if (contentWidth > 1200)
        {
            contentWidth = 1200;
            contentHeight = contentWidth / ratio;
        }

        Width = Math.Max(320, contentWidth);
        Height = Math.Max(240, contentHeight) + 40;
    }
}
