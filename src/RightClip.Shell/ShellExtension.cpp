#include <windows.h>
#include <shobjidl.h>
#include <shlobj.h>
#include <shlwapi.h>
#include <algorithm>
#include <atomic>
#include <string>
#include <vector>

namespace
{
    HMODULE moduleHandle;
    std::atomic<long> objectCount{ 0 };

    const CLSID CLSID_RightClipTrim = { 0x6b22fdb5, 0x38a2, 0x4ef0, { 0x9d, 0x8a, 0x2c, 0x4d, 0x24, 0xe2, 0x10, 0x01 } };
    const CLSID CLSID_RightClipTracks = { 0x6b22fdb5, 0x38a2, 0x4ef0, { 0x9d, 0x8a, 0x2c, 0x4d, 0x24, 0xe2, 0x10, 0x02 } };
    const CLSID CLSID_RightClipDetails = { 0x6b22fdb5, 0x38a2, 0x4ef0, { 0x9d, 0x8a, 0x2c, 0x4d, 0x24, 0xe2, 0x10, 0x03 } };
    const CLSID CLSID_RightClipRoot = { 0x6b22fdb5, 0x38a2, 0x4ef0, { 0x9d, 0x8a, 0x2c, 0x4d, 0x24, 0xe2, 0x10, 0x04 } };

    enum class CommandKind
    {
        Trim,
        Tracks,
        Details
    };

    struct CommandDescription
    {
        const CLSID* clsid;
        const wchar_t* name;
        const wchar_t* action;
        const wchar_t* tooltip;
        const wchar_t* handlerName;
    };

    const CommandDescription commands[] =
    {
        { &CLSID_RightClipTrim, L"Trim video", L"trim", L"Trim or split this video with RightClip", L"RightClip.Trim" },
        { &CLSID_RightClipTracks, L"Edit tracks", L"tracks", L"Change audio tracks and soft subtitles with RightClip", L"RightClip.Tracks" },
        { &CLSID_RightClipDetails, L"Video details", L"details", L"Change video metadata with RightClip", L"RightClip.Details" }
    };

    const wchar_t* extensions[] = { L".mp4", L".mov", L".mkv", L".webm" };

    std::wstring QuoteArgument(const std::wstring& value)
    {
        std::wstring result(L"\"");
        size_t slashes = 0;
        for (const wchar_t character : value)
        {
            if (character == L'\\')
            {
                ++slashes;
            }
            else if (character == L'\"')
            {
                result.append(slashes * 2 + 1, L'\\');
                result.push_back(L'\"');
                slashes = 0;
            }
            else
            {
                result.append(slashes, L'\\');
                slashes = 0;
                result.push_back(character);
            }
        }

        result.append(slashes * 2, L'\\');
        result.push_back(L'\"');
        return result;
    }

    bool HasSupportedExtension(const std::wstring& path)
    {
        const auto dot = path.find_last_of(L'.');
        if (dot == std::wstring::npos)
        {
            return false;
        }

        auto extension = path.substr(dot);
        std::transform(extension.begin(), extension.end(), extension.begin(), towlower);
        return std::any_of(std::begin(extensions), std::end(extensions), [&](const wchar_t* candidate)
        {
            return extension == candidate;
        });
    }

    bool IsSupportedSelection(IShellItemArray* items)
    {
        if (items == nullptr)
        {
            return false;
        }

        DWORD count = 0;
        if (FAILED(items->GetCount(&count)))
        {
            return false;
        }

        for (DWORD index = 0; index < count; ++index)
        {
            IShellItem* item = nullptr;
            if (FAILED(items->GetItemAt(index, &item)))
            {
                continue;
            }

            wchar_t* path = nullptr;
            const auto supported = SUCCEEDED(item->GetDisplayName(SIGDN_PARENTRELATIVEPARSING, &path)) && path != nullptr && HasSupportedExtension(path);
            if (path != nullptr)
            {
                CoTaskMemFree(path);
            }

            item->Release();
            if (supported)
            {
                return true;
            }
        }

        return false;
    }

    std::wstring ModuleDirectory()
    {
        std::vector<wchar_t> buffer(32768);
        const auto length = GetModuleFileNameW(moduleHandle, buffer.data(), static_cast<DWORD>(buffer.size()));
        if (length == 0 || length >= buffer.size())
        {
            return {};
        }

        std::wstring path(buffer.data(), length);
        const auto slash = path.find_last_of(L"\\/");
        return slash == std::wstring::npos ? std::wstring{} : path.substr(0, slash);
    }

