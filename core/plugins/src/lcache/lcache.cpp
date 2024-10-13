#include "lrucache.hpp"
#include "lua_kit.h"
#include <vector>
#include <memory>

namespace cache {
    using cache_type = cache::lru_cache<std::string, std::string>;

	static thread_local luakit::codec_base* codec = nullptr;

	static int lset(lua_State* L) {
		cache_type* cache = (cache_type*)lua_touserdata(L, 1);
		if (nullptr == cache) {
			return luaL_argerror(L, 1, "invalid lua-cache pointer");
		}
		auto key = luakit::lua_to_native<std::string>(L, 2);
		size_t data_len;
		const char* data = NULL;
		if (codec) {
			data = (char*)codec->encode(L, 3, &data_len);
		} else {
			if (LUA_TSTRING != lua_type(L, 3)) {
				return luaL_argerror(L, 3, "not codec must put string data");
			}
			data = lua_tolstring(L, 3, &data_len);
		}		
		if (data) {
			cache->set(key, std::string(data, data_len));
		} else {
			return luaL_argerror(L, 3, "not data prama");
		}
		return 0;
	}

	static int lget(lua_State* L) {
		cache_type* cache = (cache_type*)lua_touserdata(L, 1);
		if (nullptr == cache) {
			return luaL_argerror(L, 1, "invalid lua-cache pointer");
		}
		auto key = luakit::lua_to_native<std::string>(L, 2);
		try
		{
			auto value = cache->get(key);
			if (codec) {
				codec->decode(L, (uint8_t*)value.c_str(), value.size());
			} else {
				lua_pushlstring(L, value.c_str(), value.size());
			}
		}
		catch (const std::exception&)
		{
			lua_pushnil(L);
		}
		return 1;
	}

	static int ldel(lua_State* L) {
		cache_type* cache = (cache_type*)lua_touserdata(L, 1);
		if (nullptr == cache) {
			return luaL_argerror(L, 1, "invalid lua-cache pointer");
		}
		auto key = luakit::lua_to_native<std::string>(L, 2);
		lua_pushboolean(L, cache->remove(key) ? 1 : 0);
		return 1;
	}

	static int lexist(lua_State* L) {
		cache_type* cache = (cache_type*)lua_touserdata(L, 1);
		if (nullptr == cache) {
			return luaL_argerror(L, 1, "invalid lua-cache pointer");
		}
		auto key = luakit::lua_to_native<std::string>(L, 2);
		lua_pushboolean(L, cache->exist(key) ? 1 : 0);
		return 1;
	}

	static int lsize(lua_State* L) {
		cache_type* cache = (cache_type*)lua_touserdata(L, 1);
		if (nullptr == cache) {
			return luaL_argerror(L, 1, "invalid lua-cache pointer");
		}
		lua_pushinteger(L, cache->size());
		return 1;
	}

	static int lclear(lua_State* L) {
		cache_type* cache = (cache_type*)lua_touserdata(L, 1);
		if (nullptr == cache) {
			return luaL_argerror(L, 1, "invalid lua-cache pointer");
		}
		lua_pushboolean(L, cache->clear());
		return 1;
	}

	static int lrelease(lua_State* L) {
		cache_type* cache = (cache_type*)lua_touserdata(L, 1);
		if (nullptr == cache) {
			return luaL_argerror(L, 1, "invalid lua-cache pointer");
		}
		std::destroy_at(cache);
		return 0;
	}

    static int lcreate(lua_State* L) {
        size_t max_count = (size_t)luaL_checkinteger(L, 1);
		if (max_count < 1) {
			return luaL_argerror(L, 1, "cache size < 1");
		}		
		void* p = lua_newuserdatauv(L, sizeof(cache_type), 0);
		new (p) cache_type(max_count);
		if (luaL_newmetatable(L, "lcache"))//mt
		{
			luaL_Reg l[] = {
				{ "set", lset},
				{ "get", lget},
				{ "del", ldel},
				{ "exist", lexist},				
				{ "size", lsize},
				{ "clear",lclear},
				{ NULL,NULL }
			};
			luaL_newlib(L, l); //{}
			lua_setfield(L, -2, "__index");//mt[__index] = {}
			lua_pushcfunction(L, lrelease);
			lua_setfield(L, -2, "__gc");//mt[__gc] = lrelease
		}
		lua_setmetatable(L, -2);// set userdata metatable
		return 1;
    }

	static int lset_codec(lua_State* L) {
		codec = luakit::lua_to_native<luakit::codec_base*>(L, 1);
		lua_pushboolean(L, codec != nullptr);
		return 1;
	}

}

extern "C" {
    LUALIB_API int luaopen_lcache(lua_State* L)
	{
		luaL_Reg l[] = {
			{"new",cache::lcreate},
			{"release",cache::lrelease},
			{"set_codec",cache::lset_codec},
			{NULL,NULL}
		};
		luaL_newlib(L, l);
		return 1;
    }
}
