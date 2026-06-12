#!/usr/bin/env python3
# scripts/gen_weekly_log.py — 合成 1 周 IM log 用于 weekly_replay
# 用法: python3 scripts/gen_weekly_log.py data/weekly_im_log.jsonl
#
# 每条 JSON: { source, sender, text, timestamp, day, expected_feedback }
#
# 模拟 7 天: alice (PM), bob (技术), carol (设计), dave (新人), eve (偶尔冒泡)
# 任务类型: material (compute/CPU), representation (learn/method), nature (explore/decision)
#
# 1 周 (60-80 条) 量级, 让 weekly_replay 能跑出:
# - E 随时间的轨迹
# - Trust 重分配
# - Value Score 趋势
# - 表现最好的 3 个人
# - 自动 balance 任务次数

import json, random, sys, datetime
from pathlib import Path

random.seed(42)

SENDERS = [
    ("alice", "PM, 主导型, 提需求", 0.9),
    ("bob", "技术, 爱 explore + compute", 0.85),
    ("carol", "设计, 爱 representation/method", 0.8),
    ("dave", "新人, 信噪低, 偶尔发", 0.5),
    ("eve", "路人, 极稀", 0.2),
]

TEMPLATES = {
    "material": [
        "需要更多 compute 资源",
        "算力 CPU 不够",
        "机器卡死了",
        "再加一台 GPU",
        "compute 资源啥时候到位",
        "cpu 跑不动了",
        "ram 爆了",
    ],
    "representation": [
        "这个方法怎么实现",
        "学习一下新算法",
        "knowledge base 更新",
        "帮我理解这个模块",
        "知识库加一条",
        "新方法 怎么调",
        "read the docs",
    ],
    "nature": [
        "让 AI 自主决定",
        "explore 一下新策略",
        "自主决策权",
        "自己探索吧",
        "agile 自组织",
        "self-explore",
        "AI 自己做主",
    ],
    "all": [
        "hi",
        "在吗",
        "看看这个",
        "测试一下",
        "ok",
        "ok 收到",
        "thanks",
        "辛苦了",
        "下午开会",
        "1on1 改到明天",
    ],
}

DAYS = 7
MESSAGES_PER_DAY = 10  # ≈ 70 条/周

def gen():
    events = []
    base = datetime.datetime(2025, 1, 13, 9, 0, 0)  # 周一
    ts = int(base.timestamp())
    for d in range(DAYS):
        day_start = ts + d * 86400
        # 每天上午 9-12 / 下午 14-18 集中发消息
        for _ in range(MESSAGES_PER_DAY):
            sender = random.choices(
                SENDERS,
                weights=[s[2] for s in SENDERS],
            )[0][0]
            # 周一/二 material 任务多, 周三/四 representation, 周五 nature
            r = random.random()
            if d < 2: dim = "material" if r < 0.5 else ("all" if r < 0.8 else random.choice(["representation", "nature"]))
            elif d < 4: dim = "representation" if r < 0.4 else ("all" if r < 0.8 else random.choice(["material", "nature"]))
            else: dim = "nature" if r < 0.4 else ("all" if r < 0.8 else random.choice(["material", "representation"]))
            text = random.choice(TEMPLATES[dim])
            # 真实场景: 人发消息的时间戳不是均匀的
            offset = random.randint(0, 8 * 3600)
            ts_msg = day_start + offset
            # 反馈: dave/eve 通常无反馈, alice/carol/bob 给分 1-2 (大体满意)
            if sender in ("alice", "bob", "carol") and random.random() < 0.7:
                feedback = random.choice([1, 2, 2, 2, 1, 0])
            else:
                feedback = None
            events.append({
                "source": "feishu" if random.random() < 0.6 else "lark",
                "sender": sender,
                "text": text,
                "timestamp": ts_msg,
                "day": d,
                "expected_feedback": feedback,
            })
    return events

if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "data/weekly_im_log.jsonl"
    events = gen()
    Path(out).parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w") as f:
        for e in events:
            f.write(json.dumps(e, ensure_ascii=False) + "\n")
    # 统计
    by_day = {}
    by_sender = {}
    for e in events:
        by_day[e["day"]] = by_day.get(e["day"], 0) + 1
        by_sender[e["sender"]] = by_sender.get(e["sender"], 0) + 1
    print(f"wrote {len(events)} events to {out}")
    print(f"by day: {by_day}")
    print(f"by sender: {by_sender}")
