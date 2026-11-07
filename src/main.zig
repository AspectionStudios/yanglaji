//! yanglaji — gray-market price scout for the cluster-comparison chart.
//!
//! Mines asking/sold prices for accelerators and memory across the channels
//! that are readable without a login: web-search result pages (Bing HTML) fed
//! by in-language query packs (Chinese market slang included: 洋垃圾 "foreign
//! trash" = cheap ex-datacenter gear, 魔改 = modded, 矿卡 = ex-mining,
//! 闲鱼 = Xianyu), plus direct price-tracker pages (gpusold, dimmsum, ...).
//!
//! Transport is curl via child process: it is the seam that already speaks
//! this machine's egress. Parsing, FX conversion, $/GB math and the report
//! are all here. Output is a scout-grade signal — snippet-mined asking
//! prices, to be verified against the live listing before any ruling.
//!
//! Usage: yanglaji [--probes probes.json] [--config config.json] [--out report.md]

const std = @import("std");

const PriceHit = struct {
    usd: f64,
    source: []const u8,
};

const ProbeResult = struct {
    name: []const u8,
    class: []const u8,
    gb: f64,
    hits: std.ArrayList(PriceHit),
    median_usd: ?f64 = null,
    min_usd: ?f64 = null,

    fn medianPerGb(self: *const ProbeResult) ?f64 {
        if (self.median_usd) |m| return m / self.gb;
        return null;
    }
};

