-- zapret: детекторы автосмены стратегий (circular из zapret-auto.lua). Штатные детекторы не помнят, работала ли стратегия
-- на сайте, ждут 3 неудачи подряд, а после перезапуска обхода всё начинается заново. Здесь:
--  - стратегия, которая на сайте ещё не работала, меняется после первой неудачи (двух повторов данных вместо трёх);
--    проверенная - после fails неудач;
--  - неудача - ещё и закрытие TLS-соединения сервером без ответа на ClientHello;
--  - неудача соединения, начатого при прежней стратегии, не считается: браузер открывает к сайту сразу несколько;
--  - стратегия считается проверенной, когда от сервера получено больше got байт, то есть за зоной заморозки 16-20 КБ.
--    Входящие данные драйвер не перехватывает: сколько получено, видно по номеру подтверждения в исходящих пакетах;
--  - сайт, которому подошла не первая стратегия, и подсеть его сервера запоминаются в файле state: после перезапуска
--    сайт сразу идёт с этой стратегией, а другие сайты той же подсети начинают с неё же.
-- Память только подсказывает, с чего начать: не сработает - автосмена пойдёт дальше как обычно.
-- Идеи - из Zapret GUI (censorliber, MIT), см. THIRD-PARTY-NOTICES.md.
--
-- --writable=<каталог>
-- --lua-desync=circular:key=general:state=ring-general.txt:success_detector=ring_success:failure_detector=ring_failure

local RING_MAX_RECORDS = 2000
local memory = {}
local RING_STARTED = os.time()
local network_cache = { checked=-math.huge, revision=0 }

-- Маркер задаёт только непрозрачный сетевой ключ, не путь и не код. Старый процесс/watchdog не разрешает новую память.
function ring_network_key(text, now, started)
	if type(text)~="string" or #text>128 then return nil end
	local stamp, key, composition = text:match("^3 (%d+) ([A-Fa-f0-9]+) ([A-Fa-f0-9]+)\n$")
	stamp = tonumber(stamp)
	if not stamp or not key or #key~=64 or not composition or #composition~=24 or stamp>now or now-stamp>20 or (started and stamp<=started) then return nil end
	return key:upper(), composition:upper()
end
function ring_state_path(dir, state, key)
	if not dir or not state or not state:match("^[%w_-]+%.txt$") or not key or not key:match("^[A-F0-9]+$") or #key~=64 then return nil end
	return dir.."/"..state:sub(1,-5).."-"..key..".txt"
end
local function ring_context(desync)
	if not desync.arg.context then return "legacy", 0 end
	local now, mono = os.time(), clock_getfloattime()
	if mono<network_cache.checked or mono-network_cache.checked>=1 then
		local key, composition
		local dir = os.getenv("WRITABLE")
		if dir and desync.arg.context=="network-context.txt" then
			local ok, text = pcall(readfile, dir.."/network-context.txt")
			if ok then key, composition = ring_network_key(text, now, RING_STARTED) end
		end
		if key~=network_cache.key or composition~=network_cache.composition then network_cache.revision=network_cache.revision+1 end
		network_cache.key, network_cache.composition, network_cache.checked = key, composition, mono
	end
	local expected = desync.arg.state and desync.arg.state:match("^ring%-[a-z_0-9]+%-([a-f0-9]+)%-[a-f0-9]+%.txt$")
	if not expected or #expected~=24 or expected:upper()~=network_cache.composition then return nil, network_cache.revision end
	return network_cache.key, network_cache.revision
end

