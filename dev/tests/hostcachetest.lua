local fails=0
local function check(name,ok) print((ok and 'ok ' or 'FAIL ')..name);if not ok then fails=fails+1 end end
local warnings=0
DLOG=function() end;DLOG_ERR=function() warnings=warnings+1 end
host_ip=function(desync) return desync.test_ip end
pos_get=function() return 0 end
readfile=function() error('unexpected file read') end
writefile=function() error('unexpected file write') end
timer_set=function() error('unexpected timer') end
local function make(host,bucket,state)
    return {arg={key=bucket or 'general',hostcache='bounded'},func_instance='circular_fixture',outgoing=true,
        track={hostname=host,lua_state=state or {}},dis={tcp={},payload='request'}}
end
local function count(t) local n=0;for _ in pairs(t or {}) do n=n+1 end;return n end
check('bounded host cache module exists',type(ring_host_cache)=='table' and type(ring_host_cache.new)=='function')
if type(ring_host_cache)~='table' then
    autostate={}
    for i=1,5000 do automate_host_record(make('host'..i..'.test')) end
    check('learned host index remains bounded after churn',count(autostate.general)<=4096)
    io.stdout:flush();os.exit(1);return
end
for _,bad in ipairs({0,-1,4097,1.5,'4',false}) do check('invalid cache limit rejected',not pcall(ring_host_cache.new,bad)) end
do
    autostate={};local c=ring_host_cache.new(4)
    for i=1,20 do c:get(make('host'..i)) end
    check('churn bounds both LRU metadata and upstream host index',c.count==4 and count(autostate.general)==4)
end
do
    autostate={};local c=ring_host_cache.new(2)
    local a=make('a');local first=c:get(a);first.nstrategy=3
    local shared=c:get(make('a'))
    c:get(make('b'));c:get(a);c:get(make('c'))
    check('recent access protects a shared host state',shared==first and autostate.general.a==first and autostate.general.b==nil)
    c:get(make('d'));c:get(make('e'))
    check('eviction detaches only the indexed soft state',autostate.general.a==nil and first.ring_cache_evicted==true and c.count==2)
    check('an active connection keeps its existing strategy',c:get(a)==first and first.nstrategy==3)
    local replacement=c:get(make('a'));replacement.nstrategy=1
    check('new connection gets a fresh current host state',replacement~=first and autostate.general.a==replacement)
    check('old connection cannot replace the new indexed state',c:get(a)==first and autostate.general.a==replacement)
end
do
    autostate={};local c=ring_host_cache.new(1)
    local old=c:get(make('old'));local replacement={nstrategy=2};autostate.general.old=replacement
    c:get(make('new'))
    check('eviction preserves records replaced by another caller',autostate.general.old==replacement and old.ring_cache_evicted)
end
do
    autostate={};local c=ring_host_cache.new(2)
    local a=c:get(make('same','general'));local b=c:get(make('same','google'))
    check('profile namespaces do not share a host strategy',a~=b)
    for i=1,15 do c:get(make('host','bucket'..i)) end
    check('empty buckets cannot accumulate past the global capacity',c.count==2 and count(autostate)==2 and count(c.nodes)==2)
end
do
    autostate={};local c=ring_host_cache.new(4);local d=make(nil);d.test_ip='203.0.113.1'
    local iprec=c:get(d);d.track.hostname='named.test';local named=c:get(d)
    check('hostname discovery replaces an IP-only pin',named~=iprec and c:get(d)==named)
    check('unknown host creates no cache entry',c:get(make(nil))==nil and c.count==2)
    local required=make(nil);required.test_ip='203.0.113.2';required.arg.reqhost=true
    check('reqhost still rejects IP-only records',c:get(required)==nil and c.count==2)
    local calls=0
    fixture_hostkey=function() calls=calls+1;return 'custom' end
    local custom=make('ignored');custom.arg.hostkey='fixture_hostkey'
    local one=c:get(custom);local two=c:get(custom)
    check('custom hostkey executes exactly once per lookup',calls==2 and one==two)
    custom.arg.hostkey='not_a_hostkey_function'
    check('invalid custom hostkey retains upstream validation',not pcall(c.get,c,custom))
end
do
    autostate={};local c=ring_host_cache.new(1);local d=make('old');local old=c:get(d);old.nstrategy=3
    c:get(make('new'))
    local success_calls,failure_calls=0,0
    local saved_success,saved_failure=standard_success_detector,standard_failure_detector
    standard_success_detector=function() success_calls=success_calls+1;return true end
    standard_failure_detector=function() failure_calls=failure_calls+1;return true end
    local crec={ring={strategy=3,hrec=old,key='old'}}
    check('evicted connection cannot teach an obsolete success',not ring_success(d,crec) and crec.nocheck==true and success_calls==0)
    crec.nocheck=false
    check('evicted connection cannot teach an obsolete failure',not ring_failure(d,crec) and crec.nocheck==true and failure_calls==0)
    standard_success_detector,standard_failure_detector=saved_success,saved_failure
end
do
    autostate={}
    local invalid=make('invalid');invalid.arg.hostkey='not_a_hostkey_function'
    check('invalid callback retains upstream error without disabling the cache',not pcall(automate_host_record,invalid) and warnings==0)
    for i=1,9000 do automate_host_record(make('bounded'..i)) end
    check('opt-in wrapper uses the production capacity',count(autostate.general)==4096)
    for i=1,4200 do local d=make('legacy'..i,'legacy');d.arg.hostcache=nil;automate_host_record(d) end
    check('legacy and game paths retain the upstream implementation',count(autostate.legacy)==4200)
end
do
    local function heap(bounded)
        autostate={};collectgarbage('collect');local before=collectgarbage('count')
        local c=bounded and ring_host_cache.new(4096) or nil
        for i=1,50000 do
            local d=make('bench'..i..'.test','bench');d.arg.hostcache=nil
            if c then c:get(d) else automate_host_record(d) end
        end
        collectgarbage('collect')
        return collectgarbage('count')-before,count(autostate.bench)
    end
    local baseline,bn=heap(false);local bounded,cn=heap(true)
    print(string.format('heap fixture: baseline %.1f KiB/%d hosts; bounded %.1f KiB/%d hosts',baseline,bn,bounded,cn))
    check('bounded cache retains less Lua heap during fifty-thousand-host churn',bn==50000 and cn==4096 and bounded<baseline)
end
do
    local flaky=true
    autostate=setmetatable({},{__index=function() if flaky then flaky=false;error('fixture cache failure') end end})
    local d=make('fallback','fallback')
    local calls=0
    fixture_fallback_key=function() calls=calls+1;return 'fallback'..calls end
    d.arg.hostkey='fixture_fallback_key'
    local record=automate_host_record(d)
    check('fallback reuses the custom key without calling its generator twice',calls==1 and record==autostate.fallback.fallback1 and autostate.fallback.fallback2==nil)
    check('one cache failure falls back to the standard host record',record==autostate.fallback.fallback1 and warnings==1)
    local again=automate_host_record(make('fallback1','fallback'))
    check('fallback does not repeatedly log or corrupt the record',again==record and warnings==1)
end
if fails==0 then print('all host cache checks passed') end
io.stdout:flush();os.exit(fails==0 and 0 or 1)
