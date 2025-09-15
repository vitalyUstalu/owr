-- wr.lua: waiting room helper library

local redis = require "resty.redis"
local uuid = require "resty.jit-uuid"

uuid.seed()

local _M = {}

-- Settings (read from ENV, fallback to defaults)
_M.MAX_ACTIVE   = tonumber(os.getenv("WR_MAX_ACTIVE"))   or 100
_M.ACTIVE_TTL   = tonumber(os.getenv("WR_ACTIVE_TTL"))   or 60
_M.COOKIE_NAME  = os.getenv("WR_COOKIE_NAME") or "wr_token"
_M.RELEASE_INTERVAL = tonumber(os.getenv("WR_RELEASE_INTERVAL")) or 2
_M.LOCK_TTL = _M.RELEASE_INTERVAL + 5


-- Redis settings
_M.REDIS_HOST   = os.getenv("WR_REDIS_HOST")   or "127.0.0.1"
_M.REDIS_PORT   = tonumber(os.getenv("WR_REDIS_PORT")) or 6379
_M.REDIS_USER   = os.getenv("WR_REDIS_USER")   or nil
_M.REDIS_PASS   = os.getenv("WR_REDIS_PASS")   or nil

-- Redis pool settings
_M.REDIS_POOL_SIZE       = tonumber(os.getenv("WR_REDIS_POOL_SIZE")) or 200
_M.REDIS_POOL_IDLE_TIME  = tonumber(os.getenv("WR_REDIS_POOL_IDLE_TIMEOUT")) or 10000  -- ms

-- Connect to Redis
function _M.get_redis()
    local red = redis:new()
    red:set_timeout(1000)

    local ok, err = red:connect(_M.REDIS_HOST, _M.REDIS_PORT)
    if not ok then
        ngx.log(ngx.ERR, "failed to connect to redis: ", err)
        return nil, err
    end

    -- Auth
    if _M.REDIS_USER and _M.REDIS_PASS then
        local ok, err = red:auth(_M.REDIS_USER, _M.REDIS_PASS)
        if not ok then
            ngx.log(ngx.ERR, "redis auth failed: ", err)
            return nil, err
        end
    elseif _M.REDIS_PASS then
        local ok, err = red:auth(_M.REDIS_PASS)
        if not ok then
            ngx.log(ngx.ERR, "redis auth failed: ", err)
            return nil, err
        end
    end

    return red
end

-- Release Redis connection back to pool
function _M.release_redis(red)
    if not red then return end
    local ok, err = red:set_keepalive(_M.REDIS_POOL_IDLE_TIME, _M.REDIS_POOL_SIZE)
    if not ok then
        ngx.log(ngx.ERR, "failed to set redis keepalive: ", err)
    end
end

-- Extract cookie by prefix from COOKIES header
local function extract_cookie(cookies, name)
    if not cookies then return nil end
    for cookie in cookies:gmatch("([^;]+)") do
        local key, value = cookie:match("^%s*(.-)%s*=%s*(.-)%s*$")
        if key == name then
            return value
        end
    end
    return nil
end

-- Get or create wr_token cookie
function _M.get_or_create_token()
    local cookies = ngx.req.get_headers()["Cookie"] or ""
    ngx.log(ngx.ERR, "Cookie: ", cookies)
    local token = extract_cookie(cookies, _M.COOKIE_NAME)
    ngx.log(ngx.ERR, "Token from cookie: ", token)
    if not token then
        token = uuid.generate_v4()
        ngx.header["Set-Cookie"] = _M.COOKIE_NAME .. "=" .. token .. "; Path=/; HttpOnly"
    end
    return token
end

-- Check waiting room logic
function _M.check_waiting_room()
    local red, err = _M.get_redis()
    if not red then
        return {status="error", message="Redis unavailable: " .. (err or "unknown")}
    end

    local token = _M.get_or_create_token()
    ngx.log(ngx.ERR, "Token: ", token)
    local now = ngx.time()

    -- Already active
    local score = red:zscore("wr:active", token)
    if score and score ~= ngx.null then
        ngx.log(ngx.ERR, "Already active")
        red:zadd("wr:active", now, token)
        _M.release_redis(red)
        return {status="active", token=token}
    end

    -- Released from queue
    if red:sismember("wr:released", token) == 1 then
        ngx.log(ngx.ERR, "Released from queue")
        red:zadd("wr:active", now, token)
        red:srem("wr:released", token)
        _M.release_redis(red)
        return {status="active", token=token}
    end

    -- Free slot available
    local active_count = red:zcount("wr:active", now - _M.ACTIVE_TTL, "+inf")
    if active_count < _M.MAX_ACTIVE then
        ngx.log(ngx.ERR, "Free slot available")
        red:zadd("wr:active", now, token)
        _M.release_redis(red)
        return {status="active", token=token}
    end

    -- Otherwise enqueue
    local pos = red:lpos("wr:queue", token)
    if pos == ngx.null or not pos then
        ngx.log(ngx.ERR, "Otherwise enqueue")
        red:rpush("wr:queue", token)
        pos = red:llen("wr:queue") - 1
    end

    _M.release_redis(red)
    return {status="waiting", position=pos+1}
end

-- Background job: release users from queue
function _M.release_from_queue(premature)
    if premature then return end
    local red, err = _M.get_redis()
    if not red then
        ngx.log(ngx.ERR, "queue job: redis unavailable: ", err or "unknown")
        return
    end

    -- Try to acquire lock
    local lock_key = "wr:release_lock"
    local ok, err = red:set(lock_key, "1", "EX", _M.LOCK_TTL, "NX")
    if not ok or ok == ngx.null then
        if err then ngx.log(ngx.ERR, "failed to acquire lock: ", err) end
        _M.release_redis(red)
        return
    end

    local now = ngx.time()

    -- Remove inactive users
    red:zremrangebyscore("wr:active", "-inf", now - _M.ACTIVE_TTL)

    -- Promote waiting users if slots available
    local active_count = red:zcount("wr:active", now - _M.ACTIVE_TTL, "+inf")
    local slots_available = _M.MAX_ACTIVE - active_count
    
    if slots_available > 0 then
        for i = 1, slots_available do
            local token = red:lpop("wr:queue")
            if token == ngx.null then break end
            red:sadd("wr:released", token)
        end
    end
    
    -- Release lock
    red:del(lock_key)

    _M.release_redis(red)

    -- Reschedule
    local ok, err = ngx.timer.at(_M.RELEASE_INTERVAL, _M.release_from_queue)
    if not ok then ngx.log(ngx.ERR, "failed to schedule: ", err) end
end

return _M