    HRESULT AllocateString(const wchar_t* value, wchar_t** target)
    {
        if (target == nullptr)
        {
            return E_POINTER;
        }

        return SHStrDupW(value, target);
    }

    HRESULT LaunchWorker(CommandKind kind, IShellItemArray* items)
    {
        if (items == nullptr)
        {
            return E_INVALIDARG;
        }

        DWORD count = 0;
        HRESULT result = items->GetCount(&count);
        if (FAILED(result) || count == 0)
        {
            return FAILED(result) ? result : E_INVALIDARG;
        }

        const auto& description = commands[static_cast<size_t>(kind)];
        const auto directory = ModuleDirectory();
        if (directory.empty())
        {
            return HRESULT_FROM_WIN32(GetLastError());
        }

        const auto worker = directory + L"\\RightClip.exe";
        if (GetFileAttributesW(worker.c_str()) == INVALID_FILE_ATTRIBUTES)
        {
            return HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND);
        }

        auto commandLine = QuoteArgument(worker) + L" --action " + description.action;
        DWORD selected = 0;
        for (DWORD index = 0; index < count; ++index)
        {
            IShellItem* item = nullptr;
            if (FAILED(items->GetItemAt(index, &item)))
            {
                continue;
            }

            wchar_t* path = nullptr;
            if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &path)) && path != nullptr)
            {
                if (HasSupportedExtension(path))
                {
                    commandLine += L" --path ";
                    commandLine += QuoteArgument(path);
                    ++selected;
                }

                CoTaskMemFree(path);
            }

            item->Release();
        }

        if (selected == 0)
        {
            return E_INVALIDARG;
        }

        STARTUPINFOW startup{ sizeof(startup) };
        PROCESS_INFORMATION process{};
        std::vector<wchar_t> mutableCommand(commandLine.begin(), commandLine.end());
        mutableCommand.push_back(L'\0');
        const auto created = CreateProcessW(worker.c_str(), mutableCommand.data(), nullptr, nullptr, FALSE,
            CREATE_UNICODE_ENVIRONMENT, nullptr, directory.c_str(), &startup, &process);
        if (!created)
        {
            return HRESULT_FROM_WIN32(GetLastError());
        }

        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
        return S_OK;
    }

    class ExplorerCommand final : public IExplorerCommand
    {
    public:
        explicit ExplorerCommand(CommandKind kind) : kind(kind)
        {
            objectCount.fetch_add(1);
        }

        ~ExplorerCommand()
        {
            objectCount.fetch_sub(1);
        }

        HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void** object) override
        {
            if (object == nullptr)
            {
                return E_POINTER;
            }

            if (id == IID_IUnknown || id == IID_IExplorerCommand)
            {
                *object = static_cast<IExplorerCommand*>(this);
                AddRef();
                return S_OK;
            }

            *object = nullptr;
            return E_NOINTERFACE;
        }

        ULONG STDMETHODCALLTYPE AddRef() override
        {
            return static_cast<ULONG>(InterlockedIncrement(&references));
        }

        ULONG STDMETHODCALLTYPE Release() override
        {
            const auto remaining = InterlockedDecrement(&references);
            if (remaining == 0)
            {
                delete this;
            }

            return static_cast<ULONG>(remaining);
        }

        HRESULT STDMETHODCALLTYPE GetTitle(IShellItemArray*, wchar_t** name) override
        {
            return AllocateString(commands[static_cast<size_t>(kind)].name, name);
        }

        HRESULT STDMETHODCALLTYPE GetIcon(IShellItemArray*, wchar_t** icon) override
        {
            const auto directory = ModuleDirectory();
            if (directory.empty())
            {
                return E_FAIL;
            }

            const auto location = directory + L"\\RightClip.exe,0";
            return AllocateString(location.c_str(), icon);
        }

        HRESULT STDMETHODCALLTYPE GetToolTip(IShellItemArray*, wchar_t** tooltip) override
        {
            return AllocateString(commands[static_cast<size_t>(kind)].tooltip, tooltip);
        }

        HRESULT STDMETHODCALLTYPE GetCanonicalName(GUID* name) override
        {
            if (name == nullptr)
            {
                return E_POINTER;
            }

            *name = *commands[static_cast<size_t>(kind)].clsid;
            return S_OK;
        }

        HRESULT STDMETHODCALLTYPE GetState(IShellItemArray* items, BOOL, EXPCMDSTATE* state) override
        {
            if (state == nullptr)
            {
                return E_POINTER;
            }

            *state = IsSupportedSelection(items) ? ECS_ENABLED : ECS_HIDDEN;
            return S_OK;
        }

        HRESULT STDMETHODCALLTYPE Invoke(IShellItemArray* items, IBindCtx*) override
        {
            return LaunchWorker(kind, items);
        }

        HRESULT STDMETHODCALLTYPE GetFlags(EXPCMDFLAGS* flags) override
        {
            if (flags == nullptr)
            {
                return E_POINTER;
            }

            *flags = ECF_DEFAULT;
            return S_OK;
        }

        HRESULT STDMETHODCALLTYPE EnumSubCommands(IEnumExplorerCommand** subcommands) override
        {
            if (subcommands == nullptr)
            {
                return E_POINTER;
            }

            *subcommands = nullptr;
            return E_NOTIMPL;
        }

    private:
        long references{ 1 };
        CommandKind kind;
    };

    class ExplorerCommandEnumerator final : public IEnumExplorerCommand
    {
    public:
        ExplorerCommandEnumerator()
        {
            objectCount.fetch_add(1);
            for (const auto kind : { CommandKind::Trim, CommandKind::Tracks, CommandKind::Details })
            {
                auto command = new (std::nothrow) ExplorerCommand(kind);
                if (command == nullptr)
                {
                    break;
                }

                commands.push_back(command);
            }
        }

        ~ExplorerCommandEnumerator()
        {
            for (const auto command : commands)
            {
                command->Release();
            }

            objectCount.fetch_sub(1);
        }

        bool IsValid() const
        {
            return commands.size() == 3;
        }

        HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void** object) override
        {
            if (object == nullptr)
            {
                return E_POINTER;
            }

            if (id == IID_IUnknown || id == IID_IEnumExplorerCommand)
            {
                *object = static_cast<IEnumExplorerCommand*>(this);
                AddRef();
                return S_OK;
            }

            *object = nullptr;
            return E_NOINTERFACE;
        }

        ULONG STDMETHODCALLTYPE AddRef() override
        {
            return static_cast<ULONG>(InterlockedIncrement(&references));
        }

        ULONG STDMETHODCALLTYPE Release() override
        {
            const auto remaining = InterlockedDecrement(&references);
            if (remaining == 0)
            {
                delete this;
            }

            return static_cast<ULONG>(remaining);
        }

        HRESULT STDMETHODCALLTYPE Next(ULONG count, IExplorerCommand** items, ULONG* fetched) override
        {
            if (items == nullptr)
            {
                return E_POINTER;
            }

            if (fetched != nullptr)
            {
                *fetched = 0;
            }

            ULONG produced = 0;
            while (produced < count && position < commands.size())
            {
                items[produced] = commands[position];
                items[produced]->AddRef();
                ++produced;
                ++position;
            }

            if (fetched != nullptr)
            {
                *fetched = produced;
            }

            return produced == count ? S_OK : S_FALSE;
        }

        HRESULT STDMETHODCALLTYPE Skip(ULONG count) override
        {
            if (count == 0 || position + count >= commands.size())
            {
                position = commands.size();
                return count == 0 ? S_OK : S_FALSE;
            }

            position += count;
            return S_OK;
        }

        HRESULT STDMETHODCALLTYPE Reset() override
        {
            position = 0;
            return S_OK;
        }

        HRESULT STDMETHODCALLTYPE Clone(IEnumExplorerCommand** clone) override
        {
            if (clone == nullptr)
            {
                return E_POINTER;
            }

            auto copy = new (std::nothrow) ExplorerCommandEnumerator();
            if (copy == nullptr || !copy->IsValid())
            {
                delete copy;
                return E_OUTOFMEMORY;
            }

            copy->position = position;
            const auto result = copy->QueryInterface(IID_IEnumExplorerCommand, reinterpret_cast<void**>(clone));
            copy->Release();
            return result;
        }

    private:
        long references{ 1 };
        std::vector<IExplorerCommand*> commands;
        size_t position{ 0 };
    };

    class RootExplorerCommand final : public IExplorerCommand
    {
    public:
        RootExplorerCommand()
        {
            objectCount.fetch_add(1);
        }

        ~RootExplorerCommand()
        {
            objectCount.fetch_sub(1);
        }

        HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void** object) override
        {
            if (object == nullptr)
            {
                return E_POINTER;
            }

            if (id == IID_IUnknown || id == IID_IExplorerCommand)
            {
                *object = static_cast<IExplorerCommand*>(this);
                AddRef();
                return S_OK;
            }

            *object = nullptr;
            return E_NOINTERFACE;
        }

        ULONG STDMETHODCALLTYPE AddRef() override
        {
            return static_cast<ULONG>(InterlockedIncrement(&references));
        }

        ULONG STDMETHODCALLTYPE Release() override
        {
            const auto remaining = InterlockedDecrement(&references);
            if (remaining == 0)
            {
                delete this;
            }

            return static_cast<ULONG>(remaining);
        }

        HRESULT STDMETHODCALLTYPE GetTitle(IShellItemArray*, wchar_t** name) override
        {
            return AllocateString(L"RightClip", name);
        }

        HRESULT STDMETHODCALLTYPE GetIcon(IShellItemArray*, wchar_t** icon) override
        {
            const auto directory = ModuleDirectory();
            if (directory.empty())
            {
                return E_FAIL;
            }

            const auto location = directory + L"\\RightClip.exe,0";
            return AllocateString(location.c_str(), icon);
        }

        HRESULT STDMETHODCALLTYPE GetToolTip(IShellItemArray*, wchar_t** tooltip) override
        {
            return AllocateString(L"RightClip video tools", tooltip);
        }

        HRESULT STDMETHODCALLTYPE GetCanonicalName(GUID* name) override
        {
            if (name == nullptr)
            {
                return E_POINTER;
            }

            *name = CLSID_RightClipRoot;
            return S_OK;
        }

        HRESULT STDMETHODCALLTYPE GetState(IShellItemArray* items, BOOL, EXPCMDSTATE* state) override
        {
            if (state == nullptr)
            {
                return E_POINTER;
            }

            *state = IsSupportedSelection(items) ? ECS_ENABLED : ECS_HIDDEN;
            return S_OK;
        }

        HRESULT STDMETHODCALLTYPE Invoke(IShellItemArray*, IBindCtx*) override
        {
            return E_INVALIDARG;
        }

        HRESULT STDMETHODCALLTYPE GetFlags(EXPCMDFLAGS* flags) override
        {
            if (flags == nullptr)
            {
                return E_POINTER;
            }

            *flags = ECF_HASSUBCOMMANDS;
            return S_OK;
        }

        HRESULT STDMETHODCALLTYPE EnumSubCommands(IEnumExplorerCommand** subcommands) override
        {
            if (subcommands == nullptr)
            {
                return E_POINTER;
            }

            auto enumerator = new (std::nothrow) ExplorerCommandEnumerator();
            if (enumerator == nullptr || !enumerator->IsValid())
            {
                delete enumerator;
                return E_OUTOFMEMORY;
            }

            const auto result = enumerator->QueryInterface(IID_IEnumExplorerCommand, reinterpret_cast<void**>(subcommands));
            enumerator->Release();
            return result;
        }

    private:
        long references{ 1 };
    };

    class ClassFactory final : public IClassFactory
    {
    public:
        explicit ClassFactory(CommandKind kind) : kind(kind)
        {
            objectCount.fetch_add(1);
        }

        explicit ClassFactory(bool isRoot) : kind(CommandKind::Trim), root(isRoot)
        {
            objectCount.fetch_add(1);
        }

        ~ClassFactory()
        {
            objectCount.fetch_sub(1);
        }

        HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void** object) override
        {
            if (object == nullptr)
            {
                return E_POINTER;
            }

            if (id == IID_IUnknown || id == IID_IClassFactory)
            {
                *object = static_cast<IClassFactory*>(this);
                AddRef();
                return S_OK;
            }

            *object = nullptr;
            return E_NOINTERFACE;
        }

        ULONG STDMETHODCALLTYPE AddRef() override
        {
            return static_cast<ULONG>(InterlockedIncrement(&references));
        }

        ULONG STDMETHODCALLTYPE Release() override
        {
            const auto remaining = InterlockedDecrement(&references);
            if (remaining == 0)
            {
                delete this;
            }

            return static_cast<ULONG>(remaining);
        }

        HRESULT STDMETHODCALLTYPE CreateInstance(IUnknown* outer, REFIID id, void** object) override
        {
            if (outer != nullptr)
            {
                return CLASS_E_NOAGGREGATION;
            }

            IExplorerCommand* command = root
                ? static_cast<IExplorerCommand*>(new (std::nothrow) RootExplorerCommand())
                : static_cast<IExplorerCommand*>(new (std::nothrow) ExplorerCommand(kind));
            if (command == nullptr)
            {
                return E_OUTOFMEMORY;
            }

            const auto result = command->QueryInterface(id, object);
            command->Release();
            return result;
        }

        HRESULT STDMETHODCALLTYPE LockServer(BOOL lock) override
        {
            if (lock)
            {
                objectCount.fetch_add(1);
            }
            else
            {
                objectCount.fetch_sub(1);
            }

            return S_OK;
        }

    private:
        long references{ 1 };
        CommandKind kind;
        bool root{ false };
    };

    HRESULT SetRegistryValue(HKEY key, const wchar_t* name, const std::wstring& value)
    {
        const auto bytes = static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t));
        return HRESULT_FROM_WIN32(RegSetValueExW(key, name, 0, REG_SZ,
            reinterpret_cast<const BYTE*>(value.c_str()), bytes));
    }

    HRESULT RegisterKey(const std::wstring& path, const std::wstring& value, const wchar_t* name = nullptr)
    {
        HKEY key = nullptr;
        auto result = HRESULT_FROM_WIN32(RegCreateKeyExW(HKEY_CURRENT_USER, path.c_str(), 0, nullptr, 0,
            KEY_SET_VALUE | KEY_WOW64_64KEY, nullptr, &key, nullptr));
        if (SUCCEEDED(result))
        {
            result = SetRegistryValue(key, name, value);
            RegCloseKey(key);
        }

        return result;
    }

    std::wstring ClsidString(const CLSID& clsid)
    {
        wchar_t value[40]{};
        StringFromGUID2(clsid, value, static_cast<int>(std::size(value)));
        return value;
    }
}

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID)
{
    if (reason == DLL_PROCESS_ATTACH)
    {
        moduleHandle = module;
        DisableThreadLibraryCalls(module);
    }

    return TRUE;
}

