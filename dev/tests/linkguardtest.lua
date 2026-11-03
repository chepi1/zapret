local fails=0
local function check(name,ok) print((ok and 'ok ' or 'FAIL ')..name);if not ok then fails=fails+1 end end
check('link guard parser exists',type(ring_link_guard)=='function')
if type(ring_link_guard)=='function' then
    local event,until_time=ring_link_guard('1 105 100 120\n',106,90)
    check('fresh bounded disruption accepted',event==100 and until_time==120)
    check('expired heartbeat cannot freeze fallback',ring_link_guard('1 100 100 120\n',111,90)==nil)
    check('pre-start future malformed and overlong records rejected',ring_link_guard('1 100 100 120\n',105,100)==nil and ring_link_guard('1 110 100 120\n',105,90)==nil and ring_link_guard('1 105 110 120\n',106,90)==nil and ring_link_guard('1 105 100 126\n',106,90)==nil and ring_link_guard(string.rep('1',65),106,90)==nil)
    check('settled heartbeat keeps incident identity without extending pause',ring_link_guard('1 125 100 120\n',126,90)==100)
    check('pause without an incident and incident without a window rejected',ring_link_guard('1 105 0 120\n',106,90)==nil and ring_link_guard('1 105 100 0\n',106,90)==nil)
    local real_time,real_getenv=os.time,os.getenv
    local now,mono=real_time()+30,0
    local marker='1 '..now..' 0 0\n'
    os.time=function() return now end
    os.getenv=function(name) if name=='WRITABLE' then return 'root' end;return real_getenv(name) end
    local reads=0
    readfile=function(path) assert(path=='root/link-guard.txt');reads=reads+1;return marker end
    clock_getfloattime=function() return mono end
    DLOG=function() end;DLOG_ERR=function(message) error(message) end
    standard_hostkey=function() return 'link.test' end
    automate_host_record=function(d) return d.host_record end
    standard_success_detector=function() return false end
    local failure_calls=0
    standard_failure_detector=function() failure_calls=failure_calls+1;return true end
    local host={nstrategy=2,ctstrategy=3,failure_counter=0}
    local function packet(guard)
        return {arg={key='link-fixture',link_guard=guard and 'link-guard.txt' or nil},host_record=host,func_instance='fixture',outgoing=true,track={lua_state={},pos={reverse={tcp={seq0=0}}}},dis={tcp={th_ack=0},payload='hello'},target={}}
    end
    local old=packet(true);local old_conn={}
    ring_success(old,old_conn)
    check('stable network uses existing detector',ring_failure(packet(true),{})==true and failure_calls==1)
    now,mono=now+2,mono+2
    local incident=now
    marker='1 '..now..' '..incident..' '..(incident+20)..'\n'
    local during=packet(true);local during_conn={}
    local calls_before=failure_calls
    check('outage suppresses failure accounting without changing chosen strategy',ring_failure(during,during_conn)==false and failure_calls==calls_before and host.nstrategy==2)
    check('old connection is excluded after a confirmed incident',ring_failure(old,old_conn)==false and old_conn.nocheck==true)
    local read_before=reads
    for i=1,1000 do ring_failure(packet(true),{}) end
    check('per-packet detectors do not repeatedly read the guard file',reads==read_before)
    now,mono=now+21,mono+21
    marker='1 '..now..' '..incident..' '..(incident+20)..'\n'
    calls_before=failure_calls
    check('new connection resumes normal learning after bounded pause',ring_failure(packet(true),{})==true and failure_calls==calls_before+1)
    calls_before=failure_calls
    check('late failure from a tainted connection stays excluded after recovery',ring_failure(during,during_conn)==false and failure_calls==calls_before)
    local clean_old=packet(true);local clean_conn={};ring_success(clean_old,clean_conn)
    now,mono=now+2,mono+2;incident=now
    marker='1 '..now..' '..incident..' '..(incident+20)..'\n'
    ring_success(packet(true),{})
    now,mono=now+21,mono+21
    marker='1 '..now..' '..incident..' '..(incident+20)..'\n'
    check('connection spanning an incident cannot fail late into clean history',ring_failure(clean_old,clean_conn)==false)
    now,mono=now+2,mono+2;incident=now
    marker='1 '..now..' '..incident..' '..(incident+20)..'\n'
    ring_success(packet(true),{})
    now,mono=now+11,mono+11
    check('stopped publisher cannot keep new connections paused',ring_failure(packet(true),{})==true)
    now,mono=now+2,mono+2;marker='corrupt'
    check('corrupt marker preserves ordinary fallback',ring_failure(packet(true),{})==true)
    marker='1 '..now..' '..now..' '..(now+20)..'\n';mono=mono+2
    check('legacy profiles do not inherit another profile guard',ring_failure(packet(false),{})==true)
    os.time,os.getenv=real_time,real_getenv
end
io.stdout:flush();os.exit(fails>0 and 1 or 0)
