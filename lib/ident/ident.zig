// Public Domain (-) 2026-present, The Espra Core Authors.
// See the Espra Core UNLICENSE file for details.

const root = @import("root");
const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub const initialisms = std.StaticStringMap([]const u8).initComptime(map_initialisms(&.{
    "AABB",
    "AAC",
    "ABI",
    "ABIs",
    "ACK",
    "ACL",
    "ACLs",
    "ACME",
    "ACPI",
    "AES",
    "AESGCM",
    "AMQP",
    "ANSI",
    "AOT",
    "API",
    "APIs",
    "ARP",
    "ASCII",
    "ASGI",
    "ASN",
    "ASN1",
    "AST",
    "ASTs",
    "ATM",
    "AV1",
    "AVIF",
    "BGP",
    "BGR",
    "BGRA",
    "BIOS",
    "BLAKE",
    "BLAKE3",
    "BSD",
    "BSDs",
    "BSON",
    "BSS",
    "BTC",
    "CA",
    "CBOR",
    "CDC",
    "CDN",
    "CDNs",
    "CGI",
    "CIDR",
    "CLI",
    "CLIs",
    "CMYK",
    "CORS",
    "CPU",
    "CPUs",
    "CRC",
    "CRDT",
    "CRDTs",
    "CRL",
    "CRLs",
    "CRT",
    "CRTs",
    "CSP",
    "CSR",
    "CSRF",
    "CSRFs",
    "CSRs",
    "CSS",
    "CSV",
    "DAG",
    "DAGs",
    "DB",
    "DBs",
    "DER",
    "DHCP",
    "DHT",
    "DHTs",
    "DKIM",
    "DLL",
    "DLLs",
    "DMA",
    "DNS",
    "DNSSEC",
    "DOOM",
    "DOM",
    "DOS",
    "DPI",
    "DRM",
    "DSL",
    "DSLs",
    "DTLS",
    "DTO",
    "DTOs",
    "EAN",
    "ECC",
    "ECDSA",
    "ECMA",
    "ELF",
    "EOF",
    "ETH",
    "ETL",
    "EXFAT",
    "FAT",
    "FBO",
    "FD",
    "FDs",
    "FFI",
    "FFIs",
    "FIDO",
    "FIFO",
    "FLAC",
    "FTP",
    "GC",
    "GCM",
    "GCs",
    "GIF",
    "GL",
    "GLSL",
    "GPS",
    "GPT",
    "GPTs",
    "GPU",
    "GPUs",
    "GRPC",
    "GUI",
    "GUID",
    "GUIDs",
    "GUIs",
    "HCL",
    "HDR",
    "HEIF",
    "HEVC",
    "HLSL",
    "HMAC",
    "HOTP",
    "HSM",
    "HSTS",
    "HTML",
    "HTTP",
    "HTTPS",
    "IAM",
    "IANA",
    "ICMP",
    "ID",
    "IDE",
    "IDEs",
    "IDs",
    "IEEE",
    "IETF",
    "IMAP",
    "IO",
    "IOCTL",
    "IOs",
    "IP",
    "IPC",
    "IPs",
    "IPv4",
    "IPv6",
    "IR",
    "IRC",
    "IRI",
    "IRIs",
    "IRQ",
    "IRs",
    "ISBN",
    "ISO",
    "ISP",
    "JIT",
    "JITs",
    "JPEG",
    "JPG",
    "JS",
    "JSON",
    "JWT",
    "JWTs",
    "KMS",
    "KVM",
    "LAN",
    "LDAP",
    "LHS",
    "LIFO",
    "LOD",
    "LRU",
    "LSM",
    "MAC",
    "MD5",
    "MDN",
    "MFA",
    "MIME",
    "MMAP",
    "MMU",
    "MP3",
    "MP4",
    "MPEG",
    "MQTT",
    "MSDN",
    "MSL",
    "MTU",
    "MVCC",
    "NAT",
    "NATO",
    "NATs",
    "NFS",
    "NIC",
    "NTFS",
    "NTP",
    "NUMA",
    "NVMe",
    "NVRAM",
    "OCR",
    "OCSP",
    "OID",
    "OIDC",
    "OLAP",
    "OLTP",
    "ORM",
    "ORMs",
    "OS",
    "OSI",
    "OSM",
    "OTP",
    "P2P",
    "PBKDF2",
    "PBR",
    "PCI",
    "PCIe",
    "PCM",
    "PCR",
    "PDF",
    "PEM",
    "PGP",
    "PID",
    "PIDs",
    "PKCS",
    "PKI",
    "PNG",
    "POP3",
    "PTY",
    "PWA",
    "PWAs",
    "QPS",
    "QUIC",
    "RAID",
    "RAM",
    "RBAC",
    "REPL",
    "REPLs",
    "REST",
    "RFC",
    "RFCs",
    "RGB",
    "RGBA",
    "RHS",
    "RPC",
    "RPCs",
    "RSA",
    "RTC",
    "RTT",
    "SAML",
    "SASL",
    "SATA",
    "SCSI",
    "SDF",
    "SDK",
    "SDKs",
    "SFTP",
    "SHA",
    "SHA1",
    "SHA256",
    "SHA3",
    "SHA512",
    "SIMD",
    "SIP",
    "SKU",
    "SKUs",
    "SLA",
    "SMIME",
    "SMTP",
    "SNI",
    "SOAP",
    "SOL",
    "SPA",
    "SPAs",
    "SQL",
    "SRAM",
    "SSA",
    "SSAO",
    "SSE",
    "SSH",
    "SSID",
    "SSIDs",
    "SSL",
    "SSO",
    "SSR",
    "SVG",
    "SYN",
    "TAI",
    "TCP",
    "TIFF",
    "TLS",
    "TOML",
    "TOTP",
    "TPS",
    "TTL",
    "TTY",
    "TUI",
    "TUIs",
    "UDP",
    "UEFI",
    "UI",
    "UID",
    "UIDs",
    "UIs",
    "URI",
    "URIs",
    "URL",
    "URLs",
    "URN",
    "URNs",
    "USB",
    "UTC",
    "UTF16",
    "UTF32",
    "UTF8",
    "UUID",
    "UUIDs",
    "UUIDv1",
    "UUIDv2",
    "UUIDv3",
    "UUIDv4",
    "UUIDv5",
    "UUIDv6",
    "UUIDv7",
    "UUIDv8",
    "VBO",
    "VCS",
    "VLAN",
    "VM",
    "VMs",
    "VPN",
    "VPNs",
    "W3C",
    "WAL",
    "WAN",
    "WASI",
    "WASM",
    "WAV",
    "WGSL",
    "WPA",
    "WSDL",
    "WSGI",
    "XML",
    "XMPP",
    "XON",
    "XSD",
    "XSLT",
    "XSRF",
    "XSS",
    "YAML",
}) ++ (if (@hasDecl(root, "ident_initialisms")) map_initialisms(root.ident_initialisms) else .{}));

