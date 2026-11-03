"""Compare ring learning on a deterministic virtual filesystem. No network or disk I/O in workload."""
import argparse
import hashlib
import json
from pathlib import Path
import statistics
import sys
import time

parser = argparse.ArgumentParser()
parser.add_argument('--pkg', type=Path, required=True)
parser.add_argument('--baseline', type=Path, required=True)
parser.add_argument('--baseline-ref')
parser.add_argument('--runtime', required=True)
parser.add_argument('--out', type=Path, required=True)
parser.add_argument('--hosts', type=int, default=1000)
parser.add_argument('--rounds', type=int, default=7)
parser.add_argument('--warm', type=int, default=10000)
args = parser.parse_args()
if not 1 <= args.hosts <= 2000 or not 1 <= args.rounds <= 30 or not 1 <= args.warm <= 100000:
    parser.error('hosts 1..2000, rounds 1..30, warm 1..100000 required')
sys.path.insert(0, args.runtime)
from lupa import LuaRuntime, __version__ as lupa_version

fixture = r'''
local real_time=os.time
local now,mono=real_time()+10,0
local network,composition=string.rep('A',64),string.rep('C',24)
local state='ring-general-'..composition:lower()..'-abc123.txt'
local file='root/'..state:sub(1,-5)..'-'..network..'.txt'
local files,timers={},{}
local writes,bytes=0,0
os.time=function() return now end
os.getenv=function(name) if name=='WRITABLE' then return 'root' end end
clock_getfloattime=function() return mono end
getpid=function() return 42 end
DLOG=function() end;DLOG_ERR=function() end
readfile=function(path) if not files[path] then error('missing') end;return files[path] end
writefile=function(path,text) writes=writes+1;bytes=bytes+#text;files[path]=text end
os.rename=function(from,to) files[to]=files[from];files[from]=nil;return true end
os.remove=function(path) files[path]=nil;return true end
timer_set=function(name,callback,ms) timers[name]={callback=callback,at=mono+ms/1000} end
standard_success_detector=function() return true end
automate_host_record=function(d) return d.host_record end
standard_hostkey=function(d) return d.testkey end
files['root/network-context.txt']='3 '..now..' '..network..' '..composition..'\n'
local function packet(host,key)
    return {arg={key='bench',state=state,context='network-context.txt'},host_record=host,testkey=key,
        func_instance='bench',outgoing=true,track={lua_state={}},dis={tcp={},payload='hello'},target={}}
end
function run_burst(count)
    for i=1,count do
        local host={nstrategy=1,ctstrategy=3}
        local d=packet(host,'host'..i..'.example')
        assert(ring_success(d,{}))
        host.nstrategy=2
        assert(ring_success(d,{}))
    end
    return writes,bytes
end
function run_flush(count)
    now,mono=now+5,mono+5
    local ready={}
    for name,timer in pairs(timers) do if timer.at<=mono then ready[name]=timer;timers[name]=nil end end
    for name,timer in pairs(ready) do timer.callback(name) end
    local text=files[file] or ''
    local saved=0
    for line in text:gmatch('[^\n]+') do if line:match('^host%d+%.example 2') then saved=saved+1 end end
    assert(saved==count,'saved choices differ: '..saved..' / '..count)
    return writes,bytes,#text
end
function run_steady(count)
    local before=writes
    local host={nstrategy=1,ctstrategy=3}
    local d=packet(host,'host1.example')
    for i=1,count do assert(ring_success(d,{}) and host.nstrategy==2) end
    assert(writes==before,'steady choices unexpectedly write state')
end
'''
baseline = args.baseline.read_text(encoding='utf-8-sig')
current = (args.pkg / 'lua/autoring.lua').read_text(encoding='utf-8-sig')
store_source = (args.pkg / 'lua/ring-store.lua').read_text(encoding='utf-8-sig')


