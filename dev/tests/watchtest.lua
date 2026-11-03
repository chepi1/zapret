local fails=0
local function check(name,ok) print((ok and 'ok ' or 'FAIL ')..name);if not ok then fails=fails+1 end end
local a=string.rep('A',64)
local config=string.rep('C',24)
local state='ring-general-'..config:lower()..'-abc.txt'
check('network marker parser exists',type(ring_network_key)=='function')
if type(ring_network_key)=='function' then
    check('fresh marker accepted',ring_network_key('3 100 '..a..' '..config..'\n',105,90)==a)
    check('expired watchdog fails closed',ring_network_key('3 100 '..a..' '..config..'\n',121,90)==nil)
    check('marker predating process cannot unlock memory',ring_network_key('3 100 '..a..' '..config..'\n',105,100)==nil)
    check('future marker rejected',ring_network_key('3 110 '..a..' '..config..'\n',105,90)==nil)
    check('unknown marker rejected',ring_network_key('3 0 - -\n',105,90)==nil)
    check('corrupt marker rejected',ring_network_key('garbage',105,90)==nil)
    check('path injection rejected',ring_network_key('3 100 ../../other '..config..'\n',105,90)==nil)
    check('network-specific state files differ',ring_state_path('root','ring-general-abc.txt',a)~=ring_state_path('root','ring-general-abc.txt',string.rep('B',64)))
    check('unknown context has no disk state path',ring_state_path('root','ring-general-abc.txt',nil)==nil)
    check('state filename cannot escape writable directory',ring_state_path('root','../escape.txt',a)==nil)
end
-- Exercise real ring detectors against a virtual filesystem; no packets or network are used.
if type(ring_network_key)=='function' then
    local real_time, real_getenv = os.time, os.getenv
    local now, mono = os.time()+10, 0
    os.time=function() return now end
    os.getenv=function(name) if name=='WRITABLE' then return 'root' end;return real_getenv(name) end
    clock_getfloattime=function() return mono end
    DLOG=function() end;DLOG_ERR=function() end
    standard_success_detector=function() return true end
    automate_host_record=function(d) return d.host_record end
    standard_hostkey=function() return 'example.test' end
    local b=string.rep('B',64)
    local state_a=ring_state_path('root',state,a)
    local state_b=ring_state_path('root',state,b)
    local files={[state_a]='example.test 2\n',[state_b]='example.test 3\n'}
    local writes=0
    readfile=function(path) if not files[path] then error('missing') end;return files[path] end
    writefile=function(path,text) files[path]=text;writes=writes+1 end
    local host={nstrategy=1,ctstrategy=3}
    local function packet()
        return {arg={key='watch-fixture',state=state,context='network-context.txt'},host_record=host,
            func_instance='fixture',outgoing=true,track={lua_state={}},dis={tcp={},payload='hello'},target={}}
    end
    files['root/network-context.txt']='3 '..now..' '..a..' '..config..'\n'
    local old=packet();local old_conn={}
    check('network A loads only its remembered strategy',ring_success(old,old_conn)==true and host.nstrategy==2)
    now=now+1;mono=mono+2;files['root/network-context.txt']='3 '..now..' '..b..' '..config..'\n'
    check('network B resets host state and loads its own memory',ring_success(packet(),{})==true and host.nstrategy==3)
    check('old connection cannot update another network memory',ring_success(old,old_conn)==false and writes==0)
    host.nstrategy=2;ring_success(packet(),{})
    check('successful choice persists only into active network file',writes==1 and files[state_b]:find('example.test 2',1,true) and files[state_a]=='example.test 2\n')
    now=now+21;mono=mono+2
    check('watchdog expiry clears learned host hints',ring_success(packet(),{})==true and host.nstrategy==1)
    host.nstrategy=3;ring_success(packet(),{})
    check('expired watchdog prevents disk writes while RAM learning continues',writes==1 and host.nstrategy==3)
    now=now+1;mono=mono+2;files['root/network-context.txt']='3 '..now..' '..a..' '..config..'\n'
    check('returning network restores its own persisted choice',ring_success(packet(),{})==true and host.nstrategy==2)
    now=now+1;mono=mono+2;files['root/network-context.txt']='3 '..now..' '..a..' '..string.rep('D',24)..'\n'
    local previous_writes=writes
    check('changed disk composition cannot reuse memory of loaded process',ring_success(packet(),{})==true and host.nstrategy==1)
    host.nstrategy=3;ring_success(packet(),{})
    check('old loaded composition cannot save hints for new disk configuration',writes==previous_writes)
    os.time, os.getenv = real_time, real_getenv
end
io.stdout:flush();os.exit(fails>0 and 1 or 0)
