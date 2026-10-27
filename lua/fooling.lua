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
