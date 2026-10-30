-- zapret: детекторы автосмены стратегий (circular из zapret-auto.lua). Штатные детекторы не помнят, работала ли стратегия
-- на сайте, ждут 3 неудачи подряд, а после перезапуска обхода всё начинается заново. Здесь:
--  - стратегия, которая на сайте ещё не работала, меняется после первой неудачи; проверенная - после fails;
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
	local mem = memory[name]
	if mem then return mem end
	mem = { keys = {}, count = 0 }
	memory[name] = mem
	local dir, state = os.getenv("WRITABLE"), desync.arg.state
	if dir and state and #state>0 then
		mem.file = dir.."/"..state
		local ok, text = pcall(readfile, mem.file)
		if ok and text then
			for key, n in string.gmatch(text, "(%S+) (%d+)") do
				mem.keys[key] = tonumber(n)
				mem.count = mem.count+1
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
		-- Windows может отдать данные одним большим пакетом (LSO): он начинается раньше maxseq, а кончается за ним.
		-- Столько клиент мог отправить, только получая подтверждения
		if pos_get(desync,'p')>(tonumber(desync.arg.maxseq) or 32768) or ring_got(desync)>(tonumber(desync.arg.got) or 28000) then
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
	if not standard_failure_detector(desync, crec) then return false end
	local hrec = crec.ring.hrec
	-- стратегия на этом сайте ещё не работала: одной неудачи достаточно
	if hrec and hrec.ring_ok~=hrec.nstrategy then
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
