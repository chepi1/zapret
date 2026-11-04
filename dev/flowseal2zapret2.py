# Перевод стратегий Flowseal zapret-discord-youtube (winws, nfqws1) в формат strategies\altNN.txt (winws2, zapret2).
# Инструмент разработчика, в архив для пользователей не входит. Нужен Python 3.
# Запуск из корня репозитория: python -I dev/flowseal2zapret2.py <папка распакованного Flowseal> strategies [--check]
#   --check --allow-known-differences: сверить все22 профиля, явно приняв ограничения EXP.
# При выходе новой версии Flowseal: сначала --check, затем без него; новые имена и номера - в STRATEGIES ниже.
# Профили Flowseal сопоставляются секциям пакета: quic, discord_udp, discord_media, google, general,
# ipset_tcp (только если отличается от general), game_tcp, game_udp.
import os
import re
import sys
import argparse
import tempfile

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
    with open(path, encoding='utf-8') as source:
        text = source.read()
    text = re.sub(r'\^\r?\n', '', text)
    commands = [line for line in text.splitlines() if line.lstrip().lower().startswith('start ') and 'winws.exe"' in line]
    if len(commands) != 1:
        raise ValueError(f'{path}: expected one winws.exe start command')
    line = commands[0]
    line = line.replace('^!', '!')
    line = line[line.index('winws.exe"') + len('winws.exe"'):]
    pattern = re.compile(r'(--[a-z0-9-]+)(?:=("[^"]*"|[^\s"]+))?(?=\s|$)')
    profiles, cur, global_filters = [], [], set()
    end = 0
    for token in pattern.finditer(line):
        if line[end:token.start()].strip():
            raise ValueError(f'{path}: unconsumed option text: {line[end:token.start()]!r}')
        end = token.end()
        k, v = token.group(1), (token.group(2) or '').strip('"')
        if k == '--new':
            if v or not cur:
                raise ValueError(f'{path}: invalid or empty --new profile')
            profiles.append(cur)
            cur = []
            continue
        if k.startswith('--wf-'):
            if k not in ('--wf-tcp', '--wf-udp') or profiles or k in global_filters:
                raise ValueError(f'{path}: unsupported global filter: {k}')
            expected = {'--wf-tcp': '80,443,2053,2083,2087,2096,8443,%GameFilterTCP%',
                        '--wf-udp': '443,19294-19344,50000-50100,%GameFilterUDP%'}
            if v != expected[k]:
                raise ValueError(f'{path}: unsupported global capture ports: {k}={v}')
            global_filters.add(k)
            continue
        cur.append((k, v))
    if line[end:].strip() or not cur:
        raise ValueError(f'{path}: unconsumed text or empty final profile')
    if global_filters != {'--wf-tcp', '--wf-udp'}:
        raise ValueError(f'{path}: both canonical global capture filters are required')
    profiles.append(cur)
    return profiles


def blob_of(v):
    if v == '!':
        return 'fake_default_tls'
    if v.startswith('0x'):
        if not re.fullmatch(r'0x(?:[0-9a-fA-F]{2})+', v):
            raise ValueError('invalid inline blob: ' + v)
        return v
    if not v.startswith('%BIN%'):
        raise ValueError('blob must use its declared %BIN% path: ' + v)
    name = v[5:]
    if name not in BLOBS:
        raise ValueError('нет блоба для ' + name)
    return BLOBS[name]


def classify(p):
    d = dict(p)
    keys = [k for k, _ in p]
    joined = ' '.join(k + '=' + v for k, v in p)
    if '--filter-tcp' in d and '--filter-udp' in d:
        raise ValueError('combined TCP/UDP profile is not representable')
    for key in ('--filter-tcp', '--filter-udp', '--filter-l7', '--hostlist-domains'):
        if keys.count(key) > 1:
            raise ValueError('duplicate selector ' + key)
    if d.get('--filter-udp') == '%GameFilterUDP%':
        return 'game_udp'
    if d.get('--filter-tcp') == '%GameFilterTCP%':
        return 'game_tcp'
    if d.get('--filter-udp') == '19294-19344,50000-50100':
        return 'discord_udp'
    if d.get('--filter-udp') == '443':
        return 'quic_ipset' if 'ipset-all' in joined else 'quic'
    if d.get('--filter-l7') == 'quic' and '--filter-tcp' not in d and '--filter-udp' not in d:
        warn('EXP: L7-only QUIC перенесён в профиль UDP443; исходная область портов шире')
        return 'quic_ipset' if 'ipset-all' in joined else 'quic'
    tcp = d.get('--filter-tcp', '')
    if tcp == '2053,2083,2087,2096,8443':
        return 'discord_media'
    if tcp == '443' and 'list-google' in joined:
        return 'google'
    if tcp == '80,443' and 'list-general' in joined:
        return 'general'
    if tcp == '80,443,8443' and 'ipset-all' in joined:
        return 'ipset_tcp'
    if tcp == '80,443,2053,2083,2087,2096,8443' and '--hostlist' not in keys:
        return 'all_tcp'
    raise ValueError('непонятный профиль: ' + joined[:120])


