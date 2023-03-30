-- router_mgr.lua
local lcodec           = require("lcodec")
local pairs            = pairs
local log_err          = logger.err
local log_info         = logger.info
local log_debug        = logger.debug
local signal_quit      = signal.quit
local tunpack          = table.unpack
local sformat          = string.format
local id2sid           = service.id2sid
local id2nick          = service.id2nick
local check_success    = hive.success
local jumphash         = lcodec.jumphash

local monitor          = hive.get("monitor")
local thread_mgr       = hive.get("thread_mgr")
local event_mgr        = hive.get("event_mgr")

local RPC_CALL_TIMEOUT = hive.enum("NetwkTime", "RPC_CALL_TIMEOUT")
local RPC_UNREACHABLE  = hive.enum("KernCode", "RPC_UNREACHABLE")

local RouterMgr        = singleton()
local prop             = property(RouterMgr)
prop:accessor("routers", {})
prop:accessor("candidates", {})
prop:accessor("hid", 0)
function RouterMgr:__init()
    self.hid = hive.id
    self:setup()
end

--初始化
function RouterMgr:setup()
    --router接口
    self:build_service()
    --监听路由信息
    monitor:watch_service_ready(self, "router")
    monitor:watch_service_close(self, "router")
    --注册事件
    event_mgr:add_listener(self, "rpc_client_kickout")
    event_mgr:add_listener(self, "on_forward_error")
    event_mgr:add_listener(self, "reply_forward_error")
end

--服务关闭
function RouterMgr:on_service_close(id, name)
    log_debug("[RouterMgr][on_service_close] node: %s", id2nick(id))
    local router = self.routers[id]
    if router then
        router.client:close()
        self.routers[id] = nil
    end
end

--服务上线
function RouterMgr:on_service_ready(id, name, info)
    log_debug("[RouterMgr][on_service_ready] node: %s, info: %s", id2nick(id), info)
    self:add_router(info.id, info.ip, info.port)
end

--添加router
function RouterMgr:add_router(router_id, host, port)
    if router_id == hive.id then
        return
    end
    if not self.routers[router_id] then
        log_debug("[RouterMgr][add_router] %s --> %s,%s:%s", hive.name, id2nick(router_id), host, port)
        local RpcClient         = import("network/rpc_client.lua")
        self.routers[router_id] = {
            addr      = host,
            router_id = router_id,
            client    = RpcClient(self, host, port)
        }
    end
end

--错误处理
function RouterMgr:on_socket_error(client, token, err)
    self:check_router()
    log_err("[RouterMgr][on_socket_error] router lost %s:%s, err=%s", client.ip, client.port, err)
end

--连接成功
function RouterMgr:on_socket_connect(client, res)
    log_info("[RouterMgr][on_socket_connect] router %s:%s success!", client.ip, client.port)
    self:check_router()
end

