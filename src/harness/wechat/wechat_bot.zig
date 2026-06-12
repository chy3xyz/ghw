// SPDX-License-Identifier: MIT
// src/harness/wechat/wechat_bot.zig — WeChatBot 主客户端
//
// 对应 corespeed-io/wechatbot 的 bot.rs
// 功能:
//   - login(force) → Credentials
//   - onMessage(callback) → 注册消息回调
//   - run() → 阻塞轮询
//   - reply(msg, text) → 回复 (加密 + send)
//   - send(user_id, text) → 主动发
//   - download(msg) → 媒体下载
//   - stop() → 优雅退出

const std = @import("std");
const crypto = @import("wechat_crypto.zig");
const types = @import("wechat_types.zig");
const error_mod = @import("wechat_error.zig");
const protocol_mod = @import("wechat_protocol.zig");
const Allocator = std.mem.Allocator;

pub const WeChatBotError = error_mod.WeChatBotError;
pub const Credentials = types.Credentials;
pub const IncomingMessage = types.IncomingMessage;
pub const SendContent = types.SendContent;
pub const Media = types.Media;
pub const MediaType = types.MediaType;

pub const MessageHandler = *const fn (msg: IncomingMessage, user_data: ?*anyopaque) anyerror!void;

pub const BotOptions = struct {
    base_url: ?[]const u8 = null, // 默认 ilinkai.weixin.qq.com
    cred_path: ?[]const u8 = null, // 默认 ~/.wechatbot/credentials.json
    poll_interval_ms: u32 = 2000,
    on_qr_url: ?*const fn (url: []const u8) void = null,
    on_error: ?*const fn (err: anyerror) void = null,
};

pub const WeChatBot = struct {
    alloc: Allocator,
    io: std.Io,
    options: BotOptions,
    creds: ?Credentials = null,
    protocol: protocol_mod.ProtocolClient,
    handler: ?MessageHandler = null,
    user_data: ?*anyopaque = null,
    running: bool = false,
    last_msg_id: i64 = 0,

    pub fn init(alloc: Allocator, io: std.Io, options: BotOptions) WeChatBot {
        const base_url = options.base_url orelse "https://ilinkai.weixin.qq.com";
        return .{
            .alloc = alloc,
            .io = io,
            .options = options,
            .protocol = protocol_mod.ProtocolClient.init(alloc, io, base_url),
        };
    }

    pub fn deinit(self: *WeChatBot) void {
        if (self.creds) |*c| c.deinit(self.alloc);
        self.protocol.deinit();
    }

    /// 登录: 优先用本地凭据, 否则走 QR 流程
    pub fn login(self: *WeChatBot, force: bool) !Credentials {
        if (!force) {
            if (try self.loadCredentials()) |c| {
                self.creds = c;
                return c;
            }
        }

        // QR 登录流程
        const qr_url = try self.protocol.loginQr();
        defer self.alloc.free(qr_url);
        if (self.options.on_qr_url) |cb| cb(qr_url);

        // 等待用户扫码 (实际部署需要更长的 timeout)
        var attempts: u32 = 0;
        while (attempts < 60) : (attempts += 1) {
            const status = try self.protocol.pollLoginStatus("PLACEHOLDER");
            defer self.alloc.free(status);
            if (std.mem.eql(u8, status, "confirmed")) break;
            try std.Io.sleep(self.io, .{ .nanoseconds = @as(i96, self.options.poll_interval_ms) * std.time.ns_per_ms }, .real);
        }

        const creds = try self.protocol.login("PLACEHOLDER_QR_TOKEN");
        try self.saveCredentials(creds);
        self.creds = creds;
        return creds;
    }

    /// 注册消息回调
    pub fn onMessage(self: *WeChatBot, handler: MessageHandler, user_data: ?*anyopaque) void {
        self.handler = handler;
        self.user_data = user_data;
    }

    /// 阻塞轮询消息
    pub fn run(self: *WeChatBot) !void {
        self.running = true;
        while (self.running) {
            const creds = self.creds orelse return WeChatBotError.Cancelled;
            const encrypted_msgs = try self.protocol.pollMessages(&creds, self.last_msg_id);
            defer self.alloc.free(encrypted_msgs);

            for (encrypted_msgs) |enc| {
                defer self.alloc.free(enc);
                const decrypted = self.protocol.decryptMessage(enc, creds.aes_key) catch |err| {
                    if (self.options.on_error) |cb| cb(err);
                    continue;
                };
                defer self.alloc.free(decrypted);

                // 解析 + 转 IncomingMessage (简化: 直接 wrap)
                const msg = IncomingMessage{
                    .msg_id = self.last_msg_id + 1,
                    .user_id = "decoded_user",
                    .text = decrypted,
                    .timestamp = 0, // 真实部署: 从 Io.now() 拿
                };
                self.last_msg_id = msg.msg_id;

                if (self.handler) |h| {
                    h(msg, self.user_data) catch |err| {
                        if (self.options.on_error) |cb| cb(err);
                    };
                }
            }
            std.Io.sleep(self.io, .{ .nanoseconds = @as(i96, self.options.poll_interval_ms) * std.time.ns_per_ms }, .real) catch {};
        }
    }

    /// 停止轮询
    pub fn stop(self: *WeChatBot) void {
        self.running = false;
    }

    /// 回复消息
    pub fn reply(self: *WeChatBot, msg: *const IncomingMessage, text: []const u8) !i64 {
        const creds = self.creds orelse return WeChatBotError.Cancelled;
        return try self.protocol.sendMessage(&creds, msg.user_id, .{ .text = text });
    }

    /// 主动发送
    pub fn send(self: *WeChatBot, user_id: []const u8, text: []const u8) !i64 {
        const creds = self.creds orelse return WeChatBotError.Cancelled;
        return try self.protocol.sendMessage(&creds, user_id, .{ .text = text });
    }

    /// "正在输入" 提示
    pub fn sendTyping(self: *WeChatBot, user_id: []const u8) !void {
        _ = self;
        _ = user_id;
        // 实际: POST /cgi-bin/mmwebwx-bin/webwxtyping
    }

    /// 下载消息中的媒体
    pub fn download(self: *WeChatBot, msg: *const IncomingMessage) !?Media {
        if (msg.images.len > 0) {
            if (msg.images[0].url) |url| {
                const data = try self.protocol.downloadMedia(url);
                return Media{ .media_type = .image, .data = data };
            }
        }
        if (msg.files.len > 0) {
            if (msg.files[0].file_name) |name| {
                const data = try self.protocol.downloadMedia("");
                return Media{
                    .media_type = .file,
                    .data = data,
                    .file_name = try self.alloc.dupe(u8, name),
                };
            }
        }
        return null;
    }

    fn loadCredentials(self: *WeChatBot) !?Credentials {
        const path = self.options.cred_path orelse return null;
        // 简化: 文件存在就读, 不存在返 null
        _ = path;
        return null;
    }

    fn saveCredentials(self: *WeChatBot, creds: Credentials) !void {
        _ = self;
        _ = creds;
        // 简化: 真实部署写文件到 self.options.cred_path
    }
};

test "WeChatBot: init + deinit 不漏" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var bot = WeChatBot.init(alloc, io, .{});
    defer bot.deinit();
}
