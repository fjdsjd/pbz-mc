// Standalone regression for ownership of the physical wheel button (no UE or game required).
#include "item_input_messages.hpp"
#include <iostream>
using namespace PBZMC::ItemInput;
static void expect(bool condition,const char* message) {
    if (!condition) throw std::runtime_error(message);
}
int main() {
    for (bool no_legacy : {true,false}) {
        Core core; Environment env{};env.identity_valid=env.pointer.focused=true;
        unsigned t=100;core.start(env,t);
        auto context=[&](Context c){core.set_context(c,env,++t);};
        auto mouse=[&](USHORT flags,USHORT expected,bool look_blocked) {
            RAWMOUSE m{};m.usButtonFlags=flags;m.usButtonData=(flags&RI_MOUSE_WHEEL)?120:0;m.lLastX=5;
            if(flags&RI_MOUSE_MIDDLE_BUTTON_DOWN)env.held_buttons|=4;
            if(flags&RI_MOUSE_MIDDLE_BUTTON_UP)env.held_buttons&=~4;
            ++t;process_raw_mouse(core,m,env,t,t,no_legacy);
            expect(m.usButtonFlags==expected,"PBZ received the wrong raw button edge");
            expect(m.usButtonData==0 && m.lLastX==(look_blocked?0:5),"wheel/relative-look ownership changed");
        };
        for (auto native : {Context::game_pbz_hotbar,Context::motion_pbz,Context::creative_pbz}) {
            const bool motion=native!=Context::game_pbz_hotbar;
            context(native);
            mouse(RI_MOUSE_MIDDLE_BUTTON_DOWN|RI_MOUSE_WHEEL,RI_MOUSE_MIDDLE_BUTTON_DOWN,motion);
            if (no_legacy) {
                const auto batch=core.drain(env,++t);unsigned wheels=0;
                for(std::size_t i=0;i<batch.count;++i)if(batch.samples[i].wheel_delta==120)++wheels;
                expect(wheels==1,"mixed PBZ lock and hotbar wheel packet lost or replayed");
            }
            context(Context::inventory);
            mouse(RI_MOUSE_MIDDLE_BUTTON_UP,RI_MOUSE_MIDDLE_BUTTON_UP,false);
            mouse(RI_MOUSE_MIDDLE_BUTTON_DOWN,0,false);
            context(native);
            mouse(RI_MOUSE_MIDDLE_BUTTON_UP,0,motion);
            mouse(RI_MOUSE_MIDDLE_BUTTON_DOWN,RI_MOUSE_MIDDLE_BUTTON_DOWN,motion);
            mouse(RI_MOUSE_MIDDLE_BUTTON_UP,RI_MOUSE_MIDDLE_BUTTON_UP,motion);
        }
        context(Context::game_fp);
        mouse(RI_MOUSE_MIDDLE_BUTTON_DOWN|RI_MOUSE_WHEEL,0,true);
        context(Context::motion_pbz);mouse(RI_MOUSE_MIDDLE_BUTTON_UP,0,true);
        mouse(RI_MOUSE_LEFT_BUTTON_DOWN|RI_MOUSE_RIGHT_BUTTON_DOWN|RI_MOUSE_MIDDLE_BUTTON_DOWN,
              RI_MOUSE_MIDDLE_BUTTON_DOWN,true);
        mouse(RI_MOUSE_LEFT_BUTTON_UP|RI_MOUSE_RIGHT_BUTTON_UP|RI_MOUSE_MIDDLE_BUTTON_UP,RI_MOUSE_MIDDLE_BUTTON_UP,true);
    }
    std::cout<<"PASS: PBZ middle press/release, MC pick and wheel, both raw input registrations and held-button handoffs.\n";
}
