#pragma once
#include "checkpoint_json.hpp"

namespace PBZMC::Hotbar {
using Campaign::Value;
using Campaign::require;
inline constexpr std::string_view section="PBZMC_HotbarSelection";
inline constexpr wchar_t section_wide[]=L"PBZMC_HotbarSelection";
struct Selection {std::string mode;int selected{};};
inline std::string marker(std::string_view id,std::string_view checkpoint,std::string_view mode,int selected) {
    Campaign::validate_uuid(id);Campaign::validate_sha(checkpoint);
    require(mode=="free" || mode=="adventure","invalid hotbar profile mode");
    require(selected>=1 && selected<=9,"invalid hotbar selected slot");
    return "{\"owner\":\"pbzmc\",\"schema\":\"hotbar-selection-v1\",\"campaign_id\":\""+std::string(id)+
        "\",\"checkpoint\":\""+std::string(checkpoint)+"\",\"mode\":\""+std::string(mode)+"\",\"selected\":\""+std::to_string(selected)+"\"}";
}
inline std::optional<Selection> read(const Value& root,std::string_view id,std::string_view checkpoint) {
    const auto actual=Checkpoint::key(root,section);if(!actual) return std::nullopt;
    const auto& value=root.object.at(*actual);
    require(value.kind==Value::Kind::object,"unrecognized hotbar selection");
    const auto mode=value.object.find("mode"),digest=value.object.find("checkpoint"),slot=value.object.find("selected");
    require(mode!=value.object.end() && mode->second.kind==Value::Kind::string &&
        digest!=value.object.end() && digest->second.kind==Value::Kind::string &&
        slot!=value.object.end() && slot->second.kind==Value::Kind::string,"invalid hotbar selection fields");
    int selected{};
    for(int i=1;i<=9;++i) if(slot->second.atom==std::to_string(i)) selected=i;
    require(value==Campaign::parse(marker(id,digest->second.atom,mode->second.atom,selected)),"unrecognized hotbar owner/schema/campaign");
    // A full inventory/building commit includes its current selection. The
    // older small override is inert after the checkpoint changes.
    if(digest->second.atom!=checkpoint) return std::nullopt;
    return Selection{mode->second.atom,selected};
}
template<class Read,class Prepare,class Write,class Digest>
Checkpoint::Proof put(std::string_view id,std::string_view checkpoint,std::string_view mode,int selected,
    std::string_view expected_sha,Read read_root,Prepare prepare,Write write,Digest digest,bool& started) {
    require(!started,"hotbar write already started");Campaign::validate_sha(expected_sha);
    const auto text=marker(id,checkpoint,mode,selected);const auto expected=Campaign::parse(text);
    const auto before_text=read_root();Campaign::check_write_size(before_text.size());
    std::size_t nodes{};auto before=Campaign::parse(before_text,&nodes);
    Campaign::check_limit(nodes,Campaign::node_limit-24,"expanded save JSON values before hotbar write");
    const auto scope=Checkpoint::current(before);
    require(scope.campaign_id==id && scope.checkpoint==checkpoint,"hotbar checkpoint changed");
    read(before,id,checkpoint);const auto prior=Checkpoint::key(before,section);
    const auto hash=digest(before_text);require(hash==expected_sha,"hotbar root precondition changed");
    if(prior && before.object.at(*prior)==expected) return {*prior,hash,hash,false};
    prepare(text);require(read_root()==before_text,"hotbar root changed during preparation");
    started=true;write();const auto after_text=read_root();auto after=Campaign::parse(after_text);
    const auto result=read(after,id,checkpoint);const auto actual=Checkpoint::key(after,section);
    require(result && result->mode==mode && result->selected==selected && actual,"hotbar readback mismatch");
    if(prior) before.object.erase(*prior);after.object.erase(*actual);
    require(before==after,"unrelated ordinary root changed during hotbar write");
    return {*actual,hash,digest(after_text),true};
}
} // namespace PBZMC::Hotbar