-- Поддельный сброс. На ClientHello с запрещённым именем фильтр отвечает сбросом от имени сервера, раньше настоящего ответа.
-- Настоящий сервер при этом отвечает дальше, но Windows уже поверила сбросу и закрыла соединение. Подделку видно:
--  - по TTL: он не такой, как у SYN+ACK этого сервера (замер: у Facebook 85 и 114, у GitHub 53 и 117);
--  - по времени: сброс пришёл быстрее, чем мог бы ответить сервер. Замер у YouTube: TTL бывает тот же, 117, сброс приходит через
--    0.6 мс при задержке до сервера 12.5 мс, а winws2 видит его через 6-8 мс после отправки (своя задержка обработки).
--    Отсчёт идёт от конца обработки пакета (rst_mark - последняя функция стратегии). Настоящий ответ такого сервера - от 18 мс.
-- Если здесь ошибка и сброс настоящий, сервер пришлёт его снова на следующий пакет клиента. Если ПК занят и сброс увиден позже,
-- он просто пройдёт, как раньше.
local RST_TTL_DELTA = 2
local RST_GAP_MAX = 0.010
-- Непроверенной стратегии на сайте хватает двух повторов данных вместо трёх. Windows повторяет через 0.3 и ещё через 0.6 с, третий раз -
-- ещё через 1.2 с: сайт уходит на следующую стратегию примерно через секунду, а не через две. Идея - из z2k (necronicle, MIT)
local RETRANS_UNPROVEN = 2
-- Сервер закрыл TLS-соединение, не ответив на ClientHello: ничего или только TLS alert (7 байт). Значит, он получил не то, что нужно:
-- до него дошёл фейк или испорченный разрез, и повторять это незачем. Настоящий ответ на ClientHello всегда длиннее. Содержимое входящих
-- пакетов драйвер не перехватывает, а FIN виден, поэтому смотрим по его номеру. Идея проверки на alert - из z2k
local TLS_ALERT_LEN = 7
local function tls_refused(desync)
	local tcp, track = desync.dis.tcp, desync.track
	if not tcp or not track or desync.outgoing or track.l7proto~="tls" or bitand(tcp.th_flags, TH_FIN)==0 then return false end
	local seq = pos_get(desync,'s')
	local server = track.pos.direct.tcp
	local last = math.max(seq+#desync.dis.payload, server.uppos or 0)
	return seq>=1 and last<=TLS_ALERT_LEN+1
end
local function forged_rst(desync)
	local tcp, track = desync.dis.tcp, desync.track
	if not tcp or not track or desync.outgoing or bitand(tcp.th_flags, TH_RST)==0 then return false end
	local ttl = (desync.dis.ip and desync.dis.ip.ip_ttl) or (desync.dis.ip6 and desync.dis.ip6.ip6_hlim)
	if track.incoming_ttl and ttl and math.abs(ttl-track.incoming_ttl)>RST_TTL_DELTA then return true end
	local sent = track.lua_state.rst_sent
	if sent then
		local gap = clock_getfloattime()-sent
		return gap>=0 and gap<RST_GAP_MAX
	end
	return false
end
function rst_guard(ctx, desync)
	if forged_rst(desync) then
		DLOG("rst_guard: forged rst dropped")
		return VERDICT_DROP
	end
end
function rst_mark(ctx, desync)
	if desync.track and desync.dis.tcp and #desync.dis.payload>0 then desync.track.lua_state.rst_sent = clock_getfloattime() end
end

-- подсеть сервера: /24 для IPv4, /48 для IPv6
local function ring_subnet(desync)
	local raw = desync.target and (desync.target.ip or desync.target.ip6)
	if not raw then return nil end
	local keep = #raw==4 and 3 or 6
	return ntop(string.sub(raw,1,keep)..string.rep("\0",#raw-keep)).."/"..(keep*8)
end

-- сколько байт клиент уже получил от сервера: номер подтверждения в исходящем пакете минус начальный номер сервера
local function ring_got(desync)
	local rev = desync.track and desync.track.pos.reverse
	if not rev or not rev.tcp or not rev.pcounter or rev.pcounter<1 then return 0 end
	if bitand(desync.dis.tcp.th_flags, TH_ACK)==0 then return 0 end
	local got = (desync.dis.tcp.th_ack - rev.tcp.seq0) % 4294967296
	return got<0x80000000 and got or 0
end

-- память одного круга: ключ (сайт или подсеть) -> номер стратегии. Каталог файла задаёт --writable: только туда
-- winws2 может писать после снижения своих прав
local function ring_mem(desync)
	local name = desync.arg.key or desync.func_instance
	local context, revision = ring_context(desync)
	local mem = memory[name]
	if mem and mem.revision==revision and mem.context==context then return mem end
	mem = { keys = {}, count = 0, context=context, revision=revision }
	memory[name] = mem
	local dir, state = os.getenv("WRITABLE"), desync.arg.state
	if dir and state and #state>0 then
		mem.file = desync.arg.context and ring_state_path(dir, state, context) or (not desync.arg.context and dir.."/"..state or nil)
		local ok, text = false, nil
		if mem.file then ok, text = pcall(readfile, mem.file) end
		if ok and text and #text<=262144 then
			for key, n in string.gmatch(text, "(%S+) (%d+)") do
				if mem.count>=RING_MAX_RECORDS then break end
				if not mem.keys[key] then mem.count = mem.count+1 end
				mem.keys[key] = tonumber(n)
			end
			DLOG("ring: loaded "..mem.count.." records from '"..mem.file.."'")
		end
	end
	return mem
end

-- Стратегия подтвердилась. Первая и так пробуется первой, поэтому в файле только сайты с другими: он остаётся маленьким
-- и переписывается редко
local function ring_remember(desync, w)
	local mem = ring_mem(desync)
	if w.revision~=nil and w.revision~=mem.revision then return end
	local changed = false
	local function put(key, n)
		if not key or mem.keys[key]==n then return end
		if not n then
			mem.count = mem.count-1
		elseif not mem.keys[key] then
			-- память не растёт без конца: переполнилась - начинаем заново
			if mem.count>=RING_MAX_RECORDS then
				mem.keys = {}
				mem.count = 0
			end
			mem.count = mem.count+1
		end
		mem.keys[key] = n
		changed = true
	end
	if w.strategy==1 then
		put(w.key, nil)
	else
		put(w.key, w.strategy)
		put(w.net, w.strategy)
	end
	if changed and mem.file and not mem.nosave then
		local t = {}
		for key, n in pairs(mem.keys) do
			t[#t+1] = key.." "..n
		end
		local ok, err = pcall(writefile, mem.file, table.concat(t,"\n").."\n")
		if not ok then
			DLOG_ERR("ring: cannot save '"..mem.file.."' : "..tostring(err)..". saving disabled")
			mem.nosave = true
		end
	end
end

-- Запись соединения. Сайт и его стратегия берутся, когда уходят первые данные (ClientHello): раньше имя неизвестно.
-- Сайт встретился впервые - начинаем с подсказки из памяти
local function ring_conn(desync, crec)
	local w = crec.ring
	if not w then
		w = {}
		crec.ring = w
	end
	if not w.strategy and desync.outgoing and #desync.dis.payload>0 then
		local hrec = automate_host_record(desync)
		local key = hrec and standard_hostkey(desync)
		if key then
			w.hrec, w.key, w.net = hrec, key, ring_subnet(desync)
			local mem = ring_mem(desync)
			if desync.arg.context and hrec.ring_revision~=mem.revision then
				hrec.nstrategy, hrec.failure_counter, hrec.failure_time_last = 1, 0, 0
				hrec.ring_seen, hrec.ring_ok, hrec.ring_revision = nil, nil, mem.revision
			end
			w.revision = mem.revision
			if not hrec.ring_seen then
				hrec.ring_seen = true
				local mem = ring_mem(desync)
				local n = mem.keys[key] or (w.net and mem.keys[w.net])
				if n and hrec.ctstrategy and n<=hrec.ctstrategy and n~=hrec.nstrategy then
					DLOG("ring: '"..key.."' starts from remembered strategy "..n)
					hrec.nstrategy = n
				end
			end
			w.strategy = hrec.nstrategy
		end
	end
	return w
end

-- true - исход соединения не влияет на выбор: оно начато при другой стратегии
local function ring_skip(desync, crec)
	if crec.nocheck then return true end
	local w = ring_conn(desync, crec)
	if w.revision~=nil and w.revision~=ring_mem(desync).revision then crec.nocheck=true; return true end
	if w.strategy and w.strategy~=w.hrec.nstrategy then
		DLOG("ring: connection started with strategy "..w.strategy..", '"..w.key.."' is at "..tostring(w.hrec.nstrategy)..". not counted")
		crec.nocheck = true
		return true
	end
	return false
end

local function ring_success_impl(desync, crec)
	if forged_rst(desync) or ring_skip(desync, crec) then return false end
	local ok = standard_success_detector(desync, crec)
	-- входящий FIN виден и у короткого ответа: это успех соединения, но ещё не проверка стратегии
	local proved = ok and desync.outgoing
	if not ok and desync.dis.tcp and desync.outgoing then
		-- Сам размер исходящего LSO-пакета не доказывает доставку: приложение может поставить большой запрос в очередь
		-- до первого ответа. Проверяем байты, получение которых клиент подтвердил номером ACK.
		if ring_got(desync)>(tonumber(desync.arg.got) or 28000) then
			DLOG("ring: past the freeze zone. treating connection as successful")
			ok, proved = true, true
		end
	end
	if not ok then return false end
	local w = crec.ring
	if proved and w.strategy then
		w.hrec.ring_ok = w.strategy
		ring_remember(desync, w)
	end
	return true
end

local function ring_failure_impl(desync, crec)
	-- подделка не значит, что стратегия не работает: соединение продолжается
	if forged_rst(desync) or ring_skip(desync, crec) then return false end
	local hrec = crec.ring.hrec
	local unproven = hrec and hrec.ring_ok~=hrec.nstrategy
	local retrans = desync.arg.retrans
	if unproven and not retrans then desync.arg.retrans = RETRANS_UNPROVEN end
	local failed = standard_failure_detector(desync, crec)
	desync.arg.retrans = retrans
	if not failed and not tls_refused(desync) then return false end
	-- стратегия на этом сайте ещё не работала: одной неудачи достаточно
	if unproven then
		hrec.failure_counter = (tonumber(desync.arg.fails) or 3)-1
		hrec.failure_time_last = os.time()
	end
	return true
end

-- Ошибка в этом коде не должна оставить соединение без обхода: при сбое работает штатный детектор
local function guarded(impl, standard)
	return function(desync, crec)
		local ok, res = pcall(impl, desync, crec)
		if ok then return res end
		DLOG_ERR("ring: "..tostring(res)..". using standard detector")
		return standard(desync, crec)
	end
end
ring_success = guarded(ring_success_impl, standard_success_detector)
ring_failure = guarded(ring_failure_impl, standard_failure_detector)
