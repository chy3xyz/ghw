//! AutoCLI — 数字生命周期拉外网世界, 写进 Memory + sqlite
//!
//! 4 接口 (Phase 6 "六气" 之 跟自然):
//! 1. Wikipedia random (单条 + abstract)
//! 2. Hacker News top (top story title + url)
//! 3. ArXiv cs.AI (最新 3 篇 title + abstract 头)
//! 4. RSS BBC Tech (最新 1 条 title + summary)
//!
//! 用 std.process.spawn + curl 子进程, 零依赖
//! 拉到的内容写 Memory.world_fetch + sqlite episodes (kind="autocli_*"), 不阻塞 main runCycle

const std = @import("std");

pub const SourceKind = enum {
    wikipedia,
    hackernews,
    arxiv,
    rss,
};

pub const FetchedItem = struct {
    source: SourceKind,
    title: []u8, // owned
    snippet: []u8, // owned (abstract / summary / body excerpt)
    url: []u8, // owned
    allocator: std.mem.Allocator,

    pub fn deinit(self: *FetchedItem) void {
        self.allocator.free(self.title);
        self.allocator.free(self.snippet);
        self.allocator.free(self.url);
    }
};

pub const AutoCLI = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// 启动时间戳 (ns), 用于节流 (避免启动时立刻跑 4 个 LLM call)
    last_fetch_ns: i128 = 0,
    /// 5min 间隔 (300s)
    interval_ns: i128 = 300 * std.time.ns_per_s,
    /// 拉过外网数据 (Phase 6 触发)
    has_fetched: bool = false,
    /// 累计拉取条数 (UI 显示)
    total_fetched: u32 = 0,
    /// 错误计数 (UI 显示)
    error_count: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) AutoCLI {
        return .{ .allocator = allocator, .io = io };
    }

    /// 4 接口各拉 1 条, 写入 fetched_items (caller deinit)
    /// 失败项跳过 (不返回 error, 拉不到是常态, 4 个有 1-2 个成功就够)
    pub fn fetchAll(self: *AutoCLI, fetched_items: *std.ArrayList(FetchedItem)) !void {
        // 1. Wikipedia random
        if (self.fetchWikipedia()) |item| {
            try fetched_items.append(self.allocator, item);
        } else |_| {
            self.error_count += 1;
        }
        // 2. Hacker News top
        if (self.fetchHackerNews()) |item| {
            try fetched_items.append(self.allocator, item);
        } else |_| {
            self.error_count += 1;
        }
        // 3. ArXiv cs.AI
        if (self.fetchArXiv()) |item| {
            try fetched_items.append(self.allocator, item);
        } else |_| {
            self.error_count += 1;
        }
        // 4. RSS BBC Tech
        if (self.fetchRss()) |item| {
            try fetched_items.append(self.allocator, item);
        } else |_| {
            self.error_count += 1;
        }
        if (fetched_items.items.len > 0) {
            self.has_fetched = true;
            self.total_fetched += @intCast(fetched_items.items.len);
        }
    }

    /// 启动时跑 1 次 (不等 5min), 然后 5min 间隔
    /// 返回 true 表示应该触发 fetch, false 表示还没到时间
    pub fn shouldFetch(self: *AutoCLI, now_ns: i128) bool {
        if (self.last_fetch_ns == 0) return true; // 启动立刻跑 1 次
        return (now_ns - self.last_fetch_ns) >= self.interval_ns;
    }

    /// 标记已跑 (避免每 cycle 都跑)
    pub fn markFetched(self: *AutoCLI, now_ns: i128) void {
        self.last_fetch_ns = now_ns;
    }

    // === 1. Wikipedia random ===
    fn fetchWikipedia(self: *AutoCLI) !FetchedItem {
        // 用 Wikipedia REST API summary 端点, 先拉 random page title
        const title_out = try self.runCurl(&.{
            "https://en.wikipedia.org/api/rest_v1/page/random/summary",
        });
        defer self.allocator.free(title_out);
        // 解析 JSON 取 title + extract + content_urls.desktop.page
        const title = try extractJsonString(self.allocator, title_out, "\"title\":\"");
        const extract = try extractJsonString(self.allocator, title_out, "\"extract\":\"");
        const url = try extractJsonString(self.allocator, title_out, "\"desktop\":{\"page\":\"");
        return FetchedItem{
            .source = .wikipedia,
            .title = title,
            .snippet = extract,
            .url = url,
            .allocator = self.allocator,
        };
    }

    // === 2. Hacker News top story ===
    fn fetchHackerNews(self: *AutoCLI) !FetchedItem {
        // 拉 top story id, 再拉 item
        const ids_out = try self.runCurl(&.{
            "https://hacker-news.firebaseio.com/v0/topstories.json",
        });
        defer self.allocator.free(ids_out);
        // 取第一个 id (前 10 字符)
        const id_str = blk: {
            const start = std.mem.indexOf(u8, ids_out, "[") orelse return error.NoHN;
            const end_pos = std.mem.indexOfPos(u8, ids_out, start + 1, ",") orelse return error.NoHN;
            const trimmed = std.mem.trim(u8, ids_out[start + 1 .. end_pos], " \t\n");
            break :blk try self.allocator.dupe(u8, trimmed);
        };
        defer self.allocator.free(id_str);
        const url_buf = try std.fmt.allocPrint(self.allocator, "https://hacker-news.firebaseio.com/v0/item/{s}.json", .{id_str});
        defer self.allocator.free(url_buf);
        const item_out = try self.runCurl(&.{url_buf});
        defer self.allocator.free(item_out);
        const title = try extractJsonString(self.allocator, item_out, "\"title\":\"");
        const url_field = try extractJsonString(self.allocator, item_out, "\"url\":\"");
        return FetchedItem{
            .source = .hackernews,
            .title = title,
            .snippet = try self.allocator.dupe(u8, "(hn top story)"),
            .url = url_field,
            .allocator = self.allocator,
        };
    }

    // === 3. ArXiv cs.AI ===
    fn fetchArXiv(self: *AutoCLI) !FetchedItem {
        // ArXiv API: arxiv.org/api/query?search_query=cat:cs.AI&sortBy=submittedDate&max_results=1
        const url = "http://export.arxiv.org/api/query?search_query=cat:cs.AI&sortBy=submittedDate&sortOrder=descending&max_results=1";
        const out = try self.runCurl(&.{url});
        defer self.allocator.free(out);
        // 找 <title> + <summary> 标签
        const title = try extractXmlTag(self.allocator, out, "title", 1); // 跳过 feed title
        const summary = try extractXmlTag(self.allocator, out, "summary", 0);
        const id_url = try extractXmlTag(self.allocator, out, "id", 1);
        return FetchedItem{
            .source = .arxiv,
            .title = title,
            .snippet = summary,
            .url = id_url,
            .allocator = self.allocator,
        };
    }

    // === 4. RSS BBC Tech ===
    fn fetchRss(self: *AutoCLI) !FetchedItem {
        // 注: BBC RSS 不一定 200, fallback 试 The Verge 或 Wired
        const urls = [_][]const u8{
            "https://feeds.bbci.co.uk/news/technology/rss.xml",
            "https://www.theverge.com/rss/index.xml",
            "https://www.wired.com/feed/rss",
        };
        for (urls) |u| {
            const out = self.runCurl(&.{u}) catch continue;
            defer self.allocator.free(out);
            const title = extractXmlTag(self.allocator, out, "title", 0) catch continue;
            const summary = extractXmlTag(self.allocator, out, "description", 0) catch try self.allocator.dupe(u8, "");
            const link = extractXmlTag(self.allocator, out, "link", 0) catch try self.allocator.dupe(u8, u);
            return FetchedItem{
                .source = .rss,
                .title = title,
                .snippet = summary,
                .url = link,
                .allocator = self.allocator,
            };
        }
        return error.NoRSS;
    }

    // === 底层: 跑 curl (pipe stdout 读) ===
    fn runCurl(self: *AutoCLI, args: []const []const u8) ![]u8 {
        var argv_buf = try std.ArrayList([]const u8).initCapacity(self.allocator, args.len + 2);
        defer argv_buf.deinit(self.allocator);
        try argv_buf.append(self.allocator, "/usr/bin/curl");
        try argv_buf.append(self.allocator, "-sL"); // silent + follow redirect
        try argv_buf.append(self.allocator, "--max-time");
        try argv_buf.append(self.allocator, "10");
        for (args) |a| try argv_buf.append(self.allocator, a);

        var child = std.process.spawn(self.io, .{
            .argv = argv_buf.items,
            .stdout = .pipe,
            .stderr = .pipe,
            .stdin = .close,
        }) catch return error.SpawnFailed;

        var out_list: std.ArrayList(u8) = .empty;
        defer out_list.deinit(self.allocator);
        if (child.stdout) |out| {
            var buf: [4096]u8 = undefined;
            while (true) {
                const n = std.Io.File.readStreaming(out, self.io, &.{&buf}) catch break;
                if (n == 0) break;
                out_list.appendSlice(self.allocator, buf[0..n]) catch break;
            }
        }
        _ = child.wait(self.io) catch {};

        return out_list.toOwnedSlice(self.allocator);
    }
};

