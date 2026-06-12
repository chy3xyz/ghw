// SPDX-License-Identifier: MIT
// src/harness/wechat/wechat_error.zig — WeChat SDK 错误层级 (对应 thiserror 层级)

const std = @import("std");

pub const WeChatBotError = error{
    /// 协议层错误 (HTTP/JSON 解析失败)
    Transport,
    /// 协议错误 (ilink API 返回 errcode != 0)
    Api,
    /// 会话过期 (errcode == -14, 自动重试)
    SessionExpired,
    /// 没有 user 的 context_token (发私聊消息前需要)
    NoContext,
    /// AES 解密失败 (key 错 / padding 错)
    CryptoError,
    /// 凭据读取/写入失败
    Credentials,
    /// 二维码 URL 获取失败
    QrCode,
    /// 登录超时
    LoginTimeout,
    /// 上传/下载失败
    MediaTransfer,
    /// 内存分配失败
    OutOfMemory,
    /// 用户取消
    Cancelled,
    /// 其他
    Other,
};

/// 协议层错误响应 (用于 API 错误处理)
pub const ApiErrorInfo = struct {
    errcode: i32,
    errmsg: []const u8,
    message: []const u8,
};
