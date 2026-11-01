-- zapret: дополнения к стандартным библиотекам zapret2 (zapret-lib.lua, zapret-antidpi.lua).

-- Фейки Flowseal портятся устаревшим TCP timestamp (tcp_ts=-600000, у Flowseal fooling=ts): DPI их читает,
-- а сервер выбрасывает. Но timestamp есть, только если его поддерживает сервер. Без него фейк ушёл бы
-- неиспорченным, сервер принял бы его как настоящие данные, и соединение сломалось бы.
-- В таком соединении портим фейк как в стандартных стратегиях bol-van: MD5-опция и сдвиг sequence.
-- Использование: fake:blob=...:tcp_ts=-600000:tcp_ts_up:fool=ts_or_md5
function ts_or_md5(dis, fooling_options)
	if not dis.tcp or find_tcp_option(dis.tcp.options, TCP_KIND_TS) then return end
	if not dis.tcp.options then dis.tcp.options = {} end
	if not find_tcp_option(dis.tcp.options, TCP_KIND_MD5) then
		table.insert(dis.tcp.options, {kind=TCP_KIND_MD5, data=brandom(16)})
	end
	dis.tcp.th_seq = u32add(dis.tcp.th_seq, -10000)
	DLOG("ts_or_md5: no tcp timestamp in this connection. fake gets md5 option and seq-10000 instead")
end

-- hostfakesplit с порядком частей altorder=1 из zapret1 (им пользуются ALT3 и ALT13 Flowseal): начало, поддельное имя, конец, настоящее имя.
-- Фильтр, собирающий сегменты подряд, получает целый запрос с чужим именем, а настоящее имя догоняет его вне очереди. В zapret2 такого
-- порядка нет. Это hostfakesplit из zapret-antidpi.lua (bol-van, MIT) с другим порядком отправки; то же сделали z2k и zapret2-next.
-- Использование: hostfakesplit_alt:host=mail.ru:tcp_ts=-600000:tcp_ts_up:fool=ts_or_md5:repeats=5
function hostfakesplit_alt(ctx, desync)
	if not desync.dis.tcp then
		if not desync.dis.icmp then instance_cutoff_shim(ctx, desync) end
		return
	end
	direction_cutoff_opposite(ctx, desync)
	local data = desync.reasm_data or desync.dis.payload
	if #data>0 and direction_check(desync) and payload_check(desync) then
		if replay_first(desync) then
			local pos = resolve_range(data, desync.l7payload, "host,endhost-1", true)
			if pos then
				-- как в hostfakesplit: настоящие части без порчи (кроме tcp_ts_up), порча и повторы - у поддельной, ip_id - у всех
				local orig = {rawsend = rawsend_opts_base(desync), reconstruct = {}, ipfrag = {}, ipid = desync.arg, fooling = {tcp_ts_up = desync.arg.tcp_ts_up}}
				local fake = {rawsend = rawsend_opts(desync), reconstruct = reconstruct_opts(desync), ipfrag = {}, ipid = desync.arg, fooling = desync.arg}
				if not rawsend_payload_segmented(desync, string.sub(data,1,pos[1]-1), 0, orig) then return VERDICT_PASS end
				if not rawsend_payload_segmented(desync, genhost(pos[2]-pos[1]+1, desync.arg.host), pos[1]-1, fake) then return VERDICT_PASS end
				if not rawsend_payload_segmented(desync, string.sub(data,pos[2]+1), pos[2], orig) then return VERDICT_PASS end
				if not rawsend_payload_segmented(desync, string.sub(data,pos[1],pos[2]), pos[1]-1, orig) then return VERDICT_PASS end
				replay_drop_set(desync)
				return VERDICT_DROP
			end
			DLOG("hostfakesplit_alt: host range cannot be resolved")
		else
			DLOG("hostfakesplit_alt: not acting on further replay pieces")
		end
		-- продолжение сборки, которая уже отправлена по частям
		if replay_drop(desync) then return VERDICT_DROP end
	end
end
