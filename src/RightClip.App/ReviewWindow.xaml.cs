using System.Windows;

namespace RightClip.App;

public partial class ReviewWindow : Window
{
    public ReviewWindow(IReadOnlyList<ReviewGroup> groups, string summary)
    {
        InitializeComponent();
        Groups.ItemsSource = groups;
        SummaryText.Text = summary;
    }

    private void RunClick(object sender, RoutedEventArgs e)
    {
        DialogResult = true;
    }

    private void CancelClick(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
    }
}