fn fetch(alloc: std.mem.Allocator, ua: []const u8, url: []const u8) ?[]u8 {
    var child = std.process.Child.init(&.{ "curl", "-sL", "--max-time", "30", "-A", ua, url }, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return null;
    const out = child.stdout.?.readToEndAlloc(alloc, 4 * 1024 * 1024) catch {
        _ = child.wait() catch {};
        return null;
    };
    _ = child.wait() catch {};
    if (out.len == 0) return null;
    return out;
}

fn stripHtml(alloc: std.mem.Allocator, html: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(alloc, html.len);
    var in_tag = false;
    var i: usize = 0;
    while (i < html.len) : (i += 1) {
        const c = html[i];
        if (c == '<') {
            in_tag = true;
            try out.append(alloc, ' ');
        } else if (c == '>') {
            in_tag = false;
        } else if (!in_tag) {
            try out.append(alloc, c);
        }
    }
    return out.items;
}

/// Relevance gate: a price only counts if one of the probe's match tokens
/// appears within `window` bytes of it in the text (ASCII case-insensitive;
/// CJK tokens compare byte-exact). Without this, followed pages (marketplace
/// hubs, rental indexes) flood the sample with unrelated prices.
fn nearToken(alloc: std.mem.Allocator, text: []const u8, pos: usize, tokens: []const []const u8) bool {
    if (tokens.len == 0) return true;
    const lo = if (pos > 350) pos - 350 else 0;
    const hi = @min(text.len, pos + 350);
    const win = text[lo..hi];
    var lower_buf = alloc.alloc(u8, win.len) catch return false;
    for (win, 0..) |c, k| lower_buf[k] = std.ascii.toLower(c);
    const lowered = lower_buf;
    for (tokens) |tok| {
        var tok_buf = alloc.alloc(u8, tok.len) catch continue;
        for (tok, 0..) |c, k| tok_buf[k] = std.ascii.toLower(c);
        if (std.mem.indexOf(u8, lowered, tok_buf) != null) return true;
    }
    return false;
}

/// Mine prices from plain text. Recognizes $ / € / ¥ / ￥ amounts and
/// amounts followed by 元. Returns USD values, relevance-gated by tokens.
fn minePrices(alloc: std.mem.Allocator, text: []const u8, fx_cny: f64, fx_eur: f64, source: []const u8, hits: *std.ArrayList(PriceHit), tokens: []const []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        var currency: enum { usd, eur, cny } = .usd;
        var start: ?usize = null;
        if (c == '$') {
            currency = .usd;
            start = i + 1;
        } else if (c == 0xE2 and i + 2 < text.len and text[i + 1] == 0x82 and text[i + 2] == 0xAC) { // €
            currency = .eur;
            start = i + 3;
        } else if (c == 0xC2 and i + 1 < text.len and text[i + 1] == 0xA5) { // ¥ (2-byte form)
            currency = .cny;
            start = i + 2;
        } else if (c == 0xEF and i + 2 < text.len and text[i + 1] == 0xBF and text[i + 2] == 0xA5) { // ￥ (3-byte form)
            currency = .cny;
            start = i + 3;
        }
        if (start) |s| {
            var j = s;
            // skip spaces between symbol and digits
            while (j < text.len and text[j] == ' ') j += 1;
            const num_start = j;
            var seen_digit = false;
            while (j < text.len and (std.ascii.isDigit(text[j]) or text[j] == ',' or text[j] == '.')) : (j += 1) {
                if (std.ascii.isDigit(text[j])) seen_digit = true;
            }
            if (seen_digit) {
                var buf: [32]u8 = undefined;
                var bl: usize = 0;
                for (text[num_start..j]) |ch| {
                    if (ch != ',' and bl < buf.len) {
                        buf[bl] = ch;
                        bl += 1;
                    }
                }
                const val = std.fmt.parseFloat(f64, buf[0..bl]) catch 0;
                var usd = val;
                switch (currency) {
                    .usd => {},
                    .eur => usd = val * fx_eur,
                    .cny => usd = val / fx_cny,
                }
                if (usd >= 15 and usd <= 250_000 and nearToken(alloc, text, i, tokens)) {
                    try hits.append(alloc, .{ .usd = usd, .source = source });
                }
                i = j;
                continue;
            }
        }
        // Amount followed by 元 (CJK yuan): digits then E5 85 83
        if (std.ascii.isDigit(c)) {
            var j = i;
            var seen_digit = false;
            while (j < text.len and (std.ascii.isDigit(text[j]) or text[j] == ',')) : (j += 1) seen_digit = true;
            if (seen_digit and j + 2 < text.len and text[j] == 0xE5 and text[j + 1] == 0x85 and text[j + 2] == 0x83) {
                var buf: [32]u8 = undefined;
                var bl: usize = 0;
                for (text[i..j]) |ch| {
                    if (ch != ',' and bl < buf.len) {
                        buf[bl] = ch;
                        bl += 1;
                    }
                }
                const val = std.fmt.parseFloat(f64, buf[0..bl]) catch 0;
                const usd = val / fx_cny;
                if (usd >= 15 and usd <= 250_000 and nearToken(alloc, text, i, tokens)) {
                    try hits.append(alloc, .{ .usd = usd, .source = source });
                }
                i = j + 3;
                continue;
            }
        }
        i += 1;
    }
}

