#include <algorithm>
#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <fstream>
#include <filesystem>
#include <limits>
#include <memory>
#include <mutex>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <unordered_map>
#include <vector>

#include <Windows.h>
#include <bcrypt.h>
#include <xaudio2.h>
#include <malloc.h>
#pragma warning(push)
#pragma warning(disable: 4100) // upstream CppUserModBase default virtual callbacks
#include <Mod/CppUserModBase.hpp>
#pragma warning(pop)
#include <LuaMadeSimple/LuaMadeSimple.hpp>
#include "native_api.hpp"
#include "input_validation.hpp"
#include "pointer_state.hpp"
#include "pointer_queue.hpp"
#include "item_input_win32.hpp"
#include "item_input_raw_hooks.hpp"
#include "campaign_json.hpp"
#include "save_json_text.hpp"
#include "host_locator.hpp"
#include "host_version.hpp"
#include "checkpoint_json.hpp"
#include "hotbar_json.hpp"
#include "../../third_party/minhook-1.3.4/include/MinHook.h"

namespace {
using namespace RC::Unreal;
using RC::LuaMadeSimple::Lua;
using PBZMC::JsonText::Use;
using PBZMC::JsonText::to_utf8;
constexpr std::wstring_view target_mod = L"PBZMCProbe";
constexpr std::string_view entry_name = "PBZMC_JsonRoundTrip";
constexpr std::string_view read_entry_name = "PBZMC_ReadAdvancedJson";
constexpr std::string_view preview_entry_name = "PBZMC_ConfigurePreviewCapture";
constexpr std::string_view pointer_entry_name = "PBZMC_ReadPointerState";
constexpr std::size_t input_limit = 64 * 1024;
constexpr wchar_t library_path[] = L"/Script/JsonBlueprintUtilities.Default__JsonBlueprintFunctionLibrary";
constexpr wchar_t from_path[] = L"/Script/JsonBlueprintUtilities.JsonBlueprintFunctionLibrary:FromString";
constexpr wchar_t to_path[] = L"/Script/JsonBlueprintUtilities.JsonBlueprintFunctionLibrary:ToString";
constexpr wchar_t advanced_getter_path[] = L"/Script/ProjectPBZ.PBZSaveLoadSubsystem:GetAdvancedSaveJsonObject";
constexpr wchar_t ordinary_getter_path[] = L"/Script/ProjectPBZ.PBZSaveLoadSubsystem:SaveJsonObjectToString";
constexpr wchar_t identity_setter_path[] = L"/Script/ProjectPBZ.PBZSaveLoadSubsystem:SaveObjectData";
constexpr wchar_t capture_class_path[] = L"/Script/Engine.SceneCaptureComponent";
constexpr wchar_t capture_setter_path[] = L"/Script/Engine.SceneCaptureComponent:SetShowFlagSettings";
constexpr wchar_t capture_getter_path[] = L"/Script/Engine.SceneCaptureComponent:GetShowFlagSettings";
constexpr wchar_t flag_struct_path[] = L"/Script/Engine.EngineShowFlagsSetting";
constexpr wchar_t fixed_capture_flags[] =
    L"((ShowFlagName=\"Fog\",Enabled=False),(ShowFlagName=\"Atmosphere\",Enabled=False),"
    L"(ShowFlagName=\"VolumetricFog\",Enabled=False),(ShowFlagName=\"Lighting\",Enabled=False),"
    L"(ShowFlagName=\"DynamicShadows\",Enabled=False),(ShowFlagName=\"AmbientOcclusion\",Enabled=False),"
    L"(ShowFlagName=\"EyeAdaptation\",Enabled=False))";
// The upstream LuaMadeSimple::get_string() uses lua_tostring then strlen.
// Preserve an exact byte contract with a Lua preflight before that conversion.
// The native entry remains a closure upvalue, not a second public global.
constexpr std::string_view lua_preflight = R"lua(
do
    local native = PBZMC_JsonRoundTrip
    local value_type, value_count, find = type, select, string.find
    PBZMC_JsonRoundTrip = function(...)
        if value_count('#', ...) ~= 1 then
            return nil, 'PBZMCJsonBridge: expected exactly one JSON string'
        end
        local value = ...
        if value_type(value) ~= 'string' then
            return nil, 'PBZMCJsonBridge: expected a JSON string'
        end
        if #value == 0 or #value > 65536 then
            return nil, 'PBZMCJsonBridge: input must contain 1..65536 UTF-8 bytes'
        end
        if find(value, '\0', 1, true) then
            return nil, 'PBZMCJsonBridge: embedded NUL is not supported'
        end
        return native(value)
    end
end
)lua";
constexpr std::string_view advanced_lua_preflight = R"lua(
do
    local native = PBZMC_ReadAdvancedJson
    local value_type, value_count, find = type, select, string.find
    PBZMC_ReadAdvancedJson = function(...)
        if value_count('#', ...) ~= 1 then
            return nil, 'PBZMCJsonBridge: expected exactly one subsystem object path'
        end
        local value = ...
        if value_type(value) ~= 'string' then
            return nil, 'PBZMCJsonBridge: expected a subsystem object path string'
        end
        if #value == 0 or #value > 4096 then
            return nil, 'PBZMCJsonBridge: subsystem path must contain 1..4096 UTF-8 bytes'
        end
        if find(value, '\0', 1, true) then
            return nil, 'PBZMCJsonBridge: embedded NUL is not supported'
        end
        return native(value)
    end
end
)lua";
constexpr std::string_view preview_lua_preflight = R"lua(
do
    local native = PBZMC_ConfigurePreviewCapture
    local value_type, value_count, find = type, select, string.find
    PBZMC_ConfigurePreviewCapture = function(...)
        if value_count('#', ...) ~= 1 then
            return nil, 'PBZMCJsonBridge: expected exactly one preview component path'
        end
        local value = ...
        if value_type(value) ~= 'string' then
            return nil, 'PBZMCJsonBridge: expected a preview component path string'
        end
        if #value == 0 or #value > 4096 then
            return nil, 'PBZMCJsonBridge: preview path must contain 1..4096 UTF-8 bytes'
        end
        if find(value, '\0', 1, true) then
            return nil, 'PBZMCJsonBridge: embedded NUL is not supported'
        end
        return native(value)
    end
end
)lua";
constexpr std::string_view pointer_lua_preflight = R"lua(
do
    local native = PBZMC_ReadPointerState
    local value_count = select
    PBZMC_ReadPointerState = function(...)
        if value_count('#', ...) ~= 0 then
            return nil, 'PBZMCJsonBridge: pointer state accepts no arguments'
        end
        return native()
    end
end
)lua";
constexpr std::string_view pointer_events_lua_preflight = R"lua(
do
    local value_count = select
    local function wrap(native)
        return function(...)
            if value_count('#', ...) ~= 0 then return nil, 'PBZMCJsonBridge: pointer capture accepts no arguments' end
            return native()
        end
    end
    PBZMC_BeginPointerCapture = wrap(PBZMC_BeginPointerCapture)
    PBZMC_ReadPointerEvents = wrap(PBZMC_ReadPointerEvents)
    PBZMC_EndPointerCapture = wrap(PBZMC_EndPointerCapture)
end
)lua";
constexpr std::string_view item_input_lua_preflight = R"lua(
do
    local value_count, value_type, find = select, type, string.find
    local function text_entry(native, limit)
        return function(...)
            if value_count('#', ...) ~= 1 then return nil, 'PBZMCJsonBridge: item input expects exactly one string' end
            local value = ...
            if value_type(value) ~= 'string' then return nil, 'PBZMCJsonBridge: item input expects a string' end
            if #value == 0 or #value > limit then return nil, 'PBZMCJsonBridge: item input string length is invalid' end
            if find(value, '\0', 1, true) then return nil, 'PBZMCJsonBridge: embedded NUL is not supported' end
            return native(value)
        end
    end
    local function no_args(native)
        return function(...)
            if value_count('#', ...) ~= 0 then return nil, 'PBZMCJsonBridge: item input accepts no arguments' end
            return native()
        end
    end
    PBZMC_BeginItemInput = text_entry(PBZMC_BeginItemInput, 96)
    PBZMC_SetItemInputContext = text_entry(PBZMC_SetItemInputContext, 32)
    PBZMC_ReadItemInputEvents = no_args(PBZMC_ReadItemInputEvents)
    PBZMC_EndItemInput = no_args(PBZMC_EndItemInput)
