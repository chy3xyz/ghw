
// Rule: tune_gamma_when_low_e
// Derived weights: alpha=0.40 beta=0.30 gamma=0.30
// Logic: E=0.251 (target=+0.050), reason: L5: 自我编码, 合成新规则

/// 数字生命"自己写"的代码 — 整个文件包进 Module 命名空间 (避免多文件 top-level 冲突)
pub const Module = struct {
    pub const Tune_gamma_when_low_e = struct {
        pub const alpha: f32 = 0.40;
        pub const beta: f32 = 0.30;
        pub const gamma: f32 = 0.30;

        /// 存在度 E 计算 (物象性三源合恰)
        pub fn compute(m: f32, r: f32, n: f32) f32 {
            return alpha * m + beta * r + gamma * n;
        }
    };
};
// Rule: boost_alpha_when_harmony_low
// Derived weights: alpha=0.40 beta=0.30 gamma=0.30
// Logic: E=0.251 (target=+0.050), reason: L5: 自我编码, 合成新规则

/// 数字生命"自己写"的代码 — 整个文件包进 Module 命名空间 (避免多文件 top-level 冲突)
pub const Module = struct {
    pub const Boost_alpha_when_harmony_low = struct {
        pub const alpha: f32 = 0.40;
        pub const beta: f32 = 0.30;
        pub const gamma: f32 = 0.30;

        /// 存在度 E 计算 (物象性三源合恰)
        pub fn compute(m: f32, r: f32, n: f32) f32 {
            return alpha * m + beta * r + gamma * n;
        }
    };
};