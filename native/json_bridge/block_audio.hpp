// Process-owned XAudio2 PCM voices; retained samples outlive every queued voice.
// Only hash-pinned original MC clips in the fixed mod directory can load.
namespace BlockAudio {
struct ClipSpec { const char* name;const char* hash;std::size_t bytes; };
#include "block_audio_catalogue.hpp"
inline IXAudio2* engine{};
inline IXAudio2MasteringVoice* master{};
inline std::vector<IXAudio2SourceVoice*> voices;
inline IXAudio2SourceVoice* elytra_voice{};
inline std::array<std::string,std::size(clips)> samples;
inline std::mutex mutex;
void retire() {
    for(auto it=voices.begin();it!=voices.end();) {
        XAUDIO2_VOICE_STATE state{};(*it)->GetState(&state,XAUDIO2_VOICE_NOSAMPLESPLAYED);
        if(!state.BuffersQueued) { (*it)->DestroyVoice();it=voices.erase(it); } else ++it;
    }
}
void clear() {
    std::lock_guard lock(mutex);
    for(auto* voice:voices) voice->DestroyVoice();voices.clear();
    if(elytra_voice){elytra_voice->DestroyVoice();elytra_voice=nullptr;}
    if(master) { master->DestroyVoice();master=nullptr; }
    if(engine) { engine->Release();engine=nullptr; }
    for(auto& clip:samples) clip.clear();
}
void prepare() {
    if(engine) return;
    std::array<wchar_t,32768> path{};
    const auto size=GetModuleFileNameW(nullptr,path.data(),static_cast<DWORD>(path.size()));
    require(size>0 && size<path.size(),"block sound executable path unavailable");
    const auto root=std::filesystem::path(path.data()).parent_path()/L"ue4ss/Mods/PBZMCProbe/Scripts/pbzmc-assets/sounds";
    for(std::size_t i=0;i<std::size(clips);++i) {
        std::ifstream file(root/(std::string(clips[i].name)+".pcm"),std::ios::binary|std::ios::ate);
        require(file.good() && file.tellg()==static_cast<std::streamoff>(clips[i].bytes),"block sound size mismatch");
        samples[i].resize(clips[i].bytes);file.seekg(0);file.read(samples[i].data(),static_cast<std::streamsize>(samples[i].size()));
        require(file.good() && sha256_text(samples[i])==clips[i].hash,"block sound digest mismatch");
    }
    IXAudio2* created{};
    require(SUCCEEDED(XAudio2Create(&created,0,XAUDIO2_DEFAULT_PROCESSOR)),"block sound output unavailable");
    if(FAILED(created->CreateMasteringVoice(&master,2,44100,0,nullptr,nullptr,AudioCategory_GameEffects))) {
        created->Release();throw std::runtime_error("block sound mastering voice unavailable");
    }
    engine=created;
}
// Caller holds mutex. All PCM is preloaded; impact-time playback does no IO.
void play_locked(std::string_view name,float gain,float pitch,float pan) {
    require(engine!=nullptr,"MC sound not prepared");
    auto found=std::find_if(std::begin(clips),std::end(clips),[&](const auto& c){return name==c.name;});
    require(found!=std::end(clips),"unknown original block sound");
    require(std::isfinite(gain)&&gain>=0&&gain<=1&&std::isfinite(pitch)&&pitch>=.25f&&pitch<=2&&std::isfinite(pan)&&std::abs(pan)<=1,"block sound parameters");
    require(voices.size()<16,"block sound voice budget");
    WAVEFORMATEX format{WAVE_FORMAT_PCM,2,44100,44100*4,4,16,0};IXAudio2SourceVoice* voice{};
    require(SUCCEEDED(engine->CreateSourceVoice(&voice,&format,0,2)),"block sound source unavailable");
    const float channels[]={gain*std::min(1.f,1.f-pan),gain*std::min(1.f,1.f+pan)};
    const auto index=static_cast<std::size_t>(found-std::begin(clips));
    XAUDIO2_BUFFER buffer{};buffer.AudioBytes=static_cast<UINT32>(samples[index].size());
    buffer.pAudioData=reinterpret_cast<const BYTE*>(samples[index].data());buffer.Flags=XAUDIO2_END_OF_STREAM;
    if(FAILED(voice->SetChannelVolumes(2,channels))||FAILED(voice->SetFrequencyRatio(pitch))||FAILED(voice->SubmitSourceBuffer(&buffer))||FAILED(voice->Start())) {
        voice->DestroyVoice();throw std::runtime_error("block sound submit failed");
    }
    voices.push_back(voice);
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
        play_locked(names[random%names.size()],1.f,pitch,0.f);
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
int lua_play(const Lua& lua) {
    try {
        require(IsInGameThread() && lua.get_stack_size()==1 && lua.is_string(1),"block sound game-thread JSON required");
        const auto input=std::string(lua.get_string(1));require(input.size()<512,"block sound request limit");
        const auto request=nlohmann::json::parse(input);
        const auto name=request.at("clip").get<std::string>();
        std::lock_guard lock(mutex);prepare();retire();
        if(name=="elytra-stop")flight_locked(0,1,true);
        else if(name=="item_elytra_elytra_loop"&&request.value("sustain",false))flight_locked(request.at("gain").get<float>(),request.at("pitch").get<float>(),false);
        else if(name!="warmup") {
            const auto gain=request.at("gain").get<float>(),pitch=request.at("pitch").get<float>(),pan=request.at("pan").get<float>();
            play_locked(name,gain,pitch,pan);
        }
        lua.set_string(nlohmann::json{{"ready",true},{"voices",voices.size()},{"elytra_voice",elytra_voice!=nullptr}}.dump());lua.set_nil();
    } catch(const std::exception& error) { lua.set_nil();lua.set_string(std::string("PBZMC block sound: ")+error.what()); }
    return 2;
}
} // namespace BlockAudio
