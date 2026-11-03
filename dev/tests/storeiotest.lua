-- Native-only event-loop/file-I/O smoke. The runner uses an empty WinDivert filter.
local file=os.getenv('WRITABLE')..'/store-io.txt'
local current
timer_set('store_io_seed',function()
    local now=os.time()
    writefile(file,'# ring-store-v2\nold.example 2 '..now..' '..now..'\n')
    current=ring_store.new({file=file,validate=function() return true end})
    current:put('new.example',3)
end,100,true)
timer_set('store_io_assert',function()
    local ok,text=pcall(readfile,file)
    local good=ok and text:find('old.example 2 ',1,true) and text:find('new.example 3 ',1,true) and current and current:get('new.example')==3
    print((good and 'ok ' or 'FAIL ')..'native timer atomically replaces existing snapshot after privilege drop')
    io.stdout:flush();os.exit(good and 0 or 1)
end,7500,true)
