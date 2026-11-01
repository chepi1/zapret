-- Проверка lua\autoring.lua и lua\fooling.lua внутри настоящего winws2 (--intercept=0: трафик не перехватывается).
-- Пакеты - имитация, но circular, детекторы, tls_mod и запись файла памяти - настоящие.
local fails = 0
local function check(name, cond)
	print((cond and "ok   " or "FAIL ")..name)
	if not cond then fails = fails+1 end
end

ran = {}
function t_strategy(ctx, desync)
	ran[#ran+1] = tonumber(desync.arg.strategy)
	return VERDICT_PASS
end
local RANGE = { from={mode='a',pos=0}, to={mode='a',pos=0} }
local function plan(n)
	local p = {}
	for i=1,n do
		p[i] = { func="t_strategy", func_n=i+1, func_instance="t_strategy_"..i, arg={strategy=tostring(i)}, payload_filter="all", range=RANGE }
	end
	return p
end

-- начальный номер сервера близко к переполнению: подтверждение должно считаться по модулю 2^32
local SERVER_SEQ0 = 4294967000
local function new_track(host)
	local function side(seq0) return { pcounter=1, pdcounter=0, pbcounter=0, tcp={seq0=seq0, seq=seq0, rseq=0, pos=0, uppos=0, uppos_prev=0} } end
	return { hostname=host, hostname_is_ip=false, l7proto="tls", lua_state={}, pos={ client=side(1000), server=side(SERVER_SEQ0) } }
end
-- o: rseq, len, got (сколько получено от сервера), key, state, ip, flags
local function packet(track, o)
	track.pos.direct = track.pos.client
	track.pos.reverse = track.pos.server
	local d = track.pos.direct.tcp
	local len = o.len or 500
	d.uppos_prev = d.uppos
	d.rseq = o.rseq or 1
	d.pos = d.rseq+len
	if d.pos>d.uppos then d.uppos = d.pos end
	track.pos.direct.pcounter = track.pos.direct.pcounter+1
	return {
		func="circular", func_n=1, func_instance="circular_1", outgoing=true, track=track, l7payload="tls_client_hello",
		arg={ fails="3", time="60", nld="2", key=o.key or "t", state=o.state or "ring-test.txt", success_detector="ring_success", failure_detector="ring_failure" },
		dis={ tcp={ th_flags=o.flags or TH_ACK, th_ack=(SERVER_SEQ0+1+(o.got or 0))%4294967296, th_seq=1001, options={} }, payload=string.rep("x",len) },
		target={ ip=pton(o.ip or "1.2.3.4") }, plan=plan(3),
	}
end
local function send(track, o)
	ran = {}
	circular(nil, packet(track, o))
	return ran[1]
end
-- соединение, в котором клиент трижды повторяет данные: так выглядит блокировка
local function fail_conn(host, o)
	local tr = new_track(host)
	local o2 = o or {}
	local first = send(tr, o2)
	local last
	for i=1,3 do last = send(tr, o2) end
	return first, last, tr
end
local function hrec_of(key, host) return autostate[key] and autostate[key][host] end

-- непроверенной стратегии хватает двух повторов
local r1 = new_track("two-retrans.example")
send(r1, { key="r" })
send(r1, { key="r" })
check("unproven: one retransmission keeps strategy", hrec_of("r","two-retrans.example").nstrategy==1)
send(r1, { key="r" })
check("unproven: two retransmissions rotate", hrec_of("r","two-retrans.example").nstrategy==2)
-- проверенной нужно три повтора на неудачу, и одна неудача её ещё не меняет
local r2 = new_track("proven-retrans.example")
send(r2, { key="r" })
hrec_of("r","proven-retrans.example").ring_ok = 1
send(r2, { key="r" }); send(r2, { key="r" })
check("proven: two retransmissions are no failure", hrec_of("r","proven-retrans.example").failure_counter==nil)
send(r2, { key="r" })
check("proven: three retransmissions are one failure", hrec_of("r","proven-retrans.example").failure_counter==1 and hrec_of("r","proven-retrans.example").nstrategy==1)

-- сервер закрыл TLS-соединение, не ответив на ClientHello
local function inbound_fin(rseq, l7, flags)
	local tr = new_track("fin.example")
	tr.l7proto = l7 or "tls"
	tr.pos.direct, tr.pos.reverse = tr.pos.server, tr.pos.client
	tr.pos.server.tcp.rseq = rseq
	return { func="circular", func_n=1, func_instance="circular_1", outgoing=false, track=tr, l7payload="empty", arg={ fails="3" },
		dis={ tcp={ th_flags=flags or (TH_FIN+TH_ACK), th_ack=0, th_seq=1, options={} }, payload="" }, target={ ip=pton("2.2.2.2") }, plan={} }
end
check("fin right after hello is a failure", ring_failure(inbound_fin(1), {})==true)
check("fin after tls alert is a failure", ring_failure(inbound_fin(8), {})==true)
check("fin after server hello is no failure", ring_failure(inbound_fin(9), {})==false)
check("fin of a plain http reply is no failure", ring_failure(inbound_fin(1, "http"), {})==false)
check("other inbound packets are no failure", ring_failure(inbound_fin(1, "tls", TH_ACK), {})==false)
local fo = inbound_fin(1); fo.outgoing = true
check("outgoing fin is no failure", ring_failure(fo, {})==false)
local fd = inbound_fin(1); fd.dis.payload = string.rep("x", 8)
check("fin carrying a server response is no failure", ring_failure(fd, {})==false)
local fa = inbound_fin(1); fa.dis.payload = string.rep("x", 7)
check("fin carrying only a tls alert is a failure", ring_failure(fa, {})==true)
local fr = inbound_fin(1); fr.track.pos.server.tcp.uppos = 100
check("old fin cannot erase a previously observed response", ring_failure(fr, {})==false)
local function file_of(state)
	local ok, text = pcall(readfile, os.getenv("WRITABLE").."/"..state)
	return ok and text or nil
end

check("WRITABLE is set", os.getenv("WRITABLE")~=nil)

-- новая стратегия меняется с первой неудачи
local first, last = fail_conn("new.example.com")
check("starts from strategy 1", first==1)
check("unproven strategy rotates after one failure", last==2 and hrec_of("t","example.com").nstrategy==2)

-- неудача соединения, начатого при прежней стратегии, не считается
local a, b = new_track("two.example.org"), new_track("two.example.org")
send(a, {}); send(b, {})
for i=1,3 do send(a, {}) end
check("first connection rotated", hrec_of("t","example.org").nstrategy==2)
for i=1,3 do send(b, {}) end
check("old connection's failure is not counted", hrec_of("t","example.org").nstrategy==2)

-- подтверждение: получено больше got байт, в том числе при переполнении номера
local c = new_track("two.example.org")
check("new connection uses rotated strategy", send(c, {})==2)
send(c, { got=20000, len=100, rseq=501 })
check("freeze zone is not a proof", hrec_of("t","example.org").ring_ok==nil)
send(c, { got=30000, len=100, rseq=601 })
check("past the freeze zone is a proof", hrec_of("t","example.org").ring_ok==2)
local text = file_of("ring-test.txt")
check("memory file written by low-integrity process", text and text:find("example.org 2",1,true) and text:find("1.2.3.0/24 2",1,true))

-- Большой исходящий пакет LSO сам по себе не доказывает, что сервер что-либо получил.
local big = new_track("big-packet.example")
send(big, { key="lso", state="ring-lso.txt", ip="3.3.3.3" })
hrec_of("lso","big-packet.example").nstrategy = 2
local big2 = new_track("big-packet.example")
send(big2, { key="lso", state="ring-lso.txt", ip="3.3.3.3", len=40000 })
check("large initial send without a reply is not a proof", hrec_of("lso","big-packet.example").ring_ok==nil)
check("unanswered large send is not saved", (file_of("ring-lso.txt") or ""):find("big-packet.example 2",1,true)==nil)
send(big2, { key="lso", state="ring-lso.txt", ip="3.3.3.3", len=40000 })
send(big2, { key="lso", state="ring-lso.txt", ip="3.3.3.3", len=40000 })
check("unanswered large send still rotates on retransmissions", hrec_of("lso","big-packet.example").nstrategy==3)

-- проверенная стратегия меняется только после fails неудач
fail_conn("two.example.org")
check("proven: 1 failure keeps strategy", hrec_of("t","example.org").nstrategy==2)
fail_conn("two.example.org")
check("proven: 2 failures keep strategy", hrec_of("t","example.org").nstrategy==2)
fail_conn("two.example.org")
check("proven: 3 failures rotate", hrec_of("t","example.org").nstrategy==3)

-- сайт той же подсети начинает с найденной стратегии; другая подсеть - с первой
check("same subnet starts from remembered strategy", send(new_track("third.example.net"), { ip="1.2.3.99" })==2)
check("other subnet starts from strategy 1", send(new_track("fourth.example.info"), { ip="9.9.9.9" })==1)

-- после перезапуска: память читается из файла; номер вне круга не годится
local f = os.getenv("WRITABLE").."/ring-load.txt"
writefile(f, "saved.example 3\n5.6.7.0/24 2\nbig.example 9\n")
local L = { key="load", state="ring-load.txt" }
check("site from file", send(new_track("saved.example"), L)==3)
L.ip = "5.6.7.9"
check("subnet from file", send(new_track("sibling.example"), L)==2)
L.ip = "8.8.4.4"
check("number outside the ring is ignored", send(new_track("big.example"), L)==1)

-- сайт заработал с первой стратегией: запись о нём убирается
local M = { key="mem3", state="ring-m.txt", ip="7.7.7.7" }
local t1 = new_track("back.example")
send(t1, M)
hrec_of("mem3","back.example").nstrategy = 2
local t2 = new_track("back.example")
send(t2, M)
M.got = 30000; M.rseq = 501
send(t2, M)
check("non-first strategy saved", (file_of("ring-m.txt") or ""):find("back.example 2",1,true)~=nil)
hrec_of("mem3","back.example").nstrategy = 1
M.got = nil; M.rseq = nil
local t3 = new_track("back.example")
send(t3, M)
M.got = 30000; M.rseq = 501
send(t3, M)
check("first strategy removes the record", (file_of("ring-m.txt") or ""):find("back.example",1,true)==nil)

-- без файла (нет state) автосмена работает
local N = { key="nostate", state="", ip="6.6.6.6" }
check("works without state file", send(new_track("x.example"), N)==1)

-- ошибка в детекторе не ломает соединение
local saved = ntop
ntop = function() error("boom") end
local okg, resg = pcall(send, new_track("err.example"), { key="err", ip="4.4.4.4" })
ntop = saved
check("detector error falls back to standard", okg and resg==1)

-- поддельный сброс: TTL не как у SYN+ACK сервера
local function inbound_rst(ttl, ip6)
	local tr = new_track("rst.example")
	tr.incoming_ttl = 85
	tr.pos.direct, tr.pos.reverse = tr.pos.server, tr.pos.client
	local d = { func="rst_guard", func_n=1, func_instance="rst_guard_1", outgoing=false, track=tr, l7payload="empty", arg={ key="rst" },
		dis={ tcp={ th_flags=TH_RST, th_ack=0, th_seq=1, options={} }, payload="" }, target={ ip=pton("2.2.2.2") }, plan={} }
	if ip6 then d.dis.ip6 = { ip6_hlim=ttl } else d.dis.ip = { ip_ttl=ttl } end
	return d
end
check("forged rst is dropped", rst_guard(nil, inbound_rst(114))==VERDICT_DROP)
check("forged rst over ipv6 is dropped", rst_guard(nil, inbound_rst(40, true))==VERDICT_DROP)
check("rst with server ttl passes", rst_guard(nil, inbound_rst(85))==nil)
check("rst one hop away passes", rst_guard(nil, inbound_rst(83))==nil)
local noconn = inbound_rst(114); noconn.track.incoming_ttl = nil
check("no syn+ack seen: rst passes", rst_guard(nil, noconn)==nil)
local outrst = inbound_rst(114); outrst.outgoing = true
check("outgoing rst passes", rst_guard(nil, outrst)==nil)
local notrst = inbound_rst(114); notrst.dis.tcp.th_flags = TH_ACK
check("other packets pass", rst_guard(nil, notrst)==nil)
-- подделка не считается неудачей стратегии, настоящий сброс - считается
local fd = inbound_rst(114); fd.arg = { inseq="4096", fails="3" }
fd.track.pos.server.tcp.rseq = 1
check("forged rst is not a failure", ring_failure(fd, {})==false)
-- TTL совпадает, но сброс пришёл быстрее, чем мог ответить сервер (YouTube: winws2 видит его через 6-8 мс, настоящий ответ - от 18 мс)
local function timed_rst(gap)
	local d = inbound_rst(85)
	d.track.lua_state.rst_sent = gap and clock_getfloattime()-gap or nil
	return d
end
check("rst right after client hello is dropped", rst_guard(nil, timed_rst(0.007))==VERDICT_DROP)
check("rst after a round trip passes", rst_guard(nil, timed_rst(0.018))==nil)
check("no time known: rst with server ttl passes", rst_guard(nil, timed_rst(nil))==nil)
local tf = timed_rst(0.007); tf.arg = { inseq="4096", fails="3" }; tf.track.pos.server.tcp.rseq = 1
check("timed forged rst is not a failure", ring_failure(tf, {})==false)
local t114 = inbound_rst(114); t114.track.incoming_ttl = 117
check("ttl 3 away is forged", rst_guard(nil, t114)==VERDICT_DROP)
local oc = inbound_rst(85); oc.outgoing = true; oc.dis.payload = "hello"
rst_mark(nil, oc)
check("send time is marked", oc.track.lua_state.rst_sent~=nil and math.abs(clock_getfloattime()-oc.track.lua_state.rst_sent)<1)
local emp = inbound_rst(85); emp.outgoing = true
rst_mark(nil, emp)
check("empty packets do not mark time", emp.track.lua_state.rst_sent==nil)
local rd = inbound_rst(85); rd.arg = { inseq="4096", fails="3" }
rd.track.pos.server.tcp.rseq = 1
check("real rst is a failure", ring_failure(rd, {})==true)

-- образец настоящего ClientHello и пакет с ним
local hello = tls_mod(fake_default_tls, "rnd,dupsid,sni=discord.com", nil)
check("test hello built", hello~=nil and hello:find("discord.com",1,true)~=nil)
local function hello_packet(arg)
	local tr = new_track("discord.com")
	tr.pos.direct, tr.pos.reverse = tr.pos.client, tr.pos.server
	return { func="t", func_n=1, func_instance="t_1", outgoing=true, track=tr, l7payload="tls_client_hello",
		arg=arg, reasm_data=hello, dis={ tcp={ th_flags=TH_ACK, th_ack=1, th_seq=1001, options={} }, payload=hello }, target={ ip=pton("1.2.3.4") } }
end

-- tls_mod=none у ALT8 и других стратегий Flowseal: в описании zapret2 такого значения нет
local okn, resn = pcall(tls_mod, fake_default_tls, "none", nil)
print("     tls_mod none: "..(okn and (resn==fake_default_tls and "blob unchanged" or "returned "..type(resn)) or "error: "..tostring(resn)))
check("tls_mod none does not break the fake", okn)

-- клон настоящего ClientHello с другим именем
tls_google = fake_default_tls
local cl = hello_packet({ blob="ch_clone", fallback="tls_google", sni_del=true, sni_first="ya.ru", sni_snt_new="0" })
tls_client_hello_clone(nil, cl)
check("clone has white name only", cl.ch_clone and cl.ch_clone:find("ya.ru",1,true)~=nil and cl.ch_clone:find("discord.com",1,true)==nil)

-- hostfakesplit_alt: порядок altorder=1. Отправка подменена, разбор ClientHello настоящий
local sent = {}
local real_send = rawsend_payload_segmented
rawsend_payload_segmented = function(d, part, seq, opts)
	sent[#sent+1] = { part=part, seq=seq, fake=(opts.fooling==d.arg) }
	return true
end
local hs = hello_packet({ host="mail.ru", dir="out", payload="tls_client_hello", tcp_ts_up=true })
local hv = hostfakesplit_alt(nil, hs)
local name_at = hello:find("discord.com",1,true)
check("hostfakesplit_alt sends four parts and drops the original", hv==VERDICT_DROP and #sent==4)
check("order: start, fake name, end, real name", #sent==4 and not sent[1].fake and sent[2].fake and not sent[3].fake and not sent[4].fake)
check("real parts rebuild the hello", #sent==4 and sent[1].part..sent[4].part..sent[3].part==hello)
check("real name goes last", #sent==4 and sent[4].part=="discord.com" and sent[4].seq==name_at-1)
check("fake name has the same place and length", #sent==4 and sent[2].seq==name_at-1 and #sent[2].part==#"discord.com" and sent[2].part~="discord.com" and sent[2].part:sub(-7)=="mail.ru")
sent = {}
local hb = hello_packet({ host="mail.ru", dir="out", payload="tls_client_hello" })
hb.reasm_data = "not a client hello"; hb.dis.payload = hb.reasm_data
check("no host in the data: nothing is sent", hostfakesplit_alt(nil, hb)==nil and #sent==0)
rawsend_payload_segmented = real_send

print(fails>0 and (fails.." FAILED") or "all ok")
io.stdout:flush()
os.exit(fails>0 and 1 or 0)
