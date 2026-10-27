# Перевод стратегий Flowseal zapret-discord-youtube (winws, nfqws1) в формат strategies\altNN.txt (winws2, zapret2).
# Инструмент разработчика, в архив для пользователей не входит. Нужен Python 3.
# Запуск из корня репозитория: python -I dev/flowseal2zapret2.py <папка распакованного Flowseal> strategies [--check]
#   --check: перевести ALT10-ALT13 и сравнить с файлами в strategies (проверка самого конвертера).
# При выходе новой версии Flowseal: сначала --check, затем без него; новые имена и номера - в STRATEGIES ниже.
# Профили Flowseal сопоставляются секциям пакета: quic, discord_udp, discord_media, google, general,
# ipset_tcp (только если отличается от general), game_tcp, game_udp.
import os
import re
import sys

BLOBS = {
    'quic_initial_www_google_com.bin': 'quic_google', 'quic_initial_4pda_to.bin': 'quic_4pda',
    'stun.bin': 'stun_fs', 'stun2.bin': 'stun2',
    'tls_clienthello_www_google_com.bin': 'tls_google', 'tls_clienthello_4pda_to.bin': 'tls_4pda',
    'tls_clienthello_www_sferum_ru.bin': 'tls_sferum', 'tls_clienthello_sochi_park.bin': 'tls_sochi',
    'ACTIVE_DISCORD_UDP.bin': 'discord_udp', 'ACTIVE_GAME_UDP.bin': 'game_udp',
}
TS = 'tcp_ts=-600000:tcp_ts_up:fool=ts_or_md5'

# id, имя, bat, описание
STRATEGIES = [
    ('1', 'ALT', 'general (ALT).bat', 'Фейки (stun + ClientHello google) с устаревшим timestamp и fakedsplit: части ClientHello вперемешку с фейковыми.'),
    ('2', 'ALT2', 'general (ALT2).bat', 'Без фейков: разрезка с ложным началом (seqovl 652) по второму байту.'),
    ('3', 'ALT3', 'general (ALT3).bat', 'Фейк ClientHello (стандартный, перемешанный, SNI google/ya.ru) и подмена имени хоста (hostfakesplit).'),
    ('4', 'ALT4', 'general (ALT4).bat', 'Фейки (stun + ClientHello google) с неверным sequence (badseq 1000) и разрезка.'),
    ('5', 'ALT5', 'general (ALT5).bat', 'Данные в SYN-пакете (syndata) и части ClientHello в обратном порядке (multidisorder).'),
    ('6', 'ALT6', 'general (ALT6).bat', 'Без фейков: разрезка с ложным началом (seqovl 681) по первому байту.'),
    ('7', 'ALT7', 'general (ALT7).bat', 'Разрезка с ложным началом (seqovl 679) по 2 и концу SNI; для сетей ipset-all и игры - данные в SYN (syndata).'),
    ('8', 'ALT8', 'general (ALT8).bat', 'Только стандартный фейк ClientHello с неверным sequence (badseq 2), без разрезки.'),
    ('9', 'ALT9', 'general (ALT9).bat', 'Только подмена имени хоста (hostfakesplit ozon.ru / google) с устаревшим timestamp.'),
    ('40', 'GENERAL', 'general.bat', 'Обычный general Flowseal: без фейков, разрезка с ложным началом (seqovl 568/681).'),
    ('41', 'EXP', 'general (EXP).bat', 'Экспериментальная Flowseal: фейк sferum + разрезка с ложным началом из stun2 (seqovl 480).'),
    ('42', 'SIMPLE FAKE', 'general (SIMPLE FAKE).bat', 'Только фейки ClientHello google с устаревшим timestamp, без разрезки. YouTube - hostfakesplit.'),
    ('43', 'SIMPLE FAKE ALT', 'general (SIMPLE FAKE ALT).bat', 'Только фейки (stun2 + ClientHello google) с неверным sequence (badseq 2), без разрезки.'),
    ('44', 'SIMPLE FAKE ALT2', 'general (SIMPLE FAKE ALT2).bat', 'Только фейки (stun2 + ClientHello sferum) с устаревшим timestamp, без разрезки.'),
    ('45', 'FAKE TLS AUTO', 'general (FAKE TLS AUTO).bat', 'Фейки (нули + стандартный ClientHello с SNI google) с badseq и части в обратном порядке (1, midsld).'),
    ('46', 'FAKE TLS AUTO ALT', 'general (FAKE TLS AUTO ALT).bat', 'Стандартный фейк с SNI google, badseq 2 и fakedsplit.'),
    ('47', 'FAKE TLS AUTO ALT2', 'general (FAKE TLS AUTO ALT2).bat', 'Стандартный фейк с SNI google, badseq 10000000 и разрезка с ложным началом (seqovl 681).'),
    ('48', 'FAKE TLS AUTO ALT3', 'general (FAKE TLS AUTO ALT3).bat', 'Стандартный фейк с SNI google, устаревший timestamp и разрезка с ложным началом (seqovl 681).'),
]
CHECK = [('10', 'general (ALT10).bat'), ('11', 'general (ALT11).bat'), ('12', 'general (ALT12).bat'), ('13', 'general (ALT13).bat')]

