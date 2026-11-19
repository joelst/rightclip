#include <windows.h>
#include <string>

int WINAPI wWinMain(HINSTANCE, HINSTANCE, wchar_t*, int)
{
    wchar_t path[32768]{};
    const auto length = GetModuleFileNameW(nullptr, path, static_cast<DWORD>(std::size(path)));
    if (length == 0 || length >= std::size(path))
    {
        return 2;
    }

    std::wstring output(path, length);
    output = output.substr(0, output.find_last_of(L"\\/") + 1) + L"worker-args.txt";
    const auto mutex = CreateMutexW(nullptr, FALSE, L"RightClipWorkerStubArguments");
    if (mutex == nullptr)
    {
        return 3;
    }

    if (WaitForSingleObject(mutex, 10000) != WAIT_OBJECT_0)
    {
        CloseHandle(mutex);
        return 4;
    }

    const auto file = CreateFileW(output.c_str(), GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ, nullptr,
        OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE)
    {
        ReleaseMutex(mutex);
        CloseHandle(mutex);
        return 5;
    }

    SetFilePointer(file, 0, nullptr, FILE_END);
    const std::wstring command = std::wstring(GetCommandLineW()) + L"\r\n";
    DWORD written = 0;
    const auto succeeded = WriteFile(file, command.data(), static_cast<DWORD>(command.size() * sizeof(wchar_t)), &written, nullptr);
    CloseHandle(file);
    ReleaseMutex(mutex);
    CloseHandle(mutex);
    return succeeded ? 0 : 6;
}
