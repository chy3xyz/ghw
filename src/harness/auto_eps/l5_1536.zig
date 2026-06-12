
// Rule: tune_gamma_when_low_e
// Derived weights: alpha=0.50 beta=0.35 gamma=0.15
// Logic: E=1.000 (target=+0.050), reason: L5: 自我编码, 合成新规则
pub const SelfTuned_Tune_gamma_when_low_e = struct {
    pub const alpha: f32 = 0.50;
    pub const beta: f32 = 0.35;
    pub const gamma: f32 = 0.15;

    /// 存在度 E 计算 (物象性三源合恰)
    pub fn compute(m: f32, r: f32, n: f32) f32 {
        return alpha * m + beta * r + gamma * n;
    }
};
// Rule: boost_alpha_when_harmony_low
// Derived weights: alpha=0.50 beta=0.35 gamma=0.15
// Logic: E=1.000 (target=+0.050), reason: L5: 自我编码, 合成新规则
pub const SelfTuned_Boost_alpha_when_harmony_low = struct {
    pub const alpha: f32 = 0.50;
    pub const beta: f32 = 0.35;
    pub const gamma: f32 = 0.15;

    /// 存在度 E 计算 (物象性三源合恰)
    pub fn compute(m: f32, r: f32, n: f32) f32 {
        return alpha * m + beta * r + gamma * n;
    }
};