end
)lua";
constexpr std::string_view campaign_lua_preflight = R"lua(
do
    local count, kind, find = select, type, string.find
    local read, current, create, generate, checkpoint, selection = PBZMC_ReadOrdinaryJson, PBZMC_ReadCampaignState, PBZMC_CreateCampaignIdentity, PBZMC_NewCampaignId, PBZMC_PutCampaignCheckpoint, PBZMC_SetHotbarSelection
    local function string_arg(value, limit)
        return kind(value) == 'string' and #value > 0 and #value <= limit and not find(value, '\0', 1, true)
    end
    PBZMC_ReadOrdinaryJson = function(...)
        if count('#', ...) ~= 1 or not string_arg((...), 4096) then
            return nil, 'PBZMCJsonBridge: expected one bounded subsystem path string'
        end
        return read(...)
    end
    local function state_reader(native)
        return function(...)
            if count('#', ...) ~= 1 or not string_arg((...), 4096) then
                return nil, 'PBZMCJsonBridge: expected one bounded subsystem path string'
            end
            return native(...)
        end
    end
    PBZMC_ReadCampaignState = state_reader(current)
    PBZMC_ReadCampaignLoadState = state_reader(PBZMC_ReadCampaignLoadState)
    PBZMC_CreateCampaignIdentity = function(...)
        local path, root_sha, id = ...
        if count('#', ...) ~= 3 or not string_arg(path, 4096) or not string_arg(root_sha, 64) or not string_arg(id, 36) then
            return nil, 'PBZMCJsonBridge: identity-not-written: expected subsystem path, root SHA256 and UUID strings'
        end
        return create(path, root_sha, id)
    end
    PBZMC_NewCampaignId = function(...)
        if count('#', ...) ~= 0 then return nil, 'PBZMCJsonBridge: UUID generation accepts no arguments' end
        return generate()
    end
    PBZMC_PutCampaignCheckpoint = function(...)
        local path, root_sha, id, digest = ...
        if count('#', ...) ~= 4 or not string_arg(path, 4096) or not string_arg(root_sha, 64)
            or not string_arg(id, 36) or not string_arg(digest, 64) then
            return nil, 'PBZMCJsonBridge: checkpoint-not-written: expected subsystem path, root SHA256, UUID and manifest SHA256 strings'
        end
        return checkpoint(path, root_sha, id, digest)
    end
    PBZMC_SetHotbarSelection = function(...)
        local path, root_sha, id, digest, mode, slot = ...
        if count('#', ...) ~= 6 or not string_arg(path,4096) or not string_arg(root_sha,64)
            or not string_arg(id,36) or not string_arg(digest,64) or (mode~='free' and mode~='adventure')
            or kind(slot)~='number' or slot%1~=0 or slot<1 or slot>9 then
            return nil,'PBZMCJsonBridge: hotbar-not-written: invalid selection arguments'
        end
        return selection(path,root_sha,id,digest,mode,string.format('%d',slot))
    end
end
)lua";
constexpr std::array<unsigned char, 32> expected_dll_hash{
    0xc2,0x73,0xe7,0x22,0x86,0x87,0xb6,0x47,0x22,0x6f,0xd6,0x3d,0x7c,0xa6,0x58,0x88,
    0xd3,0x13,0xec,0xe6,0xbe,0x18,0x99,0x6e,0xc1,0x32,0x0d,0x00,0xa5,0xef,0xe1,0xf8};
std::atomic_bool unreal_ready{false};
std::atomic_flag executing = ATOMIC_FLAG_INIT;

void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

std::wstring from_utf8(std::string_view text) {
    require(!text.empty() && text.size() <= input_limit, "input must contain 1..65536 UTF-8 bytes");
    require(text.find('\0') == std::string_view::npos, "embedded NUL is not supported");
    const auto length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), nullptr, 0);
    require(length > 0, "input is not valid UTF-8");
    std::wstring result(length, L'\0');
    require(MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), result.data(), length) == length,
            "UTF-8 conversion failed");
    return result;
}

class Sha256 {
    BCRYPT_ALG_HANDLE algorithm_{};
    BCRYPT_HASH_HANDLE hash_{};
public:
    Sha256() {
        require(BCryptOpenAlgorithmProvider(&algorithm_, BCRYPT_SHA256_ALGORITHM, nullptr, 0) >= 0, "cannot open SHA256 provider");
        if (BCryptCreateHash(algorithm_, &hash_, nullptr, 0, nullptr, 0, 0) < 0) {
            BCryptCloseAlgorithmProvider(algorithm_, 0);
            algorithm_ = nullptr;
            throw std::runtime_error("cannot create SHA256 state");
        }
    }
    ~Sha256() {
        if (hash_) BCryptDestroyHash(hash_);
        if (algorithm_) BCryptCloseAlgorithmProvider(algorithm_, 0);
    }
    void update(unsigned char* data, ULONG size) { require(BCryptHashData(hash_, data, size, 0) >= 0, "SHA256 update failed"); }
    std::array<unsigned char, 32> finish() {
        std::array<unsigned char, 32> hash{};
        require(BCryptFinishHash(hash_, hash.data(), static_cast<ULONG>(hash.size()), 0) >= 0, "SHA256 finalization failed");
        return hash;
    }
};

void verify_pinned_abi() {
    static std::once_flag verified;
    std::call_once(verified, [] {
        const auto module = GetModuleHandleW(L"UE4SS.dll");
        require(module != nullptr, "UE4SS.dll is not loaded under its expected name");
        std::array<wchar_t, 32768> path{};
        const auto length = GetModuleFileNameW(module, path.data(), static_cast<DWORD>(path.size()));
        require(length != 0 && length < path.size(), "cannot locate the loaded UE4SS.dll");
        std::ifstream input(path.data(), std::ios::binary);
        require(input.good(), "cannot verify the loaded UE4SS.dll file");
        Sha256 hasher;
        std::array<unsigned char, 64 * 1024> bytes{};
        while (input.read(reinterpret_cast<char*>(bytes.data()), bytes.size()) || input.gcount() > 0) {
            hasher.update(bytes.data(), static_cast<ULONG>(input.gcount()));
        }
        require(input.eof() && !input.bad(), "reading UE4SS.dll for identity failed");
        require(hasher.finish() == expected_dll_hash, "UE4SS.dll SHA256 mismatch; this bridge only supports cdbc0b66's verified binary");

        // No FString/TArray layout is declared. In this exact DLL the native
        // FString/TStringBase character-array accessors share their entry,
        // as do their default constructors and destructors. Reject any change
        // before using the inherited wide-string API on reflected storage.
        const auto same_export = [module](const char* a, const char* b) {
            const auto first = GetProcAddress(module, a);
            return first != nullptr && first == GetProcAddress(module, b);
        };
        require(same_export("?GetCharTArray@FString@Unreal@RC@@QEBAAEBV?$TArray@_WV?$TSizedDefaultAllocator@$0CA@@Unreal@RC@@@23@XZ",
                            "?GetCharArray@?$TStringBase@_W@Unreal@RC@@QEBAAEBV?$TArray@_WV?$TSizedDefaultAllocator@$0CA@@Unreal@RC@@@23@XZ"),
                "unsupported FString character-view ABI");
        require(same_export("??0FString@Unreal@RC@@QEAA@XZ", "??0?$TStringBase@_W@Unreal@RC@@QEAA@XZ") &&
                same_export("??1FString@Unreal@RC@@QEAA@XZ", "??1?$TStringBase@_W@Unreal@RC@@QEAA@XZ"),
                "unsupported FString lifetime ABI");
    });
}

UObject* find_object(const wchar_t* path) {
    auto* object = FUObjectHashTables::StaticFindObjectByPath(nullptr, path, false, true);
    require(object != nullptr, "required JsonBlueprintUtilities object is not loaded");
    const auto name = object->GetFullName();
    require(name.ends_with(path), "native object lookup returned an unexpected path");
    return object;
}

struct Parameter {
    const FProperty* property{};
    std::wstring name;
    std::wstring kind;
    std::size_t offset{};
    std::size_t size{};
    std::size_t alignment{};
};

struct Signature {
    UFunction* function{};
    std::size_t size{};
    std::size_t alignment{alignof(std::max_align_t)};
    std::vector<Parameter> parameters;

    const Parameter& at(std::wstring_view name) const {
        const auto it = std::find_if(parameters.begin(), parameters.end(), [name](const Parameter& p) { return p.name == name; });
        require(it != parameters.end(), "required native parameter is absent");
        return *it;
    }
};

struct ExpectedParameter {
    std::wstring_view name;
    std::wstring_view kind;
};
constexpr std::array from_parameters{
    ExpectedParameter{L"JsonString", L"StrProperty"},
    ExpectedParameter{L"OutJsonObject", L"StructProperty"},
    ExpectedParameter{L"ReturnValue", L"BoolProperty"}};
constexpr std::array to_parameters{
    ExpectedParameter{L"JsonObject", L"StructProperty"},
    ExpectedParameter{L"OutJsonString", L"StrProperty"},
    ExpectedParameter{L"ReturnValue", L"BoolProperty"}};
