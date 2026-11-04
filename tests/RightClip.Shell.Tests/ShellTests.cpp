#include <windows.h>
#include <shobjidl.h>
#include <shlobj.h>
#include <chrono>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

namespace
{
    const CLSID clsids[] =
    {
        { 0x6b22fdb5, 0x38a2, 0x4ef0, { 0x9d, 0x8a, 0x2c, 0x4d, 0x24, 0xe2, 0x10, 0x01 } },
        { 0x6b22fdb5, 0x38a2, 0x4ef0, { 0x9d, 0x8a, 0x2c, 0x4d, 0x24, 0xe2, 0x10, 0x02 } },
        { 0x6b22fdb5, 0x38a2, 0x4ef0, { 0x9d, 0x8a, 0x2c, 0x4d, 0x24, 0xe2, 0x10, 0x03 } },
        { 0x6b22fdb5, 0x38a2, 0x4ef0, { 0x9d, 0x8a, 0x2c, 0x4d, 0x24, 0xe2, 0x10, 0x05 } }
    };

    const wchar_t* titles[] = { L"Trim video", L"Edit tracks", L"Video details", L"Remove Metadata" };
    const wchar_t* actions[] = { L"trim", L"tracks", L"details", L"remove-metadata" };

    int Fail(const wchar_t* message, HRESULT result = S_OK)
    {
        std::wcerr << message << L" HRESULT=0x" << std::hex << result << std::endl;
        return 1;
    }

    std::wstring ArgumentPath()
    {
        wchar_t path[32768]{};
        const auto length = GetModuleFileNameW(nullptr, path, static_cast<DWORD>(std::size(path)));
        std::wstring directory(path, length);
        return directory.substr(0, directory.find_last_of(L"\\/") + 1) + L"worker-args.txt";
    }

    std::wstring ReadArguments()
    {
        const auto file = CreateFileW(ArgumentPath().c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
            nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file == INVALID_HANDLE_VALUE)
        {
            return {};
        }

        std::wstring contents;
        wchar_t buffer[4096];
        DWORD read = 0;
        while (ReadFile(file, buffer, sizeof(buffer), &read, nullptr) && read > 0)
        {
            contents.append(buffer, read / sizeof(wchar_t));
        }

        CloseHandle(file);
        return contents;
    }
}