def parse_opts(p):
    o = {'modes': [], 'repeats': None, 'fooling': [], 'badseq': '-10000', 'fake_tls': [], 'fake_http': [],
         'fake_unknown': [], 'fake_quic': [], 'fake_discord': [], 'fake_stun': [], 'fake_unknown_udp': [],
         'pos': None, 'seqovl': None, 'seqovl_pattern': None, 'fakedsplit_pattern': None, 'host': None,
         'cutoff': None, 'any': False, 'ip_id_zero': False, 'default_tls_mod': None, 'l3': None, 'host_alt_order': False}
    seen, tls_mod_seen = set(), set()
    blob_options = {'--dpi-desync-fake-'+name for name in ('tls', 'http', 'unknown', 'quic', 'discord', 'stun', 'unknown-udp')}
    for k, v in p:
        if k.startswith('--dpi-desync') and k not in blob_options and k != '--dpi-desync-fake-tls-mod':
            if k in seen:
                raise ValueError('duplicate action option: ' + k)
            seen.add(k)
        if k.startswith('--dpi-desync-fake-') and v == '!' and k != '--dpi-desync-fake-tls':
            raise ValueError('builtin ! blob is only supported for TLS: ' + k)
        if k == '--dpi-desync':
            if v not in ('fake', 'multisplit', 'hostfakesplit', 'syndata', 'fake,fakedsplit', 'fake,hostfakesplit',
                         'fake,multidisorder', 'fake,multisplit', 'syndata,multidisorder'):
                raise ValueError('unsupported action sequence: ' + v)
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
            slot = len(o['fake_tls'])-1
            if slot in tls_mod_seen:
                raise ValueError('duplicate TLS modifier for the same fake')
            tls_mod_seen.add(slot)
            if v != 'none':
                for modifier in v.split(','):
                    if modifier not in ('rnd', 'rndsni', 'dupsid') and not re.fullmatch(r'sni=[A-Za-z0-9_.-]+', modifier):
                        raise ValueError('unsupported TLS modifier: ' + modifier)
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
            o['fakedsplit_pattern'] = blob_of(v)
        elif k == '--dpi-desync-hostfakesplit-mod':
            for part in v.split(','):
                if part.startswith('host='):
                    o['host'] = part[5:]
                elif part == 'altorder=1':
                    o['host_alt_order'] = True
                elif part == 'altorder=0':
                    o['host_alt_order'] = False
                else:
                    raise ValueError('hostfakesplit-mod ' + part)
        elif k == '--dpi-desync-cutoff':
            o['cutoff'] = v
        elif k == '--dpi-desync-any-protocol':
            if v not in ('0', '1'):
                raise ValueError('unsupported any-protocol=' + v)
            o['any'] = v == '1'
        elif k == '--ip-id':
            if v != 'zero':
                raise ValueError('unsupported --ip-id=' + v)
            o['ip_id_zero'] = True
        elif k == '--filter-l3':
            if v not in ('ipv4', 'ipv6') or (o['l3'] and o['l3'] != v):
                raise ValueError('unsupported or conflicting --filter-l3=' + v)
            o['l3'] = v
        elif k == '--filter-l7':
            if v not in ('quic', 'discord,stun', 'discord,stun,unknown'):
                raise ValueError('unsupported --filter-l7=' + v)
        elif k == '--hostlist-domains':
            if v != 'discord.media':
                raise ValueError('unsupported --hostlist-domains=' + v)
        elif k == '--hostlist-exclude-domains':
            if v != 'fonts.googleapis.com':
                raise ValueError('unsupported --hostlist-exclude-domains=' + v)
            warn('EXP: исключение fonts.googleapis.com в IPSet-профиле не перенесено; область списков задаётся сборкой')
        elif k in ('--hostlist', '--hostlist-exclude', '--ipset', '--ipset-exclude'):
            allowed = {'--hostlist': {'list-general.txt', 'list-general-user.txt', 'list-google.txt'},
                       '--hostlist-exclude': {'list-exclude.txt', 'list-exclude-user.txt'},
                       '--ipset': {'ipset-all.txt'},
                       '--ipset-exclude': {'ipset-exclude.txt', 'ipset-exclude-user.txt'}}
            if not v.startswith('%LISTS%') or v[7:] not in allowed[k]:
                raise ValueError('unsupported list condition: ' + k + '=' + v)
        elif k in ('--filter-udp', '--filter-tcp'):
            pass
        else:
            raise ValueError('опция не перенесена: %s=%s' % (k, v))
    return o