constexpr std::array advanced_parameters{ExpectedParameter{L"ReturnValue", L"StructProperty"}};
constexpr std::array ordinary_parameters{ExpectedParameter{L"ReturnValue", L"StrProperty"}};
constexpr std::array identity_parameters{
    ExpectedParameter{L"ObjectId", L"NameProperty"}, ExpectedParameter{L"JsonObjectWrapper", L"StructProperty"}};
constexpr std::array capture_setter_parameters{ExpectedParameter{L"InShowFlagSettings", L"ArrayProperty"}};
constexpr std::array capture_getter_parameters{ExpectedParameter{L"ReturnValue", L"ArrayProperty"}};

Signature inspect_signature(const wchar_t* path, std::span<const ExpectedParameter> expected) {
    auto* object = find_object(path);
    require(object->GetFullName() == std::wstring(L"Function ") + path, "native method does not match its fixed UFunction path");
    Signature result{reinterpret_cast<UFunction*>(object)};
    result.size = result.function->GetParmsSize();
    require(result.size > 0 && result.size <= 65535 && result.function->GetNumParms() == expected.size(),
            "unexpected JSON UFunction parameter shape");
    const auto* structure = reinterpret_cast<const UStruct*>(object);
    auto* field = structure->GetChildProperties();
    std::vector<const FField*> seen;
    while (field) {
        require(seen.size() < 16 && std::find(seen.begin(), seen.end(), field) == seen.end(), "cyclic or unexpected native property chain");
        seen.push_back(field);
        auto* property = reinterpret_cast<const FProperty*>(field);
        const auto name = field->GetName();
        const auto full_name = const_cast<FField*>(field)->GetFullName();
        const auto type_end = full_name.find(L' ');
        require(type_end != std::wstring::npos, "native property type cannot be identified");
        const auto kind = full_name.substr(0, type_end);
        const auto offset = property->GetOffset_Internal();
        const auto size = property->GetSize();
        const auto alignment = property->GetMinAlignment();
        require(property->GetArrayDim() == 1 && offset >= 0 && size > 0 && alignment > 0 && alignment <= 4096 &&
                (alignment & (alignment - 1)) == 0, "unsupported native property extent or alignment");
        require(static_cast<std::size_t>(offset) + static_cast<std::size_t>(size) <= result.size && offset % alignment == 0,
                "native parameter is outside its reflected buffer or misaligned");
        for (const auto& other : result.parameters) {
            require(name != other.name, "duplicate native parameter name");
            require(static_cast<std::size_t>(offset + size) <= other.offset || other.offset + other.size <= static_cast<std::size_t>(offset),
                    "overlapping native parameters are unsupported");
        }
        result.parameters.push_back({property, name, kind, static_cast<std::size_t>(offset), static_cast<std::size_t>(size), static_cast<std::size_t>(alignment)});
        result.alignment = std::max(result.alignment, static_cast<std::size_t>(alignment));
        field = FieldAccess::next(field);
    }
    require(result.parameters.size() == expected.size(), "native UFunction parameters differ from its fixed signature");
    for (const auto& parameter : expected) {
        require(result.at(parameter.name).kind == parameter.kind, "native UFunction parameter types changed");
    }
    const auto has_return = std::any_of(expected.begin(), expected.end(), [](const auto& p) { return p.name == L"ReturnValue"; });
    if (has_return) {
        require(result.at(L"ReturnValue").offset == result.function->GetReturnValueOffset(), "native return offset mismatch");
    } else {
        // Pinned LuaUObject.cpp:181 identifies 0xFFFF as the no-return sentinel.
        require(result.function->GetReturnValueOffset() == 0xffff, "fixed void function unexpectedly has a return slot");
    }
    return result;
}

std::wstring property_kind(const FProperty* property) {
    require(property != nullptr, "required reflected property is null");
    const auto full = reinterpret_cast<FField*>(const_cast<FProperty*>(property))->GetFullName();
    const auto space = full.find(L' ');
    require(space != std::wstring::npos, "cannot identify the reflected property kind");
    return full.substr(0, space);
}

const FProperty* class_property(const wchar_t* path, std::wstring_view wanted) {
    auto* object = find_object(path);
    require(object->GetFullName() == std::wstring(L"Class ") + path, "fixed capture class metadata changed");
    const auto* field = reinterpret_cast<const UStruct*>(object)->GetChildProperties();
    std::vector<const FField*> seen;
    while (field) {
        require(seen.size() < 512 && std::find(seen.begin(), seen.end(), field) == seen.end(), "invalid capture class property chain");
        seen.push_back(field);
        if (field->GetName() == wanted) return reinterpret_cast<const FProperty*>(field);
        field = FieldAccess::next(field);
    }
    throw std::runtime_error("fixed capture class property is absent");
}

#include "pixel_texture.hpp"

const FProperty* array_inner(const FProperty* array) {
    require(property_kind(array) == L"ArrayProperty" && array->GetArrayDim() == 1, "show flags must be one reflected array");
    const auto* inner = reinterpret_cast<const FArrayProperty*>(array)->GetInner();
    require(inner != nullptr && property_kind(inner) == L"StructProperty" && inner->GetArrayDim() == 1,
            "show flags array must contain a reflected struct");
    return inner;
}

void verify_show_flag_schema() {
    auto* object = find_object(flag_struct_path);
    require(object->GetFullName() == std::wstring(L"ScriptStruct ") + flag_struct_path, "show flag struct metadata identity changed");
    const auto* structure = reinterpret_cast<const UStruct*>(object);
    const auto extent = structure->GetPropertiesSize();
    require(extent > 0 && extent <= 4096, "unexpected show flag struct extent");
    const auto* field = structure->GetChildProperties();
    std::vector<const FField*> seen;
    bool name_found = false, enabled_found = false;
    while (field) {
        require(seen.size() < 2 && std::find(seen.begin(), seen.end(), field) == seen.end(), "unexpected show flag struct fields");
        seen.push_back(field);
        const auto* property = reinterpret_cast<const FProperty*>(field);
        const auto name = field->GetName();
        const auto kind = property_kind(property);
        const auto offset = property->GetOffset_Internal();
        const auto size = property->GetSize();
        require(property->GetArrayDim() == 1 && offset >= 0 && size > 0 &&
                static_cast<std::uint64_t>(offset) + size <= static_cast<std::uint64_t>(extent), "show flag field is outside its struct");
        if (name == L"ShowFlagName" && kind == L"StrProperty" && !name_found) name_found = true;
        else if (name == L"Enabled" && kind == L"BoolProperty" && !enabled_found) enabled_found = true;
        else throw std::runtime_error("show flag field name or type differs from the fixed schema");
        field = FieldAccess::next(field);
    }
    require(name_found && enabled_found && seen.size() == 2, "show flag schema must contain ShowFlagName FString and Enabled bool");
}

class ParameterFrame {
    const Signature& signature_;
    void* data_{};
    std::size_t initialized_{};
public:
    explicit ParameterFrame(const Signature& signature) : signature_(signature) {
        data_ = _aligned_malloc(signature.size, signature.alignment);
        if (!data_) throw std::bad_alloc();
        std::memset(data_, 0, signature.size); // padding only; each property is then constructed below
        try {
            for (const auto& parameter : signature.parameters) {
                parameter.property->InitializeValue(address(parameter));
                ++initialized_;
            }
        } catch (...) {
            destroy();
            throw;
        }
    }
    ParameterFrame(const ParameterFrame&) = delete;
    ParameterFrame& operator=(const ParameterFrame&) = delete;
    ~ParameterFrame() { destroy(); }
    void* address(const Parameter& parameter) const { return static_cast<std::byte*>(data_) + parameter.offset; }
    void* data() const { return data_; }
private:
    void destroy() noexcept {
        while (initialized_ != 0) {
            const auto& parameter = signature_.parameters[--initialized_];
            // Native faults are not swallowed. A successful native construction
            // has exactly one corresponding destruction, in reverse order.
            parameter.property->DestroyValue(address(parameter));
        }
        _aligned_free(std::exchange(data_, nullptr));
    }
};

std::wstring_view read_string(const void* storage,Use use=Use::probe) {
    return PBZMC::JsonText::view(*reinterpret_cast<const TStringBase<wchar_t>*>(storage),use);
}

bool read_result(const Signature& signature, const ParameterFrame& frame) {
    const auto& result = signature.at(L"ReturnValue");
    return reinterpret_cast<FBoolProperty*>(const_cast<FProperty*>(result.property))->GetPropertyValue(frame.address(result));
}