pub const Name = struct {
    allocator: Allocator,
    parts: []const []const u8,

    pub fn deinit(self: Name) void {
        for (self.parts) |part| {
            self.allocator.free(part);
        }
        self.allocator.free(self.parts);
    }

    pub fn format(self: Name, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeByte('[');
        for (self.parts, 0..) |part, i| {
            if (i > 0) {
                try writer.writeByte(',');
            }
            try writer.writeAll(part);
        }
        try writer.writeByte(']');
    }

    pub fn to_camel(self: Name) ![]const u8 {
        var out: ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);
        for (self.parts, 0..) |part, i| {
            if (i == 0) {
                try out.appendSlice(self.allocator, part);
            } else {
                try self.append_pascal(&out, part);
            }
        }
        return self.allocator.dupe(u8, out.items);
    }

    pub fn to_kebab(self: Name) ![]const u8 {
        return self.join_with('-');
    }

    pub fn to_pascal(self: Name) ![]const u8 {
        var out: ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);
        for (self.parts) |part| {
            try self.append_pascal(&out, part);
        }
        return self.allocator.dupe(u8, out.items);
    }

    pub fn to_screaming_snake(self: Name) ![]const u8 {
        var out: ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);
        for (self.parts, 0..) |part, i| {
            if (i > 0) {
                try out.append(self.allocator, '_');
            }
            for (part) |c| {
                try out.append(self.allocator, std.ascii.toUpper(c));
            }
        }
        return self.allocator.dupe(u8, out.items);
    }

    pub fn to_snake(self: Name) ![]const u8 {
        return self.join_with('_');
    }

    fn append_pascal(self: Name, out: *ArrayList(u8), part: []const u8) !void {
        if (initialisms.get(part)) |initialism| {
            try out.appendSlice(self.allocator, initialism);
            return;
        }
        if (part.len > 1) {
            var idx = part.len - 1;
            while (idx > 0) {
                if (std.ascii.isDigit(part[idx])) {
                    idx -= 1;
                } else {
                    break;
                }
            }
            if (idx != part.len - 1) {
                idx += 1;
                if (initialisms.get(part[0..idx])) |initialism| {
                    try out.appendSlice(self.allocator, initialism);
                    try out.appendSlice(self.allocator, part[idx..]);
                    return;
                }
            }
        }
        try out.append(self.allocator, std.ascii.toUpper(part[0]));
        try out.appendSlice(self.allocator, part[1..]);
    }

    fn join_with(self: Name, separator: u8) ![]const u8 {
        var out: ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);
        for (self.parts, 0..) |part, i| {
            if (i > 0) {
                try out.append(self.allocator, separator);
            }
            try out.appendSlice(self.allocator, part);
        }
        return self.allocator.dupe(u8, out.items);
    }
};

