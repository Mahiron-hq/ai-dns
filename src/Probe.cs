// Network probing engine for AI-DNS.
// Compiled at run time by Windows PowerShell 5.1, so it is limited to C# 5 and .NET Framework 4.7+.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace AiDns
{
    /// <summary>Outcome of a single probe. <see cref="None"/> means success.</summary>
    public enum ProbeError
    {
        None,
        Timeout,
        Blackholed,
        EmptyAnswer,
        ServerFailure,
        ConnectTimeout,
        ConnectRefused,
        ConnectFailed,
        TlsTimeout,
        TlsReset,
        TlsFailed,
        CertificateInvalid,
        NoResponse,
        Stalled,
        BadResponse,
        HttpStatus
    }

    /// <summary>One A-record lookup of <see cref="Name"/> against the resolver at <see cref="Server"/>.</summary>
    public sealed class DnsQuery
    {
        public string Server;
        public string Name;
        public string Tag;

        public int RCode = -1;
        public string[] Addresses = new string[0];
        public double? RttMs;
        public int Attempts;
        public ProbeError Error = ProbeError.Timeout;

        public bool Ok { get { return Error == ProbeError.None; } }

        /// <summary>True when the server replied at all, even with an error or a blackhole address.</summary>
        public bool Answered { get { return RCode >= 0; } }
    }

    /// <summary>An HTTPS GET sent to <see cref="Address"/> with <see cref="Host"/> as SNI and Host header.</summary>
    public sealed class HttpsProbe
    {
        public string Address;
        public string Host;
        public string Path = "/";
        public string[] Headers = new string[0];
        public int MaxBytes = 65536;
        public string Tag;

        public bool TcpOk;
        public bool TlsOk;
        public int Status;
        public bool Complete;
        public bool Stalled;
        public long Bytes;
        public double? ConnectMs;
        public double? TlsMs;
        public string Head = "";
        public ProbeError Error;
        public string Detail = "";

        public bool Ok { get { return TlsOk && Status > 0 && !Stalled; } }

        internal byte[] Body;
        internal bool Chunked;
    }

    /// <summary>A DNS-over-HTTPS lookup of <see cref="Name"/> through <see cref="Template"/> served at <see cref="Address"/>.</summary>
    public sealed class DohProbe
    {
        public string Address;
        public string Template;
        public string Name = "chatgpt.com";
        public string Tag;

        public HttpsProbe Transport;
        public string[] Addresses = new string[0];
        public double? RttMs;
        public ProbeError Error = ProbeError.Timeout;

        public bool Ok { get { return Error == ProbeError.None; } }
    }

    /// <summary>Result of downloading one URL.</summary>
    public sealed class FetchResult
    {
        public string Url;
        public bool Ok;
        public int Status;
        public string Content;
        public string Error;
        public double Ms;
    }

    /// <summary>DNS wire format (RFC 1035) encoding and decoding for A queries.</summary>
    public static class DnsWire
    {
        public const int MaxNameLength = 253;

        public sealed class Response
        {
            public ushort Id;
            public int RCode;
            public bool Truncated;
            public string QuestionName;
            public List<string> Addresses = new List<string>();
        }

        /// <summary>Builds a recursive A/IN query for <paramref name="name"/>.</summary>
        /// <exception cref="ArgumentException">The name is empty, too long, non-ASCII or has an invalid label.</exception>
        public static byte[] BuildQuery(string name, ushort id)
        {
            if (name == null) throw new ArgumentNullException("name");
            string trimmed = name.TrimEnd('.');
            if (trimmed.Length == 0 || trimmed.Length > MaxNameLength) throw new ArgumentException("Invalid DNS name.", "name");

            MemoryStream ms = new MemoryStream(18 + trimmed.Length);
            ms.WriteByte((byte)(id >> 8));
            ms.WriteByte((byte)id);
            ms.WriteByte(0x01); ms.WriteByte(0x00);             // flags: recursion desired
            ms.WriteByte(0x00); ms.WriteByte(0x01);             // QDCOUNT
            for (int i = 0; i < 6; i++) ms.WriteByte(0x00);     // ANCOUNT, NSCOUNT, ARCOUNT
            foreach (string label in trimmed.Split('.'))
            {
                if (label.Length == 0 || label.Length > 63) throw new ArgumentException("Invalid DNS label.", "name");
                foreach (char c in label) if (c > 127) throw new ArgumentException("DNS name must be ASCII.", "name");
                byte[] bytes = Encoding.ASCII.GetBytes(label);
                ms.WriteByte((byte)bytes.Length);
                ms.Write(bytes, 0, bytes.Length);
            }
            ms.WriteByte(0x00);
            ms.WriteByte(0x00); ms.WriteByte(0x01);             // QTYPE A
            ms.WriteByte(0x00); ms.WriteByte(0x01);             // QCLASS IN
            return ms.ToArray();
        }

        /// <summary>Decodes a response. Returns null for anything that is not a well-formed DNS response.</summary>
        public static Response Parse(byte[] buffer, int offset, int count)
        {
            if (buffer == null || offset < 0 || count < 12 || offset + count > buffer.Length) return null;
            int end = offset + count;
            if ((buffer[offset + 2] & 0x80) == 0) return null;

            Response r = new Response();
            r.Id = (ushort)ReadUInt16(buffer, offset);
            r.Truncated = (buffer[offset + 2] & 0x02) != 0;
            r.RCode = buffer[offset + 3] & 0x0F;
            int questions = ReadUInt16(buffer, offset + 4);
            int answers = ReadUInt16(buffer, offset + 6);

            int p = offset + 12;
            for (int i = 0; i < questions; i++)
            {
                string qname;
                p = ReadName(buffer, offset, end, p, out qname);
                if (p < 0 || p + 4 > end) return null;
                if (i == 0) r.QuestionName = qname;
                p += 4;
            }
            for (int i = 0; i < answers; i++)
            {
                string ignored;
                p = ReadName(buffer, offset, end, p, out ignored);
                if (p < 0 || p + 10 > end) break;
                int type = ReadUInt16(buffer, p);
                int cls = ReadUInt16(buffer, p + 2);
                int length = ReadUInt16(buffer, p + 8);
                p += 10;
                if (p + length > end) break;
                if (type == 1 && cls == 1 && length == 4)
                    r.Addresses.Add(buffer[p] + "." + buffer[p + 1] + "." + buffer[p + 2] + "." + buffer[p + 3]);
                p += length;
            }
            return r;
        }

        /// <summary>
        /// Splits the answer into usable addresses and an error code. Smart DNS services that have
        /// dropped a domain answer 0.0.0.0 or a loopback address, which is reported as Blackholed.
        /// </summary>
        public static ProbeError Classify(Response r, out string[] usable)
        {
            List<string> good = new List<string>();
            foreach (string a in r.Addresses)
                if (a != "0.0.0.0" && !a.StartsWith("127.", StringComparison.Ordinal)) good.Add(a);
            usable = good.ToArray();
            if (good.Count > 0) return ProbeError.None;
            if (r.Addresses.Count > 0) return ProbeError.Blackholed;
            if (r.RCode != 0) return ProbeError.ServerFailure;
            return ProbeError.EmptyAnswer;
        }

        static int ReadUInt16(byte[] b, int p)
        {
            return (b[p] << 8) | b[p + 1];
        }

        // Follows compression pointers (bounded, so a malicious loop cannot hang the parser) and
        // returns the position right after the name as it appears in the original byte sequence.
        static int ReadName(byte[] b, int start, int end, int p, out string name)
        {
            name = null;
            StringBuilder sb = new StringBuilder();
            int resume = -1;
            int jumps = 0;
            while (true)
            {
                if (p >= end) return -1;
                int len = b[p];
                if (len == 0) { p++; break; }
                if ((len & 0xC0) == 0xC0)
                {
                    if (p + 1 >= end || ++jumps > 32) return -1;
                    int target = start + (((len & 0x3F) << 8) | b[p + 1]);
                    if (resume < 0) resume = p + 2;
                    if (target >= end) return -1;
                    p = target;
                    continue;
                }
                if ((len & 0xC0) != 0 || p + 1 + len > end) return -1;
                if (sb.Length > 0) sb.Append('.');
                sb.Append(Encoding.ASCII.GetString(b, p + 1, len));
                if (sb.Length > 255) return -1;
                p += 1 + len;
            }
            name = sb.ToString();
            return resume >= 0 ? resume : p;
        }
    }

    /// <summary>
    /// Sends many UDP DNS queries from a single socket and matches replies by source address,
    /// transaction id and question name. Total run time is bounded by attempts * timeout,
    /// regardless of how many servers are queried or how many of them are dead.
    /// </summary>
    public static class DnsBatch
    {
        // SIO_UDP_CONNRESET: without it an ICMP port-unreachable from one dead server makes the next
        // ReceiveFrom on the shared socket fail with WSAECONNRESET.
        const int SioUdpConnReset = -1744830452;
        const int MaxBatch = 60000;

        /// <exception cref="ArgumentException">A query has a non-IPv4 server or an invalid name, or the batch is too large.</exception>
        public static void Run(DnsQuery[] queries, int timeoutMs, int attempts)
        {
            if (queries == null) throw new ArgumentNullException("queries");
            if (timeoutMs <= 0) throw new ArgumentOutOfRangeException("timeoutMs");
            if (attempts <= 0) throw new ArgumentOutOfRangeException("attempts");
            if (queries.Length > MaxBatch) throw new ArgumentException("Too many queries in one batch.", "queries");
            int n = queries.Length;
            if (n == 0) return;

            byte[][] packets = new byte[n][];
            EndPoint[] targets = new EndPoint[n];
            double[] sentAt = new double[n];
            bool[] done = new bool[n];
            Dictionary<long, int> pending = new Dictionary<long, int>(n);
            int seed = new Random().Next(0, 65536);

            for (int i = 0; i < n; i++)
            {
                DnsQuery q = queries[i];
                IPAddress address;
                if (q == null || !IPAddress.TryParse(q.Server, out address) || address.AddressFamily != AddressFamily.InterNetwork)
                    throw new ArgumentException("Query " + i + " has no valid IPv4 server.", "queries");
                ushort id = (ushort)((seed + i) & 0xFFFF);
                packets[i] = DnsWire.BuildQuery(q.Name, id);
                targets[i] = new IPEndPoint(address, 53);
                pending[Key(address, id)] = i;
                q.Error = ProbeError.Timeout;
                q.RCode = -1;
                q.Attempts = 0;
            }

            using (Socket socket = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp))
            {
                socket.ReceiveBufferSize = 4 << 20;
                socket.SendBufferSize = 1 << 20;
                socket.Bind(new IPEndPoint(IPAddress.Any, 0));
                try { socket.IOControl(SioUdpConnReset, new byte[4], null); }
                catch (SocketException) { }

                Stopwatch clock = Stopwatch.StartNew();
                byte[] buffer = new byte[4096];
                int remaining = n;

                for (int attempt = 0; attempt < attempts && remaining > 0; attempt++)
                {
                    int sent = 0;
                    for (int i = 0; i < n; i++)
                    {
                        if (done[i]) continue;
                        try { socket.SendTo(packets[i], targets[i]); }
                        catch (SocketException) { }
                        sentAt[i] = clock.Elapsed.TotalMilliseconds;
                        queries[i].Attempts++;
                        // Pace bursts and drain replies in between so neither the NAT nor our receive buffer overflows.
                        if (++sent % 128 == 0)
                        {
                            while (remaining > 0 && socket.Poll(0, SelectMode.SelectRead))
                                remaining -= Receive(socket, buffer, queries, pending, done, sentAt, clock);
                            Thread.Sleep(1);
                        }
                    }

                    double deadline = clock.Elapsed.TotalMilliseconds + timeoutMs;
                    while (remaining > 0)
                    {
                        double left = deadline - clock.Elapsed.TotalMilliseconds;
                        if (left <= 0 || !socket.Poll((int)(left * 1000), SelectMode.SelectRead)) break;
                        remaining -= Receive(socket, buffer, queries, pending, done, sentAt, clock);
                    }
                }
            }
        }

        static int Receive(Socket socket, byte[] buffer, DnsQuery[] queries, Dictionary<long, int> pending,
                           bool[] done, double[] sentAt, Stopwatch clock)
        {
            EndPoint from = new IPEndPoint(IPAddress.Any, 0);
            int length;
            try { length = socket.ReceiveFrom(buffer, ref from); }
            catch (SocketException) { return 0; }

            IPEndPoint source = (IPEndPoint)from;
            if (source.Port != 53) return 0;
            DnsWire.Response r = DnsWire.Parse(buffer, 0, length);
            if (r == null) return 0;

            int index;
            if (!pending.TryGetValue(Key(source.Address, r.Id), out index) || done[index]) return 0;
            DnsQuery q = queries[index];
            if (r.QuestionName == null ||
                !string.Equals(r.QuestionName.TrimEnd('.'), q.Name.TrimEnd('.'), StringComparison.OrdinalIgnoreCase)) return 0;

            done[index] = true;
            q.RttMs = clock.Elapsed.TotalMilliseconds - sentAt[index];
            q.RCode = r.RCode;
            string[] usable;
            q.Error = DnsWire.Classify(r, out usable);
            q.Addresses = usable;
            return 1;
        }

        static long Key(IPAddress address, ushort id)
        {
            byte[] b = address.GetAddressBytes();
            uint ip = ((uint)b[0] << 24) | ((uint)b[1] << 16) | ((uint)b[2] << 8) | b[3];
            return ((long)ip << 16) | id;
        }
    }

    /// <summary>Runs HTTPS and DNS-over-HTTPS probes concurrently with per-operation timeouts.</summary>
    public static class HttpsBatch
    {
        const string UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36";
        const int HeadBytes = 12288;

        /// <summary>
        /// Executes every probe, at most <paramref name="parallelism"/> at a time. Never throws for
        /// network failures; each probe records its own <see cref="ProbeError"/>.
        /// </summary>
        public static void Run(HttpsProbe[] probes, DohProbe[] dohProbes, int parallelism, int connectMs, int ioMs)
        {
            if (parallelism <= 0) throw new ArgumentOutOfRangeException("parallelism");
            List<Task> tasks = new List<Task>();
            SemaphoreSlim gate = new SemaphoreSlim(parallelism);
            if (probes != null)
                foreach (HttpsProbe p in probes) if (p != null) tasks.Add(RunHttpsGated(gate, p, connectMs, ioMs));
            if (dohProbes != null)
                foreach (DohProbe d in dohProbes) if (d != null) tasks.Add(RunDohGated(gate, d, connectMs, ioMs));
            Task.WaitAll(tasks.ToArray());
        }

        static async Task RunHttpsGated(SemaphoreSlim gate, HttpsProbe p, int connectMs, int ioMs)
        {
            await gate.WaitAsync().ConfigureAwait(false);
            try
            {
                await ExecuteAsync(p, BuildRequest(p, "text/html,application/json;q=0.9,*/*;q=0.8"), connectMs, ioMs).ConfigureAwait(false);
            }
            catch (Exception e)
            {
                p.Error = ProbeError.BadResponse;
                p.Detail = e.GetBaseException().Message;
            }
            finally { gate.Release(); }
        }

        static async Task RunDohGated(SemaphoreSlim gate, DohProbe d, int connectMs, int ioMs)
        {
            await gate.WaitAsync().ConfigureAwait(false);
            try { await ExecuteDohAsync(d, connectMs, ioMs).ConfigureAwait(false); }
            catch (Exception)
            {
                d.Error = ProbeError.BadResponse;
            }
            finally { gate.Release(); }
        }

        static async Task ExecuteDohAsync(DohProbe d, int connectMs, int ioMs)
        {
            Uri uri;
            if (!Uri.TryCreate(d.Template, UriKind.Absolute, out uri) || uri.Scheme != Uri.UriSchemeHttps || uri.Port != 443)
            {
                d.Error = ProbeError.BadResponse;
                return;
            }
            byte[] query = DnsWire.BuildQuery(d.Name, 0);
            string encoded = Convert.ToBase64String(query).TrimEnd('=').Replace('+', '-').Replace('/', '_');

            HttpsProbe t = new HttpsProbe();
            t.Address = d.Address;
            t.Host = uri.Host;
            t.Path = uri.AbsolutePath + (uri.Query.Length > 1 ? uri.Query + "&" : "?") + "dns=" + encoded;
            t.MaxBytes = 16384;
            t.Tag = d.Tag;
            d.Transport = t;

            Stopwatch sw = Stopwatch.StartNew();
            await ExecuteAsync(t, BuildRequest(t, "application/dns-message"), connectMs, ioMs).ConfigureAwait(false);
            d.RttMs = sw.Elapsed.TotalMilliseconds;

            if (!t.TlsOk || t.Body == null || t.Status != 200)
            {
                d.Error = t.Error != ProbeError.None ? t.Error : ProbeError.HttpStatus;
                return;
            }
            byte[] body = t.Chunked ? Dechunk(t.Body) : t.Body;
            DnsWire.Response r = DnsWire.Parse(body, 0, body.Length);
            if (r == null || r.Id != 0)
            {
                d.Error = ProbeError.BadResponse;
                return;
            }
            string[] usable;
            d.Error = DnsWire.Classify(r, out usable);
            d.Addresses = usable;
        }

        static byte[] BuildRequest(HttpsProbe p, string accept)
        {
            if (string.IsNullOrEmpty(p.Path) || p.Path[0] != '/') throw new ArgumentException("Path must start with '/'.");
            StringBuilder sb = new StringBuilder(512);
            sb.Append("GET ").Append(p.Path).Append(" HTTP/1.1\r\n");
            sb.Append("Host: ").Append(p.Host).Append("\r\n");
            sb.Append("User-Agent: ").Append(UserAgent).Append("\r\n");
            sb.Append("Accept: ").Append(accept).Append("\r\n");
            sb.Append("Accept-Language: en-US,en;q=0.9\r\n");
            sb.Append("Accept-Encoding: identity\r\n");
            sb.Append("Connection: close\r\n");
            if (p.Headers != null)
            {
                foreach (string header in p.Headers)
                {
                    if (string.IsNullOrEmpty(header)) continue;
                    if (header.IndexOf('\r') >= 0 || header.IndexOf('\n') >= 0 || header.IndexOf(':') <= 0)
                        throw new ArgumentException("Invalid header: " + header);
                    sb.Append(header).Append("\r\n");
                }
            }
            sb.Append("\r\n");
            return Encoding.ASCII.GetBytes(sb.ToString());
        }

        static async Task ExecuteAsync(HttpsProbe p, byte[] request, int connectMs, int ioMs)
        {
            TcpClient tcp = new TcpClient(AddressFamily.InterNetwork);
            SslStream ssl = null;
            MemoryStream received = new MemoryStream();
            try
            {
                Stopwatch sw = Stopwatch.StartNew();
                Task connect = tcp.ConnectAsync(IPAddress.Parse(p.Address), 443);
                if (!await Within(connect, connectMs).ConfigureAwait(false))
                {
                    p.Error = ProbeError.ConnectTimeout;
                    return;
                }
                try { await connect.ConfigureAwait(false); }
                catch (Exception e)
                {
                    p.Error = ClassifyConnect(e);
                    p.Detail = Describe(e);
                    return;
                }
                p.TcpOk = true;
                p.ConnectMs = sw.Elapsed.TotalMilliseconds;
                tcp.NoDelay = true;

                // The request carries nothing secret, but it is still never sent over an unvalidated channel:
                // the callback rejects bad certificates and only records why, so a forged one can be reported.
                SslPolicyErrors policyErrors = SslPolicyErrors.None;
                ssl = new SslStream(tcp.GetStream(), false,
                    delegate(object sender, X509Certificate certificate, X509Chain chain, SslPolicyErrors errors)
                    {
                        policyErrors = errors;
                        return errors == SslPolicyErrors.None;
                    });

                sw.Restart();
                // SslProtocols.None lets the OS pick the protocol versions (.NET Framework 4.7+).
                Task auth = ssl.AuthenticateAsClientAsync(p.Host, null, SslProtocols.None, false);
                if (!await Within(auth, ioMs).ConfigureAwait(false))
                {
                    p.Error = ProbeError.TlsTimeout;
                    return;
                }
                try { await auth.ConfigureAwait(false); }
                catch (Exception e)
                {
                    if (policyErrors != SslPolicyErrors.None)
                    {
                        p.Error = ProbeError.CertificateInvalid;
                        p.Detail = policyErrors.ToString();
                    }
                    else
                    {
                        p.Error = e is AuthenticationException ? ProbeError.TlsFailed : ProbeError.TlsReset;
                        p.Detail = Describe(e);
                    }
                    return;
                }
                p.TlsOk = true;
                p.TlsMs = sw.Elapsed.TotalMilliseconds;

                Task write = ssl.WriteAsync(request, 0, request.Length);
                if (!await Within(write, ioMs).ConfigureAwait(false))
                {
                    p.Error = ProbeError.NoResponse;
                    return;
                }
                await write.ConfigureAwait(false);

                byte[] chunk = new byte[16384];
                int headerEnd = -1;
                long contentLength = -1;
                bool chunked = false;
                while (received.Length < p.MaxBytes)
                {
                    Task<int> read = ssl.ReadAsync(chunk, 0, chunk.Length);
                    if (!await Within(read, ioMs).ConfigureAwait(false))
                    {
                        MarkInterrupted(p, received.Length, "read timeout");
                        break;
                    }
                    int count;
                    try { count = await read.ConfigureAwait(false); }
                    catch (Exception e)
                    {
                        MarkInterrupted(p, received.Length, Describe(e));
                        break;
                    }
                    if (count <= 0)
                    {
                        p.Complete = true;
                        break;
                    }
                    received.Write(chunk, 0, count);

                    if (headerEnd < 0)
                    {
                        headerEnd = FindHeaderEnd(received.GetBuffer(), (int)received.Length);
                        if (headerEnd >= 0) ParseHeaders(p, received.GetBuffer(), headerEnd, out contentLength, out chunked);
                    }
                    if (headerEnd >= 0)
                    {
                        if (contentLength >= 0 && received.Length - headerEnd >= contentLength) { p.Complete = true; break; }
                        if (chunked && EndsWithLastChunk(received)) { p.Complete = true; break; }
                    }
                }
                if (received.Length >= p.MaxBytes) p.Complete = true;

                p.Bytes = received.Length;
                p.Head = Encoding.UTF8.GetString(received.GetBuffer(), 0, (int)Math.Min(received.Length, HeadBytes));
                if (headerEnd >= 0)
                {
                    byte[] body = new byte[received.Length - headerEnd];
                    Buffer.BlockCopy(received.GetBuffer(), headerEnd, body, 0, body.Length);
                    p.Body = body;
                    p.Chunked = chunked;
                }
                if (p.Error == ProbeError.None && p.Status == 0) p.Error = ProbeError.BadResponse;
            }
            catch (Exception e)
            {
                if (p.Error == ProbeError.None) p.Error = ProbeError.BadResponse;
                if (p.Detail.Length == 0) p.Detail = Describe(e);
            }
            finally
            {
                if (ssl != null) ssl.Dispose();
                tcp.Close();
            }
        }

        // An interruption before the first byte means the server never answered; after it, it is
        // the mid-transfer stall that DPI equipment produces on throttled connections.
        static void MarkInterrupted(HttpsProbe p, long received, string reason)
        {
            if (received == 0)
            {
                p.Error = ProbeError.NoResponse;
                p.Detail = reason;
            }
            else
            {
                p.Stalled = true;
                p.Error = ProbeError.Stalled;
                p.Detail = (received / 1024) + " KB, " + reason;
            }
        }

        static void ParseHeaders(HttpsProbe p, byte[] buffer, int headerEnd, out long contentLength, out bool chunked)
        {
            contentLength = -1;
            chunked = false;
            string header = Encoding.ASCII.GetString(buffer, 0, headerEnd);
            string[] lines = header.Split('\n');
            string[] status = lines[0].Split(' ');
            int code;
            if (status.Length > 1 && status[0].StartsWith("HTTP/", StringComparison.Ordinal) && int.TryParse(status[1], out code))
                p.Status = code;
            for (int i = 1; i < lines.Length; i++)
            {
                string line = lines[i].Trim();
                int colon = line.IndexOf(':');
                if (colon <= 0) continue;
                string name = line.Substring(0, colon).Trim();
                string value = line.Substring(colon + 1).Trim();
                long length;
                if (name.Equals("Content-Length", StringComparison.OrdinalIgnoreCase) && long.TryParse(value, out length))
                    contentLength = length;
                else if (name.Equals("Transfer-Encoding", StringComparison.OrdinalIgnoreCase) &&
                         value.IndexOf("chunked", StringComparison.OrdinalIgnoreCase) >= 0)
                    chunked = true;
            }
        }

        static int FindHeaderEnd(byte[] b, int length)
        {
            for (int i = 3; i < length; i++)
                if (b[i] == 10 && b[i - 1] == 13 && b[i - 2] == 10 && b[i - 3] == 13) return i + 1;
            return -1;
        }

        static bool EndsWithLastChunk(MemoryStream ms)
        {
            if (ms.Length < 5) return false;
            byte[] b = ms.GetBuffer();
            int n = (int)ms.Length;
            return b[n - 5] == (byte)'0' && b[n - 4] == 13 && b[n - 3] == 10 && b[n - 2] == 13 && b[n - 1] == 10;
        }

        static byte[] Dechunk(byte[] raw)
        {
            MemoryStream output = new MemoryStream();
            int p = 0;
            while (p < raw.Length)
            {
                int eol = -1;
                for (int i = p; i + 1 < raw.Length; i++)
                    if (raw[i] == 13 && raw[i + 1] == 10) { eol = i; break; }
                if (eol < 0) break;
                string hex = Encoding.ASCII.GetString(raw, p, eol - p).Split(';')[0].Trim();
                int size;
                if (!int.TryParse(hex, System.Globalization.NumberStyles.HexNumber, null, out size) || size <= 0) break;
                p = eol + 2;
                if (p + size > raw.Length) size = raw.Length - p;
                output.Write(raw, p, size);
                p += size + 2;
            }
            return output.ToArray();
        }

        static ProbeError ClassifyConnect(Exception e)
        {
            SocketException se = FindSocketException(e);
            if (se == null) return ProbeError.ConnectFailed;
            if (se.SocketErrorCode == SocketError.ConnectionRefused) return ProbeError.ConnectRefused;
            if (se.SocketErrorCode == SocketError.TimedOut) return ProbeError.ConnectTimeout;
            return ProbeError.ConnectFailed;
        }

        static SocketException FindSocketException(Exception e)
        {
            for (Exception x = e; x != null; x = x.InnerException)
            {
                SocketException se = x as SocketException;
                if (se != null) return se;
                AggregateException ae = x as AggregateException;
                if (ae != null && ae.InnerExceptions.Count > 0) return FindSocketException(ae.InnerExceptions[0]);
            }
            return null;
        }

        internal static string Describe(Exception e)
        {
            SocketException se = FindSocketException(e);
            if (se != null) return se.SocketErrorCode.ToString();
            return e.GetBaseException().Message;
        }

        internal static async Task<bool> Within(Task task, int ms)
        {
            if (task.IsCompleted) return true;
            using (CancellationTokenSource cts = new CancellationTokenSource())
            {
                Task winner = await Task.WhenAny(task, Task.Delay(ms, cts.Token)).ConfigureAwait(false);
                cts.Cancel();
                if (winner == task) return true;
            }
            Observe(task);
            return false;
        }

        // The abandoned operation faults once its socket is disposed; observe it so it is not reported as unhandled.
        static void Observe(Task task)
        {
            task.ContinueWith(delegate(Task t) { GC.KeepAlive(t.Exception); },
                TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously);
        }
    }

    /// <summary>Downloads small text documents (provider lists) in parallel.</summary>
    public static class Fetcher
    {
        /// <summary>
        /// Fetches every URL concurrently. Only HTTPS is accepted, also after redirects, and bodies
        /// larger than <paramref name="maxBytes"/> are rejected. Never throws for network failures.
        /// </summary>
        public static FetchResult[] FetchAll(string[] urls, int timeoutMs, int maxBytes, string userAgent)
        {
            if (urls == null) throw new ArgumentNullException("urls");
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            Task<FetchResult>[] tasks = new Task<FetchResult>[urls.Length];
            for (int i = 0; i < urls.Length; i++) tasks[i] = FetchAsync(urls[i], timeoutMs, maxBytes, userAgent);
            Task.WaitAll(tasks);
            FetchResult[] results = new FetchResult[urls.Length];
            for (int i = 0; i < urls.Length; i++) results[i] = tasks[i].Result;
            return results;
        }

        static async Task<FetchResult> FetchAsync(string url, int timeoutMs, int maxBytes, string userAgent)
        {
            FetchResult result = new FetchResult();
            result.Url = url;
            Stopwatch sw = Stopwatch.StartNew();
            HttpWebRequest request = null;
            try
            {
                Uri uri;
                if (!Uri.TryCreate(url, UriKind.Absolute, out uri) || uri.Scheme != Uri.UriSchemeHttps)
                {
                    result.Error = "not an https URL";
                    return result;
                }
                request = (HttpWebRequest)WebRequest.Create(uri);
                request.UserAgent = userAgent;
                request.AllowAutoRedirect = true;
                request.MaximumAutomaticRedirections = 3;
                request.AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate;
                request.CachePolicy = new System.Net.Cache.RequestCachePolicy(System.Net.Cache.RequestCacheLevel.NoCacheNoStore);

                Task<WebResponse> pending = request.GetResponseAsync();
                if (!await HttpsBatch.Within(pending, timeoutMs).ConfigureAwait(false))
                {
                    request.Abort();
                    result.Error = "timeout";
                    return result;
                }
                using (HttpWebResponse response = (HttpWebResponse)await pending.ConfigureAwait(false))
                {
                    result.Status = (int)response.StatusCode;
                    if (response.ResponseUri.Scheme != Uri.UriSchemeHttps)
                    {
                        result.Error = "redirected to a non-https URL";
                        return result;
                    }
                    using (Stream stream = response.GetResponseStream())
                    using (MemoryStream body = new MemoryStream())
                    {
                        byte[] chunk = new byte[16384];
                        while (true)
                        {
                            Task<int> read = stream.ReadAsync(chunk, 0, chunk.Length);
                            if (!await HttpsBatch.Within(read, timeoutMs).ConfigureAwait(false))
                            {
                                request.Abort();
                                result.Error = "timeout";
                                return result;
                            }
                            int n = await read.ConfigureAwait(false);
                            if (n <= 0) break;
                            body.Write(chunk, 0, n);
                            if (body.Length > maxBytes)
                            {
                                result.Error = "response too large";
                                return result;
                            }
                        }
                        result.Content = new UTF8Encoding(false).GetString(body.ToArray()).TrimStart('\uFEFF');
                        result.Ok = true;
                    }
                }
            }
            catch (WebException e)
            {
                HttpWebResponse response = e.Response as HttpWebResponse;
                if (response != null)
                {
                    result.Status = (int)response.StatusCode;
                    response.Close();
                }
                result.Error = e.Status == WebExceptionStatus.ProtocolError ? "HTTP " + result.Status : e.Status.ToString();
            }
            catch (Exception e)
            {
                result.Error = HttpsBatch.Describe(e);
            }
            finally
            {
                result.Ms = sw.Elapsed.TotalMilliseconds;
            }
            return result;
        }
    }
}
