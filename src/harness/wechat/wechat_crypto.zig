// SPDX-License-Identifier: MIT
// src/harness/wechat/wechat_crypto.zig
// AES-128-ECB 加解密 (GHW 零依赖原则: 不引入外部 crypto 库)
//
// 协议: NIST FIPS 197, 16 字节 block, 16/24/32 字节 key
// 本文件只实现 128-bit (16 字节 key) 因为 wechatbot 用 AES-128-ECB
//
// 参考:
//   - https://github.com/corespeed-io/wechatbot/blob/main/rust/src/crypto.rs
//   - FIPS 197 标准
//
// 测试: 已知 plaintext+key → ciphertext, NIST 5.1/G.1 测试向量

const std = @import("std");

/// AES S-box (256 字节)
const sbox: [256]u8 = blk: {
    var s: [256]u8 = undefined;
    // 标准 AES S-box
    const raw = [_]u8{
        0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
        0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
        0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
        0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
        0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
        0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
        0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
        0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
        0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
        0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
        0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
        0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
        0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
        0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
        0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
        0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
    };
    for (0..256) |i| s[i] = raw[i];
    break :blk s;
};

/// GF(2^8) inverse S-box (for decryption)
const inv_sbox: [256]u8 = blk: {
    var s: [256]u8 = undefined;
    for (0..256) |i| s[sbox[i]] = @intCast(i);
    break :blk s;
};

/// Round constants (Rcon)
const rcon: [11]u8 = .{ 0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36 };

/// GF(2^8) 乘法
fn gmul(a: u8, b: u8) u8 {
    var p: u8 = 0;
    var aa = a;
    var bb = b;
    for (0..8) |_| {
        if ((bb & 1) != 0) p ^= aa;
        const hi = aa & 0x80;
        aa <<= 1;
        if (hi != 0) aa ^= 0x1b;
        bb >>= 1;
    }
    return p;
}

/// SubBytes
fn subBytes(state: *[16]u8) void {
    for (0..16) |i| state[i] = sbox[state[i]];
}

fn invSubBytes(state: *[16]u8) void {
    for (0..16) |i| state[i] = inv_sbox[state[i]];
}

/// ShiftRows
fn shiftRows(state: *[16]u8) void {
    // Row 0: 不动
    // Row 1: 左移 1
    const t1 = state[1];
    state[1] = state[5];
    state[5] = state[9];
    state[9] = state[13];
    state[13] = t1;
    // Row 2: 左移 2
    const t21 = state[2];
    const t22 = state[6];
    state[2] = state[10];
    state[6] = state[14];
    state[10] = t21;
    state[14] = t22;
    // Row 3: 左移 3
    const t3 = state[15];
    state[15] = state[11];
    state[11] = state[7];
    state[7] = state[3];
    state[3] = t3;
}

fn invShiftRows(state: *[16]u8) void {
    // Row 1: 右移 1
    const t1 = state[13];
    state[13] = state[9];
    state[9] = state[5];
    state[5] = state[1];
    state[1] = t1;
    // Row 2: 右移 2
    const t21 = state[2];
    const t22 = state[6];
    state[2] = state[10];
    state[6] = state[14];
    state[10] = t21;
    state[14] = t22;
    // Row 3: 右移 3
    const t3 = state[3];
    state[3] = state[7];
    state[7] = state[11];
    state[11] = state[15];
    state[15] = t3;
}

/// MixColumns
fn mixColumns(state: *[16]u8) void {
    var i: usize = 0;
    while (i < 16) : (i += 4) {
        const a = state[i];
        const b = state[i + 1];
        const c = state[i + 2];
        const d = state[i + 3];
        state[i] = gmul(a, 2) ^ gmul(b, 3) ^ c ^ d;
        state[i + 1] = a ^ gmul(b, 2) ^ gmul(c, 3) ^ d;
        state[i + 2] = a ^ b ^ gmul(c, 2) ^ gmul(d, 3);
        state[i + 3] = gmul(a, 3) ^ b ^ c ^ gmul(d, 2);
    }
}

fn invMixColumns(state: *[16]u8) void {
    var i: usize = 0;
    while (i < 16) : (i += 4) {
        const a = state[i];
        const b = state[i + 1];
        const c = state[i + 2];
        const d = state[i + 3];
        state[i] = gmul(a, 14) ^ gmul(b, 11) ^ gmul(c, 13) ^ gmul(d, 9);
        state[i + 1] = gmul(a, 9) ^ gmul(b, 14) ^ gmul(c, 11) ^ gmul(d, 13);
        state[i + 2] = gmul(a, 13) ^ gmul(b, 9) ^ gmul(c, 14) ^ gmul(d, 11);
        state[i + 3] = gmul(a, 11) ^ gmul(b, 13) ^ gmul(c, 9) ^ gmul(d, 14);
    }
}

/// AddRoundKey (round_key 长度必须 16)
fn addRoundKey(state: *[16]u8, round_key: []const u8) void {
    for (0..16) |i| state[i] ^= round_key[i];
}