STDAPI DllGetClassObject(REFCLSID clsid, REFIID iid, LPVOID* object)
{
    if (clsid == CLSID_RightClipRoot)
    {
        auto factory = new (std::nothrow) ClassFactory(true);
        if (factory == nullptr)
        {
            return E_OUTOFMEMORY;
        }

        const auto result = factory->QueryInterface(iid, object);
        factory->Release();
        return result;
    }

    for (size_t index = 0; index < std::size(commands); ++index)
    {
        if (clsid == *commands[index].clsid)
        {
            auto factory = new (std::nothrow) ClassFactory(static_cast<CommandKind>(index));
            if (factory == nullptr)
            {
                return E_OUTOFMEMORY;
            }

            const auto result = factory->QueryInterface(iid, object);
            factory->Release();
            return result;
        }
    }

    return CLASS_E_CLASSNOTAVAILABLE;
}

STDAPI DllCanUnloadNow()
{
    return objectCount.load() == 0 ? S_OK : S_FALSE;
}

STDAPI DllRegisterServer()
{
    const auto directory = ModuleDirectory();
    const auto library = directory + L"\\RightClip.Shell.dll";
    for (const auto& command : commands)
    {
        const auto clsid = ClsidString(*command.clsid);
        auto result = RegisterKey(L"Software\\Classes\\CLSID\\" + clsid, std::wstring(L"RightClip ") + command.name + L" command");
        if (FAILED(result))
        {
            return result;
        }

        result = RegisterKey(L"Software\\Classes\\CLSID\\" + clsid + L"\\InprocServer32", library);
        if (FAILED(result))
        {
            return result;
        }

        result = RegisterKey(L"Software\\Classes\\CLSID\\" + clsid + L"\\InprocServer32", L"Apartment", L"ThreadingModel");
        if (FAILED(result))
        {
            return result;
        }

        for (const auto extension : extensions)
        {
            result = RegisterKey(std::wstring(L"Software\\Classes\\SystemFileAssociations\\") + extension +
                L"\\shellex\\ContextMenuHandlers\\" + command.handlerName, clsid);
            if (FAILED(result))
            {
                return result;
            }
        }
    }

    SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, nullptr, nullptr);
    return S_OK;
}

STDAPI DllUnregisterServer()
{
    HRESULT firstFailure = S_OK;
    for (const auto& command : commands)
    {
        const auto clsid = ClsidString(*command.clsid);
        for (const auto extension : extensions)
        {
            const auto path = std::wstring(L"Software\\Classes\\SystemFileAssociations\\") + extension +
                L"\\shellex\\ContextMenuHandlers\\" + command.handlerName;
            const auto result = HRESULT_FROM_WIN32(RegDeleteTreeW(HKEY_CURRENT_USER, path.c_str()));
            if (FAILED(result) && result != HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND) && SUCCEEDED(firstFailure))
            {
                firstFailure = result;
            }
        }

        const auto result = HRESULT_FROM_WIN32(RegDeleteTreeW(HKEY_CURRENT_USER, (L"Software\\Classes\\CLSID\\" + clsid).c_str()));
        if (FAILED(result) && result != HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND) && SUCCEEDED(firstFailure))
        {
            firstFailure = result;
        }
    }

    SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, nullptr, nullptr);
    return firstFailure;
}