def validate_match(p, kind):
    """Closed section contract for the22 pinned sources; never drop a new list condition."""
    ip_excludes = [('--ipset-exclude', '%LISTS%ipset-exclude.txt'),
                   ('--ipset-exclude', '%LISTS%ipset-exclude-user.txt')]
    host_excludes = [('--hostlist-exclude', '%LISTS%list-exclude.txt'),
                     ('--hostlist-exclude', '%LISTS%list-exclude-user.txt')]
    general = [('--hostlist', '%LISTS%list-general.txt'), ('--hostlist', '%LISTS%list-general-user.txt')]
    ipset = [('--ipset', '%LISTS%ipset-all.txt')]
    expected = {'quic': general+host_excludes+ip_excludes, 'general': general+host_excludes+ip_excludes,
                'quic_ipset': ipset+host_excludes+ip_excludes, 'ipset_tcp': ipset+host_excludes+ip_excludes,
                'discord_udp': [], 'discord_media': [('--hostlist-domains', 'discord.media')],
                'google': [('--hostlist', '%LISTS%list-google.txt')],
                'game_tcp': ipset+ip_excludes, 'game_udp': ipset+ip_excludes, 'all_tcp': ip_excludes}[kind]
    match = [(key, value) for key, value in p if key.startswith(('--hostlist', '--ipset'))]
    fonts = ('--hostlist-exclude-domains', 'fonts.googleapis.com')
    if kind == 'ipset_tcp' and fonts in match:
        expected = ipset+host_excludes+[fonts]+ip_excludes
    if match != expected:
        raise ValueError('unrepresentable list/domain conditions for ' + kind)


