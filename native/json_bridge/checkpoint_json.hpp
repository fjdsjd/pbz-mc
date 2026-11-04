#pragma once
#include "campaign_json.hpp"

namespace PBZMC::Checkpoint {
using Campaign::Value;
using Campaign::require;
inline constexpr std::string_view section = "PBZMC_Checkpoint";
inline constexpr wchar_t section_wide[] = L"PBZMC_Checkpoint";

// The anchor names an immutable campaign manifest; the Lua storage adapter owns
// verification of every profile/blob in that manifest before publishing it.
inline std::string anchor(std::string_view campaign_id,std::string_view digest) {
    Campaign::validate_uuid(campaign_id);Campaign::validate_sha(digest);
    return "{\"owner\":\"pbzmc\",\"schema\":\"campaign-checkpoint-v1\",\"campaign_id\":\""+
        std::string(campaign_id)+"\",\"checkpoint\":\""+std::string(digest)+"\"}";
}
inline std::optional<std::string> key(const Value& root,std::string_view reserved) {
    require(root.kind==Value::Kind::object,"checkpoint root must be an object");
    std::optional<std::string> found;
    for (const auto& [name,value]:root.object) {
        (void)value;
        if (Campaign::ascii_lower(name)==Campaign::ascii_lower(reserved)) {
            require(!found,"multiple equivalent checkpoint or identity namespaces");found=name;
        }
    }
    return found;
}
inline void identity(const Value& root,std::string_view campaign_id) {
    const auto actual=key(root,Campaign::section);
    require(actual && root.object.at(*actual)==Campaign::parse(Campaign::marker(campaign_id)),
        "checkpoint requires the exact current campaign identity");
}
inline std::optional<std::string> known_anchor(const Value& root,std::string_view campaign_id) {
    const auto actual=key(root,section);
    if (!actual) return std::nullopt;
    const auto& value=root.object.at(*actual);
    require(value.kind==Value::Kind::object,"unrecognized existing checkpoint anchor");
    const auto digest=value.object.find("checkpoint");
    require(digest!=value.object.end() && digest->second.kind==Value::Kind::string,"checkpoint digest missing");
    require(value==Campaign::parse(anchor(campaign_id,digest->second.atom)),"unrecognized existing checkpoint owner/schema/campaign");
    return actual;
}
struct Current {std::string campaign_id,checkpoint;};
inline std::optional<Current> inspect(const Value& root,bool allow_registration) {
    const auto gameplay=key(root,"PBZGameSystem");
    require(gameplay && *gameplay=="PBZGameSystem" && root.object.at(*gameplay).kind==Value::Kind::object,
        "campaign gameplay root required");
    const auto marker=key(root,Campaign::section);
    if (!marker && allow_registration) {
        require(!key(root,section),"campaign checkpoint without identity; registration refused");
        return std::nullopt;
    }
    require(marker && root.object.at(*marker).kind==Value::Kind::object,"campaign identity required");
    const auto& fields=root.object.at(*marker).object;
    const auto id=fields.find("campaign_id");
    require(id!=fields.end() && id->second.kind==Value::Kind::string,"campaign identity id missing");
    identity(root,id->second.atom);
    const auto anchor_key=known_anchor(root,id->second.atom);
    if (!anchor_key && allow_registration) return std::nullopt;
    require(anchor_key.has_value(),"campaign checkpoint required");
    return Current{id->second.atom,root.object.at(*anchor_key).object.at("checkpoint").atom};
}
inline Current current(const Value& root) {
    return inspect(root,false).value();
}
inline std::string verify(Value before,Value after,std::string_view campaign_id,const Value& expected) {
    identity(before,campaign_id);identity(after,campaign_id);
    const auto previous=known_anchor(before,campaign_id);
    const auto actual=known_anchor(after,campaign_id);
    require(actual && after.object.at(*actual)==expected,"checkpoint anchor differs after native write");
    if (previous) before.object.erase(*previous);
    after.object.erase(*actual);
    require(before==after,"unrelated ordinary root changed during checkpoint write");
    return *actual;
}
struct Proof { std::string actual_key,before_sha256,after_sha256;bool changed; };
template<class Read,class Prepare,class Write,class Digest>
Proof put(std::string_view campaign_id,std::string_view checkpoint,std::string_view expected_sha,
    Read read,Prepare prepare,Write write,Digest digest,bool& write_started) {
    require(!write_started,"checkpoint write already started");
    Campaign::validate_uuid(campaign_id);Campaign::validate_sha(checkpoint);Campaign::validate_sha(expected_sha);
    const auto before_text=read();
    Campaign::check_write_size(before_text.size());
    std::size_t nodes{};auto before=Campaign::parse(before_text,&nodes);
    Campaign::check_limit(nodes,Campaign::node_limit-16,"expanded save JSON values before checkpoint write");
    identity(before,campaign_id);const auto previous=known_anchor(before,campaign_id);
    const auto before_sha=digest(before_text);
    require(before_sha==expected_sha,"checkpoint root precondition changed");
    const auto text=anchor(campaign_id,checkpoint);const auto expected=Campaign::parse(text);
    if (previous && before.object.at(*previous)==expected)
        return {*previous,before_sha,before_sha,false}; // Already published; no native dirty write.
    prepare(text);
    require(read()==before_text,"ordinary root changed during checkpoint preparation");
    write_started=true; // A void native write and all subsequent failures are indeterminate.
    write();
    const auto after_text=read();
    return {verify(std::move(before),Campaign::parse(after_text),campaign_id,expected),before_sha,digest(after_text),true};
}
} // namespace PBZMC::Checkpoint