warnings = []


def warn(msg):
    warnings.append(msg)


def read_profiles(path):
    text = open(path, encoding='utf-8', errors='replace').read()
    text = re.sub(r'\^\r?\n', '', text)
    line = next(l for l in text.splitlines() if 'winws.exe' in l)
    line = line.replace('^!', '!')
    line = line[line.index('winws.exe"') + len('winws.exe"'):]
    tokens = re.findall(r'(--[a-z0-9-]+)(?:=("[^"]*"|\S*))?', line)
    profiles, cur = [], []
    for k, v in tokens:
        if k == '--new':
            profiles.append(cur)
            cur = []
            continue
        if k.startswith('--wf-'):
            continue
        cur.append((k, v.strip('"')))
    profiles.append(cur)
    return profiles


def blob_of(v):
    if v == '!':
        return 'fake_default_tls'
    if v.startswith('0x'):
        return v
    name = os.path.basename(v.replace('%BIN%', ''))
    if name not in BLOBS:
        warn('нет блоба для ' + name)
    return BLOBS.get(name, name)


def classify(p):
    d = dict(p)
    keys = [k for k, _ in p]
    joined = ' '.join(k + '=' + v for k, v in p)
    if d.get('--filter-udp') == '%GameFilterUDP%':
        return 'game_udp'
    if d.get('--filter-tcp') == '%GameFilterTCP%':
        return 'game_tcp'
    if d.get('--filter-udp', '').startswith('19294'):
        return 'discord_udp'
    if d.get('--filter-udp') == '443' or d.get('--filter-l7') == 'quic':
        return 'quic_ipset' if 'ipset-all' in joined else 'quic'
    tcp = d.get('--filter-tcp', '')
    if tcp.startswith('2053'):
        return 'discord_media'
    if tcp == '443' and 'list-google' in joined:
        return 'google'
    if tcp == '80,443' and 'list-general' in joined:
        return 'general'
    if tcp == '80,443,8443' and 'ipset-all' in joined:
        return 'ipset_tcp'
    if tcp.startswith('80,443,2053') and '--hostlist' not in keys:
        return 'all_tcp'
    warn('непонятный профиль: ' + joined[:120])
    return None


def parse_opts(p):
    o = {'modes': [], 'repeats': None, 'fooling': [], 'badseq': '-10000', 'fake_tls': [], 'fake_http': [],
         'fake_unknown': [], 'fake_quic': [], 'fake_discord': [], 'fake_stun': [], 'fake_unknown_udp': [],
         'pos': None, 'seqovl': None, 'seqovl_pattern': None, 'fakedsplit_pattern': None, 'host': None,
         'cutoff': None, 'any': False, 'ip_id_zero': False, 'default_tls_mod': None}
    for k, v in p:
        if k == '--dpi-desync':
            o['modes'] = v.split(',')
        elif k == '--dpi-desync-repeats':
            o['repeats'] = v
        elif k == '--dpi-desync-fooling':
            o['fooling'] = v.split(',')
        elif k == '--dpi-desync-badseq-increment':
            o['badseq'] = v
        elif k == '--dpi-desync-fake-tls':
            o['fake_tls'].append([blob_of(v), None])
        elif k == '--dpi-desync-fake-tls-mod':
            mod = None if v == 'none' else v
            # мод относится к последнему fake-tls, без них - к стандартному фейку
            if o['fake_tls']:
                o['fake_tls'][-1][1] = mod
            else:
                o['default_tls_mod'] = v
        elif k == '--dpi-desync-fake-http':
            o['fake_http'].append(blob_of(v))
        elif k == '--dpi-desync-fake-unknown':
            o['fake_unknown'].append(blob_of(v))
        elif k == '--dpi-desync-fake-quic':
            o['fake_quic'].append(blob_of(v))
        elif k == '--dpi-desync-fake-discord':
            o['fake_discord'].append(blob_of(v))
        elif k == '--dpi-desync-fake-stun':
            o['fake_stun'].append(blob_of(v))
        elif k == '--dpi-desync-fake-unknown-udp':
            o['fake_unknown_udp'].append(blob_of(v))
        elif k == '--dpi-desync-split-pos':
            o['pos'] = v
        elif k == '--dpi-desync-split-seqovl':
            o['seqovl'] = v
        elif k == '--dpi-desync-split-seqovl-pattern':
            o['seqovl_pattern'] = blob_of(v)
        elif k == '--dpi-desync-fakedsplit-pattern':
            o['fakedsplit_pattern'] = v
        elif k == '--dpi-desync-hostfakesplit-mod':
            for part in v.split(','):
                if part.startswith('host='):
                    o['host'] = part[5:]
                elif part == 'altorder=1':
                    pass  # в zapret2 нет: порядок частей стандартный
                else:
                    warn('hostfakesplit-mod ' + part)
        elif k == '--dpi-desync-cutoff':
            o['cutoff'] = v
        elif k == '--dpi-desync-any-protocol':
            o['any'] = v == '1'
        elif k == '--ip-id':
            o['ip_id_zero'] = v == 'zero'
        elif k in ('--filter-udp', '--filter-tcp', '--filter-l7', '--hostlist', '--hostlist-exclude', '--ipset',
                   '--ipset-exclude', '--hostlist-domains', '--hostlist-exclude-domains', '--filter-l3'):
            pass
        else:
            warn('опция не перенесена: %s=%s' % (k, v))
    return o


