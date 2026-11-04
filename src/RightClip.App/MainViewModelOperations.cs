using System.Windows;
using RightClip.Core.Media;

namespace RightClip.App;

public sealed partial class MainViewModel
{
    private OperationProgressWindow? _operationWindow;
    private bool _exitAfterOperation;

    private void BeginOperation(string description)
    {
        if (_operationWindow is not null)
        {
            return;
        }

        _exitAfterOperation = false;
        var window = new OperationProgressWindow(description, _settings.SuppressCompletionNotification);
        _operationWindow = window;
        window.CancelRequested += (_, _) => _cancellation?.Cancel();
        window.HideRequested += (_, _) => _exitAfterOperation = true;
        window.NotificationPreferenceChanged += (_, _) =>
            _settings = _settings with { SuppressCompletionNotification = window.SuppressCompletionNotification };
        Application.Current.MainWindow.WindowState = WindowState.Minimized;
        window.Show();
    }

    private void UpdateOperation(OperationProgress update)
    {
        _operationWindow?.Update(update);
    }

    private void EndOperation(IReadOnlyList<FileOperationResult> results)
    {
        var window = _operationWindow;
        _operationWindow = null;
        if (window is null)
        {
            return;
        }

        window.Complete();
        if (_exitAfterOperation)
        {
            _exitAfterOperation = false;
            IsBusy = false;
            Application.Current.Shutdown();
            return;
        }

        if (!window.SuppressCompletionNotification)
        {
            new OperationResultWindow(results) { Owner = Application.Current.MainWindow }.ShowDialog();
        }

        Application.Current.MainWindow.WindowState = WindowState.Normal;
    }

    private void CloseOperationWindow()
    {
        var window = _operationWindow;
        _operationWindow = null;
        window?.Complete();
        if (_exitAfterOperation)
        {
            _exitAfterOperation = false;
            IsBusy = false;
            Application.Current.Shutdown();
        }
        else
        {
            Application.Current.MainWindow.WindowState = WindowState.Normal;
        }
    }
}
