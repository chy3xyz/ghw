//! 通用数学工具: 张量运算、统计函数、随机数
//! 张量布局: 一维 f32 slice + 步长
//!  -- 一维向量:  v[i] = slice[i*stride]
//!  -- 二维矩阵:  M[i][j] = slice[i*row_stride + j]
//!  -- 三维张量: T[i][j][k] = slice[i*s0 + j*s1 + k]

const std = @import("std");
const math = std.math;
const mem = std.mem;
const Allocator = mem.Allocator;
const Random = std.Random;

pub const F = f32;

/// 数值误差保护
pub fn safeDiv(a: F, b: F) F {
    if (math.abs(b) < 1e-12) return 0;
    return a / b;
}

/// sigmoid
pub fn sigmoid(x: F) F {
    return @as(F, 1.0) / (@as(F, 1.0) + @exp(-x));
}

/// tanh
pub fn tanh(x: F) F {
    const e2x = @exp(2.0 * x);
    return (e2x - 1.0) / (e2x + 1.0);
}

/// 截断到 [lo, hi]
pub fn clamp(x: F, lo: F, hi: F) F {
    return @max(lo, @min(hi, x));
}

/// 截断到 [0, 1]
pub fn unit(x: F) F {
    return clamp(x, 0.0, 1.0);
}

/// Shannon 熵 H(p) = -Σ p_i log2(p_i)
/// 输入: 概率分布 (自动归一化,过滤非正元素)
pub fn shannonEntropy(probs: []const F) F {
    var sum: F = 0;
    for (probs) |p| {
        if (p > 0) sum += p;
    }
    if (sum < 1e-12) return 0;
    var h: F = 0;
    for (probs) |p| {
        if (p > 0) {
            const pn = p / sum;
            h -= pn * @log2(pn);
        }
    }
    return h;
}

/// softmax: 数值稳定版 (减去最大值)
pub fn softmax(input: []const F, output: []F) void {
    std.debug.assert(input.len == output.len);
    var max_val: F = -math.inf(F);
    for (input) |x| {
        if (x > max_val) max_val = x;
    }
    var sum: F = 0;
    for (input, 0..) |x, i| {
        output[i] = @exp(x - max_val);
        sum += output[i];
    }
    if (sum < 1e-12) {
        for (output) |*v| v.* = 1.0 / @as(F, @floatFromInt(output.len));
        return;
    }
    for (output) |*v| v.* /= sum;
}

/// L2 范数
pub fn l2norm(xs: []const F) F {
    var s: F = 0;
    for (xs) |x| s += x * x;
    return @sqrt(s);
}

/// L1 范数
pub fn l1norm(xs: []const F) F {
    var s: F = 0;
    for (xs) |x| s += @abs(x);
    return s;
}

/// Frobenius 范数 (= L2 范数对矩阵的推广)
pub fn frobNorm(xs: []const F) F {
    return l2norm(xs);
}

/// 归一化到 L2 单位向量 (就地)
pub fn normalizeL2(xs: []F) void {
    const n = l2norm(xs);
    if (n < 1e-12) return;
    for (xs) |*v| v.* /= n;
}

/// 点积
pub fn dot(a: []const F, b: []const F) F {
    std.debug.assert(a.len == b.len);
    var s: F = 0;
    for (a, b) |x, y| s += x * y;
    return s;
}

/// 余弦相似度
pub fn cosineSim(a: []const F, b: []const F) F {
    const na = l2norm(a);
    const nb = l2norm(b);
    if (na < 1e-12 or nb < 1e-12) return 0;
    return dot(a, b) / (na * nb);
}

/// 互信息简化版: I(X;Y) ≈ 1 - 归一化残差
/// 用于估计"内部世界模型"与"环境观察"之间的吻合度。
/// x_obs:  观察的某个特征向量
/// x_pred: 预测的特征向量
/// 返回: [0,1] 数值,越高代表互信息越大
pub fn mutualInformationApprox(x_obs: []const F, x_pred: []const F) F {
    std.debug.assert(x_obs.len == x_pred.len);
    var sse: F = 0;
    var sso: F = 0;
    for (x_obs, x_pred) |o, p| {
        const d = o - p;
        sse += d * d;
        sso += o * o;
    }
    if (sso < 1e-12) return 0;
    // NMSE (normalized mean squared error) -> MI ≈ 1 - NMSE
    return clamp(1.0 - sse / sso, 0.0, 1.0);
}