/// Extract organic result targets from a Bing results page. Organic
/// results live in <h2><a href="...ck/a?...&u=a1<base64url>..."> anchors;
/// the u= parameter decodes directly to the target URL, no redirector
/// hop needed. Ad/chrome targets (microsoft, bing itself) are skipped.
/// Deduplicated, order preserved.
fn extractLinks(alloc: std.mem.Allocator, html: []const u8, limit: usize) ![][]const u8 {
    var out = try std.ArrayList([]const u8).initCapacity(alloc, limit * 2);
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, html, i, "<h2><a")) |pos| {
        const href_pos = std.mem.indexOfPos(u8, html, pos, "href=\"") orelse break;
        const start = href_pos + 6;
        const end = std.mem.indexOfPos(u8, html, start, "\"") orelse break;
        const raw = html[start..end];
        i = end;
        var target: ?[]const u8 = null;
        if (std.mem.indexOf(u8, raw, "u=a1")) |upos| {
            const bstart = upos + 4;
            var bend = bstart;
            while (bend < raw.len and raw[bend] != '&' and raw[bend] != '"') bend += 1;
            const b64 = raw[bstart..bend];
            // URL-safe base64 without padding; re-pad to a multiple of 4.
            var padded = try std.ArrayList(u8).initCapacity(alloc, b64.len + 4);
            try padded.appendSlice(alloc, b64);
            while (padded.items.len % 4 != 0) try padded.append(alloc, '=');
            const dec = std.base64.url_safe.Decoder;
            const size = dec.calcSizeUpperBound(padded.items.len) catch {
                continue;
            };
            const buf = try alloc.alloc(u8, size);
            dec.decode(buf, padded.items) catch {
                continue;
            };
            const decoded = std.mem.trim(u8, buf, "\x00");
            if (std.mem.startsWith(u8, decoded, "http")) target = decoded;
        } else if (std.mem.startsWith(u8, raw, "https://") or std.mem.startsWith(u8, raw, "http://")) {
            target = raw;
        }
        const url = target orelse continue;
        if (std.mem.indexOf(u8, url, "microsoft.com") != null) continue;
        if (std.mem.indexOf(u8, url, "bing.com") != null) continue;
        if (std.mem.indexOf(u8, url, "msn.com") != null) continue;
        var dup = false;
        for (out.items) |u| {
            if (std.mem.eql(u8, u, url)) dup = true;
        }
        if (dup) continue;
        try out.append(alloc, url);
        if (out.items.len >= limit) break;
    }
    return out.items;
}

/// Extract direct result links from a Brave results page: plain hrefs,
/// search-engine chrome and asset hosts excluded. Deduplicated.
fn extractBraveLinks(alloc: std.mem.Allocator, html: []const u8, limit: usize) ![][]const u8 {
    var out = try std.ArrayList([]const u8).initCapacity(alloc, limit * 3);
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, html, i, "href=\"")) |pos| {
        const start = pos + 6;
        const end = std.mem.indexOfPos(u8, html, start, "\"") orelse break;
        const url = html[start..end];
        i = end;
        if (!std.mem.startsWith(u8, url, "https://") and !std.mem.startsWith(u8, url, "http://")) continue;
        if (std.mem.indexOf(u8, url, "brave.com") != null) continue;
        if (std.mem.indexOf(u8, url, "cdn.search.brave.com") != null) continue;
        if (std.mem.endsWith(u8, url, ".css") or std.mem.endsWith(u8, url, ".js") or std.mem.endsWith(u8, url, ".png") or std.mem.endsWith(u8, url, ".svg")) continue;
        var dup = false;
        for (out.items) |u| {
            if (std.mem.eql(u8, u, url)) dup = true;
        }
        if (dup) continue;
        try out.append(alloc, url);
        if (out.items.len >= limit) break;
    }
    return out.items;
}

fn percentEncode(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(alloc, s.len * 2);
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(alloc, c);
        } else if (c == ' ') {
            try out.append(alloc, '+');
        } else {
            try out.writer(alloc).print("%{X:0>2}", .{c});
        }
    }
    return out.items;
}

