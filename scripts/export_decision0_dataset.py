#!/usr/bin/env python3
"""export_decision0_dataset.py — GHW decision0 日志 → zjev-fit 校准数据集

用法:
  # 从 GHW sqlite 导出真实咨询记录 (需 outcome 已回填)
  python3 scripts/export_decision0_dataset.py --db ~/.local/share/ghw/ui_state.json.db --out dataset.jsonl

  # 合成种子 (冷启动; 规则生成 + 噪声, 诚实标注 synthetic)
  python3 scripts/export_decision0_dataset.py --synthetic 200 --out seed.jsonl

标签语义 (可辩护映射):
  outcome=resolved (咨询后 16 tick 危机解除) → label = 当时的 action (选对了)
  outcome=persisted (危机仍在)              → label = handoff (早该移交人类)
"""
import argparse
import json
import random
import re
import sqlite3
import sys

FEATURE_RE = re.compile(
    r"M=([\d.]+) R=([\d.]+) N=([\d.]+) E=([\d.]+) disk=([\d.]+)% mem=([\d.]+)% load=([\d.]+)/(\d+)c"
)


def parse_request(text):
    """request JSON 的 state.text → 结构化特征 (仅用于合成/审计; 导出原样保留 text)"""
    m = FEATURE_RE.search(text)
    if not m:
        return None
    return {
        "M": float(m.group(1)), "R": float(m.group(2)), "N": float(m.group(3)),
        "E": float(m.group(4)), "disk": float(m.group(5)),
        "mem": float(m.group(6)), "load": float(m.group(7)),
        "cpus": int(m.group(8)),
    }


def export_real(db_path, out_path):
    conn = sqlite3.connect(db_path)
    rows = conn.execute(
        "SELECT tick, request_text, action, outcome FROM decision0_log "
        "WHERE outcome IS NOT NULL ORDER BY id"
    ).fetchall()
    conn.close()
    n = 0
    with open(out_path, "w") as f:
        for tick, req_text, action, outcome in rows:
            # 从 request JSON 抽 state.text
            try:
                req = json.loads(req_text)
                state_text = req["state"]["text"]
            except (json.JSONDecodeError, KeyError):
                continue
            label = action if outcome == "resolved" else "handoff"
            rec = {
                "state": {"id": f"ghw-t{tick}", "text": state_text},
                "decision": {
                    "id": "crisis_action",
                    "type": "choice",
                    "options": ["proceed", "diagnose", "handoff"],
                },
                "label": label,
            }
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
            n += 1
    print(f"[export] {n} 条已回填咨询 → {out_path}")
    return n


def synthetic(seed_n, out_path, rng_seed=42):
    rng = random.Random(rng_seed)
    with open(out_path, "w") as f:
        for i in range(seed_n):
            m = round(rng.uniform(0.05, 0.95), 3)
            r = round(rng.uniform(0.05, 0.95), 3)
            n = round(rng.uniform(0.05, 0.95), 3)
            e = round((m + r + n) / 3 * rng.uniform(0.8, 1.0), 3)
            disk = round(rng.uniform(30, 99), 1)
            mem = round(rng.uniform(30, 99), 1)
            load = round(rng.uniform(0.2, 2.0), 2)
            cpus = rng.choice([4, 8, 12])
            # 规则标签 (可辩护启发 + 10% 标签噪声, 防完美可分):
            #   双热 (disk/mem 超阈) 或超订 >1.4 ⇒ handoff; 单热 ⇒ diagnose; 否则 proceed
            hot_disk, hot_mem = disk >= 90, mem >= 92
            oversub = load >= 1.4
            if hot_disk and hot_mem or oversub:
                label = "handoff"
            elif hot_disk or hot_mem or load >= 1.0:
                label = "diagnose"
            else:
                label = "proceed"
            if rng.random() < 0.10:
                label = rng.choice(["proceed", "diagnose", "handoff"])
            state_text = (
                f"M={m:.3f} R={r:.3f} N={n:.3f} E={e:.3f} "
                f"disk={disk:.1f}% mem={mem:.1f}% load={load:.2f}/{cpus}c"
            )
            rec = {
                "state": {"id": f"syn-{i}", "text": state_text},
                "decision": {
                    "id": "crisis_action",
                    "type": "choice",
                    "options": ["proceed", "diagnose", "handoff"],
                },
                "label": label,
            }
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    print(f"[export] {seed_n} 条合成种子 (10% 标签噪声) → {out_path}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", help="GHW sqlite 路径 (真实导出)")
    ap.add_argument("--synthetic", type=int, metavar="N", help="生成 N 条合成种子")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    if args.synthetic:
        synthetic(args.synthetic, args.out)
    elif args.db:
        n = export_real(args.db, args.out)
        if n == 0:
            print("[export] 无已回填记录 (需先运行带 --zjev-endpoint 的 ui_server 并等 16 tick 回填)", file=sys.stderr)
            sys.exit(1)
    else:
        ap.error("需要 --db 或 --synthetic N")


if __name__ == "__main__":
    main()