const KV = struct { []const u8, []const u8 };

pub fn from_camel(allocator: Allocator, ident: []const u8) !Name {
    return from_pascal(allocator, ident);
}

pub fn from_kebab(allocator: Allocator, ident: []const u8) !Name {
    return split_and_normalize(allocator, ident, '-');
}

// NOTE(tav): This function must never return an empty part.
pub fn from_pascal(allocator: Allocator, ident: []const u8) !Name {
    if (ident.len == 0) {
        const parts = try allocator.alloc([]const u8, 0);
        return Name{ .allocator = allocator, .parts = parts };
    }
    var split: ArrayList([]const u8) = .empty;
    errdefer {
        for (split.items) |item| {
            allocator.free(item);
        }
        split.deinit(allocator);
    }
    var start: usize = 0;
    for (0..ident.len - 1) |i| {
        const cur = ident[i];
        const next = ident[i + 1];
        if ((std.ascii.isLower(cur) or std.ascii.isDigit(cur)) and std.ascii.isUpper(next)) {
            try process_pascal_segment(allocator, &split, ident[start .. i + 1]);
            start = i + 1;
        }
    }
    try process_pascal_segment(allocator, &split, ident[start..]);
    const parts = try allocator.dupe([]const u8, split.items);
    split.deinit(allocator);
    return Name{ .allocator = allocator, .parts = parts };
}

pub fn from_screaming_snake(allocator: Allocator, ident: []const u8) !Name {
    return from_snake(allocator, ident);
}

pub fn from_snake(allocator: Allocator, ident: []const u8) !Name {
    return split_and_normalize(allocator, ident, '_');
}

fn append_part(allocator: Allocator, split: *ArrayList([]const u8), part: []const u8) !void {
    const lower = try allocator.dupe(u8, part);
    errdefer allocator.free(lower);
    for (lower) |*c| {
        c.* = std.ascii.toLower(c.*);
    }
    try split.append(allocator, lower);
}

