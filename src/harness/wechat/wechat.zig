// SPDX-License-Identifier: MIT
// src/harness/wechat/wechat.zig — WeChat iLink Bot SDK (Zig 0.17 移植)
//
// 参考: https://github.com/corespeed-io/wechatbot/blob/main/rust
//       Rust SDK 用 tokio + reqwest + AES-128-ECB
//       我们用 std.Io.Threaded + std.http.Client (Zig 0.17 零外部依赖)
//
// 模块结构:
//   - wechat_crypto.zig  : AES-128-ECB 加解密 (本仓库零依赖原则)
//   - wechat_types.zig   : 协议 + 用户友好的所有类型
//   - wechat_error.zig   : 错误层级
//   - wechat_protocol.zig: 原生 ilinkai.weixin.qq.com HTTP API
//   - wechat_bot.zig     : WeChatBot 客户端 (login, run, reply, send)
//
// 用法:
//   const wechat = @import("wechat.zig");
//   var bot = wechat.WeChatBot.init(alloc, io, .{});
//   try bot.login(false);
//   try bot.onMessage(...);
//   try bot.run();

pub const crypto = @import("wechat_crypto.zig");
pub const types = @import("wechat_types.zig");
pub const error_mod = @import("wechat_error.zig");
pub const protocol = @import("wechat_protocol.zig");
pub const bot = @import("wechat_bot.zig");

pub const WeChatBot = bot.WeChatBot;
pub const BotOptions = bot.BotOptions;
pub const IncomingMessage = types.IncomingMessage;
pub const ContentType = types.ContentType;
pub const SendContent = types.SendContent;
pub const Credentials = types.Credentials;
pub const Media = types.Media;
pub const ImageContent = types.ImageContent;
pub const VoiceContent = types.VoiceContent;
pub const FileContent = types.FileContent;
pub const VideoContent = types.VideoContent;
pub const WeChatBotError = error_mod.WeChatBotError;
