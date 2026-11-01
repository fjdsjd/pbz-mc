#pragma once
#include <map>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>
#include "../../third_party/nlohmann-json-3.11.3/json.hpp"

namespace PBZMC::Campaign {
inline constexpr std::string_view section = "PBZMC_CampaignIdentity";
inline constexpr wchar_t section_wide[] = L"PBZMC_CampaignIdentity";
inline constexpr std::size_t root_limit = 1024 * 1024;
// Reserve >4 Ki native characters for the marker and serializer. The native
// getter has a 256 Ki UTF-16-unit bound, so this initial write conservatively
// limits the BEFORE root to 252 Ki UTF-8 bytes. Reads retain their larger bound.
inline constexpr std::size_t identity_before_limit = 252 * 1024;
inline constexpr std::size_t node_limit = 100000;
inline void require(bool ok, const char* error) { if (!ok) throw std::runtime_error(error); }

// Numeric atoms retain their source lexemes. Parsing to double and comparing
// DOM values could conceal a changed large integer in unrelated host state.
struct Value {
    enum class Kind { null, boolean, number, string, array, object } kind{Kind::null};
    std::string atom;
    std::vector<Value> array;
    std::map<std::string, Value, std::less<>> object;
    bool operator==(const Value&) const = default;
};
inline std::vector<std::string> numeric_tokens(std::string_view text) {
    std::vector<std::string> result;
    for (std::size_t i=0; i<text.size();) {
        if (text[i]=='"') {
            ++i;
            while (i<text.size() && text[i]!='"') {
                if (text[i]=='\\') ++i;
                if (i<text.size()) ++i;
            }
            if (i<text.size()) ++i;
        } else if (text[i]=='-' || (text[i]>='0' && text[i]<='9')) {
            const auto start=i++;
            while (i<text.size() && std::string_view("0123456789.eE+-").find(text[i])!=std::string_view::npos) ++i;
            result.emplace_back(text.substr(start,i-start));
        } else ++i;
    }
    return result; // Grammar/UTF-8/escapes are checked by the real parser below.
}

class Parser final : public nlohmann::json_sax<nlohmann::json> {
    struct Frame { Value value; std::optional<std::string> key; };
    std::vector<Frame> stack_;
    std::vector<std::string> numbers_;
    std::size_t number_index_{}, nodes_{};
    std::optional<Value> root_;
    bool add(Value value) {
        require(++nodes_<=node_limit,"ordinary root has too many JSON values");
        if (stack_.empty()) {
            require(!root_,"ordinary root contains multiple JSON values");
            root_=std::move(value);
        } else {
            auto& frame=stack_.back();
            if (frame.value.kind==Value::Kind::array) frame.value.array.push_back(std::move(value));
            else {
                require(frame.key.has_value(),"JSON object value is missing its key");
                require(frame.value.object.emplace(*frame.key,std::move(value)).second,"duplicate JSON object key");
                frame.key.reset();
            }
        }
        return true;
    }
    bool atom(Value::Kind kind, std::string text) {
        Value value; value.kind=kind; value.atom=std::move(text); return add(std::move(value));
    }
    bool number() {
        require(number_index_<numbers_.size(),"numeric token count mismatch");
        return atom(Value::Kind::number,numbers_[number_index_++]);
    }
    bool start(Value::Kind kind) {
        require(stack_.size()<128,"ordinary root exceeds JSON nesting limit");
        Frame frame; frame.value.kind=kind; stack_.push_back(std::move(frame)); return true;
    }
    bool finish(Value::Kind kind) {
        require(!stack_.empty() && stack_.back().value.kind==kind && !stack_.back().key,"invalid JSON container ending");
        auto value=std::move(stack_.back().value); stack_.pop_back(); return add(std::move(value));
    }
public:
    explicit Parser(std::string_view text):numbers_(numeric_tokens(text)) {}
    bool null() override { return atom(Value::Kind::null,""); }
    bool boolean(bool value) override { return atom(Value::Kind::boolean,value?"true":"false"); }
    bool number_integer(number_integer_t) override { return number(); }
    bool number_unsigned(number_unsigned_t) override { return number(); }
    bool number_float(number_float_t, const string_t&) override { return number(); }
    bool string(string_t& value) override { return atom(Value::Kind::string,value); }
    bool binary(binary_t&) override { throw std::runtime_error("binary JSON is not accepted"); }
    bool start_object(std::size_t) override { return start(Value::Kind::object); }
    bool end_object() override { return finish(Value::Kind::object); }
    bool start_array(std::size_t) override { return start(Value::Kind::array); }
    bool end_array() override { return finish(Value::Kind::array); }
    bool key(string_t& value) override {
        require(!stack_.empty() && stack_.back().value.kind==Value::Kind::object && !stack_.back().key,"invalid JSON key position");
        require(!stack_.back().value.object.contains(value),"duplicate decoded JSON object key");
        stack_.back().key=value; return true;
    }
    bool parse_error(std::size_t,const std::string&,const nlohmann::detail::exception&) override {
        throw std::runtime_error("ordinary root is not one valid complete JSON object");
    }
    Value take() {
        require(root_.has_value() && stack_.empty() && number_index_==numbers_.size(),"incomplete ordinary root parse");
        require(root_->kind==Value::Kind::object,"ordinary root must be a JSON object");
        return std::move(*root_);
    }
    std::size_t nodes() const { return nodes_; }
};

inline Value parse(std::string_view text,std::size_t* nodes=nullptr) {
    require(!text.empty() && text.size()<=root_limit && text.find('\0')==std::string_view::npos,"ordinary root byte bound/NUL violation");
    require(!text.starts_with("\xef\xbb\xbf"),"ordinary root must not contain a UTF-8 BOM");
    Parser parser(text);
    require(nlohmann::json::sax_parse(text.begin(),text.end(),&parser,nlohmann::json::input_format_t::json,true,false),"ordinary root parsing failed");
    if (nodes) *nodes=parser.nodes();
    return parser.take();
}
inline std::string ascii_lower(std::string_view value) {
    std::string result(value);
    for (auto& c:result) if (c>='A' && c<='Z') c=static_cast<char>(c-'A'+'a');
    return result;
}
inline void require_absent(const Value& root) {
    require(root.kind==Value::Kind::object,"namespace check requires an object root");
    const auto reserved=ascii_lower(section);
    for (const auto& [key,value]:root.object) {
        (void)value;
        require(ascii_lower(key)!=reserved,"campaign namespace already exists or conflicts; create-only write refused");
    }
}
inline void validate_uuid(std::string_view value) {
    require(value.size()==36,"campaign id must be a canonical UUID v4");
    for (std::size_t i=0;i<value.size();++i) {
        if (i==8 || i==13 || i==18 || i==23) require(value[i]=='-',"invalid UUID separator");
        else require((value[i]>='0' && value[i]<='9') || (value[i]>='a' && value[i]<='f'),"UUID must be lowercase hexadecimal");
    }
    require(value[14]=='4' && std::string_view("89ab").find(value[19])!=std::string_view::npos,"campaign id must be an RFC 4122 UUID v4");
}
inline void validate_sha(std::string_view value) {
    require(value.size()==64,"ordinary-root precondition must be SHA256");
    for (auto c:value) require((c>='0' && c<='9') || (c>='a' && c<='f'),"root SHA256 must be lowercase hexadecimal");
}
inline std::string marker(std::string_view id) {
    validate_uuid(id);
    return "{\"owner\":\"pbzmc\",\"schema\":\"campaign-identity-v1\",\"campaign_id\":\""+std::string(id)+"\"}";
}
inline std::string verify_inserted(const Value& before,Value after,const Value& expected_marker) {
    require(after.kind==Value::Kind::object && expected_marker.kind==Value::Kind::object,"identity verification requires object roots and marker");
    require_absent(before);
    const auto reserved=ascii_lower(section);
    std::optional<std::string> actual_key;
    for (const auto& [key,value]:after.object) {
        if (ascii_lower(key)==reserved) {
            require(!actual_key,"multiple equivalent campaign namespaces after write");
            require(value==expected_marker,"campaign marker differs after native write");
            actual_key=key;
        }
    }
    require(actual_key.has_value(),"campaign marker was not inserted");
    after.object.erase(*actual_key);
    require(before==after,"unrelated ordinary root fields changed during identity write");
    return *actual_key; // FName may reuse an existing case-insensitive display spelling.
}
struct CreationProof { std::string actual_key, before_sha256, after_sha256; };
template<class Read,class Prepare,class Write,class Digest>
CreationProof create_only(std::string_view id,std::string_view expected_sha,
    Read read,Prepare prepare,Write write,Digest digest,bool& write_started) {
    require(!write_started,"identity write already started");
    validate_uuid(id); validate_sha(expected_sha);
    const auto before_text=read();
    require(before_text.size()<=identity_before_limit,"ordinary root exceeds the identity write bound with required reserve");
    std::size_t before_nodes{};
    const auto before=parse(before_text,&before_nodes);
    require(before_nodes<=node_limit-16,"ordinary root lacks the identity write node reserve");
    require_absent(before);
    const auto before_hash=digest(before_text);
    require(before_hash==expected_sha,"ordinary root precondition changed");
    const auto marker_text=marker(id);
    const auto expected_marker=parse(marker_text);
    prepare(marker_text);
    // Do not use a cached root after FromString/import or callback execution.
    require(read()==before_text,"ordinary root changed during identity preparation");
    write_started=true; // After this point even an exception is indeterminate.
    write();
    const auto after_text=read();
    return {verify_inserted(before,parse(after_text),expected_marker),before_hash,digest(after_text)};
}
} // namespace PBZMC::Campaign
