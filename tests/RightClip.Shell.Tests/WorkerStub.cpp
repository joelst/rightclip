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
    const auto file = CreateFileW(output.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE)
    {
        return 3;
    }

    const std::wstring command(GetCommandLineW());
    DWORD written = 0;
    const auto succeeded = WriteFile(file, command.data(), static_cast<DWORD>(command.size() * sizeof(wchar_t)), &written, nullptr);
    CloseHandle(file);
    return succeeded ? 0 : 4;
}
