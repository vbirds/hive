--monitor_agent.lua
local RpcClient     = import("network/rpc_client.lua")
local tunpack       = table.unpack
local env_addr      = environ.addr
local log_err       = logger.err
local log_warn      = logger.warn
local log_info      = logger.info
local check_failed  = hive.failed
local smake_id      = service.make_id
local id2nick       = service.id2nick
local time_str      = datetime_ext.time_str

local event_mgr     = hive.get("event_mgr")
local gc_mgr        = hive.get("gc_mgr")
local thread_mgr    = hive.get("thread_mgr")
local update_mgr    = hive.get("update_mgr")

local RPC_FAILED    = hive.enum("KernCode", "RPC_FAILED")
local ServiceStatus = enum("ServiceStatus")

local MonitorAgent  = singleton()
local prop          = property(MonitorAgent)
prop:reader("client", nil)
prop:reader("ready_watchers", {})
prop:reader("close_watchers", {})
prop:reader("services", {})

function MonitorAgent:__init()
    --创建连接
    local ip, port = env_addr("HIVE_MONITOR_ADDR")
    --过滤clb不能自己连自己
    if hive.service_name == "monitor" then
        ip = "127.0.0.1"
    end
    self.client = RpcClient(self, ip, port)
    --注册事件
    event_mgr:add_vote(self, "vote_stop_service")
    event_mgr:add_listener(self, "rpc_service_changed")
    event_mgr:add_listener(self, "on_remote_message")
    event_mgr:add_listener(self, "rpc_offset_time")
    event_mgr:add_listener(self, "rpc_reload")
    event_mgr:add_listener(self, "rpc_set_env")
    event_mgr:add_listener(self, "rpc_reload_env")
    event_mgr:add_listener(self, "rpc_set_server_status")
    event_mgr:add_listener(self, "rpc_hive_quit")
    event_mgr:add_listener(self, "rpc_set_log_level")
    event_mgr:add_listener(self, "rpc_full_gc")
    event_mgr:add_listener(self, "rpc_count_lua_obj")
    event_mgr:add_listener(self, "rpc_set_gc_step")
    event_mgr:add_listener(self, "rpc_check_endless_loop")

    event_mgr:add_trigger(self, "on_router_connected")

    update_mgr:attach_hour(self)
end

function MonitorAgent:on_hour()
    gc_mgr:dump_mem_obj(50)
end

--检测是否可以自动退出
function MonitorAgent:vote_stop_service()
    if not hive.is_ready() then
        return true
    end
    for _, name in ipairs(hive.pre_services or {}) do
        if self:exist_service(name) then
            log_warn("[MonitorAgent][vote_stop_service] pre service [{}] has runing,wait next check", name)
            return false
        end
        log_info("[MonitorAgent][vote_stop_service] pre service [{}] has stop", name)
    end
    return true
end

function MonitorAgent:on_router_connected(is_ready)
    --self.client:register()
end

--监听服务断开
function MonitorAgent:watch_service_close(listener, service_name)
    if not self.close_watchers[service_name] then
        self.close_watchers[service_name] = {}
    end
    self.close_watchers[service_name][listener] = true
end

--监听服务注册
function MonitorAgent:watch_service_ready(listener, service_name)
    if not self.ready_watchers[service_name] then
        self.ready_watchers[service_name] = {}
    end
    self.ready_watchers[service_name][listener] = true
end

function MonitorAgent:watch_services()
    local services = {}
    for service_name, _ in pairs(self.ready_watchers) do
        services[service_name] = true
    end
    for service_name, _ in pairs(self.close_watchers) do
        services[service_name] = true
    end
    for _, service_name in ipairs(hive.pre_services or {}) do
        services[service_name] = true
    end
    return services
end

function MonitorAgent:exist_service(service_name, index)
    local services = self.services[service_name]
    if services then
        if index then
            local sid = smake_id(service_name, index)
            return services[sid] and true or false
        end
        return next(services) and true or false
    end
    return false
end

function MonitorAgent:query_services(service_name)
    if self.client then
        local ok, info = self.client:call("rpc_query_services", service_name)
        return ok and info or nil
    end
    return nil
end

-- 连接关闭回调
function MonitorAgent:on_socket_error(client, token, err)
    log_info("[MonitorAgent][on_socket_error] disconnect monitor fail!:[{}:{}],err:{}", self.client.ip, self.client.port, err)
end

-- 连接成回调
function MonitorAgent:on_socket_connect(client)
    log_info("[MonitorAgent][on_socket_connect]: connect monitor success!:[{}:{}]", self.client.ip, self.client.port)
    client:register(self:watch_services())
end