/// 线性同余随机 (确定性、可重现的轻量 PRNG, 仅用于演示)
/// 避免依赖全局 Random 接口, 方便嵌入到任何环境中
pub const LCG = struct {
    state: u64,

    pub fn init(seed: u64) LCG {
        return .{ .state = if (seed == 0) 0xdeadbeef else seed };
    }

    pub fn next(self: *LCG) u64 {
        self.state = self.state *% 6364136223846793005 +% 1442695040888963407;
        return self.state;
    }

    /// [0, 1) 单精度
    pub fn unitF(self: *LCG) F {
        const v = self.next();
        return @as(F, @floatFromInt(v & 0xFFFFFF)) / @as(F, 16777216.0);
    }

    /// [lo, hi) 单精度
    pub fn range(self: *LCG, lo: F, hi: F) F {
        return lo + (hi - lo) * self.unitF();
    }

    /// 整数 [0, n)
    pub fn lessThan(self: *LCG, n: u32) u32 {
        return @intCast(self.next() % n);
    }

    /// Fisher-Yates shuffle (就地)
    pub fn shuffle(self: *LCG, comptime T: type, items: []T) void {
        if (items.len < 2) return;
        var i: usize = items.len - 1;
        while (i > 0) : (i -= 1) {
            const j = self.lessThan(@intCast(i + 1));
            mem.swap(T, &items[i], &items[j]);
        }
    }
};

// ===== 张量辅助 (高维数据布局与切片操作) =====

/// 三维张量 W[i][j][k] 的步长
pub const Tensor3Shape = struct {
    d0: usize, // 物理维度
    d1: usize, // 社会维度
    d2: usize, // 存在维度
    pub const total = 3;

    pub fn product(self: Tensor3Shape) usize {
        return self.d0 * self.d1 * self.d2;
    }
};

/// 二维张量 M[i][j] 步长
pub const Tensor2Shape = struct {
    rows: usize,
    cols: usize,
    pub fn product(self: Tensor2Shape) usize {
        return self.rows * self.cols;
    }
};

/// 三维张量按 (i, j, k) 索引到一维数组
pub fn idx3(s: Tensor3Shape, i: usize, j: usize, k: usize) usize {
    std.debug.assert(i < s.d0 and j < s.d1 and k < s.d2);
    return i * s.d1 * s.d2 + j * s.d2 + k;
}

/// 二维张量按 (i, j) 索引
pub fn idx2(s: Tensor2Shape, i: usize, j: usize) usize {
    std.debug.assert(i < s.rows and j < s.cols);
    return i * s.cols + j;
}

/// 估算两个概率分布的 Jensen-Shannon 散度
/// 用作"世界模型预测与现实"的差异度量之一
pub fn jsDivergence(p: []const F, q: []const F) F {
    std.debug.assert(p.len == q.len);
    var sum: F = 0;
    var mid: [256]F = undefined; // 演示用,实际长度由调用方保证
    const n = p.len;
    if (n > mid.len) return 0;
    for (p, 0..) |pi, i| {
        sum += pi;
        mid[i] = (pi + q[i]) * 0.5;
    }
    if (sum < 1e-12) return 0;
    const h_mid = shannonEntropy(mid[0..n]);
    // JS = H(mid) - 0.5*H(p) - 0.5*H(q) (使用 log2 自然单位)
    return clamp(h_mid - 0.5 * shannonEntropy(p) - 0.5 * shannonEntropy(q), 0.0, 1.0);
}

/// 能量守恒投影: 给定一个非负张量,按指定总能量归一化
pub fn projectToEnergy(buf: []F, total_energy: F) void {
    var sum: F = 0;
    for (buf) |v| sum += @abs(v);
    if (sum < 1e-12) return;
    const k = total_energy / sum;
    for (buf) |*v| v.* *= k;
}

test "shannonEntropy: 均匀分布" {
    const xs = [_]F{ 0.25, 0.25, 0.25, 0.25 };
    try std.testing.expectApproxEqAbs(@log2(4.0), shannonEntropy(&xs), 1e-4);
}

test "shannonEntropy: 退化分布 = 0" {
    const xs = [_]F{ 0, 0, 1, 0 };
    try std.testing.expectEqual(@as(F, 0), shannonEntropy(&xs));
}

test "softmax: 数值稳定" {
    var buf: [4]F = .{ 1000, 1001, 1002, 1003 };
    var out: [4]F = undefined;
    softmax(&buf, &out);
    var sum: F = 0;
    for (out) |v| sum += v;
    try std.testing.expectApproxEqAbs(@as(F, 1.0), sum, 1e-5);
}

test "l2norm" {
    const xs = [_]F{ 3, 4 };
    try std.testing.expectEqual(@as(F, 5.0), l2norm(&xs));
}

test "LCG: 可重现 + shuffle" {
    var rng1 = LCG.init(42);
    var rng2 = LCG.init(42);
    var arr1: [10]u32 = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    var arr2: [10]u32 = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    rng1.shuffle(u32, &arr1);
    rng2.shuffle(u32, &arr2);
    try std.testing.expectEqualSlices(u32, &arr1, &arr2);
    // 至少打乱过
    var same: usize = 0;
    for (arr1, 0..) |v, i| {
        if (v == @as(u32, @intCast(i + 1))) same += 1;
    }
    try std.testing.expect(same < arr1.len);
}

test "idx3 / idx2" {
    const s3 = Tensor3Shape{ .d0 = 2, .d1 = 3, .d2 = 4 };
    try std.testing.expectEqual(@as(usize, 11), idx3(s3, 0, 2, 3));
    const s2 = Tensor2Shape{ .rows = 3, .cols = 4 };
    try std.testing.expectEqual(@as(usize, 9), idx2(s2, 2, 1));
}