std::string round_trip(std::string_view utf8) {
    require(unreal_ready.load(), "Unreal initialization has not completed");
    verify_pinned_abi();
    require(IsInGameThread(), "PBZMC_JsonRoundTrip must be called from ExecuteInGameThread in PBZMCProbe");
    require(!executing.test_and_set(), "nested or concurrent JSON bridge calls are not supported");
    struct ReleaseBusy { ~ReleaseBusy() { executing.clear(); } } release_busy;
    const auto input = from_utf8(utf8);
    auto* library = find_object(library_path);
    const auto from = inspect_signature(from_path, from_parameters);
    const auto to = inspect_signature(to_path, to_parameters);
    const auto& produced_json = from.at(L"OutJsonObject");
    const auto& consumed_json = to.at(L"JsonObject");
    require(produced_json.property->SameType(consumed_json.property) && consumed_json.property->SameType(produced_json.property),
            "native JSON properties are not the same reflected type");
    require(produced_json.size == consumed_json.size && produced_json.alignment == consumed_json.alignment,
            "JSON wrapper reflection differs between FromString and ToString");

    ParameterFrame from_frame(from);
    ParameterFrame to_frame(to);
    auto* input_string = reinterpret_cast<TStringBase<wchar_t>*>(from_frame.address(from.at(L"JsonString")));
    require(input_string->Len() == 0, "native string initialization did not produce an empty string");
    input_string->Append(input.c_str());
    require(read_string(input_string) == input, "native FString input differs after append");

    library->ProcessEvent(from.function, from_frame.data());
    require(read_result(from, from_frame), "native FromString rejected the JSON object");
    consumed_json.property->CopyCompleteValue(to_frame.address(consumed_json), from_frame.address(produced_json));
    library->ProcessEvent(to.function, to_frame.data());
    require(read_result(to, to_frame), "native ToString failed");
    return to_utf8(read_string(to_frame.address(to.at(L"OutJsonString"))));
}

std::string read_advanced_json(std::string_view utf8_path) {
    require(unreal_ready.load(), "Unreal initialization has not completed");
    verify_pinned_abi();
    require(IsInGameThread(), "PBZMC_ReadAdvancedJson must be called from ExecuteInGameThread in PBZMCProbe");
    require(!executing.test_and_set(), "nested or concurrent JSON bridge calls are not supported");
    struct ReleaseBusy { ~ReleaseBusy() { executing.clear(); } } release_busy;
    require(!utf8_path.empty() && utf8_path.size() <= PBZMC::Validation::advanced_path_limit,
            "subsystem path must contain 1..4096 UTF-8 bytes");
    const auto path = from_utf8(utf8_path);
    PBZMC::Validation::advanced_subsystem_path(path);
    auto* subsystem = FUObjectHashTables::StaticFindObjectByPath(nullptr, path.c_str(), false, true);
    require(subsystem != nullptr, "requested transient PBZSaveLoadSubsystem is not loaded");
    PBZMC::Validation::advanced_subsystem_identity(subsystem->GetFullName(), path);

    // Both functions and their entire signatures are fixed by the bridge.
    // No caller-controlled function name or native pointer is accepted.
    auto* library = find_object(library_path);
    const auto getter = inspect_signature(advanced_getter_path, advanced_parameters);
    const auto to = inspect_signature(to_path, to_parameters);
    const auto& produced_json = getter.at(L"ReturnValue");
    const auto& consumed_json = to.at(L"JsonObject");
    require(produced_json.property->SameType(consumed_json.property) && consumed_json.property->SameType(produced_json.property),
            "advanced getter and ToString do not use the same reflected JSON type");
    require(produced_json.size == consumed_json.size && produced_json.alignment == consumed_json.alignment,
            "advanced JSON wrapper size or alignment differs from ToString");

    ParameterFrame getter_frame(getter);
    ParameterFrame to_frame(to);
    subsystem->ProcessEvent(getter.function, getter_frame.data());
    consumed_json.property->CopyCompleteValue(to_frame.address(consumed_json), getter_frame.address(produced_json));
    library->ProcessEvent(to.function, to_frame.data());
    require(read_result(to, to_frame), "native ToString failed for the advanced JSON object");
    return to_utf8(read_string(to_frame.address(to.at(L"OutJsonString")),Use::save),Use::save);
}

std::string sha256_text(std::string_view text) {
    Sha256 hasher;
    hasher.update(reinterpret_cast<unsigned char*>(const_cast<char*>(text.data())),static_cast<ULONG>(text.size()));
    constexpr char digits[]="0123456789abcdef";
    std::string result;
    for (const auto byte:hasher.finish()) { result.push_back(digits[byte>>4]); result.push_back(digits[byte&15]); }
    return result;
}

UObject* fixed_save_subsystem(std::string_view utf8_path) {
    require(!utf8_path.empty() && utf8_path.size()<=PBZMC::Validation::advanced_path_limit,"invalid subsystem path length");
    const auto path=from_utf8(utf8_path);
    PBZMC::Validation::advanced_subsystem_path(path);
    auto* subsystem=FUObjectHashTables::StaticFindObjectByPath(nullptr,path.c_str(),false,true);
    require(subsystem!=nullptr,"requested PBZSaveLoadSubsystem is not loaded");
    PBZMC::Validation::advanced_subsystem_identity(subsystem->GetFullName(),path);
    require(!subsystem->IsUnreachable(),"save subsystem is unreachable");
    return subsystem;
}

// Internal helper deliberately does not reacquire executing: a create operation
// reads before/after while one outer game-thread/ABI/reentrancy guard is held.
std::string ordinary_json_unlocked(UObject* subsystem) {
    const auto getter=inspect_signature(ordinary_getter_path,ordinary_parameters);
    ParameterFrame frame(getter);
    subsystem->ProcessEvent(getter.function,frame.data());
    const auto wide=read_string(frame.address(getter.at(L"ReturnValue")),Use::save);
    require(wide.find(L'\0')==std::wstring_view::npos,"ordinary JSON contains embedded native NUL");
    // Owned bytes. Public readers and write transactions parse once at the
    // point of use; the second pre-write read must match these exact bytes.
    return to_utf8(wide,Use::save);
}

std::string read_ordinary_json(std::string_view path) {
    require(unreal_ready.load(),"Unreal initialization has not completed"); verify_pinned_abi();
    require(IsInGameThread(),"ordinary save reads require the game thread");
    require(!executing.test_and_set(),"nested or concurrent JSON bridge calls are not supported");
    struct ReleaseBusy { ~ReleaseBusy() { executing.clear(); } } release_busy;
    return ordinary_json_unlocked(fixed_save_subsystem(path));
}

std::string new_campaign_id() {
    std::array<unsigned char,16> bytes{};
    require(BCryptGenRandom(nullptr,bytes.data(),static_cast<ULONG>(bytes.size()),BCRYPT_USE_SYSTEM_PREFERRED_RNG)>=0,
            "system random UUID generation failed");
    bytes[6]=static_cast<unsigned char>((bytes[6]&15)|0x40);
    bytes[8]=static_cast<unsigned char>((bytes[8]&63)|0x80);
    constexpr char digits[]="0123456789abcdef";
    std::string result;
    for (std::size_t i=0;i<bytes.size();++i) {
        if (i==4 || i==6 || i==8 || i==10) result.push_back('-');
        result.push_back(digits[bytes[i]>>4]); result.push_back(digits[bytes[i]&15]);
    }
    PBZMC::Campaign::validate_uuid(result); return result;
}

