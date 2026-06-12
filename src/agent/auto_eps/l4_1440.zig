// src/agent/params.zig (auto-generated)
// 目的: 自适应 ε 调度, 平衡探索与利用
// 不变量: alpha / beta / gamma / E
pub const Module = struct {
  const std = @import("std");
  
  pub const alpha: f32 = 0.45;
  pub const beta: f32 = 0.35;
  pub const gamma: f32 = 0.20;
  pub const E: f32 = 0.5; // 存在增益基线
  
  pub const AdaptiveEpsilon = struct {
      pub const base: f32 = 0.05;
      pub const min_e_for_utilization: f32 = 0.5;
      pub const max_epsilon: f32 = 0.20;
  
    /// 自适应 ε: 存在度越低, 探索率越高 (存在增益导向)
      pub fn compute(e: f32) f32 {
          if (e > min_e_for_utilization) {
              return base * (1.0 - std.math.tanh(e));
          } else {
              return @min(max_epsilon, base * (1.0 + 1.0 / (1.0 + @exp(-(min_e_for_utilization - e)))));
          }
      }
  };
};
