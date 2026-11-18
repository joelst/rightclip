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
        window.HideRequested += (_, _) =>
        {
            _exitAfterOperation = true;
            HideEditor();
        };
        window.NotificationPreferenceChanged += (_, _) =>
            _settings = _settings with { SuppressCompletionNotification = window.SuppressCompletionNotification };
        window.ReturnRequested += (_, _) => ReturnFromOperation();
        window.CloseApplicationRequested += (_, _) => CloseAfterOperation();
        HideEditor();
        window.Show();
        window.Activate();
    }

    private static void HideEditor()
    {
        var mainWindow = Application.Current.MainWindow;
        if (mainWindow is MainWindow editor)
        {
            editor.CloseDetachedPreview();
        }

        mainWindow.Hide();
    }

    private void UpdateOperation(OperationProgress update)
    {
        _operationWindow?.Update(update);
    }

    private void EndOperation(IReadOnlyList<FileOperationResult> results)
    {
        var window = _operationWindow;
        if (window is null)
        {
            return;
        }

        if (_exitAfterOperation || (window.SuppressCompletionNotification && results.All(result => result.Succeeded)))
        {
            CloseAfterOperation();
            return;
        }

        window.ShowCompletion(results);
    }

    private void ReturnFromOperation()
    {
        var window = _operationWindow;
        if (window is null || !window.IsComplete)
        {
            return;
        }

        _operationWindow = null;
        window.Dismiss();
        var mainWindow = Application.Current.MainWindow;
        mainWindow.Show();
        mainWindow.WindowState = WindowState.Normal;
        mainWindow.Activate();
    }

    private void CloseAfterOperation()
    {
        var window = _operationWindow;
        _operationWindow = null;
        _exitAfterOperation = false;
        window?.Dismiss();
        IsBusy = false;
        Application.Current.Shutdown();
    }

    private void CloseOperationWindow()
    {
        var window = _operationWindow;
        if (window is null || window.IsComplete)
        {
            return;
        }

        _operationWindow = null;
        window.Dismiss();
        if (_exitAfterOperation)
        {
            CloseAfterOperation();
            return;
        }

        var mainWindow = Application.Current.MainWindow;
        mainWindow.Show();
        mainWindow.WindowState = WindowState.Normal;
    }
}