std::string create_campaign_identity(std::string_view path,std::string_view expected_sha,std::string_view id,bool& write_started) {
    PBZMC::Campaign::validate_uuid(id); PBZMC::Campaign::validate_sha(expected_sha);
    require(unreal_ready.load(),"Unreal initialization has not completed"); verify_pinned_abi();
    require(IsInGameThread(),"campaign identity writes require the game thread");
    require(!executing.test_and_set(),"nested or concurrent JSON bridge calls are not supported");
    struct ReleaseBusy { ~ReleaseBusy() { executing.clear(); } } release_busy;
    auto* subsystem=fixed_save_subsystem(path);
    auto* library=find_object(library_path);
    const auto from=inspect_signature(from_path,from_parameters);
    const auto to=inspect_signature(to_path,to_parameters);
    const auto setter=inspect_signature(identity_setter_path,identity_parameters);
    const auto& produced=from.at(L"OutJsonObject");
    const auto& consumed=setter.at(L"JsonObjectWrapper");
    const auto& serialized=to.at(L"JsonObject");
    for (const auto* other:{&consumed,&serialized}) {
        require(produced.property->SameType(other->property) && other->property->SameType(produced.property),"identity JSON properties have different native types");
        require(produced.size==other->size && produced.alignment==other->alignment,"identity JSON wrapper extents differ");
    }
    ParameterFrame from_frame(from),to_frame(to),set_frame(setter);
    const auto proof=PBZMC::Campaign::create_only(id,expected_sha,
        [&] {
            require(fixed_save_subsystem(path)==subsystem,"save subsystem changed during identity operation");
            return ordinary_json_unlocked(subsystem);
        },
        [&](std::string_view marker) {
            const auto wide=from_utf8(marker);
            auto* input=reinterpret_cast<TStringBase<wchar_t>*>(from_frame.address(from.at(L"JsonString")));
            require(input->Len()==0,"identity input string initialization failed");
            input->Append(wide.c_str()); require(read_string(input)==wide,"identity input string differs after append");
            library->ProcessEvent(from.function,from_frame.data());
            require(read_result(from,from_frame),"native FromString rejected the fixed marker");
            serialized.property->CopyCompleteValue(to_frame.address(serialized),from_frame.address(produced));
            library->ProcessEvent(to.function,to_frame.data());
            require(read_result(to,to_frame),"marker validation serialization failed");
            const auto serialized_marker=to_utf8(read_string(to_frame.address(to.at(L"OutJsonString"))));
            require(PBZMC::Campaign::parse(serialized_marker)==PBZMC::Campaign::parse(marker),"native marker round trip changed its content");
            const auto& name=setter.at(L"ObjectId");
            const auto* end=name.property->ImportText_Direct(PBZMC::Campaign::section_wide,set_frame.address(name),subsystem,0,nullptr);
            require(end==PBZMC::Campaign::section_wide+std::size(PBZMC::Campaign::section_wide)-1,"fixed campaign FName was not fully imported");
            consumed.property->CopyCompleteValue(set_frame.address(consumed),from_frame.address(produced));
        },
        [&] { subsystem->ProcessEvent(setter.function,set_frame.data()); },
        [](std::string_view text) { return sha256_text(text); },write_started);
    return nlohmann::json{{"campaign_id",std::string(id)},{"actual_key",proof.actual_key},
        {"before_sha256",proof.before_sha256},{"after_sha256",proof.after_sha256},
        {"created_in_memory",true},{"disk_persistence_verified",false}}.dump();
}

std::string put_campaign_checkpoint(std::string_view path,std::string_view expected_sha,
    std::string_view id,std::string_view checkpoint,bool& write_started,std::string_view mode="",int selected=0) {
    PBZMC::Campaign::validate_uuid(id);PBZMC::Campaign::validate_sha(expected_sha);PBZMC::Campaign::validate_sha(checkpoint);
    require(unreal_ready.load(),"Unreal initialization has not completed");verify_pinned_abi();
    require(IsInGameThread(),"campaign checkpoint writes require the game thread");
    require(!executing.test_and_set(),"nested or concurrent JSON bridge calls are not supported");
    struct ReleaseBusy { ~ReleaseBusy() { executing.clear(); } } release_busy;
    auto* subsystem=fixed_save_subsystem(path);
    auto* library=find_object(library_path);
    const auto from=inspect_signature(from_path,from_parameters);
    const auto to=inspect_signature(to_path,to_parameters);
    const auto setter=inspect_signature(identity_setter_path,identity_parameters);
    const auto& produced=from.at(L"OutJsonObject");
    const auto& consumed=setter.at(L"JsonObjectWrapper");
    const auto& serialized=to.at(L"JsonObject");
    for (const auto* other:{&consumed,&serialized}) {
        require(produced.property->SameType(other->property) && other->property->SameType(produced.property),"checkpoint JSON properties have different native types");
        require(produced.size==other->size && produced.alignment==other->alignment,"checkpoint JSON wrapper extents differ");
    }
    ParameterFrame from_frame(from),to_frame(to),set_frame(setter);
    const auto read=[&] {
            require(fixed_save_subsystem(path)==subsystem,"save subsystem changed during checkpoint operation");
            return ordinary_json_unlocked(subsystem);
        };
    const auto prepare=[&](std::string_view anchor) {
            const auto wide=from_utf8(anchor);
            auto* input=reinterpret_cast<TStringBase<wchar_t>*>(from_frame.address(from.at(L"JsonString")));
            require(input->Len()==0,"checkpoint input string initialization failed");
            input->Append(wide.c_str());require(read_string(input)==wide,"checkpoint input string differs after append");
            library->ProcessEvent(from.function,from_frame.data());
            require(read_result(from,from_frame),"native FromString rejected the checkpoint anchor");
            serialized.property->CopyCompleteValue(to_frame.address(serialized),from_frame.address(produced));
            library->ProcessEvent(to.function,to_frame.data());
            require(read_result(to,to_frame),"checkpoint validation serialization failed");
            const auto roundtrip=to_utf8(read_string(to_frame.address(to.at(L"OutJsonString"))));
            require(PBZMC::Campaign::parse(roundtrip)==PBZMC::Campaign::parse(anchor),"native checkpoint round trip changed its content");
            const auto& name=setter.at(L"ObjectId");
            const auto* section=selected ? PBZMC::Hotbar::section_wide : PBZMC::Checkpoint::section_wide;
            const auto* end=name.property->ImportText_Direct(section,set_frame.address(name),subsystem,0,nullptr);
            require(end==section+std::char_traits<wchar_t>::length(section),"fixed save section FName was not fully imported");
            consumed.property->CopyCompleteValue(set_frame.address(consumed),from_frame.address(produced));
        };
    const auto write=[&] { subsystem->ProcessEvent(setter.function,set_frame.data()); };
    const auto digest=[](std::string_view text) { return sha256_text(text); };
    const auto proof=selected ? PBZMC::Hotbar::put(id,checkpoint,mode,selected,expected_sha,read,prepare,write,digest,write_started)
        : PBZMC::Checkpoint::put(id,checkpoint,expected_sha,read,prepare,write,digest,write_started);
    return nlohmann::json{{"campaign_id",std::string(id)},{"checkpoint",std::string(checkpoint)},
        {"actual_key",proof.actual_key},{"before_sha256",proof.before_sha256},{"after_sha256",proof.after_sha256},
        {"changed_in_memory",proof.changed},{"disk_persistence_verified",false},{"selected",selected},{"mode",std::string(mode)}}.dump();
}

void configure_preview_capture(std::string_view utf8_path) {
    require(unreal_ready.load(), "Unreal initialization has not completed");
    verify_pinned_abi();
    require(IsInGameThread(), "PBZMC_ConfigurePreviewCapture must be called from ExecuteInGameThread in PBZMCProbe");
    require(!executing.test_and_set(), "nested or concurrent bridge calls are not supported");
    struct ReleaseBusy { ~ReleaseBusy() { executing.clear(); } } release_busy;
    require(!utf8_path.empty() && utf8_path.size() <= PBZMC::Validation::preview_path_limit,
            "preview path must contain 1..4096 UTF-8 bytes");
    const auto path = from_utf8(utf8_path);
    const auto actor_path = PBZMC::Validation::preview_component_actor_path(path);
    auto* component = FUObjectHashTables::StaticFindObjectByPath(nullptr, path.c_str(), false, true);
    require(component != nullptr && !component->IsUnreachable(), "requested preview component is not loaded or reachable");
    PBZMC::Validation::preview_component_identity(component->GetFullName(), path);
    auto* actor = FUObjectHashTables::StaticFindObjectByPath(nullptr, actor_path.c_str(), false, true);
    require(actor != nullptr && !actor->IsUnreachable(), "requested preview actor is not loaded or reachable");
    PBZMC::Validation::preview_actor_identity(actor->GetFullName(), actor_path);

    const auto setter = inspect_signature(capture_setter_path, capture_setter_parameters);
    const auto getter = inspect_signature(capture_getter_path, capture_getter_parameters); // metadata only
    const auto* input = setter.at(L"InShowFlagSettings").property;
    const auto* output = getter.at(L"ReturnValue").property;
    const auto* member = class_property(capture_class_path, L"ShowFlagSettings");
    const auto* inner = array_inner(input);
    for (const auto* other : {output, member}) {
        const auto* other_inner = array_inner(other);
        require(input->SameType(other) && other->SameType(input) &&
                inner->SameType(other_inner) && other_inner->SameType(inner),
                "capture setter, getter and member do not share the same native array/struct type");
    }
    // GetStruct() exports TObjectPtr<UScriptStruct>& without an exported
    // unpacker. Do not flatten it. The fixed three-way native SameType check
    // above is paired with this separately validated, previously reflected type.
    verify_show_flag_schema();
    ParameterFrame frame(setter);
    const auto* end = input->ImportText_Direct(fixed_capture_flags, frame.address(setter.at(L"InShowFlagSettings")), component, 0, nullptr);
    require(end != nullptr && end == fixed_capture_flags + std::size(fixed_capture_flags) - 1,
            "fixed show flag text was rejected or not fully consumed; capture was not modified");
    // Only this fixed setter can be invoked, on the exact looked-up component.
    // Import failure leaves only temporary constructed storage to destroy.
    component->ProcessEvent(setter.function, frame.data());
}

