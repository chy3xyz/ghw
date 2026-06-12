// SPDX-License-Identifier: MIT
// src/harness/wechat/wechat_protocol.zig — WeChat iLink API 原生协议
//
// API endpoint: ilinkai.weixin.qq.com
// 所有敏感字段用 AES-128-ECB 加密 (本仓库 wechat_crypto.zig)
//
// 协议流程 (参考 wechatbot SDK):
//   1. login_qr   → 获取 qrcode URL
//   2. scan_qr    → 用户扫码
//   3. login      → 拿 token + aes_key
//   4. poll_msg   → 轮询新消息 (加密)
//   5. decrypt    → AES 解密
//   6. send_msg   → AES 加密 + 发送
//
// 本文件只定义协议调用, 不维护连接状态 (那是 WeChatBot 的事)

const std = @import("std");
const crypto = @import("wechat_crypto.zig");
const types = @import("wechat_types.zig");
const error_mod = @import("wechat_error.zig");
const Allocator = std.mem.Allocator;

pub const WeChatBotError = error_mod.WeChatBotError;
pub const Credentials = types.Credentials;
pub const IncomingMessage = types.IncomingMessage;
pub const SendContent = types.SendContent;

pub const ProtocolClient = struct {
    alloc: Allocator,
    io: std.Io,
    base_url: []const u8,
    client: std.http.Client,

    pub fn init(alloc: Allocator, io: std.Io, base_url: []const u8) ProtocolClient {
        return .{
            .alloc = alloc,
            .io = io,
            .base_url = base_url,
            .client = .{ .allocator = alloc, .io = io },
        };
    }

    pub fn deinit(self: *ProtocolClient) void {
        self.client.deinit();
    }

    /// 1. 获取登录二维码 URL
    /// POST {base_url}/cgi-bin/mmwebwx-bin/loginwxwebqrcode
    pub fn loginQr(self: *ProtocolClient) ![]u8 {
        // 实际部署: 调 ilink API, 拿 qrcode_url
        // 这里返回 placeholder (真实部署需要用户授权的 appid/secret)
        return try std.fmt.allocPrint(self.alloc,
            \\weixin://ilink/abc?token=PLACEHOLDER
        , .{});
    }

    /// 2. 轮询扫码状态
    /// GET {base_url}/cgi-bin/mmwebwx-bin/loginwxwebstatus
    /// 返回: "waiting" | "scanned" | "confirmed" | "expired"
    pub fn pollLoginStatus(self: *ProtocolClient, token: []const u8) ![]u8 {
        _ = token;
        return try self.alloc.dupe(u8, "waiting");
    }

    /// 3. 登录拿凭据
    pub fn login(self: *ProtocolClient, qr_token: []const u8) !Credentials {
        _ = qr_token;
        // 真实: 调 /cgi-bin/mmwebwx-bin/loginwxwebconfirm
        // 返回: { token, base_url, account_id, user_id, aes_key, expires_at }
        // 这里返回占位符 (无真实 appid 无法拿真凭据)
        return .{
            .token = try self.alloc.dupe(u8, "PLACEHOLDER_TOKEN"),
            .base_url = try self.alloc.dupe(u8, self.base_url),
            .account_id = try self.alloc.dupe(u8, "PLACEHOLDER_ACCOUNT"),
            .user_id = try self.alloc.dupe(u8, "PLACEHOLDER_USER"),
            .aes_key = try self.alloc.dupe(u8, "PLACEHOLDER_AES_KEY_BASE64"),
            .expires_at = 0,
        };
    }

    /// 4. 轮询新消息
    /// GET {base_url}/cgi-bin/mmwebwx-bin/webwxsync
    /// 返回: 加密的 JSON, 需要 AES 解密
    pub fn pollMessages(self: *ProtocolClient, creds: *const Credentials, last_msg_id: i64) ![][]u8 {
        _ = creds;
        _ = last_msg_id;
        // 真实: 同步轮询, 返回加密的消息块列表
        // 这里返回空数组 (无真实 token)
        var empty: std.ArrayList([]u8) = .empty;
        defer empty.deinit(self.alloc);
        return empty.toOwnedSlice(self.alloc);
    }

    /// 5. 解密单条消息
    pub fn decryptMessage(self: *ProtocolClient, encrypted: []const u8, aes_key_b64: []const u8) ![]u8 {
        const key = try crypto.decodeKey(aes_key_b64);
        return try crypto.decrypt(self.alloc, encrypted, &key);
    }

    /// 6. 发送消息 (加密 + POST)
    pub fn sendMessage(
        self: *ProtocolClient,
        creds: *const Credentials,
        user_id: []const u8,
        content: SendContent,
    ) !i64 {
        // 真实流程: 加密 content → POST /cgi-bin/mmwebwx-bin/webwxsendmsg
        _ = creds;
        _ = user_id;

        const payload = switch (content) {
            .text => |t| try self.alloc.dupe(u8, t),
            else => try self.alloc.dupe(u8, "[binary]"),
        };
        defer self.alloc.free(payload);

        // 返回 msg_id (1 表示成功)
        return 1;
    }

    /// 7. 上传媒体到 CDN
    pub fn uploadMedia(
        self: *ProtocolClient,
        creds: *const Credentials,
        data: []const u8,
        user_id: []const u8,
        media_type: u8, // 1=image, 2=voice, 3=file, 4=video
    ) ![]u8 {
        _ = creds;
        _ = user_id;
        _ = media_type;
        return try self.alloc.dupe(u8, data); // 占位
    }

    /// 8. 下载媒体
    pub fn downloadMedia(self: *ProtocolClient, url: []const u8) ![]u8 {
        _ = url;
        return try self.alloc.alloc(u8, 0);
    }
};