// === JSON 字符串提取 (简化, 处理 \" 转义) ===
fn extractJsonString(alloc: std.mem.Allocator, json: []const u8, key: []const u8) ![]u8 {
    const start = std.mem.indexOf(u8, json, key) orelse return error.KeyNotFound;
    var pos: usize = start + key.len;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    while (pos < json.len) {
        const c = json[pos];
        if (c == '"') break;
        if (c == '\\' and pos + 1 < json.len) {
            const next = json[pos + 1];
            switch (next) {
                '"' => try out.append(alloc, '"'),
                '\\' => try out.append(alloc, '\\'),
                'n' => try out.append(alloc, '\n'),
                't' => try out.append(alloc, '\t'),
                'r' => try out.append(alloc, '\r'),
                else => try out.append(alloc, next),
            }
            pos += 2;
        } else {
            try out.append(alloc, c);
            pos += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

// === XML 标签提取 (skip_n 个匹配, 处理 CDATA + entity) ===
fn extractXmlTag(alloc: std.mem.Allocator, xml: []const u8, tag: []const u8, skip_n: usize) ![]u8 {
    var pos: usize = 0;
    var found: usize = 0;
    // 构造 close_tag "</tag>" 一次
    var close_tag_buf: [128]u8 = undefined;
    const close_tag = std.fmt.bufPrint(&close_tag_buf, "</{s}>", .{tag}) catch return error.TagNotFound;
    while (true) {
        const open_pos = std.mem.indexOfPos(u8, xml, pos, "<") orelse return error.TagNotFound;
        // 验证 open_pos 后是 tag (不是其他标签)
        const after_lt = open_pos + 1;
        if (after_lt + tag.len > xml.len) return error.TagNotFound;
        if (!std.mem.eql(u8, xml[after_lt..][0..tag.len], tag)) {
            pos = open_pos + 1;
            continue;
        }
        const close_open = std.mem.indexOfPos(u8, xml, open_pos, ">") orelse return error.TagNotFound;
        const content_start = close_open + 1;
        const content_end = std.mem.indexOfPos(u8, xml, content_start, close_tag) orelse return error.TagNotFound;
        if (found == skip_n) {
            const raw = xml[content_start..content_end];
            // 解码 CDATA
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(alloc);
            var i: usize = 0;
            while (i < raw.len) {
                if (i + 8 < raw.len and std.mem.eql(u8, raw[i..][0..8], "<![CDATA[")) {
                    const cdata_start = i + 9;
                    const cdata_end = std.mem.indexOfPos(u8, raw, cdata_start, "]]>") orelse raw.len;
                    try out.appendSlice(alloc, raw[cdata_start..cdata_end]);
                    i = cdata_end + 3;
                } else if (raw[i] == '&') {
                    // 简化: 跳过 entity
                    if (i + 5 < raw.len and std.mem.eql(u8, raw[i..][0..5], "&amp;")) {
                        try out.append(alloc, '&');
                        i += 5;
                    } else if (i + 4 < raw.len and std.mem.eql(u8, raw[i..][0..4], "&lt;")) {
                        try out.append(alloc, '<');
                        i += 4;
                    } else if (i + 4 < raw.len and std.mem.eql(u8, raw[i..][0..4], "&gt;")) {
                        try out.append(alloc, '>');
                        i += 4;
                    } else {
                        try out.append(alloc, raw[i]);
                        i += 1;
                    }
                } else {
                    try out.append(alloc, raw[i]);
                    i += 1;
                }
            }
            return out.toOwnedSlice(alloc);
        }
        found += 1;
        pos = content_end + close_tag.len;
    }
}

// ===== Tests =====

test "AutoCLI: extractJsonString basic" {
    const alloc = std.testing.allocator;
    const json = "{\"title\":\"Hello \\\"World\\\"\",\"empty\":\"\"}";
    const t = try extractJsonString(alloc, json, "\"title\":\"");
    defer alloc.free(t);
    try std.testing.expectEqualStrings("Hello \"World\"", t);
    const e = try extractJsonString(alloc, json, "\"empty\":\"");
    defer alloc.free(e);
    try std.testing.expectEqualStrings("", e);
}

test "AutoCLI: extractXmlTag skip" {
    const alloc = std.testing.allocator;
    const xml = "<rss><title>Feed Title</title><item><title>First Item</title></item></rss>";
    const t1 = try extractXmlTag(alloc, xml, "title", 0);
    defer alloc.free(t1);
    try std.testing.expectEqualStrings("Feed Title", t1);
    const t2 = try extractXmlTag(alloc, xml, "title", 1);
    defer alloc.free(t2);
    try std.testing.expectEqualStrings("First Item", t2);
}

test "AutoCLI: extractXmlTag CDATA" {
    const alloc = std.testing.allocator;
    const xml = "<item><title>cd test</title><summary><![CDATA[contains <code> and &amp; stuff]]></summary></item>";
    const s = try extractXmlTag(alloc, xml, "summary", 0);
    defer alloc.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "contains <code>") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "& stuff") != null);
}