def validate_actions(p, o, kind):
    """Every recognized action option must have a consumer in this section adapter."""
    raw = dict(p)
    actions = {key for key in raw if key.startswith('--dpi-desync') or key == '--ip-id'}
    base = {'--dpi-desync', '--dpi-desync-repeats'}
    udp = {
        'quic': base | {'--dpi-desync-fake-quic'},
        'quic_ipset': base | {'--dpi-desync-fake-quic'},
        'discord_udp': base | {'--dpi-desync-fake-discord', '--dpi-desync-fake-stun', '--dpi-desync-fake-unknown-udp', '--dpi-desync-any-protocol', '--dpi-desync-cutoff'},
        'game_udp': base | {'--dpi-desync-fake-unknown-udp', '--dpi-desync-any-protocol', '--dpi-desync-cutoff'},
    }
    if kind in udp:
        if actions - udp[kind]:
            raise ValueError('unsupported/unused UDP action options: '+ ','.join(sorted(actions-udp[kind])))
        if kind == 'discord_udp':
            l7 = raw.get('--filter-l7')
            expected = 'discord,stun,unknown' if o['fake_unknown_udp'] else 'discord,stun'
            if l7 != expected or not o['fake_discord'] or not o['fake_stun']:
                raise ValueError('voice L7 condition and explicit Discord/STUN fakes are required')
            if o['fake_unknown_udp']:
                if raw.get('--dpi-desync-any-protocol') != '1':
                    raise ValueError('unknown voice payload requires any-protocol=1')
            elif '--dpi-desync-any-protocol' in raw:
                raise ValueError('voice any-protocol without unknown payload is not represented')
        if kind == 'game_udp' and (raw.get('--dpi-desync-any-protocol') != '1' or not o['cutoff'] or not o['fake_unknown_udp']):
            raise ValueError('game UDP requires any-protocol=1, cutoff and explicit fake payloads')
        return
    tcp = base | {'--dpi-desync-cutoff', '--dpi-desync-any-protocol', '--ip-id', '--dpi-desync-fooling',
                  '--dpi-desync-badseq-increment', '--dpi-desync-fake-tls', '--dpi-desync-fake-tls-mod',
                  '--dpi-desync-fake-http', '--dpi-desync-fake-unknown', '--dpi-desync-split-pos',
                  '--dpi-desync-split-seqovl', '--dpi-desync-split-seqovl-pattern',
                  '--dpi-desync-fakedsplit-pattern', '--dpi-desync-hostfakesplit-mod'}
    if actions-tcp:
        raise ValueError('unsupported/unused TCP action options: '+ ','.join(sorted(actions-tcp)))
    modes = set(o['modes'])
    required_modes = {
        '--dpi-desync-repeats': {'fake', 'fakedsplit', 'hostfakesplit'},
        '--dpi-desync-fooling': {'fake', 'fakedsplit', 'hostfakesplit'},
        '--dpi-desync-badseq-increment': {'fake', 'fakedsplit', 'hostfakesplit'},
        '--dpi-desync-split-pos': {'multisplit', 'multidisorder', 'fakedsplit'},
        '--dpi-desync-split-seqovl': {'multisplit', 'multidisorder'},
        '--dpi-desync-split-seqovl-pattern': {'multisplit', 'multidisorder'},
        '--dpi-desync-fakedsplit-pattern': {'fakedsplit'},
        '--dpi-desync-hostfakesplit-mod': {'hostfakesplit'},
    }
    for option in ('--dpi-desync-fake-tls', '--dpi-desync-fake-tls-mod', '--dpi-desync-fake-http', '--dpi-desync-fake-unknown'):
        required_modes[option] = {'fake'}
    for option, consumers in required_modes.items():
        if option in raw and not modes & consumers:
            raise ValueError('action does not consume '+option)
    if '--dpi-desync-badseq-increment' in raw and 'badseq' not in o['fooling']:
        raise ValueError('badseq increment requires badseq fooling')
    if kind in ('google', 'discord_media') and actions & {'--dpi-desync-fake-http', '--dpi-desync-fake-unknown', '--dpi-desync-any-protocol'}:
        raise ValueError('TLS-only section does not represent these payload options')
    if '--dpi-desync-fake-unknown' in raw and not o['any']:
        raise ValueError('unknown TCP fake requires any-protocol=1')


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
        raise ValueError('fooling ' + x)
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
            raise ValueError('cutoff в профиле ' + kind)
        lines.append('--out-range=-d10')
    f = fooling(o)
    rep = 'repeats=' + o['repeats'] if o['repeats'] else ''
    modes = o['modes']
    if not modes:
        raise ValueError('TCP profile has no desync action')
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
                        raise ValueError('fake-tls-mod до fake-tls')
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
                if o['pos'] and ',' in o['pos']:
                    raise ValueError('multiple fakedsplit positions are not representable per payload')
                pos = o['pos'] or ''
                pat = ('pattern=' + o['fakedsplit_pattern']) if o['fakedsplit_pattern'] else ''
                body.append('--lua-desync=' + join('fakedsplit', pinline, ('pos=' + pos) if pos else '', pat, f, rep, ipid))
            elif m == 'hostfakesplit':
                if ptype == 'unknown':
                    continue  # без имени хоста подменять нечего
                action = 'hostfakesplit_alt' if o['host_alt_order'] else 'hostfakesplit'
                body.append('--lua-desync=' + join(action, ('host=' + o['host']) if o['host'] else '', f, rep, ipid))
            elif m == 'syndata':
                pass
            else:
                raise ValueError('режим ' + m)
        if body:
            lines.append('--payload=' + ptype)
            lines += body
    return lines


def udp_section(o, kind):
    rep = 'repeats=' + o['repeats'] if o['repeats'] else ''
    if 'fake' not in o['modes'] or len(o['modes']) > 1:
        raise ValueError('udp режим ' + ','.join(o['modes']))
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
    for index, p in enumerate(read_profiles(path), 1):
        try:
            kind = classify(p)
            o = parse_opts(p)
            validate_match(p, kind)
            validate_actions(p, o, kind)
            l7 = dict(p).get('--filter-l7')
            allowed_l7 = ('discord,stun', 'discord,stun,unknown') if kind == 'discord_udp' else (('quic',) if kind in ('quic', 'quic_ipset') else ())
            if l7 and l7 not in allowed_l7:
                raise ValueError('L7 condition is incompatible with section ' + kind)
            if kind in ('quic', 'quic_ipset', 'discord_udp', 'game_udp'):
                if o['l3']:
                    raise ValueError('L3 condition for UDP is not representable by the current section format')
                lines = udp_section(o, 'quic' if kind == 'quic_ipset' else kind)
            elif kind == 'all_tcp':
                for k in ('discord_media', 'google', 'general', 'ipset_tcp'):
                    if k in sec:
                        raise ValueError('duplicate section ' + k)
                    sec[k] = (['# match-l3: ' + o['l3']] if o['l3'] else []) + tcp_section(o, k)
                continue
            else:
                lines = tcp_section(o, kind)
        except ValueError as error:
            raise ValueError(f'{path}: profile {index}: {error}') from error
        if o['l3']:
            lines.insert(0, '# match-l3: ' + o['l3'])
        if kind == 'quic_ipset':
            if 'quic' in sec and sec['quic'] != lines:
                raise ValueError(f'{path}: profile {index}: QUIC ipset and hostlist actions differ')
            sec.setdefault('quic', lines)
            continue
        if kind in sec:
            raise ValueError(f'{path}: profile {index}: duplicate section {kind}')
        sec[kind] = lines
    if 'ipset_tcp' in sec and 'general' in sec:
        # без порта 80 и 8443 профили одинаковы - тогда tcp_ipset берёт секцию general
        if sec['ipset_tcp'] == sec['general']:
            del sec['ipset_tcp']
    return sec


