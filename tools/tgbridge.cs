// zapret: встроенный мост Telegram (MTProto -> WebSocket), перенос основной логики tg-ws-proxy от Flowseal
// (github.com/Flowseal/tg-ws-proxy, MIT, см. LICENSE-tg-ws-proxy.txt).
//
// Telegram Desktop подключается к 127.0.0.1:<порт> как к MTProto-прокси (secret "dd..."). Мост снимает обфускацию
// клиента, узнаёт номер дата-центра, открывает WebSocket к kws<N>.web.telegram.org/apiws (веб-версию Telegram у нас
// не режут, в отличие от адресов самих дата-центров) и гонит трафик туда, перешифровывая его своим ключом.
// Каждое сообщение MTProto уходит отдельным кадром WebSocket - так ждёт сервер.
//
// Компилируется PowerShell (Add-Type) при запуске tools\tgbridge.ps1, поэтому только C# 5: без $"", ?. и nameof.
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace ZapretTg
{
    // AES-256-CTR: 128-битный счётчик big-endian, как в obfuscated2
    public sealed class AesCtr : IDisposable
    {
        private readonly ICryptoTransform _enc;
        private readonly byte[] _counter = new byte[16];
        private readonly byte[] _ks = new byte[16];
        private int _pos = 16;
        private byte[] _ctrBuf = new byte[0];
        private byte[] _ksBuf = new byte[0];

        public AesCtr(byte[] key, byte[] iv)
        {
            Aes aes = Aes.Create();
            aes.Mode = CipherMode.ECB;
            aes.Padding = PaddingMode.None;
            aes.Key = key;
            _enc = aes.CreateEncryptor();
            Buffer.BlockCopy(iv, 0, _counter, 0, 16);
        }

        private void Inc()
        {
            for (int j = 15; j >= 0; j--) { if (++_counter[j] != 0) break; }
        }

        public void Process(byte[] buf, int off, int len)
        {
            int i = 0;
            while (i < len && _pos < 16) { buf[off + i] ^= _ks[_pos++]; i++; }
            if (i == len) return;
            int rem = len - i;
            int blocks = (rem + 15) / 16;
            if (_ctrBuf.Length < blocks * 16) { _ctrBuf = new byte[blocks * 16]; _ksBuf = new byte[blocks * 16]; }
            for (int b = 0; b < blocks; b++) { Buffer.BlockCopy(_counter, 0, _ctrBuf, b * 16, 16); Inc(); }
            _enc.TransformBlock(_ctrBuf, 0, blocks * 16, _ksBuf, 0);
            for (int k = 0; k < rem; k++) buf[off + i + k] ^= _ksBuf[k];
            int used = rem % 16;
            if (used == 0) { _pos = 16; }
            else { Buffer.BlockCopy(_ksBuf, (blocks - 1) * 16, _ks, 0, 16); _pos = used; }
        }

        public void Skip(int n) { Process(new byte[n], 0, n); }

        public void Dispose() { _enc.Dispose(); }
    }

    // Шифры одного соединения: клиент <-> мост (с secret) и мост <-> Telegram (без secret)
    public sealed class CryptoCtx
    {
        public AesCtr CltDec, CltEnc, TgEnc, TgDec;
        public int Dc;
        public bool Media;
        public bool Test;
        public uint Proto;
        public byte[] RelayInit;
    }

    // Делит поток к Telegram на пакеты транспорта MTProto: каждый уходит отдельным кадром WebSocket
    public sealed class Splitter
    {
        private readonly uint _proto;
        private byte[] _c = new byte[0];
        private byte[] _p = new byte[0];
        private int _len;
        private bool _disabled;

        public Splitter(uint proto) { _proto = proto; }

        public List<byte[]> Split(byte[] cipher, byte[] plain)
        {
            List<byte[]> parts = new List<byte[]>();
            if (cipher.Length == 0) return parts;
            if (_disabled) { parts.Add(cipher); return parts; }
            if (_c.Length < _len + cipher.Length)
            {
                int cap = Math.Max(_len + cipher.Length, _c.Length * 2);
                Array.Resize(ref _c, cap);
                Array.Resize(ref _p, cap);
            }
            Buffer.BlockCopy(cipher, 0, _c, _len, cipher.Length);
            Buffer.BlockCopy(plain, 0, _p, _len, plain.Length);
            _len += cipher.Length;
            int off = 0;
            while (off < _len)
            {
                int pl = NextLen(off, _len - off);
                if (pl < 0) break;
                if (pl == 0) { parts.Add(Slice(off, _len - off)); off = _len; _disabled = true; break; }
                parts.Add(Slice(off, pl));
                off += pl;
            }
            if (off > 0)
            {
                Buffer.BlockCopy(_c, off, _c, 0, _len - off);
                Buffer.BlockCopy(_p, off, _p, 0, _len - off);
                _len -= off;
            }
            return parts;
        }

        public List<byte[]> Flush()
        {
            List<byte[]> parts = new List<byte[]>();
            if (_len > 0) { parts.Add(Slice(0, _len)); _len = 0; }
            return parts;
        }

        private byte[] Slice(int off, int n)
        {
            byte[] r = new byte[n];
            Buffer.BlockCopy(_c, off, r, 0, n);
            return r;
        }

        // длина следующего пакета: -1 - данных ещё мало, 0 - не похоже на пакет (дальше без деления)
        private int NextLen(int off, int avail)
        {
            if (_proto == 0xEFEFEFEF)
            {
                int first = _p[off];
                long payload; int header;
                if (first == 0x7F || first == 0xFF)
                {
                    if (avail < 4) return -1;
                    payload = ((long)_p[off + 1] | ((long)_p[off + 2] << 8) | ((long)_p[off + 3] << 16)) * 4;
                    header = 4;
                }
                else { payload = (first & 0x7F) * 4; header = 1; }
                if (payload <= 0 || payload > 16 * 1024 * 1024) return 0;
                long n = header + payload;
                return avail < n ? -1 : (int)n;
            }
            if (avail < 4) return -1;
            long len = (long)(BitConverter.ToUInt32(_p, off) & 0x7FFFFFFF);
            if (len <= 0 || len > 16 * 1024 * 1024) return 0;
            long total = 4 + len;
            return avail < total ? -1 : (int)total;
        }
    }

    // WebSocket-клиент поверх TLS: свой, чтобы подключаться к нужному адресу с нужным именем (SNI и Host)
    public sealed class WsClient : IDisposable
    {
        private readonly TcpClient _tcp;
        private readonly SslStream _ssl;
        private readonly object _sendLock = new object();
        private static readonly RandomNumberGenerator Rng = RandomNumberGenerator.Create();

        private WsClient(TcpClient tcp, SslStream ssl) { _tcp = tcp; _ssl = ssl; }

        public static async Task<WsClient> Connect(string addr, string host, string path, int timeoutMs)
        {
            TcpClient tcp = new TcpClient(AddressFamily.InterNetwork);
            tcp.NoDelay = true;
            SslStream ssl = null;
            try
            {
                Task c = tcp.ConnectAsync(addr, 443);
                if (await Task.WhenAny(c, Task.Delay(timeoutMs)) != c) throw new TimeoutException("подключение к " + addr);
                await c;
                ssl = new SslStream(tcp.GetStream(), false);
                // TLS 1.2 явно: "по умолчанию Windows" в PowerShell 5.1 на старой Windows 10 может значить устаревшие версии.
                // Сертификат *.web.telegram.org проверяется как обычно.
                Task a = ssl.AuthenticateAsClientAsync(host, null, SslProtocols.Tls12, false);
                if (await Task.WhenAny(a, Task.Delay(timeoutMs)) != a) throw new TimeoutException("TLS с " + host);
                await a;
                byte[] key = new byte[16];
                Rng.GetBytes(key);
                string req = "GET " + path + " HTTP/1.1\r\nHost: " + host + "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
                    "Sec-WebSocket-Key: " + Convert.ToBase64String(key) + "\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: binary\r\n\r\n";
                byte[] rb = Encoding.ASCII.GetBytes(req);
                await ssl.WriteAsync(rb, 0, rb.Length);
                // заголовки ответа - до пустой строки
                List<byte> head = new List<byte>();
                byte[] one = new byte[1];
                while (head.Count < 8192)
                {
                    Task<int> r = ssl.ReadAsync(one, 0, 1);
                    if (await Task.WhenAny(r, Task.Delay(timeoutMs)) != r) throw new TimeoutException("ответ " + host);
                    if (await r <= 0) throw new IOException("сервер закрыл соединение");
                    head.Add(one[0]);
                    int n = head.Count;
                    if (n >= 4 && head[n - 4] == 13 && head[n - 3] == 10 && head[n - 2] == 13 && head[n - 1] == 10) break;
                }
                string status = Encoding.ASCII.GetString(head.ToArray()).Split('\n')[0];
                if (status.IndexOf(" 101", StringComparison.Ordinal) < 0) throw new IOException("ответ " + status.Trim());
                return new WsClient(tcp, ssl);
            }
            catch
            {
                if (ssl != null) ssl.Dispose();
                tcp.Close();
                throw;
            }
        }

        private void SendFrame(int opcode, byte[] data, int off, int len)
        {
            byte[] mask = new byte[4];
            lock (Rng) { Rng.GetBytes(mask); }
            int h = len < 126 ? 2 : (len < 65536 ? 4 : 10);
            byte[] f = new byte[h + 4 + len];
            f[0] = (byte)(0x80 | opcode);
            if (len < 126) f[1] = (byte)(0x80 | len);
            else if (len < 65536) { f[1] = 0x80 | 126; f[2] = (byte)(len >> 8); f[3] = (byte)len; }
            else { f[1] = 0x80 | 127; for (int i = 0; i < 8; i++) f[2 + i] = (byte)((long)len >> (8 * (7 - i))); }
            Buffer.BlockCopy(mask, 0, f, h, 4);
            for (int i = 0; i < len; i++) f[h + 4 + i] = (byte)(data[off + i] ^ mask[i & 3]);
            lock (_sendLock) { _ssl.Write(f, 0, f.Length); }
        }

        public void Send(byte[] data) { SendFrame(0x2, data, 0, data.Length); }

        private async Task<byte[]> ReadExact(int n)
        {
            byte[] b = new byte[n];
            int got = 0;
            while (got < n)
            {
                int r = await _ssl.ReadAsync(b, got, n - got);
                if (r <= 0) return null;
                got += r;
            }
            return b;
        }

        // Следующее сообщение (кадры-продолжения склеиваются). null - соединение закрыто.
        public async Task<byte[]> Recv()
        {
            MemoryStream msg = null;
            while (true)
            {
                byte[] h = await ReadExact(2);
                if (h == null) return null;
                bool fin = (h[0] & 0x80) != 0;
                int op = h[0] & 0x0F;
                bool masked = (h[1] & 0x80) != 0;
                long len = h[1] & 0x7F;
                if (len == 126) { byte[] b = await ReadExact(2); if (b == null) return null; len = (b[0] << 8) | b[1]; }
                else if (len == 127) { byte[] b = await ReadExact(8); if (b == null) return null; len = 0; for (int i = 0; i < 8; i++) len = (len << 8) | b[i]; }
                if (len < 0 || len > 32 * 1024 * 1024) throw new IOException("слишком большой кадр WebSocket");
                byte[] mk = null;
                if (masked) { mk = await ReadExact(4); if (mk == null) return null; }
                byte[] p = len > 0 ? await ReadExact((int)len) : new byte[0];
                if (p == null) return null;
                if (masked) for (int i = 0; i < p.Length; i++) p[i] ^= mk[i & 3];
                if (op == 0x8) return null;
                if (op == 0x9) { SendFrame(0xA, p, 0, p.Length); continue; }
                if (op == 0xA) continue;
                if (fin && msg == null) return p;
                if (msg == null) msg = new MemoryStream();
                msg.Write(p, 0, p.Length);
                if (fin) return msg.ToArray();
            }
        }

        public void Dispose()
        {
            try { SendFrame(0x8, new byte[0], 0, 0); } catch { }
            try { _ssl.Dispose(); } catch { }
            try { _tcp.Close(); } catch { }
        }
    }

    // Пул готовых соединений WebSocket к DC2 и DC4 (как у tg-ws-proxy): провайдер отбрасывает часть новых подключений
    // к адресам Telegram, а из пула Telegram получает уже открытое. Пул живёт, только пока Telegram пользуется мостом
    // (последние 10 минут): без него к серверам Telegram ничего не ходит.
    public static class Pool
    {
        private const int Size = 2;
        private const double MaxAgeSec = 100;
        private static readonly Dictionary<string, Queue<KeyValuePair<WsClient, DateTime>>> Idle = new Dictionary<string, Queue<KeyValuePair<WsClient, DateTime>>>();
        private static readonly HashSet<string> Refilling = new HashSet<string>();
        private static readonly Dictionary<string, int> Failures = new Dictionary<string, int>();
        private static readonly Dictionary<string, DateTime> RetryAfter = new Dictionary<string, DateTime>();
        private static DateTime _lastUse = DateTime.MinValue;
        private static Timer _timer;

        private static string Key(int dc, bool media) { return dc + (media ? "m" : ""); }

        public static void Start()
        {
            _timer = new Timer(delegate { Maintain(); }, null, 5000, 5000);
        }

        public static WsClient Get(int dc, bool media)
        {
            _lastUse = DateTime.Now;
            string k = Key(dc, media);
            WsClient got = null;
            List<WsClient> old = new List<WsClient>();
            lock (Idle)
            {
                Queue<KeyValuePair<WsClient, DateTime>> q;
                if (Idle.TryGetValue(k, out q))
                {
                    while (q.Count > 0)
                    {
                        KeyValuePair<WsClient, DateTime> e = q.Dequeue();
                        if ((DateTime.Now - e.Value).TotalSeconds < MaxAgeSec) { got = e.Key; break; }
                        old.Add(e.Key);
                    }
                }
            }
            foreach (WsClient w in old) w.Dispose();
            Refill(dc, media);
            return got;
        }

        private static void Refill(int dc, bool media)
        {
            string k = Key(dc, media);
            int need;
            lock (Idle)
            {
                if (Refilling.Contains(k)) return;
                DateTime ra;
                if (RetryAfter.TryGetValue(k, out ra) && ra > DateTime.Now) return;
                Queue<KeyValuePair<WsClient, DateTime>> q;
                need = Size - (Idle.TryGetValue(k, out q) ? q.Count : 0);
                if (need <= 0) return;
                Refilling.Add(k);
            }
            Task.Run(async () =>
            {
                int ok = 0;
                try
                {
                    List<Task<WsClient>> ts = new List<Task<WsClient>>();
                    for (int i = 0; i < need; i++) ts.Add(Bridge.ConnectFront(dc, media));
                    foreach (Task<WsClient> t in ts)
                    {
                        WsClient ws = null;
                        try { ws = await t; } catch { }
                        if (ws == null) continue;
                        lock (Idle)
                        {
                            Queue<KeyValuePair<WsClient, DateTime>> q;
                            if (!Idle.TryGetValue(k, out q)) { q = new Queue<KeyValuePair<WsClient, DateTime>>(); Idle[k] = q; }
                            q.Enqueue(new KeyValuePair<WsClient, DateTime>(ws, DateTime.Now));
                        }
                        ok++;
                    }
                }
                finally
                {
                    lock (Idle)
                    {
                        Refilling.Remove(k);
                        if (ok > 0) { Failures.Remove(k); RetryAfter.Remove(k); }
                        else
                        {
                            int f;
                            Failures.TryGetValue(k, out f);
                            Failures[k] = ++f;
                            RetryAfter[k] = DateTime.Now.AddSeconds(Math.Min(60, Math.Pow(2, f - 1)));
                        }
                    }
                }
            });
        }

        // Раз в 5 секунд: старые соединения - закрыть, пул - дозаполнить, пока Telegram пользуется мостом
        private static void Maintain()
        {
            try
            {
                bool active = (DateTime.Now - _lastUse).TotalMinutes < 10;
                List<WsClient> old = new List<WsClient>();
                lock (Idle)
                {
                    foreach (Queue<KeyValuePair<WsClient, DateTime>> q in Idle.Values)
                    {
                        int n = q.Count;
                        for (int i = 0; i < n; i++)
                        {
                            KeyValuePair<WsClient, DateTime> e = q.Dequeue();
                            if (active && (DateTime.Now - e.Value).TotalSeconds < MaxAgeSec) q.Enqueue(e); else old.Add(e.Key);
                        }
                    }
                }
                foreach (WsClient w in old) w.Dispose();
                if (!active) return;
                foreach (int dc in new int[] { 2, 4 }) { Refill(dc, false); Refill(dc, true); }
            }
            catch { }
        }
    }

    public static class Bridge
    {
        private static byte[] _secret;
        private static string _logPath;
        private static readonly object LogLock = new object();
        private static readonly RandomNumberGenerator Rng = RandomNumberGenerator.Create();
        // запасной адрес веб-входа Telegram (как у tg-ws-proxy): если DNS отдаёт недоступный
        private const string FrontIp = "149.154.167.220";

        public static void Log(string text)
        {
            if (string.IsNullOrEmpty(_logPath)) return;
            lock (LogLock)
            {
                try
                {
                    FileInfo fi = new FileInfo(_logPath);
                    if (fi.Exists && fi.Length > 1024 * 1024) File.Copy(_logPath, _logPath + ".1", true);
                    if (fi.Exists && fi.Length > 1024 * 1024) File.Delete(_logPath);
                    File.AppendAllText(_logPath, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + text + "\r\n", new UTF8Encoding(false));
                }
                catch { }
            }
        }

        public static byte[] FromHex(string hex)
        {
            byte[] b = new byte[hex.Length / 2];
            for (int i = 0; i < b.Length; i++) b[i] = Convert.ToByte(hex.Substring(i * 2, 2), 16);
            return b;
        }

        private static byte[] Sha256(byte[] a, byte[] b)
        {
            byte[] all = new byte[a.Length + b.Length];
            Buffer.BlockCopy(a, 0, all, 0, a.Length);
            Buffer.BlockCopy(b, 0, all, a.Length, b.Length);
            using (SHA256 s = SHA256.Create()) { return s.ComputeHash(all); }
        }

        private static byte[] Sub(byte[] a, int off, int n)
        {
            byte[] r = new byte[n];
            Buffer.BlockCopy(a, off, r, 0, n);
            return r;
        }

        private static byte[] Reversed(byte[] a)
        {
            byte[] r = (byte[])a.Clone();
            Array.Reverse(r);
            return r;
        }

        // Рукопожатие клиента (64 байта, обфускация с secret): номер дата-центра и ключи. null - чужой secret.
        public static CryptoCtx ParseClient(byte[] hs, byte[] secret)
        {
            byte[] prekeyIv = Sub(hs, 8, 48);
            AesCtr dec = new AesCtr(Sha256(Sub(prekeyIv, 0, 32), secret), Sub(prekeyIv, 32, 16));
            byte[] plain = (byte[])hs.Clone();
            dec.Process(plain, 0, 64);
            uint proto = BitConverter.ToUInt32(plain, 56);
            if (proto != 0xEFEFEFEF && proto != 0xEEEEEEEE && proto != 0xDDDDDDDD) { dec.Dispose(); return null; }
            int dcIdx = BitConverter.ToInt16(plain, 60);
            CryptoCtx ctx = new CryptoCtx();
            ctx.Proto = proto;
            ctx.Media = dcIdx < 0;
            int dc = Math.Abs(dcIdx);
            if (dc >= 10000) { ctx.Test = true; dc -= 10000; }
            ctx.Dc = dc;
            ctx.CltDec = dec;
            byte[] rev = Reversed(prekeyIv);
            ctx.CltEnc = new AesCtr(Sha256(Sub(rev, 0, 32), secret), Sub(rev, 32, 16));
            // своё рукопожатие с Telegram: тот же протокол и дата-центр, случайные ключи без secret
            byte[] rnd = new byte[64];
            while (true)
            {
                lock (Rng) { Rng.GetBytes(rnd); }
                uint s4 = BitConverter.ToUInt32(rnd, 0);
                if (rnd[0] == 0xEF) continue;
                // HEAD, POST, "GET ", 0xEEEEEEEE, 0xDDDDDDDD, начало TLS, OPTI
                if (s4 == 0x44414548 || s4 == 0x54534F50 || s4 == 0x20544547 || s4 == 0xEEEEEEEE || s4 == 0xDDDDDDDD || s4 == 0x02010316 || s4 == 0x4954504F) continue;
                if (BitConverter.ToUInt32(rnd, 4) == 0) continue;
                break;
            }
            byte[] encKey = Sub(rnd, 8, 32), encIv = Sub(rnd, 40, 16);
            AesCtr tmp = new AesCtr(encKey, encIv);
            byte[] enc = (byte[])rnd.Clone();
            tmp.Process(enc, 0, 64);
            tmp.Dispose();
            byte[] tail = new byte[8];
            Buffer.BlockCopy(BitConverter.GetBytes(proto), 0, tail, 0, 4);
            Buffer.BlockCopy(BitConverter.GetBytes((short)(ctx.Media ? -ctx.Dc : ctx.Dc)), 0, tail, 4, 2);
            byte[] r2 = new byte[2];
            lock (Rng) { Rng.GetBytes(r2); }
            tail[6] = r2[0]; tail[7] = r2[1];
            byte[] relay = (byte[])rnd.Clone();
            for (int i = 0; i < 8; i++) relay[56 + i] = (byte)(tail[i] ^ enc[56 + i] ^ rnd[56 + i]);
            ctx.RelayInit = relay;
            ctx.TgEnc = new AesCtr(encKey, encIv);
            ctx.TgEnc.Skip(64);
            byte[] rrev = Reversed(Sub(relay, 8, 48));
            ctx.TgDec = new AesCtr(Sub(rrev, 0, 32), Sub(rrev, 32, 16));
            return ctx;
        }

        private static async Task<byte[]> ReadExact(Stream s, int n, int timeoutMs)
        {
            byte[] b = new byte[n];
            int got = 0;
            while (got < n)
            {
                Task<int> r = s.ReadAsync(b, got, n - got);
                if (await Task.WhenAny(r, Task.Delay(timeoutMs)) != r) return null;
                int k = await r;
                if (k <= 0) return null;
                got += k;
            }
            return b;
        }

        // Адреса дата-центров для прямого подключения (если у провайдера их не режут), как у tg-ws-proxy
        private static readonly Dictionary<int, string> DcIps = new Dictionary<int, string> {
            { 1, "149.154.175.50" }, { 2, "149.154.167.51" }, { 3, "149.154.175.100" }, { 4, "149.154.167.91" }, { 5, "149.154.171.5" } };
        // Дата-центр, до которого не достучались никак, какое-то время не пробуем: иначе Telegram ждал бы по 10 секунд
        // на каждое соединение. Срок растёт с каждым провалом подряд: 1, 2, 4, 8, 15 минут. У провайдеров, что режут
        // DC1/DC3/DC5 наглухо, мост больше не тратит на них по 5-13 секунд каждую минуту. Удачное подключение сбрасывает счёт.
        private static readonly Dictionary<string, DateTime> DeadUntil = new Dictionary<string, DateTime>();
        private static readonly Dictionary<string, int> DeadCount = new Dictionary<string, int>();

        public static bool IsFront(int dc) { return dc == 2 || dc == 4 || dc == 203; }

        private static List<string> WsHosts(int dc, bool media)
        {
            if (dc == 203) dc = 2;
            List<string> hosts = new List<string>();
            if (media) hosts.Add("kws" + dc + "-1.web.telegram.org");
            hosts.Add("kws" + dc + ".web.telegram.org");
            return hosts;
        }

        // Одно соединение с веб-входом 149.154.167.220 (для пула DC2 и DC4)
        public static async Task<WsClient> ConnectFront(int dc, bool media)
        {
            foreach (string host in WsHosts(dc, media))
            {
                try { return await WsClient.Connect(FrontIp, host, "/apiws", 4000); }
                catch { }
            }
            return null;
        }

        // WebSocket к дата-центру, когда в пуле пусто. Провайдер отбрасывает часть новых подключений к адресам Telegram,
        // поэтому к веб-входу (DC2, DC4) - до трёх попыток, потом адрес из DNS. Для медиа - сначала kws<N>-1.
        public static async Task<WsClient> ConnectDc(int dc, bool media, bool test)
        {
            string path = test ? "/apiws_test" : "/apiws";
            List<string> addrs = new List<string>();
            if (IsFront(dc)) { addrs.Add(FrontIp); addrs.Add(FrontIp); addrs.Add(FrontIp); }
            foreach (string host in WsHosts(dc, media))
            {
                foreach (string addr in addrs.Count > 0 ? addrs.ToArray() : new string[0])
                {
                    try { return await WsClient.Connect(addr, host, path, 3000); }
                    catch (Exception ex) { Log("DC" + dc + (media ? " media" : "") + ": " + host + " через " + addr + " - " + ex.Message); }
                }
                try { return await WsClient.Connect(host, host, path, 4000); }
                catch (Exception ex) { Log("DC" + dc + (media ? " media" : "") + ": " + host + " - " + ex.Message); }
            }
            return null;
        }

        // Прямое TCP к дата-центру (обфускация MTProto без WebSocket) - последняя попытка
        private static async Task<TcpClient> ConnectDcTcp(int dc)
        {
            string ip;
            if (!DcIps.TryGetValue(dc == 203 ? 2 : dc, out ip)) return null;
            TcpClient t = new TcpClient(AddressFamily.InterNetwork);
            t.NoDelay = true;
            try
            {
                Task c = t.ConnectAsync(ip, 443);
                if (await Task.WhenAny(c, Task.Delay(5000)) != c) throw new TimeoutException("подключение к " + ip);
                await c;
                return t;
            }
            catch (Exception ex)
            {
                Log("DC" + dc + ": прямое подключение к " + ip + " - " + ex.Message);
                t.Close();
                return null;
            }
        }

        private static bool IsDead(string key)
        {
            lock (DeadUntil) { DateTime t; return DeadUntil.TryGetValue(key, out t) && t > DateTime.Now; }
        }

        // Возвращает срок в минутах, на который дата-центр отложен (0 - снят)
        private static int SetDead(string key, bool dead)
        {
            lock (DeadUntil)
            {
                if (!dead) { DeadUntil.Remove(key); DeadCount.Remove(key); return 0; }
                int n;
                DeadCount.TryGetValue(key, out n);
                // соединения, начатые до отметки, проваливаются следом - не удлиняем срок за каждое из них
                DateTime until;
                if (DeadUntil.TryGetValue(key, out until) && until > DateTime.Now) return (int)Math.Ceiling((until - DateTime.Now).TotalMinutes);
                n++;
                DeadCount[key] = n;
                int minutes = Math.Min(15, 1 << Math.Min(n - 1, 4));
                DeadUntil[key] = DateTime.Now.AddMinutes(minutes);
                return minutes;
            }
        }

        // Клиент <-> дата-центр напрямую по TCP: та же перешифровка, без деления на кадры
        private static async Task BridgeTcp(NetworkStream cs, TcpClient tg, CryptoCtx c)
        {
            using (tg)
            {
                NetworkStream ts = tg.GetStream();
                await ts.WriteAsync(c.RelayInit, 0, c.RelayInit.Length);
                Task upTask = Task.Run(async () =>
                {
                    byte[] buf = new byte[65536];
                    while (true)
                    {
                        int n = await cs.ReadAsync(buf, 0, buf.Length);
                        if (n <= 0) break;
                        c.CltDec.Process(buf, 0, n);
                        c.TgEnc.Process(buf, 0, n);
                        await ts.WriteAsync(buf, 0, n);
                    }
                });
                Task downTask = Task.Run(async () =>
                {
                    byte[] buf = new byte[65536];
                    while (true)
                    {
                        int n = await ts.ReadAsync(buf, 0, buf.Length);
                        if (n <= 0) break;
                        c.TgDec.Process(buf, 0, n);
                        c.CltEnc.Process(buf, 0, n);
                        await cs.WriteAsync(buf, 0, n);
                    }
                });
                await Task.WhenAny(upTask, downTask);
            }
        }

        private static async Task Handle(TcpClient client)
        {
            string label = "?";
            CryptoCtx ctx = null;
            WsClient ws = null;
            long up = 0, down = 0;
            DateTime started = DateTime.Now;
            try
            {
                label = client.Client.RemoteEndPoint.ToString();
                client.NoDelay = true;
                NetworkStream cs = client.GetStream();
                byte[] hs = await ReadExact(cs, 64, 10000);
                if (hs == null) return;
                ctx = ParseClient(hs, _secret);
                if (ctx == null) { Log(label + " чужое рукопожатие (не тот secret) - закрываю"); return; }
                if (ctx.Dc < 1 || (ctx.Dc > 5 && ctx.Dc != 203)) { Log(label + " неизвестный дата-центр " + ctx.Dc); return; }
                string key = ctx.Dc + (ctx.Media ? "m" : "") + (ctx.Test ? "t" : "");
                if (IsDead(key)) return;
                if (IsFront(ctx.Dc) && !ctx.Test) ws = Pool.Get(ctx.Dc == 203 ? 2 : ctx.Dc, ctx.Media);
                if (ws == null) ws = await ConnectDc(ctx.Dc, ctx.Media, ctx.Test);
                if (ws == null)
                {
                    TcpClient tg = ctx.Test ? null : await ConnectDcTcp(ctx.Dc);
                    if (tg == null)
                    {
                        // DC2 и DC4 не "хороним": провайдер отбрасывает подключения через раз, следующее может пройти
                        int minutes = IsFront(ctx.Dc) ? 0 : SetDead(key, true);
                        Log(label + " DC" + ctx.Dc + (ctx.Media ? " media" : "") + ": недоступен ни через WebSocket, ни напрямую" +
                            (minutes > 0 ? " - не пробую " + minutes + " мин" : ""));
                        return;
                    }
                    await BridgeTcp(cs, tg, ctx);
                    return;
                }
                SetDead(key, false);
                ws.Send(ctx.RelayInit);
                WsClient w = ws;
                CryptoCtx c = ctx;
                Task upTask = Task.Run(async () =>
                {
                    Splitter sp = new Splitter(c.Proto);
                    byte[] buf = new byte[65536];
                    while (true)
                    {
                        int n = await cs.ReadAsync(buf, 0, buf.Length);
                        if (n <= 0) { foreach (byte[] t in sp.Flush()) w.Send(t); break; }
                        c.CltDec.Process(buf, 0, n);
                        byte[] plain = Sub(buf, 0, n);
                        c.TgEnc.Process(buf, 0, n);
                        byte[] cipher = Sub(buf, 0, n);
                        foreach (byte[] part in sp.Split(cipher, plain)) w.Send(part);
                        Interlocked.Add(ref up, n);
                    }
                });
                Task downTask = Task.Run(async () =>
                {
                    while (true)
                    {
                        byte[] d = await w.Recv();
                        if (d == null) break;
                        c.TgDec.Process(d, 0, d.Length);
                        c.CltEnc.Process(d, 0, d.Length);
                        await cs.WriteAsync(d, 0, d.Length);
                        Interlocked.Add(ref down, d.Length);
                    }
                });
                await Task.WhenAny(upTask, downTask);
            }
            catch (Exception ex)
            {
                Log(label + " ошибка: " + ex.GetType().Name + ": " + ex.Message);
            }
            finally
            {
                if (ws != null) ws.Dispose();
                try { client.Close(); } catch { }
                if (ctx != null && (up > 0 || down > 0))
                    Log(label + " DC" + ctx.Dc + (ctx.Media ? " media" : "") + ": отправлено " + up + " Б, получено " + down + " Б за " + (int)(DateTime.Now - started).TotalSeconds + " с");
                if (ctx != null) { ctx.CltDec.Dispose(); ctx.CltEnc.Dispose(); ctx.TgEnc.Dispose(); ctx.TgDec.Dispose(); }
            }
        }

        // Главный цикл: слушает только 127.0.0.1. Возвращается лишь при ошибке запуска (порт занят).
        public static void Run(int port, string secretHex, string logPath)
        {
            _secret = FromHex(secretHex);
            _logPath = logPath;
            TcpListener listener = new TcpListener(IPAddress.Loopback, port);
            try { listener.Start(); }
            catch (Exception ex) { Log("порт " + port + " занят (" + ex.Message + ") - мост не запущен"); throw; }
            Log("мост Telegram слушает 127.0.0.1:" + port);
            Pool.Start();
            while (true)
            {
                TcpClient c = listener.AcceptTcpClient();
                Task.Run(() => Handle(c));
            }
        }

        // ---------- проверки (dev\tests) ----------

        // Как клиент Telegram: рукопожатие с secret для дата-центра dc, протокол "padded intermediate" (dd)
        private static byte[] ClientHandshake(byte[] secret, int dcIdx, out AesCtr enc, out AesCtr dec)
        {
            byte[] hs = new byte[64];
            while (true) { lock (Rng) { Rng.GetBytes(hs); } if (hs[0] != 0xEF && BitConverter.ToUInt32(hs, 4) != 0) break; }
            Buffer.BlockCopy(BitConverter.GetBytes(0xDDDDDDDDu), 0, hs, 56, 4);
            Buffer.BlockCopy(BitConverter.GetBytes((short)dcIdx), 0, hs, 60, 2);
            byte[] prekeyIv = Sub(hs, 8, 48);
            enc = new AesCtr(Sha256(Sub(prekeyIv, 0, 32), secret), Sub(prekeyIv, 32, 16));
            byte[] e = (byte[])hs.Clone();
            enc.Process(e, 0, 64);
            for (int i = 56; i < 64; i++) hs[i] = e[i];
            byte[] rev = Reversed(prekeyIv);
            dec = new AesCtr(Sha256(Sub(rev, 0, 32), secret), Sub(rev, 32, 16));
            return hs;
        }

        private static byte[] Frame(byte[] payload)
        {
            byte[] f = new byte[4 + payload.Length];
            Buffer.BlockCopy(BitConverter.GetBytes(payload.Length), 0, f, 0, 4);
            Buffer.BlockCopy(payload, 0, f, 4, payload.Length);
            return f;
        }

        // Шифры моста сходятся с шифрами клиента и сервера Telegram в обе стороны. "ok" или описание ошибки.
        public static string SelfTest()
        {
            byte[] secret = new byte[16];
            lock (Rng) { Rng.GetBytes(secret); }
            AesCtr cEnc, cDec;
            byte[] hs = ClientHandshake(secret, -4, out cEnc, out cDec);
            CryptoCtx ctx = ParseClient(hs, secret);
            if (ctx == null) return "мост не разобрал рукопожатие клиента";
            if (ctx.Dc != 4 || !ctx.Media || ctx.Proto != 0xDDDDDDDD) return "неверный разбор: DC" + ctx.Dc + " media=" + ctx.Media;
            byte[] wrong = new byte[16];
            if (ParseClient(hs, wrong) != null) return "рукопожатие с чужим secret принято";
            // сервер Telegram: ключи из relay init без secret
            byte[] ri = ctx.RelayInit;
            AesCtr sDec = new AesCtr(Sub(ri, 8, 32), Sub(ri, 40, 16));
            byte[] rp = (byte[])ri.Clone();
            sDec.Process(rp, 0, 64);
            if (BitConverter.ToUInt32(rp, 56) != 0xDDDDDDDD || BitConverter.ToInt16(rp, 60) != -4) return "сервер не понял рукопожатие моста";
            byte[] rrev = Reversed(Sub(ri, 8, 48));
            AesCtr sEnc = new AesCtr(Sub(rrev, 0, 32), Sub(rrev, 32, 16));
            // клиент -> сервер: два пакета одним куском, мост должен разрезать на два кадра
            byte[] m1 = Encoding.ASCII.GetBytes("hello telegram 0123456789"), m2 = new byte[300];
            for (int i = 0; i < m2.Length; i++) m2[i] = (byte)i;
            byte[] f1 = Frame(m1), f2 = Frame(m2);
            byte[] wire = new byte[f1.Length + f2.Length];
            Buffer.BlockCopy(f1, 0, wire, 0, f1.Length);
            Buffer.BlockCopy(f2, 0, wire, f1.Length, f2.Length);
            byte[] sent = (byte[])wire.Clone();
            cEnc.Process(sent, 0, sent.Length);
            ctx.CltDec.Process(sent, 0, sent.Length);
            byte[] plain = (byte[])sent.Clone();
            ctx.TgEnc.Process(sent, 0, sent.Length);
            List<byte[]> parts = new Splitter(ctx.Proto).Split(sent, plain);
            if (parts.Count != 2 || parts[0].Length != f1.Length) return "пакеты разрезаны неверно: " + parts.Count;
            byte[] got = new byte[sent.Length];
            Buffer.BlockCopy(parts[0], 0, got, 0, parts[0].Length);
            Buffer.BlockCopy(parts[1], 0, got, parts[0].Length, parts[1].Length);
            sDec.Process(got, 0, got.Length);
            for (int i = 0; i < wire.Length; i++) if (got[i] != wire[i]) return "сервер получил не то, что отправил клиент";
            // сервер -> клиент
            byte[] back = Frame(Encoding.ASCII.GetBytes("answer from telegram"));
            byte[] b2 = (byte[])back.Clone();
            sEnc.Process(b2, 0, b2.Length);
            ctx.TgDec.Process(b2, 0, b2.Length);
            ctx.CltEnc.Process(b2, 0, b2.Length);
            cDec.Process(b2, 0, b2.Length);
            for (int i = 0; i < back.Length; i++) if (b2[i] != back[i]) return "клиент получил не то, что отправил сервер";
            // срок для мёртвого дата-центра: 1, 2, 4... минут; соединения, проваленные внутри срока, его не удлиняют
            string dk = "selftest";
            int d1 = SetDead(dk, true), d1again = SetDead(dk, true);
            lock (DeadUntil) DeadUntil[dk] = DateTime.Now.AddSeconds(-1);
            int d2 = SetDead(dk, true);
            lock (DeadUntil) DeadUntil[dk] = DateTime.Now.AddSeconds(-1);
            int d3 = SetDead(dk, true);
            bool dead = IsDead(dk);
            SetDead(dk, false);
            if (d1 != 1 || d1again != 1 || d2 != 2 || d3 != 4 || !dead || IsDead(dk)) return "срок мёртвого дата-центра: " + d1 + "," + d1again + "," + d2 + "," + d3;
            return "ok";
        }

        // Живая проверка через запущенный мост: запрос req_pq_multi (первый шаг входа, без учётной записи) к дата-центру dc.
        // Telegram отвечает resPQ с тем же nonce - значит, путь до дата-центра через мост работает.
        public static string LiveTest(int port, string secretHex, int dc)
        {
            byte[] secret = FromHex(secretHex);
            using (TcpClient tc = new TcpClient(AddressFamily.InterNetwork))
            {
                tc.Connect(IPAddress.Loopback, port);
                tc.ReceiveTimeout = 15000;
                NetworkStream s = tc.GetStream();
                AesCtr enc, dec;
                s.Write(ClientHandshake(secret, dc, out enc, out dec), 0, 64);
                byte[] nonce = new byte[16];
                lock (Rng) { Rng.GetBytes(nonce); }
                long msgId = ((long)(DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalSeconds << 32) & ~3L;
                byte[] body = new byte[40];
                Buffer.BlockCopy(BitConverter.GetBytes(msgId), 0, body, 8, 8);
                Buffer.BlockCopy(BitConverter.GetBytes(20), 0, body, 16, 4);
                Buffer.BlockCopy(BitConverter.GetBytes(0xBE7E8EF1u), 0, body, 20, 4);
                Buffer.BlockCopy(nonce, 0, body, 24, 16);
                byte[] pkt = Frame(body);
                enc.Process(pkt, 0, pkt.Length);
                s.Write(pkt, 0, pkt.Length);
                byte[] lenb = new byte[4];
                int got = 0;
                while (got < 4) { int r = s.Read(lenb, got, 4 - got); if (r <= 0) return "DC" + dc + ": соединение закрыто без ответа"; got += r; }
                dec.Process(lenb, 0, 4);
                int len = BitConverter.ToInt32(lenb, 0) & 0x7FFFFFFF;
                if (len < 40 || len > 4096) return "DC" + dc + ": странная длина ответа " + len;
                byte[] resp = new byte[len];
                got = 0;
                while (got < len) { int r = s.Read(resp, got, len - got); if (r <= 0) return "DC" + dc + ": ответ оборван"; got += r; }
                dec.Process(resp, 0, len);
                if (BitConverter.ToUInt32(resp, 20) != 0x05162463) return "DC" + dc + ": ответ не resPQ";
                for (int i = 0; i < 16; i++) if (resp[24 + i] != nonce[i]) return "DC" + dc + ": чужой nonce";
                return "ok";
            }
        }
    }
}