function MonitorAgent:notify_service_event(listener_set, service_name, id, info, is_ready)
    for listener in pairs(listener_set or {}) do
        if id ~= hive.id then
            thread_mgr:fork(function()
                if is_ready then
                    listener:on_service_ready(id, service_name, info)
                else
                    listener:on_service_close(id, service_name, info)
                end
            end)
        end
    end
end

--服务改变
function MonitorAgent:rpc_service_changed(service_name, readys, closes)
    log_info("[MonitorAgent][rpc_service_changed] {},{},{}", service_name, readys, closes)
    for id, info in pairs(readys) do
        if not self.services[service_name] then
            self.services[service_name] = {}
        end
        local pid = self.services[service_name][id]
        if not pid or pid ~= info.pid then
            if pid and pid ~= info.pid then
                log_warn("[MonitorAgent][rpc_service_changed] ready service [{}] replace", id2nick(id))
            end
            self.services[service_name][id] = info.pid
            self:notify_service_event(self.ready_watchers[service_name], service_name, id, info, true)
        end
    end
    for id, info in pairs(closes) do
        if self.services[service_name] then
            local pid = self.services[service_name][id]
            if pid == info.pid then
                self:notify_service_event(self.close_watchers[service_name], service_name, id, {}, false)
                self.services[service_name][id] = nil
            else
                log_warn("[MonitorAgent][rpc_service_changed] close service [{}] has replace", id2nick(id))
            end
        end
    end
end

--执行远程rpc消息
function MonitorAgent:on_remote_message(data, message)
    if not message then
        return { code = RPC_FAILED, msg = "message is nil !" }
    end
    local ok, code, res = tunpack(event_mgr:notify_listener(message, data))
    if check_failed(code, ok) then
        log_err("[MonitorAgent][on_remote_message] web_rpc faild: ok={}, ec={}", ok, code)
        return { code = ok and code or RPC_FAILED, msg = ok and "" or code }
    end
    return { code = 0, data = res }
end

function MonitorAgent:rpc_offset_time(offset)
    timer.offset(offset)
    thread_mgr:sleep(100)
    event_mgr:notify_trigger("evt_offset_time")
    log_info("[MonitorAgent][rpc_offset_time] {}", time_str(hive.now))
end

function MonitorAgent:rpc_reload()
    log_info("[MonitorAgent][rpc_reload]")
    signal.hotfix()
end

function MonitorAgent:rpc_full_gc()
    gc_mgr:full_gc()
    hive.scheduler:broadcast("rpc_full_gc")
end

function MonitorAgent:rpc_count_lua_obj(less_num)
    local adata       = hive.scheduler:collect("rpc_count_lua_obj", less_num)
    adata["hive"]     = gc_mgr:dump_mem_obj(less_num)
    adata["mem"]      = gc_mgr:mem_size()
    adata["real_mem"] = gc_mgr:real_mem_size()
    return adata
end

function MonitorAgent:rpc_set_gc_step(open, slow_step, fast_step)
    gc_mgr:set_gc_step(open, slow_step, fast_step)
    return { open = open, slow_step = slow_step, fast_step = fast_step }
end

function MonitorAgent:notify_change_env(key)
    event_mgr:notify_trigger("evt_change_env", key)
    --通知woker更新
    local scheduler = hive.load("scheduler")
    scheduler:broadcast("on_reload_env", key)
end

function MonitorAgent:rpc_set_env(key, value)
    local old = environ.get(key)
    environ.set(key, value)
    log_info("[MonitorAgent][rpc_set_env] {}:{},old:{} --> new:{}", key, value, old, environ.get(key))
    self:notify_change_env(key)
end

function MonitorAgent:rpc_reload_env()
    local diff_keys = hive.reload_env()
    for _, key in ipairs(diff_keys) do
        log_info("[MonitorAgent][rpc_reload_env] new conf diff:{}={}", key, environ.get(key))
        self:notify_change_env(key)
    end
end

function MonitorAgent:rpc_set_server_status(status)
    if hive.status_stop() then
        log_err("[MonitorAgent][rpc_set_server_status] change status irreversible: {} --> {} ", status, hive.service_status)
        return
    end
    hive.change_service_status(status)
end

function MonitorAgent:rpc_hive_quit(reason)
    if hive.safe_stop and not hive.status_stop() then
        hive.change_service_status(ServiceStatus.STOP)
    end
end

function MonitorAgent:rpc_set_log_level(level)
    log_info("[MonitorAgent][rpc_set_log_level] level:{}", level)
    logger.filter(level)
end

function MonitorAgent:rpc_check_endless_loop(start)
    log_info("[MonitorAgent][rpc_check_endless_loop] start:{}", start)
    hive.check_endless_loop(start)
    return { code = 0, msg = "ok", start = start }
end

hive.monitor = MonitorAgent()

return MonitorAgent
