-- Bounded contextual hints. Packet callbacks only change RAM; one timer publishes one snapshot.
ring_store = {}
local HEADER = "# ring-store-v2\n"
local MAX_RECORDS, MAX_BYTES, TTL = 2000, 262144, 30*24*60*60
local SAVE_DELAY, RETRY_DELAY = 5, 30
local pending, scheduled, serial = {}, false, 0
local timer_retry_at, timer_failed_at
local schedule, dispatch

local function log(text)
    if type(DLOG_ERR)=="function" then pcall(DLOG_ERR,"ring store: "..tostring(text)) end
end
local function unlink(store, key)
    local record = store.records[key]
    if not record then return end
    if record.prev then store.records[record.prev].next=record.next else store.head=record.next end
    if record.next then store.records[record.next].prev=record.prev else store.tail=record.prev end
end
local function remove(store, key)
    if not store.records[key] then return end
    unlink(store,key);store.records[key]=nil;store.count=store.count-1
end
local function touch(store, key, now)
    local record=store.records[key]
    if store.head~=key then
        unlink(store,key)
        record.prev=nil;record.next=store.head
        if store.head then store.records[store.head].prev=key else store.tail=key end
        store.head=key
    end
    record.used=now
end
local function mark_dirty(store)
    if not store.file or store.disabled then return end
    if not store.dirty then store.dirty=true;store.since=clock_getfloattime() end
    pending[store]=true
    schedule()
end
local function expired(store, record, now)
    return record.confirmed>now or now-record.confirmed>=store.ttl
end
local function publish(store, mono)
    local ok,valid=pcall(store.validate)
    if not ok or valid~=true then store.disabled=true;store.dirty=false;return end
    local now=store.now()
    local key=store.tail
    while key do
        local previous=store.records[key].prev
        if expired(store,store.records[key],now) then remove(store,key) end
        key=previous
    end
    local lines,bytes={HEADER},#HEADER
    key=store.head
    while key do
        local record=store.records[key]
        local line=key.." "..record.n.." "..record.confirmed.." "..record.used.."\n"
        if bytes+#line<=store.maxbytes then lines[#lines+1]=line;bytes=bytes+#line end
        key=record.next
    end
    ok,valid=pcall(function()
        local text=table.concat(lines)
        writefile(store.temp,text)
        if readfile(store.temp)~=text then error("incomplete temporary snapshot") end
        local moved,err=os.rename(store.temp,store.file)
        if not moved then error(err or "rename failed") end
    end)
    if ok then
        store.dirty=false;store.retry=nil
    else
        pcall(os.remove,store.temp)
        store.retry=mono+RETRY_DELAY
        log(tostring(valid).."; retry in "..RETRY_DELAY.."s")
    end
end
dispatch=function()
    local mono=clock_getfloattime()
    local selected,due
    for store in pairs(pending) do
        if not store.dirty or store.disabled then pending[store]=nil
        else
            if mono<store.since then store.since=mono;store.retry=nil end
            local ready=math.max(store.since+SAVE_DELAY,store.retry or -math.huge)
            if ready<=mono and (not selected or ready<due or (ready==due and store.serial<selected.serial)) then selected,due=store,ready end
        end
    end
    if selected then
        local ok,err=pcall(publish,selected,mono)
        if not ok then selected.retry=mono+RETRY_DELAY;log(err) end
        if not selected.dirty or selected.disabled then pending[selected]=nil end
    end
end
schedule=function()
    if scheduled then return end
    local now=clock_getfloattime()
    if timer_failed_at and now<timer_failed_at then timer_failed_at=now;timer_retry_at=now+RETRY_DELAY end
    if timer_retry_at and now<timer_retry_at then pending={};return end
    local ok,err=pcall(function()
        if type(timer_set)~="function" then error("timer API unavailable") end
        return timer_set("ring_store_flush_v2",function()
            scheduled=false
            local success,message=pcall(dispatch)
            if not success then log(message);pending={} end
            if next(pending) then schedule() end
        end,1000,true)
    end)
    if ok and err~=false then scheduled=true;timer_retry_at=nil;timer_failed_at=nil
    else
        timer_failed_at=now;timer_retry_at=now+RETRY_DELAY
        -- Do not retain abandoned stores if the timer API is unavailable. A later change can retry.
        for store in pairs(pending) do if not store.timer_warned then store.timer_warned=true;log(err) end end
        pending={}
    end
end

local methods={}
function methods:discard()
    self.disabled=true;self.dirty=false;pending[self]=nil
end
function methods:get(key)
    local record=self.records[key]
    if not record then return nil end
    local now=self.now()
    if expired(self,record,now) then remove(self,key);mark_dirty(self);return nil end
    touch(self,key,now)
    return record.n
end
function methods:put(key,n)
    if type(key)~="string" or #key==0 or #key>255 or key:find("%s") then return false end
    if n~=nil and (type(n)~="number" or n%1~=0 or n<2 or n>128) then return false end
    local record=self.records[key]
    if not n then
        if not record then return false end
        remove(self,key);mark_dirty(self);return true
    end
    local now=self.now()
    if record then
        local changed=record.n~=n or now<record.confirmed or now-record.confirmed>=60
        touch(self,key,now)
        if changed then record.n=n;record.confirmed=now;mark_dirty(self) end
        return changed
    end
    if self.count>=self.maxrecords then remove(self,self.tail) end
    record={n=n,confirmed=now,used=now,next=self.head}
    self.records[key]=record;self.count=self.count+1
    if self.head then self.records[self.head].prev=key else self.tail=key end
    self.head=key
    mark_dirty(self)
    return true
end
local function limit(value,default,minimum,maximum)
    value=value or default
    assert(type(value)=="number" and value%1==0 and value>=minimum and value<=maximum,"invalid ring store limit")
    return value
end
function ring_store.new(options)
    options=options or {}
    serial=serial+1
    local store=setmetatable({records={},count=0,serial=serial,file=options.file,validate=options.validate or function() return false end,
        now=options.now or function() return os.time() end,
        maxrecords=limit(options.maxrecords,MAX_RECORDS,1,MAX_RECORDS),maxbytes=limit(options.maxbytes,MAX_BYTES,64,MAX_BYTES),
        ttl=limit(options.ttl,TTL,1,TTL)},{__index=methods})
    if not store.file then return store end
    store.temp=store.file..".tmp-"..tostring(type(getpid)=="function" and getpid() or 0)
    local ok,text=pcall(readfile,store.file)
    if not ok then return store end
    if type(text)~="string" or #text>store.maxbytes or text:sub(1,#HEADER)~=HEADER then store.disabled=true;return store end
    local now=store.now()
    for line in text:sub(#HEADER+1):gmatch("[^\r\n]+") do
        local key,n,confirmed,used=line:match("^(%S+) (%d+) (%d+) (%d+)$")
        n,confirmed,used=tonumber(n),tonumber(confirmed),tonumber(used)
        if key and #key<=255 and n>=2 and n<=128 and confirmed>0 and used>=confirmed and used<=now and now-confirmed<store.ttl and not store.records[key] then
            if store.count>=store.maxrecords then break end
            local record={n=n,confirmed=confirmed,used=used,prev=store.tail}
            store.records[key]=record;store.count=store.count+1
            if store.tail then store.records[store.tail].next=key else store.head=key end
            store.tail=key
        end
    end
    return store
end
