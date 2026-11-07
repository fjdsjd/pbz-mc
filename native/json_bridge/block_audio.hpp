// Process-owned XAudio2 PCM voices; retained samples outlive every queued voice.
// Only hash-pinned original MC clips in the fixed mod directory can load.
namespace BlockAudio {
struct ClipSpec { const char* name;const char* hash;std::size_t bytes; };
#include "block_audio_catalogue.hpp"
inline IXAudio2* engine{};
inline IXAudio2MasteringVoice* master{};
struct Voice { IXAudio2SourceVoice* voice;std::uint64_t id;std::string event,source,owner;std::size_t clip; };
inline std::vector<Voice> voices;
inline std::uint64_t next_voice{};
inline IXAudio2SourceVoice* elytra_voice{};
inline std::array<std::string,std::size(clips)> samples;
inline std::array<std::uint64_t,std::size(clips)> sample_use{};
inline std::uint64_t sample_clock{};
inline std::size_t creature_bytes{};
constexpr std::size_t creature_budget=32*1024*1024;
bool creature_clip(std::size_t i) { return std::string_view(clips[i].name).starts_with("mob_"); }
const auto& clip_lookup() {
    static const auto lookup=[] { std::unordered_map<std::string_view,std::size_t> result;
        for(std::size_t i=0;i<std::size(clips);++i)require(result.emplace(clips[i].name,i).second,"duplicate sound identifier");
        return result; }();
    return lookup;
}
inline std::filesystem::path sound_root;
inline std::mutex mutex;
void retire() {
    for(auto it=voices.begin();it!=voices.end();) {
        XAUDIO2_VOICE_STATE state{};it->voice->GetState(&state,XAUDIO2_VOICE_NOSAMPLESPLAYED);
        if(!state.BuffersQueued) { it->voice->DestroyVoice();it=voices.erase(it); } else ++it;
    }
}
void clear() {
    std::lock_guard lock(mutex);
    for(auto& voice:voices) voice.voice->DestroyVoice();voices.clear();
    if(elytra_voice){elytra_voice->DestroyVoice();elytra_voice=nullptr;}
    if(master) { master->DestroyVoice();master=nullptr; }
    if(engine) { engine->Release();engine=nullptr; }
    for(auto& clip:samples) clip.clear();
    creature_bytes=0;sample_use.fill(0);sample_clock=0;
}
void load_sample(std::size_t i) {
    sample_use[i]=++sample_clock;
    if(!samples[i].empty()) return;
    if(creature_clip(i)) {
        while(creature_bytes+clips[i].bytes>creature_budget) {
            std::size_t victim=std::size(clips);
            for(std::size_t j=0;j<std::size(clips);++j) {
                if(!creature_clip(j)||samples[j].empty()||std::any_of(voices.begin(),voices.end(),[&](const auto& v){return v.clip==j;}))continue;
                if(victim==std::size(clips)||sample_use[j]<sample_use[victim])victim=j;
            }
            require(victim<std::size(clips),"creature sound cache busy");
            creature_bytes-=samples[victim].size();std::string{}.swap(samples[victim]);
        }
    }
    std::ifstream file(sound_root/(std::string(clips[i].name)+".pcm"),std::ios::binary|std::ios::ate);
    require(file.good() && file.tellg()==static_cast<std::streamoff>(clips[i].bytes),"block sound size mismatch");
    std::string data(clips[i].bytes,'\0');file.seekg(0);file.read(data.data(),static_cast<std::streamsize>(data.size()));
    require(file.good() && sha256_text(data)==clips[i].hash,"block sound digest mismatch");
    samples[i]=std::move(data);
    if(creature_clip(i))creature_bytes+=samples[i].size();
}
void prepare() {
    if(engine) return;
    std::array<wchar_t,32768> path{};
    const auto size=GetModuleFileNameW(nullptr,path.data(),static_cast<DWORD>(path.size()));
    require(size>0 && size<path.size(),"block sound executable path unavailable");
    sound_root=std::filesystem::path(path.data()).parent_path()/L"ue4ss/Mods/PBZMCProbe/Scripts/pbzmc-assets/sounds";
    for(std::size_t i=0;i<std::size(clips);++i) {
        if(!std::string_view(clips[i].name).starts_with("build_")&&!creature_clip(i)) load_sample(i);
    }
    IXAudio2* created{};
    require(SUCCEEDED(XAudio2Create(&created,0,XAUDIO2_DEFAULT_PROCESSOR)),"block sound output unavailable");
    if(FAILED(created->CreateMasteringVoice(&master,2,44100,0,nullptr,nullptr,AudioCategory_GameEffects))) {
        created->Release();throw std::runtime_error("block sound mastering voice unavailable");
    }
    engine=created;
}
// Existing combat sounds are warm. Construction variants are read once on first use.
void parameters(IXAudio2SourceVoice* voice,float gain,float pitch,float pan) {
    require(std::isfinite(gain)&&gain>=0&&gain<=1&&std::isfinite(pitch)&&pitch>=.25f&&pitch<=2&&std::isfinite(pan)&&std::abs(pan)<=1,"block sound parameters");
    const float channels[]={gain*std::min(1.f,1.f-pan),gain*std::min(1.f,1.f+pan)};
    require(SUCCEEDED(voice->SetChannelVolumes(2,channels))&&SUCCEEDED(voice->SetFrequencyRatio(pitch)),"block sound parameters rejected");
}
std::uint64_t play_locked(std::string_view name,float gain,float pitch,float pan,
    std::string event={},std::string source={},std::string owner={}) {
    require(engine!=nullptr,"MC sound not prepared");
    auto found=clip_lookup().find(name);
    require(found!=clip_lookup().end(),"unknown original block sound");
    require(std::isfinite(gain)&&gain>=0&&gain<=1&&std::isfinite(pitch)&&pitch>=.25f&&pitch<=2&&std::isfinite(pan)&&std::abs(pan)<=1,"block sound parameters");
    require(voices.size()<16,"block sound voice budget");
    const auto index=found->second;
    load_sample(index);
    WAVEFORMATEX format{WAVE_FORMAT_PCM,2,44100,44100*4,4,16,0};IXAudio2SourceVoice* voice{};
    require(SUCCEEDED(engine->CreateSourceVoice(&voice,&format,0,2)),"block sound source unavailable");
    XAUDIO2_BUFFER buffer{};buffer.AudioBytes=static_cast<UINT32>(samples[index].size());
    buffer.pAudioData=reinterpret_cast<const BYTE*>(samples[index].data());buffer.Flags=XAUDIO2_END_OF_STREAM;
    try {
        parameters(voice,gain,pitch,pan);
        require(SUCCEEDED(voice->SubmitSourceBuffer(&buffer))&&SUCCEEDED(voice->Start()),"block sound submit failed");
        require(next_voice<9007199254740991ull,"block sound voice identifiers exhausted");
        const auto id=++next_voice;
        voices.push_back({voice,id,std::move(event),std::move(source),std::move(owner),index});
        return id;
    } catch(...) { voice->DestroyVoice();throw; }
}
bool shield_hit() noexcept {
    try {
        std::lock_guard lock(mutex);
        if(!engine) return false;
        retire();
        static std::uint32_t random=0x9e3779b9u;
        random^=random<<13;random^=random>>17;random^=random<<5;
        constexpr std::array names{"item_shield_block1","item_shield_block2","item_shield_block3","item_shield_block4","item_shield_block5"};
        const float pitch=.8f+static_cast<float>((random>>8)&0xffffu)/65535.f*.4f;
        play_locked(names[random%names.size()],1.f,pitch,0.f,"minecraft:item.shield.block","player");
        return true;
    } catch(...) { return false; } // Audio must never cancel a successful block.
}
// One flight owner, independent of the bounded one-shot pool. Buffers are
// finite even if Lua stops heartbeating; stop/land destroys this voice at once.
void flight_locked(float gain,float pitch,bool stop) {
    require(std::isfinite(gain)&&gain>=0&&gain<=1&&std::isfinite(pitch)&&pitch>=.25f&&pitch<=2,"elytra sound parameters");
    if(stop){if(elytra_voice){elytra_voice->DestroyVoice();elytra_voice=nullptr;}return;}
    if(!elytra_voice){
        WAVEFORMATEX format{WAVE_FORMAT_PCM,2,44100,44100*4,4,16,0};
        require(SUCCEEDED(engine->CreateSourceVoice(&elytra_voice,&format,0,2)),"elytra sound voice unavailable");
    }
    const float channels[]={gain,gain};
    require(SUCCEEDED(elytra_voice->SetChannelVolumes(2,channels))&&SUCCEEDED(elytra_voice->SetFrequencyRatio(pitch)),"elytra sound parameters rejected");
    XAUDIO2_VOICE_STATE state{};elytra_voice->GetState(&state,XAUDIO2_VOICE_NOSAMPLESPLAYED);
    if(!state.BuffersQueued){
        const auto found=std::find_if(std::begin(clips),std::end(clips),[](const auto& c){return std::string_view(c.name)=="item_elytra_elytra_loop";});
        require(found!=std::end(clips),"original elytra sound missing");
        const auto& pcm=samples[static_cast<std::size_t>(found-std::begin(clips))];
        XAUDIO2_BUFFER buffer{};buffer.AudioBytes=static_cast<UINT32>(pcm.size());buffer.pAudioData=reinterpret_cast<const BYTE*>(pcm.data());buffer.Flags=XAUDIO2_END_OF_STREAM;
        require(SUCCEEDED(elytra_voice->SubmitSourceBuffer(&buffer))&&SUCCEEDED(elytra_voice->Start()),"elytra sound submit failed");
    }
}
// Filters operate on actual XAudio2 voices, including ordinary MC gameplay
// sounds. A command owner's lifecycle cleanup cannot stop another owner's clip.
std::size_t stop_locked(std::string_view event,std::string_view source,std::string_view owner) {
    const auto matches=[&](const auto& v){return (event.empty()||v.event==event)
        &&(source.empty()||v.source==source)&&(owner.empty()||v.owner==owner);};
    std::size_t count{};
    for(auto it=voices.begin();it!=voices.end();) {
        if(matches(*it)){it->voice->DestroyVoice();it=voices.erase(it);++count;}else ++it;
    }
    if(elytra_voice&&owner.empty()&&(event.empty()||event=="minecraft:item.elytra.flying")
        &&(source.empty()||source=="player")) { elytra_voice->DestroyVoice();elytra_voice=nullptr;++count; }
    return count;
}
std::string metadata(const nlohmann::json& request,const char* field,std::size_t limit) {
    auto value=request.value(field,std::string{});
    require(value.size()<=limit&&std::all_of(value.begin(),value.end(),[](unsigned char c){
        return (c>='a'&&c<='z')||(c>='0'&&c<='9')||c=='_'||c=='.'||c=='-'||c==':'||c=='/';
    }),"block sound metadata");
    return value;
}
int lua_play(const Lua& lua) {
    try {
        require(IsInGameThread() && lua.get_stack_size()==1 && lua.is_string(1),"block sound game-thread JSON required");
        const auto input=std::string(lua.get_string(1));require(input.size()<1024,"block sound request limit");
        const auto request=nlohmann::json::parse(input);
        std::lock_guard lock(mutex);prepare();retire();
        const auto operation=request.value("op",std::string{"play"});
        const auto event=metadata(request,"sound_event",256),source=metadata(request,"source",32),owner=metadata(request,"owner",80);
        nlohmann::json result{{"protocol",2},{"ready",true}};
        if(operation=="stop")result["stopped"]=stop_locked(event,source,owner);
        else if(operation=="update") {
            const auto id=request.at("id").get<std::uint64_t>();
            const auto it=std::find_if(voices.begin(),voices.end(),[&](const auto& v){return v.id==id&&v.owner==owner;});
            result["active"]=it!=voices.end();
            if(it!=voices.end())parameters(it->voice,request.at("gain").get<float>(),request.at("pitch").get<float>(),request.at("pan").get<float>());
        } else if(operation=="status") {
            result["active"]=nlohmann::json::array();
            for(const auto& v:voices)if(owner.empty()||owner==v.owner)result["active"].push_back(v.id);
        } else {
            require(operation=="play","unknown block sound operation");
            const auto name=request.at("clip").get<std::string>();
            if(name=="elytra-stop")flight_locked(0,1,true);
            else if(name=="item_elytra_elytra_loop"&&request.value("sustain",false))flight_locked(request.at("gain").get<float>(),request.at("pitch").get<float>(),false);
            else if(name!="warmup")result["id"]=play_locked(name,request.at("gain").get<float>(),request.at("pitch").get<float>(),request.at("pan").get<float>(),event,source,owner);
        }
        result["voices"]=voices.size();result["elytra_voice"]=elytra_voice!=nullptr;result["creature_cache_bytes"]=creature_bytes;
        lua.set_string(result.dump());lua.set_nil();
    } catch(const std::exception& error) { lua.set_nil();lua.set_string(std::string("PBZMC block sound: ")+error.what()); }
    return 2;
}
} // namespace BlockAudio
