// SPDX-License-Identifier: MIT
// src/harness/wechat/wechat_types.zig — WeChat iLink 协议 + 用户友好类型
//
// 完全 1:1 移植 corespeed-io/wechatbot 的 types.rs
// (在 Zig 0.17 里用 std.ArrayList + 简单 JSON 序列化)

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const MessageType = enum { friend, group, system, unknown };
pub const MessageState = enum { unread, read, recalled };
pub const MessageItemType = enum { text, image, voice, file, video, link, location, system };
pub const ContentType = enum { text, image, voice, file, video, link, location, system };
pub const MediaType = enum { image, voice, file, video };

/// 协议级: 原始 ilink API 消息
pub const WireMessage = struct {
    msg_id: i64,
    from_user_id: []const u8,
    to_user_id: []const u8,
    msg_type: []const u8, // "text" | "image" | ...
    content: []const u8,
    timestamp: i64,
    raw_json: []const u8,
};

/// 协议级: 消息项
pub const WireMessageItem = struct {
    item_type: MessageItemType,
    text: ?[]const u8 = null,
    media: ?CDNMedia = null,
};

/// 协议级: CDN 媒体引用
pub const CDNMedia = struct {
    media_id: []const u8,
    url: ?[]const u8 = null,
    aes_key: ?[]const u8 = null,
    file_size: ?i64 = null,
};

/// 用户友好: 接收消息
pub const IncomingMessage = struct {
    msg_id: i64,
    user_id: []const u8,
    user_name: ?[]const u8 = null,
    text: []const u8 = "",
    content_type: ContentType = .text,
    images: []const ImageContent = &[_]ImageContent{},
    voices: []const VoiceContent = &[_]VoiceContent{},
    files: []const FileContent = &[_]FileContent{},
    videos: []const VideoContent = &[_]VideoContent{},
    quoted: ?QuotedMessage = null,
    timestamp: i64 = 0,
    message_type: MessageType = .friend,
};

/// 引用消息
pub const QuotedMessage = struct {
    msg_id: i64,
    title: ?[]const u8 = null,
    text: ?[]const u8 = null,
};

/// 图片内容
pub const ImageContent = struct {
    media_id: []const u8,
    url: ?[]const u8 = null,
    /// 本地缓存 (download 后填)
    local_data: ?[]const u8 = null,
};

/// 语音内容
pub const VoiceContent = struct {
    media_id: []const u8,
    text: ?[]const u8 = null, // 语音转文字 (如果有)
    duration_ms: ?i64 = null,
};

/// 文件内容
pub const FileContent = struct {
    media_id: []const u8,
    file_name: ?[]const u8 = null,
    file_size: ?i64 = null,
};

/// 视频内容
pub const VideoContent = struct {
    media_id: []const u8,
    url: ?[]const u8 = null,
    duration_ms: ?i64 = null,
};

/// 凭据
pub const Credentials = struct {
    token: []const u8,
    base_url: []const u8,
    account_id: []const u8,
    user_id: []const u8,
    aes_key: []const u8, // base64 字符串
    expires_at: i64,

    pub fn deinit(self: *Credentials, alloc: Allocator) void {
        alloc.free(self.token);
        alloc.free(self.base_url);
        alloc.free(self.account_id);
        alloc.free(self.user_id);
        alloc.free(self.aes_key);
    }
};

/// 发送内容 (Image/Video/File 字节)
pub const SendContent = union(enum) {
    text: []const u8,
    image: []const u8, // PNG/JPG 字节
    file: struct {
        data: []const u8,
        file_name: []const u8,
    },
    video: []const u8,
};

/// 媒体 (download 后)
pub const Media = struct {
    media_type: MediaType,
    data: []u8, // owned
    file_name: ?[]u8 = null,

    pub fn deinit(self: *Media, alloc: Allocator) void {
        alloc.free(self.data);
        if (self.file_name) |f| alloc.free(f);
    }
};

// ===== JSON 序列化 (Zig 0.17 用 std.json 静态) =====

/// 把 IncomingMessage 序列化成 JSON Lines 格式 (给 GHW IM Bridge 用)
pub fn serializeToJson(alloc: Allocator, msg: IncomingMessage) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.print(alloc,
        \\{{"msg_id":{d},"source":"wechat","sender":"{s}","text":"{s}","timestamp":{d}}}
    , .{ msg.msg_id, msg.user_id, msg.text, msg.timestamp });
    return buf.toOwnedSlice(alloc);
}

test "serializeToJson: 简单 text 消息" {
    const alloc = std.testing.allocator;
    const msg = IncomingMessage{
        .msg_id = 12345,
        .user_id = "alice",
        .text = "hello",
        .timestamp = 1700000000,
    };
    const json = try serializeToJson(alloc, msg);
    defer alloc.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"source\":\"wechat\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"sender\":\"alice\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"text\":\"hello\"") != null);
}
