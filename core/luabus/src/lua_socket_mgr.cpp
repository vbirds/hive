#include "stdafx.h"
#include "lua_socket_mgr.h"
#include "lua_socket_node.h"

bool lua_socket_mgr::setup(lua_State* L, uint32_t max_fd) {
	m_luakit = std::make_shared<kit_state>(L);
	m_mgr = std::make_shared<socket_mgr>();
	m_codec = m_luakit->create_codec();
	m_router = std::make_shared<socket_router>(m_mgr);
	return m_mgr->setup(max_fd);
}

int lua_socket_mgr::listen(lua_State* L, const char* ip, int port) {
	if (ip == nullptr || port <= 0) {
		return luakit::variadic_return(L, nullptr, "invalid param");
	}
	std::string err;
	eproto_type proto_type = (eproto_type)luaL_optinteger(L, 3, 0);
	auto token = m_mgr->listen(err, ip, port, proto_type);
	if (token == 0) {
		return luakit::variadic_return(L, nullptr, err);
	}

	auto listener = new lua_socket_node(token, m_luakit->L(), m_mgr, m_router, true, proto_type);
	if (proto_type == eproto_type::proto_rpc || proto_type == eproto_type::proto_head) {
		listener->set_codec(m_codec);
	}
	return luakit::variadic_return(L, listener, "ok");
}

int lua_socket_mgr::connect(lua_State* L, const char* ip, const char* port, int timeout) {
	if (ip == nullptr || port == nullptr) {
		return luakit::variadic_return(L, nullptr, "invalid param");
	}

	std::string err;
	eproto_type proto_type = (eproto_type)luaL_optinteger(L, 4, 0);
	auto token = m_mgr->connect(err, ip, port, timeout, proto_type);
	if (token == 0) {
		return luakit::variadic_return(L, nullptr, err);
	}

	auto stream = new lua_socket_node(token, m_luakit->L(), m_mgr, m_router, false, proto_type);
	if (proto_type == eproto_type::proto_rpc || proto_type == eproto_type::proto_head) {
		stream->set_codec(m_codec);
	}
	return luakit::variadic_return(L, stream, "ok");
}

int lua_socket_mgr::map_token(uint32_t node_id, uint32_t token,uint16_t hash) {
	return m_router->map_token(node_id, token, hash);
}

int lua_socket_mgr::set_node_status(uint32_t node_id, uint8_t status) {
	return m_router->set_node_status(node_id, status);
}

void lua_socket_mgr::map_router_node(uint32_t router_id, uint32_t target_id, uint8_t status) {
	return m_router->map_router_node(router_id,target_id,status);
}

void lua_socket_mgr::set_router_id(int id) {
	m_router->set_router_id(id);
}

void lua_socket_mgr::set_service_name(uint32_t service_id, std::string service_name) {
	m_router->set_service_name(service_id, service_name);
}

void lua_socket_mgr::set_rpc_key(std::string key) {
	m_mgr->set_handshake_verify(key);
}

const std::string lua_socket_mgr::get_rpc_key() {
	return m_mgr->get_handshake_verify();
}
int lua_socket_mgr::broadgroup(lua_State* L, codec_base* codec) {
	size_t data_len = 0;
	std::vector<uint32_t> groups;
	if (!lua_to_native(L, 2, groups)) {
		lua_pushboolean(L, false);
		return 1;
	}
	char* data = (char*)codec->encode(L, 3, &data_len);
	if (data_len > 1 && data_len < NET_PACKET_MAX_LEN) {
		//发送数据
		m_mgr->broadgroup(groups, data, data_len);
		lua_pushboolean(L, true);
		return 1;
	}
	lua_pushboolean(L, false);
	return 1;
}
//玩家路由
void lua_socket_mgr::set_player_service(uint32_t player_id, uint32_t sid, uint8_t login) {
	m_router->set_player_service(player_id, sid, login);
}
uint32_t lua_socket_mgr::find_player_sid(uint32_t player_id, uint16_t service_id) {
	return m_router->find_player_sid(player_id, service_id);
}
void lua_socket_mgr::clean_player_sid(uint32_t sid) {
	m_router->clean_player_sid(sid);
}