def fooling(o):
    f = set(o['fooling'])
    parts = []
    if 'ts' in f:
        parts.append('tcp_ts=-600000:tcp_ts_up' + ('' if 'md5sig' in f else ':fool=ts_or_md5'))
    if 'md5sig' in f:
        parts.append('tcp_md5')
    if 'badseq' in f:
        parts.append('tcp_seq=%s:tcp_ack=-66000' % o['badseq'])
    for x in f - {'ts', 'md5sig', 'badseq'}:
        warn('fooling ' + x)
    return ':'.join(parts)


def join(*parts):
    return ':'.join(x for x in parts if x)


def tcp_section(o, kind):
    lines = []
    ipid = 'ip_id=zero' if o['ip_id_zero'] else ''
    if kind == 'game_tcp':
        lines.append('--out-range=<' + (o['cutoff'] or 'n4'))
    else:
        if o['cutoff']:
            warn('cutoff в профиле ' + kind)
        lines.append('--out-range=-d10')
    f = fooling(o)
    rep = 'repeats=' + o['repeats'] if o['repeats'] else ''
    modes = o['modes']
    if 'syndata' in modes:
        lines += ['--payload=empty', '--lua-desync=syndata']
    payloads = [('tls_client_hello', '')]
    if kind in ('general', 'ipset_tcp', 'game_tcp'):
        payloads.append(('http_req', ''))
    if o['any']:
        payloads.append(('unknown', 'payload=unknown'))
    for ptype, pinline in payloads:
        body = []
        for m in modes:
            if m == 'fake':
                if ptype == 'tls_client_hello':
                    fakes = o['fake_tls'] or [['fake_default_tls', o['default_tls_mod'] or 'rnd,rndsni,dupsid']]
                    if o['default_tls_mod'] and o['fake_tls']:
                        warn('fake-tls-mod до fake-tls')
                elif ptype == 'http_req':
                    fakes = [[b, None] for b in (o['fake_http'] or ['fake_default_http'])]
                else:
                    if not o['fake_unknown']:
                        warn('нет fake-unknown для ' + kind)
                    fakes = [[b, None] for b in (o['fake_unknown'] or ['0x' + '00' * 256])]
                for b, mod in fakes:
                    body.append('--lua-desync=' + join('fake', pinline, 'blob=' + b, ('tls_mod=' + mod) if mod else '', f, rep, ipid))
            elif m in ('multisplit', 'multidisorder'):
                ov = ''
                if o['seqovl']:
                    ov = join('seqovl=' + o['seqovl'], ('seqovl_pattern=' + o['seqovl_pattern']) if o['seqovl_pattern'] else '')
                body.append('--lua-desync=' + join(m, pinline, ('pos=' + o['pos']) if o['pos'] else '', ov, ipid))
            elif m == 'fakedsplit':
                pos = o['pos'].split(',')[0] if o['pos'] else ''
                pat = ('pattern=' + o['fakedsplit_pattern']) if o['fakedsplit_pattern'] else ''
                body.append('--lua-desync=' + join('fakedsplit', pinline, ('pos=' + pos) if pos else '', pat, f, rep, ipid))
            elif m == 'hostfakesplit':
                if ptype == 'unknown':
                    continue  # без имени хоста подменять нечего
                body.append('--lua-desync=' + join('hostfakesplit', ('host=' + o['host']) if o['host'] else '', f, rep, ipid))
            elif m == 'syndata':
                pass
            else:
                warn('режим ' + m)
        if body:
            lines.append('--payload=' + ptype)
            lines += body
    return lines