fn map_initialisms(comptime input: []const []const u8) [input.len]KV {
    @setEvalBranchQuota(10_000);
    comptime {
        var result: [input.len]KV = undefined;
        for (input, 0..) |item, i| {
            var lower: [item.len]u8 = undefined;
            _ = std.ascii.lowerString(&lower, item);
            const lower_str = lower;
            result[i] = .{ &lower_str, item };
        }
        return result;
    }
}

fn process_pascal_segment(allocator: Allocator, split: *ArrayList([]const u8), segment: []const u8) !void {
    var buf: [64]u8 = undefined;
    var idx: usize = 0;
    while (idx < segment.len) {
        var match_len: usize = segment.len - idx;
        while (match_len > 0) : (match_len -= 1) {
            if (match_len > 64) {
                continue;
            }
            for (segment[idx .. idx + match_len], 0..) |c, i| {
                buf[i] = std.ascii.toLower(c);
            }
            if (initialisms.has(buf[0..match_len])) {
                const after = idx + match_len;
                if (after < segment.len and std.ascii.isLower(segment[after])) {
                    continue;
                }
                break;
            }
        }
        if (match_len > 0) {
            var end = idx + match_len;
            while (end < segment.len and std.ascii.isDigit(segment[end])) {
                end += 1;
            }
            try append_part(allocator, split, segment[idx..end]);
            idx = end;
        } else {
            var end = idx;
            while (end < segment.len and std.ascii.isUpper(segment[end])) {
                end += 1;
            }
            if (end > idx + 1 and end < segment.len and std.ascii.isLower(segment[end])) {
                try append_part(allocator, split, segment[idx .. end - 1]);
                idx = end - 1;
            } else {
                try append_part(allocator, split, segment[idx..]);
                break;
            }
        }
    }
}

// NOTE(tav): This function must never return an empty part.
fn split_and_normalize(allocator: Allocator, ident: []const u8, separator: u8) !Name {
    var split: ArrayList([]const u8) = .empty;
    errdefer {
        for (split.items) |item| {
            allocator.free(item);
        }
        split.deinit(allocator);
    }
    var it = std.mem.splitScalar(u8, ident, separator);
    while (it.next()) |part| {
        if (part.len == 0) {
            continue;
        }
        try append_part(allocator, &split, part);
    }
    const parts = try allocator.dupe([]const u8, split.items);
    split.deinit(allocator);
    return Name{ .allocator = allocator, .parts = parts };
}

const testing = std.testing;

const Spec = struct {
    camel: []const u8,
    kebab: []const u8,
    pascal: []const u8,
};

fn validate_conversion(spec: Spec, name: Name) !void {
    const _from_camel = try name.to_camel();
    defer testing.allocator.free(_from_camel);
    try testing.expectEqualStrings(spec.camel, _from_camel);
    const _from_kebab = try name.to_kebab();
    defer testing.allocator.free(_from_kebab);
    try testing.expectEqualStrings(spec.kebab, _from_kebab);
    const _from_pascal = try name.to_pascal();
    defer testing.allocator.free(_from_pascal);
    try testing.expectEqualStrings(spec.pascal, _from_pascal);
}

fn validate_spec(spec: Spec) !void {
    // camelCase
    const name_from_camel = try from_camel(testing.allocator, spec.camel);
    defer name_from_camel.deinit();
    try validate_conversion(spec, name_from_camel);
    // PascalCase
    const name_from_pascal = try from_pascal(testing.allocator, spec.pascal);
    defer name_from_pascal.deinit();
    try validate_conversion(spec, name_from_pascal);
    // kebab-case
    const name_from_kebab = try from_kebab(testing.allocator, spec.kebab);
    defer name_from_kebab.deinit();
    try validate_conversion(spec, name_from_kebab);
    // snake_case
    const snake_case = try testing.allocator.dupe(u8, spec.kebab);
    defer testing.allocator.free(snake_case);
    std.mem.replaceScalar(u8, snake_case, '-', '_');
    const name_from_snake = try from_snake(testing.allocator, snake_case);
    defer name_from_snake.deinit();
    try validate_conversion(spec, name_from_snake);
    // SCREAMING_SNAKE_CASE
    const screaming_snake_case = try testing.allocator.dupe(u8, snake_case);
    defer testing.allocator.free(screaming_snake_case);
    _ = std.ascii.upperString(screaming_snake_case, screaming_snake_case);
    const name_from_screaming_snake = try from_screaming_snake(testing.allocator, screaming_snake_case);
    defer name_from_screaming_snake.deinit();
    try validate_conversion(spec, name_from_screaming_snake);
}

