// Windows x64. Real Win32 conversion, parser, and write/readback guards;
// the host save getter/setter are replaced by an in-memory PBZ-shaped root.
#include "../native/json_bridge/save_json_text.hpp"
#include "../native/json_bridge/hotbar_json.hpp"
#include <iostream>
using namespace PBZMC;
namespace {
void check(bool ok,const char* what) { if (!ok) throw std::runtime_error(what); }
template<class F> void rejected(F f,std::string expected) {
    try { f(); } catch (const std::runtime_error& e) {
        if (std::string_view(e.what()).find(expected)!=std::string_view::npos) return;
        throw;
    }
    throw std::runtime_error("expected rejection: "+expected);
}
struct NativeView {
    int units;
    const wchar_t* data;
    int Len() const {return units;}
    const wchar_t* operator*() const {return data;}
};
std::string expanded(std::wstring_view wide) {
    const NativeView s{static_cast<int>(wide.size()),wide.data()};
    return JsonText::to_utf8(JsonText::view(s,JsonText::Use::save),JsonText::Use::save);
}
std::string zeros(std::size_t count) {
    std::string s(count*2-1,'0');
    for (std::size_t i=1;i<s.size();i+=2) s[i]=',';
    return s;
}
}
int main() try {
    using namespace Campaign;
    const std::string id="7d703fd6-27af-4ea1-89c3-53c9d44a324a",sha(64,'a'),cp(64,'b');
    const auto digest=[&](std::string_view){return sha;}; // precondition token; no hash implementation under test
    // Same Windows conversion and native-view guards used by the DLL.
    for (int n:{256*1024-1,256*1024,256*1024+1,1024*1024+1}) {
        std::wstring wide(n,L'a');wide.front()=L'中';
        check(expanded(wide).size()==static_cast<std::size_t>(n+2),"read across old FString boundary");
    }
    const auto maximum=std::to_string(root_limit);
    const std::wstring unicode(root_limit/3+1,L'中');
    rejected([&]{expanded(unicode);},"UTF-8 bytes)="+std::to_string(unicode.size()*3)+", limit="+maximum);
    rejected([&]{JsonText::view(NativeView{static_cast<int>(root_limit+1),nullptr},JsonText::Use::save);},
        "UTF-16 code units)="+std::to_string(root_limit+1)+", limit="+maximum);
    rejected([&]{JsonText::view(NativeView{-1,nullptr},JsonText::Use::save);},"negative length");
    rejected([&]{expanded(std::wstring(1,0xd800));},"invalid UTF-16");
    std::wstring boundary(root_limit,L' ');boundary[0]=L'{';boundary[1]=L'}';
    check(parse(expanded(boundary)).object.empty(),"inclusive full size read");
    boundary.push_back(L' ');rejected([&]{expanded(boundary);},"UTF-16 code units");
    rejected([&]{parse(std::string(root_limit+1,' '));},"UTF-8 bytes");
    const auto node_json=[](std::size_t total){return "{\"s\":["+zeros(total-2)+"]}";};
    parse(node_json(node_limit));
    rejected([&]{parse(node_json(node_limit+1));},"JSON values="+std::to_string(node_limit+1));

    // A growing save with both >1 MiB of UTF-8 text and >100k values:
    // first registration -> checkpoint -> hotbar -> read -> next checkpoint.
    std::string root="{\"PBZGameSystem\":{\"stage\":2,\"label\":\"引号\\\"99\",\"xp\":9007199254740993},\"events\":["+
        zeros(105000)+"],\"padding\":\""+std::string(1024*1024,'a')+"\"}";
    const auto host=parse(root);
    check(!Checkpoint::inspect(host,true),"new campaign not recognized");
    rejected([&]{Checkpoint::current(host);},"identity required");
    int writes{};std::string field,prepared;
    const auto read=[&]{return root;};
    const auto prepare=[&](std::string_view marker){prepared=marker;};
    const auto write=[&]{
        ++writes;root.pop_back();root+=",\""+field+"\":"+prepared+"}";
    };
    bool started=false;field=section;
    create_only(id,sha,read,prepare,write,digest,started);
    check(started && !Checkpoint::inspect(parse(root),true),"identity-only bootstrap recovery");
    started=false;field=Checkpoint::section;
    Checkpoint::put(id,cp,sha,read,prepare,write,digest,started);
    started=false;field=Hotbar::section;
    Hotbar::put(id,cp,"free",7,sha,read,prepare,write,digest,started);
    auto loaded=parse(root);auto scope=Checkpoint::current(loaded);
    check(writes==3 && scope.campaign_id==id && scope.checkpoint==cp && Hotbar::read(loaded,id,cp)->selected==7,"large campaign readback");
    const std::string next(64,'c');
    started=false;
    Checkpoint::put(id,next,sha,read,prepare,[&]{
        ++writes;root.replace(root.find(cp),cp.size(),next);
    },digest,started);
    loaded=parse(root);
    check(writes==4 && Checkpoint::current(loaded).checkpoint==next && !Hotbar::read(loaded,id,next),"next savepoint");
    loaded.object.erase(std::string(section));loaded.object.erase(std::string(Checkpoint::section));loaded.object.erase(std::string(Hotbar::section));
    check(loaded==host,"changed unrelated native fields");
    rejected([&]{Checkpoint::inspect(parse("{\"PBZGameSystem\":{},\"PBZMC_Checkpoint\":{}}"),true);},"without identity");
    rejected([&]{parse("{\"x\":1,\"\\u0078\":2}");},"duplicate");

    // All three setters must reject the read-only margin before prepare/write.
    root="{\"PBZGameSystem\":{}}";root.resize(identity_before_limit,' ');
    int prepared_count=0;const auto count_prepare=[&](std::string_view) {++prepared_count;};
    bool at_limit=false;
    create_only(id,sha,read,prepare,[&]{root.insert(root.find('}')+1,",\"PBZMC_CampaignIdentity\":"+prepared);},digest,at_limit);
    check(at_limit,"inclusive write reserve");
    root="{\"PBZGameSystem\":{}}";root.resize(identity_before_limit+1,' ');
    started=false;
    const std::string expected="="+std::to_string(root.size())+", limit="+std::to_string(identity_before_limit);
    rejected([&]{create_only(id,sha,read,count_prepare,write,digest,started);},expected);
    rejected([&]{Checkpoint::put(id,cp,sha,read,count_prepare,write,digest,started);},expected);
    rejected([&]{Hotbar::put(id,cp,"free",7,sha,read,count_prepare,write,digest,started);},expected);
    check(!started && !prepared_count && writes==4,"out-of-budget write reached the setter");
    std::cout<<"PASS: native conversion, large campaign registration/load and repeated savepoint, limits and no-write guards\n";
} catch(const std::exception& e) {std::cerr<<e.what()<<'\n';return 1;}