int wmain(int argc, wchar_t** argv)
{
    if (argc != 5)
    {
        return Fail(L"Expected shell DLL, MP4, MOV, and unsupported file paths.");
    }

    auto result = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    if (FAILED(result))
    {
        return Fail(L"CoInitializeEx failed.", result);
    }

    const auto library = LoadLibraryW(argv[1]);
    if (library == nullptr)
    {
        CoUninitialize();
        return Fail(L"LoadLibrary failed.", HRESULT_FROM_WIN32(GetLastError()));
    }

    using GetClassObject = HRESULT(STDAPICALLTYPE*)(REFCLSID, REFIID, LPVOID*);
    const auto getClassObject = reinterpret_cast<GetClassObject>(GetProcAddress(library, "DllGetClassObject"));
    if (getClassObject == nullptr)
    {
        FreeLibrary(library);
        CoUninitialize();
        return Fail(L"DllGetClassObject export was not found.");
    }

    PIDLIST_ABSOLUTE identifiers[3]{};
    IShellItemArray* items = nullptr;
    for (auto index = 0; index < 3; ++index)
    {
        result = SHParseDisplayName(argv[index + 2], nullptr, &identifiers[index], 0, nullptr);
        if (FAILED(result))
        {
            return Fail(L"SHParseDisplayName failed.", result);
        }
    }

    PCIDLIST_ABSOLUTE readOnlyIdentifiers[] = { identifiers[0], identifiers[1], identifiers[2] };
    result = SHCreateShellItemArrayFromIDLists(3, readOnlyIdentifiers, &items);
    for (const auto identifier : identifiers)
    {
        CoTaskMemFree(identifier);
    }
    if (FAILED(result))
    {
        return Fail(L"SHCreateShellItemArrayFromIDLists failed.", result);
    }

    for (size_t index = 0; index < std::size(clsids); ++index)
    {
        IClassFactory* factory = nullptr;
        result = getClassObject(clsids[index], IID_IClassFactory, reinterpret_cast<void**>(&factory));
        if (FAILED(result))
        {
            return Fail(L"DllGetClassObject failed.", result);
        }

        IExplorerCommand* command = nullptr;
        result = factory->CreateInstance(nullptr, IID_IExplorerCommand, reinterpret_cast<void**>(&command));
        factory->Release();
        if (FAILED(result))
        {
            return Fail(L"CreateInstance failed.", result);
        }

        wchar_t* title = nullptr;
        result = command->GetTitle(items, &title);
        if (FAILED(result) || title == nullptr || std::wstring(title) != titles[index])
        {
            return Fail(L"The Explorer command title is incorrect.", result);
        }
        CoTaskMemFree(title);

        wchar_t* icon = nullptr;
        result = command->GetIcon(items, &icon);
        if (FAILED(result) || icon == nullptr)
        {
            return Fail(L"The Explorer command did not expose an icon.", result);
        }
        const std::wstring iconLocation(icon);
        CoTaskMemFree(icon);
        const std::wstring iconSuffix = L"\\RightClip.exe,0";
        if (iconLocation.size() < iconSuffix.size() ||
            iconLocation.compare(iconLocation.size() - iconSuffix.size(), iconSuffix.size(), iconSuffix) != 0)
        {
            return Fail(L"The Explorer command icon does not point to RightClip.exe.");
        }

        EXPCMDSTATE state = ECS_HIDDEN;
        result = command->GetState(items, FALSE, &state);
        if (FAILED(result) || state != ECS_ENABLED)
        {
            return Fail(L"The Explorer command is not enabled for a multi-file selection.", result);
        }

        DeleteFileW(ArgumentPath().c_str());
        result = command->Invoke(items, nullptr);
        command->Release();
        if (FAILED(result))
        {
            return Fail(L"The Explorer command could not start its worker.", result);
        }

        std::wstring arguments;
        for (auto attempt = 0; attempt < 50 && arguments.empty(); ++attempt)
        {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
            arguments = ReadArguments();
        }

        const auto first = L"--path \"" + std::wstring(argv[2]) + L"\"";
        const auto second = L"--path \"" + std::wstring(argv[3]) + L"\"";
        if (arguments.find(std::wstring(L"--action ") + actions[index]) == std::wstring::npos ||
            arguments.find(first) == std::wstring::npos || arguments.find(second) == std::wstring::npos ||
            arguments.find(argv[4]) != std::wstring::npos)
        {
            return Fail(L"The worker received incorrect action or path arguments.");
        }
    }

    const CLSID rootClsid = { 0x6b22fdb5, 0x38a2, 0x4ef0, { 0x9d, 0x8a, 0x2c, 0x4d, 0x24, 0xe2, 0x10, 0x04 } };
    IClassFactory* rootFactory = nullptr;
    result = getClassObject(rootClsid, IID_IClassFactory, reinterpret_cast<void**>(&rootFactory));
    if (FAILED(result))
    {
        return Fail(L"The RightClip root class factory was not found.", result);
    }

    IExplorerCommand* root = nullptr;
    result = rootFactory->CreateInstance(nullptr, IID_IExplorerCommand, reinterpret_cast<void**>(&root));
    rootFactory->Release();
    if (FAILED(result))
    {
        return Fail(L"The RightClip root command could not be created.", result);
    }

    wchar_t* rootTitle = nullptr;
    result = root->GetTitle(items, &rootTitle);
    if (FAILED(result) || rootTitle == nullptr || std::wstring(rootTitle) != L"RightClip")
    {
        return Fail(L"The RightClip root title is incorrect.", result);
    }
    CoTaskMemFree(rootTitle);

    EXPCMDFLAGS flags = ECF_DEFAULT;
    result = root->GetFlags(&flags);
    if (FAILED(result) || (flags & ECF_HASSUBCOMMANDS) == 0)
    {
        return Fail(L"The RightClip root does not advertise its submenu.", result);
    }

    IEnumExplorerCommand* enumerator = nullptr;
    result = root->EnumSubCommands(&enumerator);
    root->Release();
    if (FAILED(result) || enumerator == nullptr)
    {
        return Fail(L"The RightClip submenu could not be enumerated.", result);
    }

    for (const auto expectedTitle : titles)
    {
        IExplorerCommand* child = nullptr;
        ULONG fetched = 0;
        result = enumerator->Next(1, &child, &fetched);
        if (result != S_OK || fetched != 1 || child == nullptr)
        {
            return Fail(L"A RightClip submenu command is missing.", result);
        }

        wchar_t* childTitle = nullptr;
        result = child->GetTitle(items, &childTitle);
        child->Release();
        if (FAILED(result) || childTitle == nullptr || std::wstring(childTitle) != expectedTitle)
        {
            return Fail(L"A RightClip submenu title is incorrect.", result);
        }
        CoTaskMemFree(childTitle);
    }

    IExplorerCommand* extra = nullptr;
    ULONG fetched = 0;
    if (enumerator->Next(1, &extra, &fetched) != S_FALSE || fetched != 0)
    {
        return Fail(L"The RightClip submenu has unexpected extra commands.");
    }
    enumerator->Release();

    items->Release();
    FreeLibrary(library);
    CoUninitialize();
    std::wcout << L"All four commands launched the worker with correct multi-select arguments." << std::endl;
    return 0;
}