--切换主router
function RouterMgr:check_router()
    self.candidates = {}
    for _, node in pairs(self.routers) do
        if node.client:is_alive() then
            self.candidates[#self.candidates + 1] = node
        end
    end
end

--查找指定router
function RouterMgr:get_router(router_id)
    return self.routers[router_id]
end

--查找hash router
function RouterMgr:hash_router(service_id)
    local hash_key = self.hid + service_id
    local count    = #self.candidates
    if count > 0 then
        local index = jumphash(hash_key, count)
        local node  = self.candidates[index]
        if node == nil then
            log_err("[RouterMgr][hash_router] the hash node nil,hashkey:%s,index:%s", hash_key, index)
        end
        return node
    end
end

--通过router发送点对点消息
function RouterMgr:forward_client(router, method, rpc, session_id, ...)
    if router then
        return router.client:forward_socket(method, rpc, session_id, ...)
    end
    return false, "router not connected"
end

--通过router发送广播，并收集所有的结果
function RouterMgr:collect(service_id, rpc, ...)
    local collect_res          = {}
    local session_id           = thread_mgr:build_session_id()
    local ok, code, target_cnt = self:forward_client(self:hash_router(service_id), "call_broadcast", rpc, session_id, service_id, rpc, ...)
    if check_success(code, ok) then
        while target_cnt > 0 do
            target_cnt              = target_cnt - 1
            local ok_c, code_c, res = thread_mgr:yield(session_id, "collect", RPC_CALL_TIMEOUT)
            if check_success(code_c, ok_c) then
                collect_res[#collect_res + 1] = res
            end
        end
    end
    return ok, code, collect_res
end

--通过router传递广播
function RouterMgr:broadcast(service_id, rpc, ...)
    local router = self:hash_router(service_id)
    return self:forward_client(router, "call_broadcast", rpc, 0, service_id, rpc, ...)
end

--发送给指定目标
function RouterMgr:call_target(target, rpc, ...)
    if target == hive.id then
        local res = event_mgr:notify_listener(rpc, ...)
        return tunpack(res)
    end
    local session_id = thread_mgr:build_session_id()
    return self:forward_client(self:hash_router(id2sid(target)), "call_target", rpc, session_id, target, rpc, ...)
end

--发送给指定目标
function RouterMgr:send_target(target, rpc, ...)
    if target == hive.id then
        event_mgr:notify_listener(rpc, ...)
        return true
    end
    return self:forward_client(self:hash_router(id2sid(target)), "call_target", rpc, 0, target, rpc, ...)
end

--指定路由发送给指定目标
function RouterMgr:router_call(router_id, target, rpc, ...)
    local router     = self:get_router(router_id)
    local session_id = thread_mgr:build_session_id()
    return self:forward_client(router, "call_target", rpc, session_id, target, rpc, ...)
end

--指定路由发送给指定目标
function RouterMgr:router_send(router_id, target, rpc, ...)
    local router = self:get_router(router_id)
    return self:forward_client(router, "call_target", rpc, 0, target, rpc, ...)
end

--发送给指定service的hash
function RouterMgr:call_hash(service_id, hash_key, rpc, ...)
    local session_id = thread_mgr:build_session_id()
    return self:forward_client(self:hash_router(service_id), "call_hash", rpc, session_id, service_id, hash_key, rpc, ...)
end

--发送给指定service的hash
function RouterMgr:send_hash(service_id, hash_key, rpc, ...)
    return self:forward_client(self:hash_router(service_id), "call_hash", rpc, 0, service_id, hash_key, rpc, ...)
end

--发送给指定service的master
function RouterMgr:call_master(service_id, rpc, ...)
    local session_id = thread_mgr:build_session_id()
    return self:forward_client(self:hash_router(service_id), "call_master", rpc, session_id, service_id, rpc, ...)
end

--发送给指定service的master
function RouterMgr:send_master(service_id, rpc, ...)
    return self:forward_client(self:hash_router(service_id), "call_master", rpc, 0, service_id, rpc, ...)
end

--生成针对服务的访问接口
function RouterMgr:build_service_method(service, service_id)
    local method_list = {
        ["call_%s_hash"]     = function(obj, hash_key, rpc, ...)
            return obj:call_hash(service_id, hash_key, rpc, ...)
        end,
        ["send_%s_hash"]     = function(obj, hash_key, rpc, ...)
            return obj:send_hash(service_id, hash_key, rpc, ...)
        end,
        ["call_%s_master"]   = function(obj, rpc, ...)
            return obj:call_master(service_id, rpc, ...)
        end,
        ["send_%s_master"]   = function(obj, rpc, ...)
            return obj:send_master(service_id, rpc, ...)
        end,
        ["send_%s_all"]      = function(obj, rpc, ...)
            return obj:broadcast(service_id, rpc, ...)
        end,
        ["send_%s_all_self"] = function(obj, rpc, ...)
            if service_id == hive.service_id then
                event_mgr:notify_listener(rpc, ...)
            end
            return obj:broadcast(service_id, rpc, ...)
        end,
        ["collect_%s"]       = function(obj, rpc, ...)
            return obj:collect(service_id, rpc, ...)
        end,
    }
    for fmt_key, handler in pairs(method_list) do
        local method = sformat(fmt_key, service)
        if not RouterMgr[method] then
            RouterMgr[method] = handler
        end
    end
end


--生成针对服务的访问接口
function RouterMgr:build_service()
    local services = service.services()
    for service, service_id in pairs(services) do
        self:build_service_method(service, service_id)
    end
end

--业务事件响应
-------------------------------------------------------------------------------

--服务被踢下线
function RouterMgr:rpc_client_kickout(router_id, reason)
    log_err("[RouterMgr][rpc_client_kickout] reason:%s router_id:%s", reason, router_id)
    signal_quit()
end

--路由集群转发失败
function RouterMgr:on_forward_error(session_id, error_msg, source_id)
    log_err("[RouterMgr][on_forward_error] session_id:%s,from:%s,%s", session_id, id2nick(source_id), error_msg)
    self:send_target(source_id, "reply_forward_error", session_id, error_msg)
end

function RouterMgr:reply_forward_error(session_id, error_msg)
    log_err("[RouterMgr][reply_forward_error] %s,%s", thread_mgr:get_title(session_id), error_msg)
    thread_mgr:response(session_id, false, RPC_UNREACHABLE, error_msg)
end

hive.router_mgr = RouterMgr()

return RouterMgr