struct PointerApi {
    using Window = HWND;
    Window foreground() const { return GetForegroundWindow(); }
    std::uint64_t milliseconds() const { return GetTickCount64(); }
    bool eligible_window(Window window) const {
        if (!window) return false;
        DWORD process{};
        if (!GetWindowThreadProcessId(window, &process)) return false;
        std::array<wchar_t, 128> name{};
        const auto length = GetClassNameW(window, name.data(), static_cast<int>(name.size()));
        if (length <= 0 || static_cast<std::size_t>(length) >= name.size() - 1) return false;
        return PBZMC::Pointer::eligible(reinterpret_cast<std::uintptr_t>(window), process, GetCurrentProcessId(),
            std::wstring_view(name.data(), static_cast<std::size_t>(length)), IsWindowVisible(window) != FALSE, IsIconic(window) != FALSE);
    }
    bool geometry(Window window, PBZMC::Pointer::State& state) const {
        POINT point{}; RECT rect{};
        if (!GetCursorPos(&point) || !ScreenToClient(window, &point) || !GetClientRect(window, &rect)) return false;
        const auto width = static_cast<std::int64_t>(rect.right) - rect.left;
        const auto height = static_cast<std::int64_t>(rect.bottom) - rect.top;
        if (rect.left != 0 || rect.top != 0 || width <= 0 || height <= 0 || width > 65535 || height > 65535) return false;
        state.x = point.x; state.y = point.y;
        state.width = static_cast<std::int32_t>(width); state.height = static_cast<std::int32_t>(height);
        return true;
    }
    SHORT key_state(PBZMC::Pointer::Key key) const {
        constexpr std::array keys{VK_LBUTTON, VK_RBUTTON, VK_SHIFT, VK_CONTROL, int('E'), VK_ESCAPE, int('F'), int('Q'),
                                  int('1'), int('2'), int('3'), int('4'), int('5'), int('6'), int('7'), int('8'), int('9')};
        static_assert(keys.size() == static_cast<std::size_t>(PBZMC::Pointer::Key::count));
        return GetAsyncKeyState(keys[static_cast<std::size_t>(key)]);
    }
};

std::string read_pointer_state() {
    require(unreal_ready.load(), "Unreal initialization has not completed");
    verify_pinned_abi();
    require(IsInGameThread(), "PBZMC_ReadPointerState must be called from ExecuteInGameThread in PBZMCProbe");
    require(!executing.test_and_set(), "nested or concurrent bridge calls are not supported");
    struct ReleaseBusy { ~ReleaseBusy() { executing.clear(); } } release_busy;
    PointerApi api;
    return PBZMC::Pointer::json(PBZMC::Pointer::sample(api));
}

// The worker only reads eligible Win32 state. It never touches Unreal, Lua,
// native game memory, input injection or another application's keys.
class PointerCapture {
    std::mutex control_mutex;
    std::mutex mutex;
    std::condition_variable wake;
    std::thread worker;
    bool stopping{}, failed{};
    PBZMC::Pointer::Queue queue;
public:
    ~PointerCapture() { stop(); }
    void start() {
        std::lock_guard control(control_mutex);
        std::lock_guard lock(mutex);
        require(!worker.joinable(), "pointer capture is already active");
        PointerApi api;
        const auto initial = PBZMC::Pointer::sample(api);
        require(initial.focused, "pointer capture requires the game foreground");
        queue = {}; queue.push(initial); stopping = false; failed = false;
        worker = std::thread([this] {
            try {
                std::unique_lock lock(mutex);
                PointerApi api;
                while (!wake.wait_for(lock, std::chrono::milliseconds(4), [this] { return stopping; }))
                    queue.push(PBZMC::Pointer::sample(api));
            } catch (...) { std::lock_guard lock(mutex); failed = true; }
        });
    }
    std::string drain() {
        std::lock_guard control(control_mutex);
        std::lock_guard lock(mutex);
        require(worker.joinable() && !failed, "pointer capture is inactive or failed");
        PointerApi api;
        queue.push(PBZMC::Pointer::sample(api)); // freshest focus check before replay
        return queue.drain();
    }
    void stop() {
        std::lock_guard control(control_mutex);
        { std::lock_guard lock(mutex); stopping = true; }
        wake.notify_all();
        if (worker.joinable()) worker.join();
        std::lock_guard lock(mutex); queue = {};
    }
};
PointerCapture pointer_capture;

int lua_pointer_capture(const Lua& lua, int operation) {
    try {
        require(lua.get_stack_size() == 0, "pointer capture accepts no arguments");
        require(unreal_ready.load(), "Unreal initialization has not completed");
        verify_pinned_abi();
        require(IsInGameThread(), "pointer capture must be controlled on the game thread");
        require(!executing.test_and_set(), "nested or concurrent bridge calls are not supported");
        struct ReleaseBusy { ~ReleaseBusy() { executing.clear(); } } release_busy;
        if (operation == 0) { pointer_capture.start(); lua.set_bool(true); }
        else if (operation == 1) lua.set_string(pointer_capture.drain());
        else { pointer_capture.stop(); lua.set_bool(true); }
        lua.set_nil();
    } catch (const std::exception& error) {
        lua.set_nil(); lua.set_string(std::string("PBZMCJsonBridge: ") + error.what());
    }
    return 2;
}
int lua_begin_pointer_capture(const Lua& lua) { return lua_pointer_capture(lua, 0); }
int lua_read_pointer_events(const Lua& lua) { return lua_pointer_capture(lua, 1); }
int lua_end_pointer_capture(const Lua& lua) { return lua_pointer_capture(lua, 2); }

int lua_item_input(const Lua& lua, int operation) {
    try {
        const bool text_argument = operation == 0 || operation == 1;
        require(lua.get_stack_size() == (text_argument ? 1 : 0), "item input argument count is invalid");
        if (text_argument) require(lua.is_string(1), "item input requires a string");
        require(unreal_ready.load(), "Unreal initialization has not completed");
        verify_pinned_abi();
        require(IsInGameThread(), "item input must be controlled on the game thread in PBZMCProbe");
        require(!executing.test_and_set(), "nested or concurrent bridge calls are not supported");
        struct ReleaseBusy { ~ReleaseBusy() { executing.clear(); } } release_busy;
        auto& input = PBZMC::ItemInput::Capture::instance();
        if (operation == 0) {
            const std::string text(lua.get_string(1));
            input.begin(PBZMC::ItemInput::parse_bindings(text));
            try { PBZMC::ItemInput::RawInputHooks::ensure(); }
            catch(...) { input.end();throw; }
            lua.set_bool(true);
        } else if (operation == 1) {
            const std::string text(lua.get_string(1));
            input.set_context(PBZMC::ItemInput::parse_context(text)); lua.set_bool(true);
        } else if (operation == 2) lua.set_string(input.read());
        else { input.end(); lua.set_bool(true); }
        lua.set_nil();
    } catch (const std::exception& error) {
        lua.set_nil(); lua.set_string(std::string("PBZMCJsonBridge: ") + error.what());
    }
    return 2;
}
int lua_begin_item_input(const Lua& lua) { return lua_item_input(lua, 0); }
int lua_set_item_input_context(const Lua& lua) { return lua_item_input(lua, 1); }
int lua_read_item_input_events(const Lua& lua) { return lua_item_input(lua, 2); }
int lua_end_item_input(const Lua& lua) { return lua_item_input(lua, 3); }

int lua_round_trip(const Lua& lua) {
    try {
        require(lua.get_stack_size() == 1 && lua.is_string(1), "usage: PBZMC_JsonRoundTrip(json_utf8_text)");
        const std::string input(lua.get_string(1));
        const auto output = round_trip(input);
        lua.set_string(output);
        lua.set_nil();
    } catch (const std::exception& error) {
        lua.set_nil();
        lua.set_string(std::string("PBZMCJsonBridge: ") + error.what());
    }
    return 2; // success: text, nil; rejected call: nil, explanatory text
}

int lua_read_advanced_json(const Lua& lua) {
    try {
        require(lua.get_stack_size() == 1 && lua.is_string(1), "usage: PBZMC_ReadAdvancedJson(subsystem_object_path)");
        const std::string input(lua.get_string(1));
        const auto output = read_advanced_json(input);
        lua.set_string(output);
        lua.set_nil();
    } catch (const std::exception& error) {
        lua.set_nil();
        lua.set_string(std::string("PBZMCJsonBridge: ") + error.what());
    }
    return 2;
}