def run(source, helper):
    samples = []
    version = None
    for _ in range(args.rounds):
        lua = LuaRuntime(unpack_returned_tuples=True)
        if helper:
            lua.execute(helper)
        lua.execute(source)
        lua.execute(fixture)
        version = lua.eval('_VERSION')
        heap = lua.eval("function() collectgarbage('collect'); return collectgarbage('count') end")
        heap_before = heap()
        start = time.process_time_ns()
        wall = time.perf_counter_ns()
        burst_writes, burst_bytes = lua.globals().run_burst(args.hosts)
        burst_wall_ms = (time.perf_counter_ns() - wall) / 1e6
        burst_ms = (time.process_time_ns() - start) / 1e6
        start = time.process_time_ns()
        wall = time.perf_counter_ns()
        final_writes, final_bytes, snapshot_bytes = lua.globals().run_flush(args.hosts)
        flush_wall_ms = (time.perf_counter_ns() - wall) / 1e6
        flush_ms = (time.process_time_ns() - start) / 1e6
        start = time.process_time_ns()
        wall = time.perf_counter_ns()
        lua.globals().run_steady(args.warm)
        warm_wall_ms = (time.perf_counter_ns() - wall) / 1e6
        warm_cpu_ms = (time.process_time_ns() - start) / 1e6
        heap_after = heap()
        samples.append(dict(burst_cpu_ms=burst_ms, flush_cpu_ms=flush_ms, burst_wall_ms=burst_wall_ms, flush_wall_ms=flush_wall_ms,
                            warm_cpu_ms=warm_cpu_ms, warm_wall_ms=warm_wall_ms,
                            lua_heap_before_kib=heap_before, lua_heap_after_kib=heap_after, lua_heap_growth_kib=heap_after-heap_before,
                            burst_write_calls=burst_writes, total_write_calls=final_writes,
                            burst_bytes=burst_bytes, total_bytes=final_bytes, snapshot_bytes=snapshot_bytes))
    return dict(lua_version=version, samples=samples,
                median_burst_cpu_ms=statistics.median(s['burst_cpu_ms'] for s in samples),
                median_flush_cpu_ms=statistics.median(s['flush_cpu_ms'] for s in samples),
                median_burst_wall_ms=statistics.median(s['burst_wall_ms'] for s in samples),
                median_flush_wall_ms=statistics.median(s['flush_wall_ms'] for s in samples),
                median_warm_wall_ms=statistics.median(s['warm_wall_ms'] for s in samples),
                median_lua_heap_growth_kib=statistics.median(s['lua_heap_growth_kib'] for s in samples))


result = dict(kind='synthetic virtual filesystem; no packets, network, or physical disk',
              hosts=args.hosts, rounds=args.rounds, warm=args.warm, lupa_version=lupa_version,
              baseline_ref=args.baseline_ref,
              cpu_note='Windows process CPU accounting is quantized; zero does not mean zero work.',
              baseline_sha256=hashlib.sha256(args.baseline.read_bytes()).hexdigest(),
              current_sha256={name: hashlib.sha256((args.pkg / 'lua' / name).read_bytes()).hexdigest()
                              for name in ('autoring.lua', 'ring-store.lua')},
              baseline=run(baseline, None), current=run(current, store_source))
assert all(s['burst_write_calls'] == args.hosts for s in result['baseline']['samples'])
assert all(s['burst_write_calls'] == 0 and s['total_write_calls'] == 1 for s in result['current']['samples'])
args.out.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
for name in ('baseline', 'current'):
    row = result[name]
    print(f"{name}: burst wall median {row['median_burst_wall_ms']:.3f} ms; "
          f"flush {row['median_flush_wall_ms']:.3f} ms; "
          f"warm {row['median_warm_wall_ms']:.3f} ms; heap +{row['median_lua_heap_growth_kib']:.1f} KiB; "
          f"writes {row['samples'][0]['burst_write_calls']} -> {row['samples'][0]['total_write_calls']}")