ORDER = ['quic', 'discord_udp', 'discord_media', 'google', 'general', 'ipset_tcp', 'game_tcp', 'game_udp']


def render(sec, sid, name, bat, desc, notes=()):
    out = ['# name: ' + name, '# desc: ' + desc, '# flowseal: ' + bat + ' (перенесено конвертером из 1.10.4)']
    out += ['# compatibility: ' + note for note in notes]
    for k in ORDER:
        if k in sec:
            out.append('[' + k + ']')
            out += sec[k]
    missing = [k for k in ORDER if k not in sec and k != 'ipset_tcp']
    if missing:
        raise ValueError('%s: нет секций %s' % (name, missing))
    return '\n'.join(out) + '\n'


def read_ours(path):
    sec, cur = {}, None
    with open(path, encoding='utf-8-sig') as source:
        lines = source.read().splitlines()
    for l in lines:
        l = l.strip()
        if l.startswith('# match-l3:') and cur:
            sec[cur].append(l)
            continue
        if not l or l.startswith('#'):
            continue
        m = re.match(r'^\[([a-z_]+)\]$', l)
        if m:
            cur = m.group(1)
            if cur not in ORDER or cur in sec:
                raise ValueError(f'{path}: unknown or duplicate section {cur}')
            sec[cur] = []
        elif cur:
            sec[cur].append(l)
        else:
            raise ValueError(f'{path}: action outside a section')
    return sec


def main():
    sys.stdout.reconfigure(encoding='utf-8')
    sys.stderr.reconfigure(encoding='utf-8')
    parser = argparse.ArgumentParser(description='Import Flowseal profiles without silently dropping unsupported options.')
    parser.add_argument('source')
    parser.add_argument('output')
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--allow-known-differences', action='store_true', help='Accept the four documented EXP compatibility differences only.')
    args = parser.parse_args()
    prepared = []
    try:
        definitions = STRATEGIES + [(sid, 'ALT'+sid, bat, '') for sid, bat in CHECK]
        for sid, name, bat, desc in definitions:
            warnings.clear()
            sections = convert(os.path.join(args.source, bat))
            notes = list(warnings)
            if notes and not args.allow_known_differences:
                raise ValueError(f'{bat}: known differences require --allow-known-differences: '+ '; '.join(notes))
            prepared.append((sid, name, sections, render(sections, sid, name, bat, desc, notes), notes))
        if args.check:
            different = False
            for sid, name, sections, _, notes in prepared:
                ours = read_ours(os.path.join(args.output, 'alt%s.txt' % sid))
                changed = [key for key in ORDER if sections.get(key) != ours.get(key)]
                different |= bool(changed)
                print(f'{name}: '+ ('DIFF '+','.join(changed) if changed else 'ok') + ('; '+ '; '.join(notes) if notes else ''))
            return int(different)
        os.makedirs(args.output, exist_ok=True)
        managed = {sid for sid, *_ in STRATEGIES}
        for sid, name, _, text, notes in prepared:
            if sid not in managed:
                continue
            temporary = None
            try:
                with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', newline='\n', dir=args.output, prefix='.import-', suffix='.tmp', delete=False) as output:
                    temporary = output.name
                    output.write(text)
                os.replace(temporary, os.path.join(args.output, 'alt%s.txt' % sid))
            finally:
                if temporary and os.path.exists(temporary):
                    os.unlink(temporary)
            print(f'alt{sid}.txt {name}: '+ ('; '.join(notes) if notes else 'ok'))
        return 0
    except (ValueError, OSError) as error:
        print('Import rejected: '+str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