int lua_read_ordinary_json(const Lua& lua) {
    try {
        require(lua.get_stack_size()==1 && lua.is_string(1),"usage: PBZMC_ReadOrdinaryJson(subsystem_path)");
        auto raw=read_ordinary_json(std::string(lua.get_string(1)));
        PBZMC::Campaign::parse(raw); // Do not expose an unvalidated root to Lua.
        lua.set_string(raw); lua.set_nil();
    } catch (const std::exception& error) { lua.set_nil(); lua.set_string(std::string("PBZMCJsonBridge: ")+error.what()); }
    return 2;
}
int campaign_state(const Lua& lua,bool allow_registration) {
    try {
        require(lua.get_stack_size()==1 && lua.is_string(1),"usage: PBZMC_ReadCampaignState(subsystem_path)");
        const auto raw=read_ordinary_json(std::string(lua.get_string(1)));
        std::size_t nodes{};
        const auto root=PBZMC::Campaign::parse(raw,&nodes);
        const auto current=PBZMC::Checkpoint::inspect(root,allow_registration);
        auto result=nlohmann::json{{"root_sha256",sha256_text(raw)},{"root_bytes",raw.size()}};
        bool bootstrap_backup=false;
        if (current) {
            result["campaign_id"]=current->campaign_id;result["checkpoint"]=current->checkpoint;
            if(const auto selection=PBZMC::Hotbar::read(root,current->campaign_id,current->checkpoint)) {
                result["selected"]=selection->selected;result["selection_mode"]=selection->mode;
            }
        } else {
            // First use will write an identity and/or checkpoint. Reject a
            // full root before Lua creates any local bootstrap files.
            PBZMC::Campaign::check_write_size(raw.size());
            PBZMC::Campaign::check_limit(nodes,PBZMC::Campaign::node_limit-16,"expanded save JSON values before registration");
            result["needs_registration"]=true;
            const auto marker=PBZMC::Checkpoint::key(root,PBZMC::Campaign::section);
            // inspect() already verified the exact owner/schema/UUID. A
            // partial bootstrap must recover that identity, never create a
            // new empty campaign. Only brand-new registrations need a backup.
            if(marker) result["campaign_id"]=root.object.at(*marker).object.at("campaign_id").atom;
            else bootstrap_backup=true;
        }
        lua.set_string(result.dump());lua.set_nil();
        // The backup crosses Lua as opaque bytes once. Do not parse or hash a
        // chapter-sized PBZ root again in Lua merely to register two markers.
        if(bootstrap_backup) lua.set_string(raw);else lua.set_nil();
    } catch(const std::exception& error) {lua.set_nil();lua.set_string(std::string("PBZMCJsonBridge: ")+error.what());lua.set_nil();}
    return 3;
}
int lua_read_campaign_state(const Lua& lua) { return campaign_state(lua,false); }
int lua_read_campaign_load_state(const Lua& lua) { return campaign_state(lua,true); }
int lua_new_campaign_id(const Lua& lua) {
    try {
        require(lua.get_stack_size()==0,"usage: PBZMC_NewCampaignId()");
        lua.set_string(new_campaign_id()); lua.set_nil();
    } catch (const std::exception& error) { lua.set_nil(); lua.set_string(std::string("PBZMCJsonBridge: ")+error.what()); }
    return 2;
}
int lua_create_campaign_identity(const Lua& lua) {
    bool started=false;
    try {
        require(lua.get_stack_size()==3 && lua.is_string(1) && lua.is_string(2) && lua.is_string(3),
            "usage: PBZMC_CreateCampaignIdentity(subsystem_path,root_sha256,uuid)");
        // LuaMadeSimple::get_string removes its stack entry. Copy each value
        // before consuming the next; the remaining arguments shift to index 1.
        const std::string path(lua.get_string(1));
        const std::string sha(lua.get_string(1));
        const std::string id(lua.get_string(1));
        lua.set_string(create_campaign_identity(path,sha,id,started)); lua.set_nil();
    } catch (const std::exception& error) {
        lua.set_nil();
        lua.set_string(std::string("PBZMCJsonBridge: ")+(started?"identity-write-uncertain: ":"identity-not-written: ")+error.what());
    }
    return 2;
}

int lua_put_campaign_checkpoint(const Lua& lua) {
    bool started=false;
    try {
        require(lua.get_stack_size()==4 && lua.is_string(1) && lua.is_string(2) && lua.is_string(3) && lua.is_string(4),
            "usage: PBZMC_PutCampaignCheckpoint(subsystem_path,root_sha256,uuid,checkpoint_sha256)");
        const std::string path(lua.get_string(1));
        const std::string sha(lua.get_string(1));
        const std::string id(lua.get_string(1));
        const std::string checkpoint(lua.get_string(1));
        lua.set_string(put_campaign_checkpoint(path,sha,id,checkpoint,started));lua.set_nil();
    } catch (const std::exception& error) {
        lua.set_nil();
        lua.set_string(std::string("PBZMCJsonBridge: ")+(started?"checkpoint-write-uncertain: ":"checkpoint-not-written: ")+error.what());
    }
    return 2;
}
int lua_set_hotbar_selection(const Lua& lua) {
    bool started=false;
    try {
        require(lua.get_stack_size()==6,"usage: PBZMC_SetHotbarSelection(path,root_sha,id,checkpoint,mode,slot)");
        for(int i=1;i<=6;++i) require(lua.is_string(i),"hotbar bridge requires bounded strings");
        const std::string path(lua.get_string(1)),sha(lua.get_string(1)),id(lua.get_string(1)),checkpoint(lua.get_string(1)),mode(lua.get_string(1)),slot(lua.get_string(1));
        require(slot.size()==1 && slot[0]>='1' && slot[0]<='9',"invalid hotbar slot");
        lua.set_string(put_campaign_checkpoint(path,sha,id,checkpoint,started,mode,slot[0]-'0'));lua.set_nil();
    } catch(const std::exception& error) {
        lua.set_nil();lua.set_string(std::string("PBZMCJsonBridge: ")+(started?"hotbar-write-uncertain: ":"hotbar-not-written: ")+error.what());
    }
    return 2;
}

int lua_configure_preview_capture(const Lua& lua) {
    try {
        require(lua.get_stack_size() == 1 && lua.is_string(1), "usage: PBZMC_ConfigurePreviewCapture(component_object_path)");
        const std::string input(lua.get_string(1));
        configure_preview_capture(input);
        lua.set_bool(true);
        lua.set_nil();
    } catch (const std::exception& error) {
        lua.set_nil();
        lua.set_string(std::string("PBZMCJsonBridge: ") + error.what());
    }
    return 2; // true,nil means complete import + setter returned, not visual verification.
}

int lua_read_pointer_state(const Lua& lua) {
    try {
        require(lua.get_stack_size() == 0, "usage: PBZMC_ReadPointerState()");
        const auto output = read_pointer_state();
        lua.set_string(output);
        lua.set_nil();
    } catch (const std::exception& error) {
        lua.set_nil();
        lua.set_string(std::string("PBZMCJsonBridge: ") + error.what());
    }
    return 2;
}

struct HostBuild {
    std::string_view sha256;
    std::uint32_t steam_build, cl, take_damage, apply_health, modify_attribute, activate_state, retry_a, retry_b;
};
constexpr HostBuild host_builds[] = {
#include "host_builds.inc"
};
struct HostCheck {std::optional<HostBuild> layout;std::string message;};
const HostCheck& host_check() {
    static const HostCheck found=[] {
        std::string identity="PBZ.exe";
        try {
        std::array<wchar_t,32768> path{};
        const auto count=GetModuleFileNameW(nullptr,path.data(),static_cast<DWORD>(path.size()));
        require(count && count<path.size(),"cannot locate executable");
        PBZMC::Locator::FileMap file(path.data());
        const auto data=file.bytes();
        const auto digest=sha256_text({reinterpret_cast<const char*>(data.data()),data.size()});
        const auto cl=PBZMC::HostVersion::changelist(path.data());
        identity="CL-"+std::to_string(cl)+" SHA-256 "+digest;
        const HostBuild* known=nullptr;std::uint32_t latest{};
        for (const auto& build:host_builds) {
            latest=std::max(latest,build.cl);
            if(build.sha256==digest) known=&build;
        }
        require(known || cl>latest,"unrecognized PBZ build or engine family");
        const auto a=PBZMC::Locator::locate(data,GetModuleHandleW(nullptr),sha256_text);
        if(known) {
            const PBZMC::Locator::Addresses pinned{known->take_damage,known->apply_health,known->modify_attribute,
                known->activate_state,known->retry_a,known->retry_b};
            require(a==pinned,"native locations differ from verified build");
        }
        HostBuild layout{{},known?known->steam_build:0,cl,a[0],a[1],a[2],a[3],a[4],a[5]};
        return HostCheck{layout,"PBZMC-HOST: "+identity+"; 6 native locations verified"+(known?" (tested build)":" (newer build, auto-detected)")};
        } catch(const std::exception& e) {
            return HostCheck{std::nullopt,"PBZMC-HOST: "+identity+"; "+e.what()};
        }
    }();
    return found;
}
const HostBuild& verified_host_build() {
    const auto& check=host_check();
    if(!check.layout) throw std::runtime_error(check.message);
    return *check.layout;
}

