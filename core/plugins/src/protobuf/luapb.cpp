#include <algorithm>
#include "pb.c"
#include "lua_kit.h"
#include "xor.h"

using namespace std;
using namespace luakit;

namespace luapb {

    thread_local std::unordered_map<uint32_t,std::string> pb_cmd_ids;

    constexpr int FlagMask_REQ      = 0x01;
    constexpr int FlagMask_RES      = 0x02;
    constexpr int FlagMask_Encrypt  = 0x04;
    constexpr int FlagMask_Zip      = 0x08;

    #pragma pack(1)
    struct pb_header {
        uint16_t    len;            // 整个包的长度
        uint8_t     flag;           // 标志位
        uint8_t     seq_id;         // 序号
        uint32_t    cmd_id;         // 协议ID
        uint32_t    session_id;     // sessionId
    };
    #pragma pack()

    class pbcodec : public codec_base {
    public:
        pbcodec() {
        }

        virtual int load_packet(size_t data_len) {
            if (!m_slice) return 0;
            pb_header* header =(pb_header*)m_slice->peek(sizeof(pb_header));
            if (!header) return 0;
            m_packet_len = header->len;
            if (m_packet_len < sizeof(pb_header)) return -1;
            if (m_packet_len >= 0xffff) return -1;
            if (!m_slice->peek(m_packet_len)) return 0;
            if (m_packet_len > data_len) return 0;
            return m_packet_len;
        }

        virtual uint8_t* encode(lua_State* L, int index, size_t* len) {
            //header
            pb_header header;
            lpb_State *LS = lpb_lstate(L);
            lpb_Env e;
            e.L = L, e.LS = LS;
            pb_resetbuffer(e.b = &LS->buffer);
            pb_Slice sh = pb_lslice((const char*)&header, sizeof(header));
            //cmdid
            header.cmd_id = (uint32_t)lua_tointeger(L, index++);
            header.flag = (uint8_t)lua_tointeger(L, index++);
            header.session_id = (uint32_t)lua_tointeger(L, index++);
            header.seq_id = 0xff;//服务端包不检测序号
            //string类型直接发送
            int type = lua_type(L, index);
            if (type != LUA_TSTRING && type != LUA_TTABLE) {
                return nullptr;
            }
            if (type == LUA_TSTRING) {
                size_t data_len = 0;
                const char* buf = lua_tolstring(L, index, &data_len);
                pb_addslice(e.b, sh);
                pb_addslice(e.b, pb_lslice(buf,data_len));                
            } else {
                const pb_Type* t = pb_type_from_stack(L, LS, &header);
                if (t == nullptr) luaL_error(L, "pb message not define cmd: %d", header.cmd_id);
                //encode            
                lua_pushvalue(L, index);
                pb_addslice(e.b, sh);
                lpbE_encode(&e, t, -1);
            }
            *len = pb_bufflen(e.b);
            auto data = (uint8_t*)pb_buffer(e.b);
            ((pb_header*)data)->len = *len;
            //encrypt
            if (encrypt(header.flag)) {
                xor_code(data+sizeof(header), *len - sizeof(header));
            }
            return data;
        }

        virtual size_t decode(lua_State* L) {
            pb_header* header =(pb_header*)m_slice->erase(sizeof(pb_header));
            //cmd_id
            lpb_State* LS = lpb_lstate(L);
            const pb_Type* t = pb_type_from_enum(L, LS, header->cmd_id);
            if (t == nullptr) {
                throw lua_exception("pb message not define cmd: %d", header->cmd_id);
            }
            //data
            size_t data_len;
            char* data = (char*)m_slice->data(&data_len);
            //encrypt
            if (encrypt(header->flag)) {
                xor_code((uint8_t*)data, data_len);
            }

            //return
            int top = lua_gettop(L);
            lua_pushinteger(L, data_len);
            lua_pushinteger(L, header->cmd_id);
            lua_pushinteger(L, header->flag);
            lua_pushinteger(L, header->session_id);
            lua_pushinteger(L, header->seq_id);
            //decode
            lua_push_function(L, [&](lua_State* L) {
                lpb_Env e;
                pb_Slice s = pb_lslice(data, data_len);
                lpb_pushtypetable(L, LS, t);
                e.L = L, e.LS = LS, e.s = &s;
                lpbD_message(&e, t);
                return 1;
            });
            if (lua_pcall(L, 0, 1, 0)) {
                throw lua_exception("decode pb cmdid: %d failed: %s", header->cmd_id, lua_tostring(L, -1));
            }
            return lua_gettop(L) - top;
        }

    protected:
        const pb_Type* pb_type_from_enum(lua_State* L, lpb_State* LS, size_t cmd_id) {
            auto it = pb_cmd_ids.find(cmd_id);
            if (it == pb_cmd_ids.end()) throw lua_exception("pb decode invalid cmdid: %d!", cmd_id);
            return lpb_type(L, LS, pb_lslice(it->second.c_str(), it->second.size()));
        }

        const pb_Type* pb_type_from_stack(lua_State* L, lpb_State* LS, pb_header* header) {
            auto it = pb_cmd_ids.find(header->cmd_id);
            if (it == pb_cmd_ids.end()) luaL_error(L, "invalid pb cmd: %d", header->cmd_id);
            return lpb_type(L, LS, pb_lslice(it->second.c_str(), it->second.size()));
        }

        bool encrypt(uint8_t flag) {
            return (flag & FlagMask_Encrypt) == FlagMask_Encrypt;
        }

        bool is_zip(uint8_t flag) {
            return (flag & FlagMask_Zip) == FlagMask_Zip;
        }

    protected:
    };
    
    static codec_base* pb_codec() {
        pbcodec* codec = new pbcodec();
        codec->set_buff(&thread_buff);
        return codec;
    }

    luakit::lua_table open_luapb(lua_State* L) {
        luaopen_pb(L);
        lua_table luapb(L);
        luapb.set_function("pbcodec", pb_codec);
        luapb.set_function("bind_cmd", [](uint32_t cmd_id, std::string fullname) { pb_cmd_ids[cmd_id] = fullname; });
        luapb.set_function("xor_init", [](uint64_t key) { xor_init(key); });
        return luapb;
    }
}

extern "C" {
    LUALIB_API int luaopen_luapb(lua_State* L) {
        auto luapb = luapb::open_luapb(L);
        return luapb.push_stack();
    }
}