fn medianOf(hits: []const PriceHit) ?f64 {
    if (hits.len == 0) return null;
    const vals = hits;
    std.mem.sort(PriceHit, @constCast(vals), {}, struct {
        fn lt(_: void, a: PriceHit, b: PriceHit) bool {
            return a.usd < b.usd;
        }
    }.lt);
    return vals[vals.len / 2].usd;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    var probes_path: []const u8 = "probes.json";
    var config_path: []const u8 = "config.json";
    var out_path: []const u8 = "report.md";
    const args = try std.process.argsAlloc(alloc);
    var ai: usize = 1;
    while (ai < args.len) : (ai += 1) {
        if (std.mem.eql(u8, args[ai], "--probes") and ai + 1 < args.len) {
            ai += 1;
            probes_path = args[ai];
        } else if (std.mem.eql(u8, args[ai], "--config") and ai + 1 < args.len) {
            ai += 1;
            config_path = args[ai];
        } else if (std.mem.eql(u8, args[ai], "--out") and ai + 1 < args.len) {
            ai += 1;
            out_path = args[ai];
        }
    }

    const cfg_bytes = try std.fs.cwd().readFileAlloc(alloc, config_path, 1 << 20);
    const cfg = (try std.json.parseFromSlice(std.json.Value, alloc, cfg_bytes, .{})).value;
    const fx = cfg.object.get("fx").?.object;
    const fx_cny = fx.get("CNY").?.float;
    const fx_eur = fx.get("EUR").?.float;
    const ua = cfg.object.get("user_agent").?.string;
    const floors = cfg.object.get("floors_usd_per_gb").?.object;

    const probes_bytes = try std.fs.cwd().readFileAlloc(alloc, probes_path, 1 << 20);
    const probes_val = (try std.json.parseFromSlice(std.json.Value, alloc, probes_bytes, .{})).value;

    var results = try std.ArrayList(ProbeResult).initCapacity(alloc, 16);

    for (probes_val.array.items) |p| {
        const obj = p.object;
        var res = ProbeResult{
            .name = obj.get("name").?.string,
            .class = obj.get("class").?.string,
            .gb = switch (obj.get("gb").?) {
                .integer => |v| @floatFromInt(v),
                .float => |v| v,
                else => 0,
            },
            .hits = try std.ArrayList(PriceHit).initCapacity(alloc, 32),
        };

        // Match tokens for the relevance gate.
        var tokens = try std.ArrayList([]const u8).initCapacity(alloc, 4);
        if (obj.get("match")) |m| {
            for (m.array.items) |t| try tokens.append(alloc, t.string);
        }

        // Direct tracker / listing pages.
        if (obj.get("urls")) |urls| {
            for (urls.array.items) |u| {
                if (fetch(alloc, ua, u.string)) |html| {
                    const text = try stripHtml(alloc, html);
                    const tag = try std.fmt.allocPrint(alloc, "page: {s}", .{u.string});
                    try minePrices(alloc, text, fx_cny, fx_eur, tag, &res.hits, tokens.items);
                }
                std.Thread.sleep(200 * std.time.ns_per_ms);
            }
        }
        // In-language search packs. Brave HTML is the primary discovery
        // layer (its snippets carry prices and its links are direct);
        // Bing is the fallback when Brave yields nothing (its result
        // targets are base64-wrapped in redirector anchors — see
        // extractLinks). Either way: mine the results page, then follow
        // the top result links and mine those pages too.
        if (obj.get("queries")) |queries| {
            for (queries.array.items) |q| {
                const enc = try percentEncode(alloc, q.string);
                const tag = try std.fmt.allocPrint(alloc, "search: {s}", .{q.string});
                var got_links = false;
                const brave_url = try std.fmt.allocPrint(alloc, "https://search.brave.com/search?q={s}&source=web", .{enc});
                if (fetch(alloc, ua, brave_url)) |html| {
                    const text = try stripHtml(alloc, html);
                    try minePrices(alloc, text, fx_cny, fx_eur, tag, &res.hits, tokens.items);
                    const links = try extractBraveLinks(alloc, html, 3);
                    if (links.len > 0) got_links = true;
                    for (links) |link| {
                        if (fetch(alloc, ua, link)) |page| {
                            const ptext = try stripHtml(alloc, page);
                            const ptag = try std.fmt.allocPrint(alloc, "page: {s}", .{link});
                            try minePrices(alloc, ptext, fx_cny, fx_eur, ptag, &res.hits, tokens.items);
                        }
                        std.Thread.sleep(200 * std.time.ns_per_ms);
                    }
                }
                if (!got_links) {
                    const bing_url = try std.fmt.allocPrint(alloc, "https://www.bing.com/search?q={s}&count=20", .{enc});
                    if (fetch(alloc, ua, bing_url)) |html| {
                        const text = try stripHtml(alloc, html);
                        try minePrices(alloc, text, fx_cny, fx_eur, tag, &res.hits, tokens.items);
                        const links = try extractLinks(alloc, html, 3);
                        for (links) |link| {
                            if (fetch(alloc, ua, link)) |page| {
                                const ptext = try stripHtml(alloc, page);
                                const ptag = try std.fmt.allocPrint(alloc, "page: {s}", .{link});
                                try minePrices(alloc, ptext, fx_cny, fx_eur, ptag, &res.hits, tokens.items);
                            }
                            std.Thread.sleep(200 * std.time.ns_per_ms);
                        }
                    }
                }
            }
        }

        if (res.hits.items.len > 0) {
            res.median_usd = medianOf(res.hits.items);
            var min_v: f64 = std.math.floatMax(f64);
            for (res.hits.items) |h| min_v = @min(min_v, h.usd);
            res.min_usd = min_v;
        }
        try results.append(alloc, res);
        std.debug.print("probe {s}: {d} prices mined\n", .{ res.name, res.hits.items.len });
    }

    // Sort by median $/GB ascending; no-price probes last.
    std.mem.sort(ProbeResult, results.items, {}, struct {
        fn lt(_: void, a: ProbeResult, b: ProbeResult) bool {
            const av = a.medianPerGb();
            const bv = b.medianPerGb();
            if (av == null and bv == null) return false;
            if (av == null) return false;
            if (bv == null) return true;
            return av.? < bv.?;
        }
    }.lt);

    // Report.
    var rep = try std.ArrayList(u8).initCapacity(alloc, 8192);
    const w = rep.writer(alloc);
    try w.writeAll("# yanglaji — gray-market scout report\n\n");
    try w.writeAll("Snippet-mined asking/sold prices from login-free surfaces (search packs in-language + price trackers). ");
    try w.writeAll("Scout-grade signal: verify against the live listing before any ruling. Prices in USD after FX.\n\n");
    try w.writeAll("| Probe | Class | GB | Min $ | Median $ | Median $/GB | Hits | Cheapest source |\n");
    try w.writeAll("|---|---|---|---|---|---|---|---|\n");
    for (results.items) |*r| {
        if (r.median_usd) |med| {
            var cheap_src: []const u8 = "";
            var cheap_v: f64 = std.math.floatMax(f64);
            for (r.hits.items) |h| {
                if (h.usd < cheap_v) {
                    cheap_v = h.usd;
                    cheap_src = h.source;
                }
            }
            try w.print("| {s} | {s} | {d:.0} | {d:.0} | {d:.0} | **{d:.2}** | {d} | {s} |\n", .{
                r.name, r.class, r.gb, r.min_usd.?, med, med / r.gb, r.hits.items.len, cheap_src,
            });
        } else {
            try w.print("| {s} | {s} | {d:.0} | — | — | — | 0 | no prices mined |\n", .{ r.name, r.class, r.gb });
        }
    }

    try w.writeAll("\n## Flags vs the chart's floors\n\n");
    var any_flag = false;
    for (results.items) |*r| {
        const pg = r.medianPerGb() orelse continue;
        if (floors.get(r.class)) |f| {
            const fv = f.object.get("value").?.float;
            const fl = f.object.get("label").?.string;
            if (pg < fv) {
                any_flag = true;
                try w.print("- **{s}**: median {d:.2} $/GB beats the {s} ({d:.2} $/GB)\n", .{ r.name, pg, fl, fv });
            }
        }
    }
    if (!any_flag) try w.writeAll("No probe beat its class floor this run.\n");

    const file = try std.fs.cwd().createFile(out_path, .{});
    defer file.close();
    try file.writeAll(rep.items);
    std.debug.print("wrote {s} ({d} bytes)\n", .{ out_path, rep.items.len });
}
