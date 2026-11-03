local fails=0
local function check(name,ok) print((ok and 'ok ' or 'FAIL ')..name);if not ok then fails=fails+1 end end
check('ring store module exists',type(ring_store)=='table' and type(ring_store.new)=='function')
if type(ring_store)~='table' then io.stdout:flush();os.exit(1);return end

local real_time,real_rename,real_remove=os.time,os.rename,os.remove
local mono,epoch=0,1700000000
local files,timers={},{}
local writes,commits,timer_attempts=0,0,0
local fail_rename,fail_write,fail_timer,partial_write=false,false,false,false
clock_getfloattime=function() return mono end
os.time=function() return epoch+math.floor(mono) end
DLOG=function() end;DLOG_ERR=function() end
getpid=function() return 42 end
readfile=function(path) if files[path]==nil then error('missing') end;return files[path] end
writefile=function(path,text) writes=writes+1;if fail_write then error('write denied') end;files[path]=partial_write and 'partial' or text end
os.rename=function(from,to) if fail_rename then return nil,'rename denied' end;files[to]=files[from];files[from]=nil;commits=commits+1;return true end
os.remove=function(path) files[path]=nil;return true end
timer_set=function(name,callback,ms,oneshot,data)
    timer_attempts=timer_attempts+1
    if fail_timer then error('timer unavailable') end
    assert(oneshot and ms>0)
    timers[name]={at=mono+ms/1000,callback=callback,data=data}
end
local function advance(seconds)
    local target=mono+seconds
    while true do
        local name,event
        for k,v in pairs(timers) do if v.at<=target and (not event or v.at<event.at) then name,event=k,v end end
        if not event then break end
        timers[name]=nil;mono=event.at;event.callback(name,event.data)
    end
    mono=target
end
local function reset_counts() advance(40);writes,commits=0,0 end
local function store(file,options)
    options=options or {};options.file=file;options.validate=options.validate or function() return true end
    return ring_store.new(options)
end
local function row(key,n,confirmed,used) return key..' '..n..' '..confirmed..' '..used..'\n' end

local s=store('burst.txt',{maxrecords=3})
s:put('a.example',2);s:put('b.example',3);s:put('c.example',2)
check('learning updates RAM without synchronously writing files',writes==0 and s:get('a.example')==2 and s.count==3)
advance(4);check('burst does not flush before five seconds',writes==0)
advance(1);check('burst publishes one atomic snapshot',writes==1 and commits==1 and files['burst.txt']:find('# ring-store-v2\n',1,true)==1)
s:get('a.example');s:put('d.example',3)
check('full cache evicts only least recently used record',s.count==3 and s:get('b.example')==nil and s:get('a.example')==2 and s:get('c.example')==2 and s:get('d.example')==3)
advance(5)
local reloaded=store('burst.txt',{maxrecords=3})
check('saved TTL and strategy survive reload',reloaded.count==3 and reloaded:get('a.example')==2 and reloaded:get('d.example')==3)
reset_counts()
local a,b=store('circle-a.txt'),store('circle-b.txt')
a:put('a',2);b:put('b',2)
advance(5);check('one timer callback writes at most one dirty circle',commits==1)
advance(1);check('another dirty circle is eventually saved',commits==2)
reset_counts()
local streaming=store('streaming.txt');streaming:put('first.example',2)
advance(4);streaming:put('later.example',3);advance(1)
check('continuous learning does not postpone original flush deadline',commits==1 and files['streaming.txt']:find('later.example 3 ',1,true)~=nil)
reset_counts()
for i=1,12 do
    local obsolete=store('obsolete'..i..'.txt',{validate=function() return false end})
    obsolete:put('old.example',2)
    if obsolete.discard then obsolete:discard() end