/// Key expansion (AES-128 → 11 round keys, 每 16 字节)
fn keyExpansion(key: *const [16]u8, round_keys: *[176]u8) void {
    // 前 16 字节直接是 key
    for (0..16) |i| round_keys[i] = key[i];

    var i: usize = 16;
    var rcon_idx: usize = 1;
    var temp: [4]u8 = undefined;

    while (i < 176) {
        for (0..4) |j| temp[j] = round_keys[i - 4 + j];

        if (i % 16 == 0) {
            // RotWord
            const t = temp[0];
            temp[0] = temp[1];
            temp[1] = temp[2];
            temp[2] = temp[3];
            temp[3] = t;
            // SubWord
            for (0..4) |j| temp[j] = sbox[temp[j]];
            // Rcon
            temp[0] ^= rcon[rcon_idx];
            rcon_idx += 1;
        }

        for (0..4) |j| {
            round_keys[i + j] = round_keys[i - 16 + j] ^ temp[j];
        }
        i += 4;
    }
}

/// 加密一个 16 字节 block
fn encryptBlock(block: *const [16]u8, round_keys: *const [176]u8, out: *[16]u8) void {
    var state: [16]u8 = block.*;

    addRoundKey(&state, round_keys[0..16]);

    var round: usize = 1;
    while (round < 10) : (round += 1) {
        subBytes(&state);
        shiftRows(&state);
        mixColumns(&state);
        addRoundKey(&state, round_keys[round * 16 ..][0..16]);
    }
    // 最后一轮无 MixColumns
    subBytes(&state);
    shiftRows(&state);
    addRoundKey(&state, round_keys[160..176]);

    out.* = state;
}

/// 解密一个 16 字节 block
fn decryptBlock(block: *const [16]u8, round_keys: *const [176]u8, out: *[16]u8) void {
    var state: [16]u8 = block.*;

    addRoundKey(&state, round_keys[160..176]);

    var round: usize = 9;
    while (round > 0) : (round -= 1) {
        invShiftRows(&state);
        invSubBytes(&state);
        addRoundKey(&state, round_keys[round * 16 ..][0..16]);
        invMixColumns(&state);
    }
    invShiftRows(&state);
    invSubBytes(&state);
    addRoundKey(&state, round_keys[0..16]);

    out.* = state;
}

/// 公开 API: 加密任意长度 (ECB 模式, PKCS#7 padding)
pub fn encrypt(alloc: std.mem.Allocator, plaintext: []const u8, key: *const [16]u8) ![]u8 {
    var round_keys: [176]u8 = undefined;
    keyExpansion(key, &round_keys);

    // PKCS#7 padding
    const pad_len: u8 = @intCast(16 - (plaintext.len % 16));
    const padded_len = plaintext.len + pad_len;
    const padded = try alloc.alloc(u8, padded_len);
    defer alloc.free(padded);
    @memcpy(padded[0..plaintext.len], plaintext);
    var i: usize = plaintext.len;
    while (i < padded_len) : (i += 1) padded[i] = pad_len;

    const out = try alloc.alloc(u8, padded_len);
    var block: [16]u8 = undefined;
    var in_block: [16]u8 = undefined;
    var j: usize = 0;
    while (j < padded_len) : (j += 16) {
        @memcpy(&in_block, padded[j..][0..16]);
        encryptBlock(&in_block, &round_keys, &block);
        @memcpy(out[j..][0..16], &block);
    }
    return out;
}

/// 公开 API: 解密 (自动去 PKCS#7 padding)
pub fn decrypt(alloc: std.mem.Allocator, ciphertext: []const u8, key: *const [16]u8) ![]u8 {
    if (ciphertext.len % 16 != 0) return error.InvalidCiphertextLength;
    if (ciphertext.len == 0) return try alloc.dupe(u8, "");

    var round_keys: [176]u8 = undefined;
    keyExpansion(key, &round_keys);

    const out = try alloc.alloc(u8, ciphertext.len);
    var block: [16]u8 = undefined;
    var in_block: [16]u8 = undefined;
    var j: usize = 0;
    while (j < ciphertext.len) : (j += 16) {
        @memcpy(&in_block, ciphertext[j..][0..16]);
        decryptBlock(&in_block, &round_keys, &block);
        @memcpy(out[j..][0..16], &block);
    }

    // 验证并去 PKCS#7 padding
    const pad_len = out[out.len - 1];
    if (pad_len == 0 or pad_len > 16) return error.InvalidPadding;
    var k: usize = 0;
    while (k < pad_len) : (k += 1) {
        if (out[out.len - 1 - k] != pad_len) return error.InvalidPadding;
    }
    return alloc.realloc(out, out.len - pad_len);
}

/// 生成 16 字节随机 key (用于演示, 真实场景用 wechatbot SDK 的 generate_aes_key)
pub fn generateKey(prng: std.Random) [16]u8 {
    var key: [16]u8 = undefined;
    for (0..16) |i| key[i] = prng.intRangeAtMost(u8, 0, 255);
    return key;
}

