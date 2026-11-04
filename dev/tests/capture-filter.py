"""Evaluate the bundled engine's actual filters; never open WinDivert or send packets."""
import ctypes as c
import ipaddress
from pathlib import Path
import struct
import sys

pkg = Path(sys.argv[1])
dll = c.WinDLL(str(pkg / 'bin/WinDivert.dll'), use_last_error=True)
compile_filter = dll.WinDivertHelperCompileFilter
compile_filter.argtypes = (c.c_char_p, c.c_int, c.c_void_p, c.c_uint, c.POINTER(c.c_char_p), c.POINTER(c.c_uint))
compile_filter.restype = c.c_int
evaluate = dll.WinDivertHelperEvalFilter
evaluate.argtypes = (c.c_char_p, c.c_void_p, c.c_uint, c.c_void_p)
evaluate.restype = c.c_int

class Address(c.Structure):
    _fields_ = [('timestamp', c.c_int64), ('flags', c.c_uint32), ('reserved', c.c_uint32), ('data', c.c_ubyte * 64)]

assert c.sizeof(Address) == 80
exported_filters = [Path(path).read_text(encoding='utf-8-sig').strip().encode('ascii') for path in sys.argv[2:]]
for value in exported_filters:
    error, position = c.c_char_p(), c.c_uint()
    assert compile_filter(value, 0, None, 0, c.byref(error), c.byref(position)), (error.value, position.value, value[max(0, position.value-80):position.value+120])
filters = exported_filters[:2]

def packet(dst, proto='udp', port=27015, payload=b'game', flags=0x02, src=None, sport=40000):
    ip = ipaddress.ip_address(dst)
    if proto == 'udp':
        body = struct.pack('!HHHH', sport, port, 8 + len(payload), 0) + payload
        protocol = 17
    else:
        body = struct.pack('!HHIIBBHHH', sport, port, 1, 0, 0x50, flags, 65535, 0, 0) + payload
        protocol = 6
    if ip.version == 4:
        head = struct.pack('!BBHHHBBH4s4s', 0x45, 0, 20 + len(body), 0, 0, 64, protocol, 0, ipaddress.ip_address(src or '10.0.0.2').packed, ip.packed)
    else:
        head = struct.pack('!IHBB16s16s', 6 << 28, len(body), protocol, 64, ipaddress.ip_address(src or '2001:4860::1234').packed, ip.packed)
    return head + body, ip.version

count = 0
def check(dst, *, outbound=True, excluded=False, expected_before=None, **kwargs):
    global count
    raw, version = packet(dst, **kwargs)
    address = Address()
    address.flags = ((1 << 17) if outbound else 0) | ((1 << 20) if version == 6 else 0)
    buffer = c.create_string_buffer(raw)
    results = [bool(evaluate(value, buffer, len(raw), c.byref(address))) for value in filters]
    if expected_before is not None:
        assert results[0] == expected_before, ('baseline', dst, kwargs, results)
    assert results[1] == (results[0] and not excluded), (dst, outbound, kwargs, results)
    count += 1

for cidr in ('104.255.104.0/22', '164.153.136.0/22', '192.81.240.0/21', '198.133.210.0/24'):
    net = ipaddress.ip_network(cidr)
    for dst in (str(net.network_address), str(net.broadcast_address)):
        for port in (1024, 27015, 50050, 65535):
            check(dst, port=port, excluded=True, expected_before=True)
        for port in (443, 1024, 27123, 65535):
            for flags in (0x02, 0x10, 0x18, 0x11, 0x14):
                check(dst, proto='tcp', port=port, flags=flags, excluded=True, expected_before=True)
        check(dst, src='1.1.1.1', proto='tcp', port=443, flags=0x12, outbound=False, expected_before=True)
        for sport in (443, 27123):
            for flags in (0x12, 0x11, 0x14):
                check('10.0.0.2', src=dst, proto='tcp', port=49152, sport=sport, flags=flags, outbound=False, excluded=True, expected_before=True)
        check('1.1.1.1', src=dst, proto='tcp', port=27123, expected_before=True)
        check(dst, outbound=False)
        check(dst, port=443, payload=b'\xc0\0\0\0\x01' + bytes(251), excluded=True, expected_before=True)
    for dst in (str(net.network_address - 1), str(net.broadcast_address + 1)):
        check(dst, expected_before=True)
        check(dst, proto='tcp', port=27123, expected_before=True)
        for flags in (0x12, 0x11, 0x14):
            check('10.0.0.2', src=dst, proto='tcp', port=49152, sport=27123, flags=flags, outbound=False, expected_before=True)
for dst in ('8.8.8.8', '1.1.1.1', '2001:4860:4860::8888', '2606:4700:4700::1111'):
    check(dst, expected_before=True)
    check(dst, proto='tcp', port=443, expected_before=True)
    for flags in (0x12, 0x11, 0x14):
        local = '10.0.0.2' if ipaddress.ip_address(dst).version == 4 else '2001:4860::1234'
        check(local, src=dst, proto='tcp', port=49152, sport=27123, flags=flags, outbound=False, expected_before=True)
if len(exported_filters) > 2:
    filters = [exported_filters[0], exported_filters[2]]
    for last in range(99, 133):
        remote = f'123.123.123.{last}'
        excluded = 100 <= last <= 131
        check(remote, port=27015, excluded=excluded, expected_before=True)
        check(remote, proto='tcp', port=443, flags=0x10, excluded=excluded, expected_before=True)
        for flags in (0x12, 0x11, 0x14):
            check('10.0.0.2', src=remote, proto='tcp', port=49152, sport=27123,
                  flags=flags, outbound=False, excluded=excluded, expected_before=True)
print(f'ok {count} native packet cases: remote-address TCP exclusions in both directions, outbound UDP excluded, other paths retained; {len(exported_filters)} complete filters compiled')