test "preserved round-trip conversions" {
    const specs = [_]Spec{
        .{ .camel = "", .kebab = "", .pascal = "" },
        .{ .camel = "2", .kebab = "2", .pascal = "2" },
        .{ .camel = "c89Parser", .kebab = "c89-parser", .pascal = "C89Parser" },
        .{ .camel = "fooBar", .kebab = "foo-bar", .pascal = "FooBar" },
        .{ .camel = "httpServer", .kebab = "http-server", .pascal = "HTTPServer" },
        .{ .camel = "httpSite", .kebab = "http-site", .pascal = "HTTPSite" },
        .{ .camel = "http2Server", .kebab = "http2-server", .pascal = "HTTP2Server" },
        .{ .camel = "http11Server", .kebab = "http11-server", .pascal = "HTTP11Server" },
        .{ .camel = "httpsServer", .kebab = "https-server", .pascal = "HTTPSServer" },
        .{ .camel = "i", .kebab = "i", .pascal = "I" },
        .{ .camel = "idSet", .kebab = "id-set", .pascal = "IDSet" },
        .{ .camel = "ids", .kebab = "ids", .pascal = "IDs" },
        .{ .camel = "idsMap", .kebab = "ids-map", .pascal = "IDsMap" },
        .{ .camel = "networkCIDR", .kebab = "network-cidr", .pascal = "NetworkCIDR" },
        .{ .camel = "pcrTestKit", .kebab = "pcr-test-kit", .pascal = "PCRTestKit" },
        .{ .camel = "peerAPIOp", .kebab = "peer-api-op", .pascal = "PeerAPIOp" },
        .{ .camel = "peerIDs", .kebab = "peer-ids", .pascal = "PeerIDs" },
        .{ .camel = "serviceAPIKey", .kebab = "service-api-key", .pascal = "ServiceAPIKey" },
        .{ .camel = "serviceKey", .kebab = "service-key", .pascal = "ServiceKey" },
        .{ .camel = "sha256Hash", .kebab = "sha256-hash", .pascal = "SHA256Hash" },
        .{ .camel = "uuidv7UUIDs", .kebab = "uuidv7-uuids", .pascal = "UUIDv7UUIDs" },
        .{ .camel = "userACLIDs", .kebab = "user-acl-ids", .pascal = "UserACLIDs" },
        .{ .camel = "username", .kebab = "username", .pascal = "Username" },
        .{ .camel = "xmlHTTP", .kebab = "xml-http", .pascal = "XMLHTTP" },
        .{ .camel = "xmlHTTPRequest", .kebab = "xml-http-request", .pascal = "XMLHTTPRequest" },
    };
    for (specs) |spec| {
        try validate_spec(spec);
    }
}

test "special pascal case conversions" {
    const specs = [_][3][]const u8{
        .{ "STUNServers", "stun-servers", "StunServers" },
    };
    for (specs) |spec| {
        const name = try from_pascal(testing.allocator, spec[0]);
        defer name.deinit();
        const _to_kebab = try name.to_kebab();
        defer testing.allocator.free(_to_kebab);
        try testing.expectEqualStrings(spec[1], _to_kebab);
        const _to_pascal = try name.to_pascal();
        defer testing.allocator.free(_to_pascal);
        try testing.expectEqualStrings(spec[2], _to_pascal);
    }
}
