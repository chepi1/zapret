-- Ограниченный индекс runtime-состояния наших обучаемых circular-профилей.
-- Загружать после zapret-auto.lua; включать только аргументом hostcache=bounded.
-- Выбор ключей повторяет automate_host_record из zapret2 (bol-van, MIT).
local upstream_host_record = assert(automate_host_record)
local MAX_HOSTS = 4096
ring_host_cache = {}

local function unlink(cache, node)
	if node.prev then node.prev.next = node.next else cache.first = node.next end
	if node.next then node.next.prev = node.prev else cache.last = node.prev end
	node.prev, node.next = nil, nil
end

local function touch(cache, node)
	if cache.first==node then return end
	if node.active then unlink(cache, node) end
	node.prev, node.next = nil, cache.first
	if cache.first then cache.first.prev = node else cache.last = node end
	cache.first, node.active = node, true
end

local function evict(cache)
	local node = cache.last
	local bucket = autostate and autostate[node.askey]
	if bucket and bucket[node.hostkey]==node.record then
		bucket[node.hostkey] = nil
		if next(bucket)==nil then autostate[node.askey] = nil end
	end
	local nodes = cache.nodes[node.askey]
	nodes[node.hostkey] = nil
	if next(nodes)==nil then cache.nodes[node.askey] = nil end
	unlink(cache, node)
	node.active, node.record.ring_cache_evicted = false, true
	cache.count = cache.count-1
end

local function resolve(desync)
	local hkf = standard_hostkey
	if desync.arg.hostkey then
		hkf = _G[desync.arg.hostkey]
		if type(hkf)~="function" then error("automate: invalid hostkey function '"..desync.arg.hostkey.."'") end
	end
	local hostkey = hkf(desync)
	if not hostkey then return nil end
	local askey = (desync.arg.key and #desync.arg.key>0) and desync.arg.key or desync.func_instance
	return askey, hostkey
end

local function lookup(cache, desync, askey, hostkey)
	if not hostkey then return nil end
	local state = desync.track and desync.track.lua_state
	-- Как и upstream automate_conn_record, наши профили используют один circular на track.
	local pin = state and state.ring_host_pin
	if pin and pin.token==cache.token and pin.askey==askey and pin.hostkey==hostkey then
		-- Не возвращать выселенную запись в общий индекс: там уже может быть новая.
		if pin.node.active then touch(cache, pin.node) end
		return pin.node.record
	end
	local nodes = cache.nodes[askey]
	local node = nodes and nodes[hostkey]
	if not node then
		if cache.count>=cache.capacity then evict(cache) end
		if not autostate then autostate = {} end
		local bucket = autostate[askey]
		if not bucket then bucket = {}; autostate[askey] = bucket end
		local record = bucket[hostkey]
		if not record then record = {}; bucket[hostkey] = record end
		nodes = cache.nodes[askey]
		if not nodes then nodes = {}; cache.nodes[askey] = nodes end
		node = {askey=askey, hostkey=hostkey, record=record}
		nodes[hostkey], cache.count = node, cache.count+1
	end
	touch(cache, node)
	if state then state.ring_host_pin = {token=cache.token, askey=askey, hostkey=hostkey, node=node} end
	return node.record
end

local function get(cache, desync)
	local askey, hostkey = resolve(desync)
	return lookup(cache, desync, askey, hostkey)
end

-- Тот же штатный индекс, но ключ уже вычислен: custom callback нельзя вызывать дважды.
local function upstream_resolved(askey, hostkey)
	if not autostate then autostate = {} end
	if not autostate[askey] then autostate[askey] = {} end
	if not autostate[askey][hostkey] then autostate[askey][hostkey] = {} end
	return autostate[askey][hostkey]
end

function ring_host_cache.new(capacity)
	if capacity==nil then capacity = MAX_HOSTS end
	assert(type(capacity)=="number" and capacity>=1 and capacity<=MAX_HOSTS and capacity%1==0, "invalid host cache capacity")
	return {capacity=capacity, count=0, nodes={}, token={}, get=get}
end

local cache = ring_host_cache.new()
local disabled = false
function automate_host_record(desync)
	if disabled or desync.arg.hostcache~="bounded" then return upstream_host_record(desync) end
	local askey, hostkey = resolve(desync)
	if not hostkey then return nil end
	local ok, record = pcall(lookup, cache, desync, askey, hostkey)
	if ok then return record end
	-- Штатный путь остаётся доступен при неожиданном сбое собственного слоя.
	disabled, cache = true, nil
	DLOG_ERR("host cache: "..tostring(record)..". using standard host records")
	return upstream_resolved(askey, hostkey)
end