/// 解码协议 key (支持 3 种格式: base64, 十六进制字符串, 32 字节二进制)
pub fn decodeKey(input: []const u8) ![16]u8 {
    var key: [16]u8 = undefined;

    // 十六进制 (32 字符)
    if (input.len == 32) {
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            const hi: u8 = try hexNibble(input[i * 2]);
            const lo: u8 = try hexNibble(input[i * 2 + 1]);
            key[i] = @as(u8, hi << 4) | lo;
        }
        return key;
    }

    // 16 字节二进制
    if (input.len == 16) {
        @memcpy(&key, input);
        return key;
    }

    // base64 (>= 16 字符, 解码后应该 16 字节)
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const exact_size = try decoder.calcSizeForSlice(input);
    const buf = try std.heap.page_allocator.alloc(u8, exact_size);
    defer std.heap.page_allocator.free(buf);
    try decoder.decode(buf, input);
    if (buf.len != 16) return error.InvalidKeyLength;
    @memcpy(&key, buf);
    return key;
}

fn hexNibble(c: u8) !u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => error.InvalidHex,
    };
}

// ===== Tests (NIST FIPS 197 附录 B 测试向量) =====

test "AES-128: NIST 附录 B 加密向量" {
    _ = std.testing.allocator; // placeholder for clarity
    // FIPS 197 附录 B (p.35): key=000102030405060708090a0b0c0d0e0f, plaintext=00112233445566778899aabbccddeeff
    // ciphertext 应该是 69c4e0d86a7b0430d8cdb78070b4c55a
    const key = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f };
    const plain = [_]u8{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff };
    var round_keys: [176]u8 = undefined;
    keyExpansion(&key, &round_keys);
    var out: [16]u8 = undefined;
    encryptBlock(&plain, &round_keys, &out);
    const expected = [_]u8{ 0x69, 0xc4, 0xe0, 0xd8, 0x6a, 0x7b, 0x04, 0x30, 0xd8, 0xcd, 0xb7, 0x80, 0x70, 0xb4, 0xc5, 0x5a };
    try std.testing.expectEqualSlices(u8, &expected, &out);
}

test "AES-128: 加解密 roundtrip" {
    const alloc = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const key = generateKey(prng.random());
    const messages = [_][]const u8{
        "Hello, WeChat!",
        "",
        "GHW digital life AES test",
        "x",
        "A block of text that is exactly 16",
    };
    for (messages) |msg| {
        const ct = try encrypt(alloc, msg, &key);
        defer alloc.free(ct);
        const pt = try decrypt(alloc, ct, &key);
        defer alloc.free(pt);
        try std.testing.expectEqualSlices(u8, msg, pt);
    }
}

test "AES-128: decrypt NIST 附录 B 验证" {
    const alloc = std.testing.allocator;
    const key = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f };
    const ct = [_]u8{ 0x69, 0xc4, 0xe0, 0xd8, 0x6a, 0x7b, 0x04, 0x30, 0xd8, 0xcd, 0xb7, 0x80, 0x70, 0xb4, 0xc5, 0x5a };
    const expected = [_]u8{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff };

    // 用 decryptBlock (不剥 padding) 验证
    var round_keys: [176]u8 = undefined;
    keyExpansion(&key, &round_keys);
    var pt: [16]u8 = undefined;
    decryptBlock(&ct, &round_keys, &pt);
    try std.testing.expectEqualSlices(u8, &expected, &pt);

    // 验证完整加解密链路: 用一段会 PKCS#7 pad 到 32 字节的 plaintext
    const msg = "Hello, World!!!!"; // 16 字节 (不需要 padding)
    const encrypted = try encrypt(alloc, msg, &key);
    defer alloc.free(encrypted);
    const decrypted = try decrypt(alloc, encrypted, &key);
    defer alloc.free(decrypted);
    try std.testing.expectEqualSlices(u8, msg, decrypted);
}

test "AES-128: decodeKey 支持 hex / binary" {
    // Hex 32 字符
    const hex_key = "000102030405060708090a0b0c0d0e0f";
    const k1 = try decodeKey(hex_key);
    try std.testing.expectEqual(@as(u8, 0x00), k1[0]);
    try std.testing.expectEqual(@as(u8, 0x0f), k1[15]);

    // 16 字节 binary
    const bin_key = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f };
    const k2 = try decodeKey(&bin_key);
    try std.testing.expectEqualSlices(u8, &bin_key, &k2);

    // base64 (wechatbot 例子, 24 字符, 16 字节)
    // 0x00,0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88,0x99,0xaa,0xbb,0xcc,0xdd,0xee,0xff
    // = "ABEiM0RVZneImaq7zN3u/w=="
    // (url-safe no-pad: "ABEiM0RVZneImaq7zN3u_w")
    const b64_key = "ABEiM0RVZneImaq7zN3u_w";
    const k3 = try decodeKey(b64_key);
    try std.testing.expectEqual(@as(u8, 0x00), k3[0]);
    try std.testing.expectEqual(@as(u8, 0xff), k3[15]);
}