end
local active=store('active.txt');active:put('active.example',3);advance(5)
check('discarded contexts do not retain or delay active pending snapshot',commits==1 and files['active.txt']~=nil)
reset_counts()
local valid=true
local scoped=store('scoped.txt',{validate=function() return valid end})
scoped:put('scoped.example',2);valid=false
advance(6)
check('network change before flush discards pending disk write',writes==0 and files['scoped.txt']==nil and scoped:get('scoped.example')==2)
reset_counts()
local now=os.time()
files['ages.txt']='# ring-store-v2\n'..row('expired',2,now-11,now-1)..row('future',2,now+1,now+1)..row('fresh',3,now-5,now-1)..row('zero',0,now,now)..row('fresh',2,now,now)
local ages=store('ages.txt',{ttl=10})
check('expired future invalid and duplicate records do not become trusted hints',ages.count==1 and ages:get('expired')==nil and ages:get('future')==nil and ages:get('zero')==nil and ages:get('fresh')==3)
advance(5)
check('TTL removes a stale hint from RAM',ages:get('fresh')==nil and ages.count==0)
reset_counts()
files['unknown.txt']='old.example 2\n'
local unknown=store('unknown.txt');unknown:put('new.example',2);advance(6)
check('unversioned guarded file remains untouched',unknown:get('old.example')==nil and unknown:get('new.example')==2 and files['unknown.txt']=='old.example 2\n' and writes==0)
files['oversized.txt']=string.rep('x',262145)
local oversized=store('oversized.txt');oversized:put('new.example',2);advance(6)
check('oversized state is neither loaded nor overwritten',oversized.count==1 and #files['oversized.txt']==262145 and writes==0)
reset_counts()
local budget=store('budget.txt',{maxbytes=180})
for i=1,10 do budget:put(string.rep('x',65)..i..'.example',2) end
advance(5)
local budget_reload=store('budget.txt',{maxbytes=180})
check('disk byte budget keeps most recently used hints',#files['budget.txt']<=180 and budget_reload:get(string.rep('x',65)..'10.example')==2 and budget.count==10)
reset_counts()
local old='# ring-store-v2\n'..row('old.example',2,os.time(),os.time())
files['retry.txt']=old
local retry=store('retry.txt');retry:put('new.example',3);fail_rename=true
advance(5)
check('rename failure preserves old file and RAM learning',files['retry.txt']==old and retry:get('new.example')==3 and writes==1 and commits==0)
advance(29);check('failed save does not retry for thirty seconds',writes==1)
fail_rename=false;advance(1)
check('transient save failure is retried after backoff',writes==2 and commits==1 and files['retry.txt']:find('new.example 3 ',1,true)~=nil)
reset_counts()
local denied=store('denied.txt');denied:put('new.example',2);fail_write=true
advance(5)
check('write failure cannot publish partial snapshot',files['denied.txt']==nil and denied:get('new.example')==2 and commits==0)
fail_write=false;reset_counts()
files['partial.txt']=old
local partial=store('partial.txt');partial:put('new.example',2);partial_write=true
advance(5)
check('incomplete temporary file cannot replace last good snapshot',files['partial.txt']==old and commits==0)
partial_write=false;reset_counts()
fail_timer=true
local before_attempts=timer_attempts
local ram=store('ram.txt');local ok=pcall(function() ram:put('ram.example',2) end)
check('unavailable timer keeps adaptation in RAM',ok and writes==0 and ram:get('ram.example')==2)
for i=1,1000 do ram:put('ram'..i..'.example',2) end
check('failed timer scheduling has one shared bounded retry deadline',timer_attempts-before_attempts==1 and writes==0)
fail_timer=false;advance(29);ram:put('early.example',3)
check('timer cooldown is not bypassed by a new learning event',timer_attempts-before_attempts==1)
advance(1);ram:put('next.example',3);advance(5)
check('timer recovery can schedule later persistence',commits==1)
reset_counts()
local bad=store('bad-context.txt',{validate=function() error('context unavailable') end})
bad:put('bad.example',2)
check('failed context callback never escapes timer or writes state',pcall(function() advance(6) end) and writes==0)
local bounded=store(nil)
for i=1,2200 do bounded:put('host'..i,2) end
check('default bound retains two thousand records without resetting all',bounded.count==2000 and bounded:get('host1')==nil and bounded:get('host201')==2 and bounded:get('host2200')==2)
os.time,os.rename,os.remove=real_time,real_rename,real_remove
io.stdout:flush();os.exit(fails>0 and 1 or 0)
