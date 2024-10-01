local sformat    = string.format
local log_warn   = logger.warn
local log_err    = logger.err
local scheduler  = hive.load("scheduler")

local thread     = import("feature/worker_agent.lua")
local ProxyAgent = singleton(thread)
local prop       = property(ProxyAgent)
prop:reader("ignore_statistics", {})
prop:reader("statis_status", false)
prop:reader("warns", {})

function ProxyAgent:__init()
    self.service  = "proxy"
    self.cur_path = stdfs.current_path()
    --开启调度器
    if scheduler then
        self:startup("worker.proxy")
        --开启统计
        if environ.status("HIVE_STATIS") then
            self.statis_status = true
            log_warn("[ProxyAgent:__init] open statis !!!,it will degrade performance")
        end
    end
    --添加忽略的rpc统计事件
    self:ignore_statis("rpc_heartbeat")
    self:ignore_statis("on_heartbeat")
    --日志上报
    if hive.title ~= self.service then
        local wlvl = environ.number("HIVE_WEBHOOK_LVL")
        if wlvl then
            --添加webhook功能
            logger.add_monitor(self, wlvl)
        end
    end
    --添加告警限制
    self:add_warn("on_proto_recv", 8192)
    self:add_warn("on_proto_send", 8192)
    self:add_warn("on_rpc_send", 8192)
end

--日志分发
function ProxyAgent:dispatch_log(content, lvl_name, source)
    local title = sformat("[%s]", lvl_name)
    return self:send("rpc_fire_webhook", title, content, source)
end

function ProxyAgent:send_webhook_log(hook_api, url, content, ...)
    return self:send("rpc_send_webhook", hook_api, url, "", content, hive.where_call(), ...)
end

function ProxyAgent:http_get(url, querys, headers, datas, timeout, debug)
    return self:call("rpc_http_get", url, querys, headers, datas, timeout, debug)
end

function ProxyAgent:http_post(url, post_data, headers, querys, timeout, debug)
    return self:call("rpc_http_post", url, post_data, headers, querys, timeout, debug)
end

function ProxyAgent:http_put(url, post_data, headers, querys, timeout, debug)
    return self:call("rpc_http_put", url, post_data, headers, querys, timeout, debug)
end

function ProxyAgent:http_del(url, querys, headers, timeout, debug)
    return self:call("rpc_http_del", url, querys, headers, timeout, debug)
end

function ProxyAgent:ignore_statis(name)
    self.ignore_statistics[name] = true
end

function ProxyAgent:statistics(event, name, len)
    local wlen = self.warns[name]
    if wlen and len > wlen then
        log_err("[ProxyAgent][statistics] [%s:%s],send len:%s,please check the logic is right?", event, name, len)
    end
    if self.statis_status and not self.ignore_statistics[name] then
        self:send(event, name, len)
    end
end

function ProxyAgent:add_warn(name, len)
    self.warns[name] = len
end

hive.proxy_agent = ProxyAgent()

return ProxyAgent