def udp_section(o, kind):
    rep = 'repeats=' + o['repeats'] if o['repeats'] else ''
    if 'fake' not in o['modes'] or len(o['modes']) > 1:
        warn('udp режим ' + ','.join(o['modes']))
    if kind == 'quic':
        lines = ['--out-range=-n10', '--payload=quic_initial']
        for b in o['fake_quic'] or ['fake_default_quic']:
            lines.append('--lua-desync=' + join('fake', 'blob=' + b, rep))
        return lines
    if kind == 'discord_udp':
        lines = ['--out-range=' + (('<' + o['cutoff']) if o['cutoff'] else 'a')]
        if o['fake_discord']:
            lines.append('--payload=discord_ip_discovery')
            lines += ['--lua-desync=' + join('fake', 'blob=' + b, rep) for b in o['fake_discord']]
        if o['fake_stun']:
            lines.append('--payload=stun')
            lines += ['--lua-desync=' + join('fake', 'blob=' + b, rep) for b in o['fake_stun']]
        if o['fake_unknown_udp']:
            warn('голос Discord: неизвестный UDP не перенесён (фильтр профиля - discord,stun)')
        return lines
    lines = ['--out-range=<' + (o['cutoff'] or 'n4'), '--payload=all']
    lines += ['--lua-desync=' + join('fake', 'payload=all', 'blob=' + b, rep) for b in o['fake_unknown_udp']]
    return lines


def convert(path):
    sec = {}
    for p in read_profiles(path):
        kind = classify(p)
        if not kind:
            continue
        o = parse_opts(p)
        if kind in ('quic', 'quic_ipset', 'discord_udp', 'game_udp'):
            lines = udp_section(o, 'quic' if kind == 'quic_ipset' else kind)
        elif kind == 'all_tcp':
            for k in ('discord_media', 'google', 'general', 'ipset_tcp'):
                sec[k] = tcp_section(o, k)
            continue
        else:
            lines = tcp_section(o, kind)
        if kind == 'quic_ipset':
            if 'quic' in sec and sec['quic'] != lines:
                warn('QUIC для ipset отличается от QUIC для списка: взят списочный')
            sec.setdefault('quic', lines)
            continue
        sec[kind] = lines
    if 'ipset_tcp' in sec and 'general' in sec:
        # без порта 80 и 8443 профили одинаковы - тогда tcp_ipset берёт секцию general
        if sec['ipset_tcp'] == sec['general']:
            del sec['ipset_tcp']
    return sec


ORDER = ['quic', 'discord_udp', 'discord_media', 'google', 'general', 'ipset_tcp', 'game_tcp', 'game_udp']


def render(sec, sid, name, bat, desc):
    out = ['# name: ' + name, '# desc: ' + desc, '# flowseal: ' + bat + ' (перенесено конвертером из 1.10.4)']
    for k in ORDER:
        if k in sec:
            out.append('[' + k + ']')
            out += sec[k]
    missing = [k for k in ORDER if k not in sec and k != 'ipset_tcp']
    if missing:
        warn('%s: нет секций %s' % (name, missing))
    return '\n'.join(out) + '\n'


def read_ours(path):
    sec, cur = {}, None
    for l in open(path, encoding='utf-8'):
        l = l.strip()
        if not l or l.startswith('#'):
            continue
        m = re.match(r'^\[([a-z_]+)\]$', l)
        if m:
            cur = m.group(1)
            sec[cur] = []
        elif cur:
            sec[cur].append(l)
    return sec


def main():
    sys.stdout.reconfigure(encoding='utf-8')
    fs, out = sys.argv[1], sys.argv[2]
    if '--check' in sys.argv:
        for sid, bat in CHECK:
            warnings.clear()
            got = convert(os.path.join(fs, bat))
            ours = read_ours(os.path.join(out, 'alt%s.txt' % sid))
            print('=== ALT%s %s' % (sid, 'warnings: ' + '; '.join(warnings) if warnings else ''))
            for k in ORDER:
                if got.get(k) != ours.get(k):
                    print('  [%s] отличается' % k)
                    print('    наш:   ' + '\n           '.join(ours.get(k) or ['-']))
                    print('    новый: ' + '\n           '.join(got.get(k) or ['-']))
        return
    for sid, name, bat, desc in STRATEGIES:
        warnings.clear()
        sec = convert(os.path.join(fs, bat))
        text = render(sec, sid, name, bat, desc)
        with open(os.path.join(out, 'alt%s.txt' % sid), 'w', encoding='utf-8', newline='\n') as fh:
            fh.write(text)
        print('alt%s.txt %-20s %s' % (sid, name, ('; '.join(sorted(set(warnings)))) if warnings else 'ok'))


if __name__ == '__main__':
    main()