#include "block_audio.hpp"
#include "health_gate.hpp"
#include "shield_gate.hpp"
#include "death_gate.hpp"
#include "minecraft_hit.hpp"

// Hex is an exact binary boundary for LuaMadeSimple's NUL-terminated getter.
// BCrypt avoids hundreds of milliseconds of Lua hashing on building commits.
int lua_hash_hex(const Lua& lua) {
    try {
        require(lua.get_stack_size()==1 && lua.is_string(1),"SHA256 hex string required");
        const auto hex=std::string(lua.get_string(1));
        require(hex.size()<=32*1024*1024 && hex.size()%2==0,"SHA256 input limit");
        std::string bytes(hex.size()/2,'\0');
        const auto digit=[](char c)->unsigned char {
            if(c>='0'&&c<='9') return static_cast<unsigned char>(c-'0');
            if(c>='a'&&c<='f') return static_cast<unsigned char>(c-'a'+10);
            throw std::runtime_error("SHA256 invalid hex");
        };
        for(std::size_t i=0;i<bytes.size();++i) bytes[i]=static_cast<char>((digit(hex[i*2])<<4)|digit(hex[i*2+1]));
        lua.set_string(sha256_text(bytes));lua.set_nil();
    } catch(const std::exception& error) { lua.set_nil();lua.set_string(error.what()); }
    return 2;
}

int lua_host_compatible(const Lua& lua) {
    const auto& check=host_check();
    if(!check.layout) {
        static std::once_flag shown;
        std::call_once(shown,[&] {
            auto message=L"PBZMC 无法匹配当前游戏版本，模组已停止加载。\n请将以下信息和 UE4SS.log 附到 GitHub Issues：\n\n"+
                from_utf8(check.message)+L"\n\nhttps://github.com/fjdsjd/pbz-mc/issues";
            MessageBoxW(nullptr,message.c_str(),L"PBZMC 兼容性错误",MB_OK|MB_ICONERROR|MB_SETFOREGROUND);
        });
    }
    lua.set_bool(check.layout.has_value());lua.set_string(check.message);return 2;
}

class JsonBridge final : public RC::CppUserModBase {
public:
    ~JsonBridge() override { HealthGate::clear();BlockAudio::clear();ShieldGate::clear();PBZMC::ItemInput::Capture::instance().stop_noexcept(); pointer_capture.stop(); }
    JsonBridge() {
        ModName = L"PBZMCJsonBridge";
        ModVersion = L"0.1.0-alpha.5";
        ModDescription = L"Fixed JSON and create-only campaign identity bridge, preview and item input";
        ModAuthors = L"PBZMC";
        ModIntendedSDKVersion = L"3.0.1-1183-gcdbc0b66";
        register_on_unreal_init([](RC::CppUserModBase*) { unreal_ready.store(true); });
        register_on_lua_start([](RC::CppUserModBase*, RC::CStringView name, Lua&, Lua& main_lua, Lua&, Lua*) {
            if (std::wstring_view(name.data, name.size) == target_mod) {
                main_lua.register_function("PBZMC_HostCompatible", &lua_host_compatible);
                // Threads belonging to this Lua mod share globals. No functions
                // are registered in any other mod's Lua state.
                main_lua.register_function(std::string(entry_name), &lua_round_trip);
                main_lua.execute_string(lua_preflight);
                main_lua.register_function(std::string(read_entry_name), &lua_read_advanced_json);
                main_lua.execute_string(advanced_lua_preflight);
                main_lua.register_function("PBZMC_ReadOrdinaryJson", &lua_read_ordinary_json);
                main_lua.register_function("PBZMC_ReadCampaignState", &lua_read_campaign_state);
                main_lua.register_function("PBZMC_ReadCampaignLoadState", &lua_read_campaign_load_state);
                main_lua.register_function("PBZMC_NewCampaignId", &lua_new_campaign_id);
                main_lua.register_function("PBZMC_CreateCampaignIdentity", &lua_create_campaign_identity);
                main_lua.register_function("PBZMC_PutCampaignCheckpoint", &lua_put_campaign_checkpoint);
                main_lua.register_function("PBZMC_SetHotbarSelection", &lua_set_hotbar_selection);
                main_lua.execute_string(campaign_lua_preflight);
                main_lua.register_function(std::string(preview_entry_name), &lua_configure_preview_capture);
                main_lua.execute_string(preview_lua_preflight);
                main_lua.register_function(std::string(pointer_entry_name), &lua_read_pointer_state);
                main_lua.execute_string(pointer_lua_preflight);
                main_lua.register_function("PBZMC_BeginPointerCapture", &lua_begin_pointer_capture);
                main_lua.register_function("PBZMC_ReadPointerEvents", &lua_read_pointer_events);
                main_lua.register_function("PBZMC_EndPointerCapture", &lua_end_pointer_capture);
                main_lua.execute_string(pointer_events_lua_preflight);
                main_lua.register_function("PBZMC_BeginItemInput", &lua_begin_item_input);
                main_lua.register_function("PBZMC_SetItemInputContext", &lua_set_item_input_context);
                main_lua.register_function("PBZMC_ReadItemInputEvents", &lua_read_item_input_events);
                main_lua.register_function("PBZMC_EndItemInput", &lua_end_item_input);
                main_lua.register_function("PBZMC_ShieldState", &ShieldGate::lua_set);
#ifndef PBZMC_RELEASE
                main_lua.register_function("PBZMC_DevShieldHit", &ShieldGate::lua_dev_hit);
#endif
                main_lua.register_function("PBZMC_NativeHit", &MinecraftHit::lua_hit);
                HealthGate::start(main_lua);
                main_lua.register_function("PBZMC_BindHealth", &HealthGate::lua_bind);
                main_lua.register_function("PBZMC_PollHealth", &HealthGate::lua_poll);
                main_lua.register_function("PBZMC_EntityHealthLease", &HealthGate::lua_entity);
                main_lua.register_function("PBZMC_BindDeath", &DeathGate::lua_bind);
                main_lua.register_function("PBZMC_BlockSound", &BlockAudio::lua_play);
                main_lua.register_function("PBZMC_HashHex", &lua_hash_hex);
                main_lua.register_function("PBZMC_RefreshPixelTexture", &PixelTexture::refresh);
                main_lua.execute_string(R"lua(
                  do local native=PBZMC_HashHex
                    PBZMC_HashHex=function(hex)
                      assert(type(hex)=='string' and #hex<=33554432 and #hex%2==0 and not hex:find('[^0-9a-f]'), 'invalid SHA256 hex')
                      return native(hex)
                    end
                  end
                )lua");
                main_lua.execute_string(item_input_lua_preflight);
            }
        });
        register_on_lua_stop([](RC::CppUserModBase*, RC::CStringView name, Lua&, Lua& main_lua, Lua&, Lua*) {
            if (std::wstring_view(name.data, name.size) == target_mod) {
                PBZMC::ItemInput::Capture::instance().stop_noexcept();
                HealthGate::stop();
                ShieldGate::clear();
                BlockAudio::clear();
                main_lua.execute_string(std::string_view("PBZMC_BlockSound = nil; PBZMC_HashHex = nil"));
                pointer_capture.stop();
                main_lua.execute_string(std::string_view("PBZMC_JsonRoundTrip = nil; PBZMC_ReadAdvancedJson = nil; PBZMC_ConfigurePreviewCapture = nil; PBZMC_ReadPointerState = nil"));
                main_lua.execute_string(std::string_view("PBZMC_ReadOrdinaryJson = nil; PBZMC_ReadCampaignState = nil; PBZMC_ReadCampaignLoadState = nil; PBZMC_NewCampaignId = nil; PBZMC_CreateCampaignIdentity = nil; PBZMC_PutCampaignCheckpoint = nil; PBZMC_SetHotbarSelection = nil"));
                main_lua.execute_string(std::string_view("PBZMC_BeginPointerCapture = nil; PBZMC_ReadPointerEvents = nil; PBZMC_EndPointerCapture = nil"));
                main_lua.execute_string(std::string_view("PBZMC_BeginItemInput = nil; PBZMC_SetItemInputContext = nil; PBZMC_ReadItemInputEvents = nil; PBZMC_EndItemInput = nil"));
            }
        });
    }
};
} // namespace

extern "C" __declspec(dllexport) RC::CppUserModBase* start_mod() { return new JsonBridge; }
extern "C" __declspec(dllexport) void uninstall_mod(RC::CppUserModBase* mod) { delete mod; }
