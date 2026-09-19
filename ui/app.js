// app.js — GHW UI 客户端逻辑
// 配合 Alpine.js + HTMX 使用
//
// Alpine 全局组件: ghwApp()
// HTMX 自动接管: 聊天发送 → POST /api/chat, 聊天历史 → GET /api/chat/history

function ghwApp() {
  return {
    // ===== 状态 =====
    tab: 'status',
    state: null,            // 最新 /api/state
    // x-text/x-html 计算值: 深链 x-show 效果不重算 (AGENTS.md), 数据绑定走文本通道
    saveBlockedHtml: '',
    ruleProposeLine: '规则提议: off',
    chatInfoLine: '',
    log: [],                // 最新 /api/log
    error: null,
    _pollTimer: null,

    // 记忆搜索 (sqlite)
    memoryQuery: '',
    memoryResults: null,

    // 第一性原理清单 (GET /api/laws)
    laws: null,
    lawsFilter: 'all', // all | hard_axiom | life_law | evaluation
    lawsOpen: true,
    // P2c: 宿主画像推送 / 同伴 inbox 详情
    hostProfileForm: { battery_pct: 12, thermal_hot: true, bg_restricted: false },
    peerShareForm: { peer_id: 'demo-peer', host_crisis: true, favored_dim: 1, material: 0.55 },
    peerInbox: { total_received: 0, entries: [] },
    hostProfileBusy: false,
    peerShareBusy: false,

    // ===== Tab 配置 =====
    tabs: [
      { id: 'status',       label: '生命信息',   icon: '🜂' },
      { id: 'capabilities', label: '能力地图',   icon: '🗺️' },
      { id: 'evolved',      label: '落盘代码',   icon: '📝' },
      { id: 'goals',        label: '提议目标',   icon: '🎯' },
      { id: 'tasks',        label: '任务队列',   icon: '📋' },
      { id: 'actions',      label: '动作历史',   icon: '⚡' },
      { id: 'reflect',      label: '自省/记忆',  icon: '🪞' },
      { id: 'memory',       label: '记忆搜索',   icon: '🔍' },
      { id: 'log',          label: '成长日志',   icon: '📜' },
      { id: 'chat',         label: '对话',       icon: '💬' },
    ],

    // ===== 能力地图 =====
    capabilities: null,
    trendData: { l1: [], l2: [], l3: [], l4: [], l5: [] },
    maxTrendValue: 1,

    // ===== Phase 8.7 L4 闭环反馈 =====
    proposeHistory: { history: [], avg_delta: 0 },

    // ===== Phase 9 宫 deep (从 capabilities.nine_palaces_deep 同步) =====
    ninePalaces: {
      mrn_var_now: 0, mrn_min_now: 0,
      mrn_buf_var: 0, mrn_buf_count: 0,
      mrn_seen: false, mrn_strong_seen: false, e_var_seen: false,
    },

    // ===== 9 宫 milestone 触发历史 (从 /api/nine_palaces_history) =====
    ninePalacesHistory: { history: [], summary: { e_var: false, mrn: false, mrn_strong: false } },

    // ===== Phase 1 production: 多 GHW 互联 peer dashboard (从 /api/peers) =====
    peerDashboard: { self: null, peers: [] },

    // ===== 落盘文件 (L3 L4 L5 真落盘 + 集成到 ghw 源码) =====
    evolvedFiles: [],
    evolvedSelected: null,  // 当前查看的文件名
    evolvedContent: '',     // 当前文件内容

    // 动作历史
    actions: [],
    actionRunning: false,

    // P9: TaskQueue + 人类反馈
    tasks: { tasks: [], pending: 0, completed: 0 },
    taskFeedbackBusy: false,
    taskSubmitBusy: false,
    newTask: { title: '', description: '', dimension: 'all' },
    taskSourceFilter: 'all',

    // 同伴 (GHW Link)
    peers: { self: null, peers: [] },
    newPeerPath: '',
    lastPeerResult: '',

    // ===== 指标卡 (计算属性) =====
    get metrics() {
      if (!this.state) return [];
      const s = this.state;
      const hs = s.provenance?.human_symbiosis;
      const rows = [
        { label: 'Tick',         value: this.formatNum(s.tick),       hint: '已跑周期数',           color: 'text-ghw-text' },
        { label: 'E (存在度)',   value: s.E.toFixed(3),               hint: this.eHint(),            color: this.eColor() },
        { label: 'α·M 物质贡献', value: (s.alpha * s.M).toFixed(3),  hint: `α=${s.alpha.toFixed(2)}`, color: 'text-blue-400' },
        { label: 'β·R 表征贡献', value: (s.beta * s.R).toFixed(3),   hint: `β=${s.beta.toFixed(2)}`,  color: 'text-fuchsia-400' },
        { label: 'γ·N 本心贡献', value: (s.gamma * s.N).toFixed(3),  hint: `γ=${s.gamma.toFixed(2)}`, color: 'text-amber-400' },
        { label: 'ΔE 累计',      value: (s.E - 0.5).toFixed(3),      hint: 'vs 初始 0.5',            color: 'text-ghw-warm' },
      ];
      if (hs) {
        rows.push(
          { label: '人类价值', value: (hs.value_score ?? 0).toFixed(3), hint: 'ValueMetric 综合分', color: 'text-cyan-300' },
          { label: '价值趋势', value: (hs.value_trend ?? 0).toFixed(4), hint: this.valueTrendHint(hs.value_trend), color: this.valueTrendColor(hs.value_trend) },
        );
      }
      const vit = s.provenance?.vitality;
      if (vit) {
        rows.push(
          { label: '代谢', value: vit.metabolism ?? '—', hint: vit.cycle_busy ? 'cycle 忙·快照可能旧' : `距上次 cycle ${vit.secs_since_cycle ?? '?'}s`, color: vit.metabolism === 'active' ? 'text-emerald-300' : 'text-amber-300' },
          { label: '同伴', value: String(vit.live_peers ?? 0), hint: '排除 self 的 live peers', color: 'text-sky-300' },
          { label: '任务', value: `${vit.completed_tasks ?? 0}/${(vit.pending_tasks ?? 0) + (vit.completed_tasks ?? 0)}`, hint: `pending=${vit.pending_tasks ?? 0}`, color: 'text-violet-300' },
          { label: 'ΔE往事', value: String(vit.episodes_nonzero_de ?? 0), hint: `episodes=${vit.episodes ?? 0}`, color: 'text-ghw-warm' },
        );
      }
      const surv = s.provenance?.survival;
      if (surv) {
        rows.push(
          { label: '外网记忆', value: String(surv.world_fetch_count ?? 0), hint: 'AutoCLI → Memory.world_fetch', color: 'text-teal-300' },
          { label: '任务动作', value: surv.last_task_action ?? 'none', hint: surv.last_task_acted ? '有界真执行已落地' : '合成/跳过', color: surv.last_task_acted ? 'text-emerald-300' : 'text-slate-400' },
          { label: '补救入队', value: String(surv.remedy_submitted_total ?? 0), hint: '诊断后 survival_remedy', color: 'text-rose-300' },
          { label: '求存信念', value: String(surv.survival_beliefs_total ?? 0), hint: '诊断→material beliefs', color: 'text-orange-300' },
          { label: '人类介入', value: String(surv.act_human_total ?? 0), hint: surv.autocli_throttle_s > 0 ? `AutoCLI ${surv.autocli_throttle_s}s` : '无节流', color: 'text-red-300' },
          { label: '高E代谢', value: String(surv.metabolism_submitted_total ?? 0), hint: '饱和时多样性任务', color: 'text-lime-300' },
          { label: '外网桥接', value: String(surv.world_bridge_total ?? 0), hint: 'fetch→任务', color: 'text-teal-300' },
          { label: '同伴写回', value: String(surv.peer_symbiosis_total ?? 0), hint: `peer_E_avg=${(surv.peer_E_avg ?? 0).toFixed(3)}`, color: 'text-sky-300' },
          { label: '规则效果', value: `${surv.feedback_improved ?? 0}/${surv.feedback_evals ?? 0}`, hint: '危机规则后压力↓', color: 'text-lime-300' },
          { label: '第一性', value: `v${surv.laws_version ?? '?'}`, hint: `${surv.laws_count ?? 0} 条硬先验 · 点开下方清单`, color: 'text-amber-300' },
          { label: '存在相', value: surv.existence_phase ?? '—', hint: surv.awakened ? (surv.host_fingerprint || '已觉醒') : '未觉醒', color: surv.existence_phase === 'crisis' ? 'text-rose-300' : 'text-emerald-300' },
          { label: '宿主短板', value: surv.shortfall ? (surv.shortfall.favored_dim === 1 ? 'M' : surv.shortfall.favored_dim === 2 ? 'R' : surv.shortfall.favored_dim === 3 ? 'N' : '—') : '—', hint: surv.shortfall?.host_crisis ? '危机' : '常态', color: 'text-orange-300' },
          { label: '宿主画像', value: surv.host_profile?.kind ?? '—', hint: surv.host_profile?.kind === 'mobile' ? `电量 ${surv.host_profile?.battery_pct ?? '?'}%` : 'SystemCollector', color: 'text-sky-300' },
          { label: '同伴inbox', value: String(surv.peer_inbox?.count ?? 0), hint: `crisis=${surv.peer_inbox?.crisis_count ?? 0} · ingest=${surv.peer_shortfall_ingest_total ?? 0}`, color: 'text-violet-300' },
        );
      }
      return rows;
    },

    get filteredLaws() {
      const all = this.laws?.laws || [];
      if (this.lawsFilter === 'all') return all;
      return all.filter(l => l.kind === this.lawsFilter);
    },

    lawKindLabel(kind) {
      switch (kind) {
        case 'hard_axiom': return '硬公理';
        case 'life_law': return '生命规律';
        case 'evaluation': return '评估契约';
        default: return kind || '—';
      }
    },

    lawKindClass(kind) {
      switch (kind) {
        case 'hard_axiom': return 'bg-rose-500/15 text-rose-300 border-rose-500/30';
        case 'life_law': return 'bg-sky-500/15 text-sky-300 border-sky-500/30';
        case 'evaluation': return 'bg-lime-500/15 text-lime-300 border-lime-500/30';
        default: return 'bg-slate-500/15 text-slate-300 border-slate-500/30';
      }
    },

    async refreshLaws() {
      try {
        const r = await fetch('/api/laws');
        if (!r.ok) return;
        this.laws = await r.json();
      } catch (e) {
        // 静默
      }
    },

    async doAwaken() {
      this.awakenBusy = true;
      try {
        const r = await fetch('/api/awaken', { method: 'POST' });
        const d = await r.json().catch(() => ({}));
        if (!r.ok) {
          this.error = d.error || '觉醒失败: 需要成功的本机采样';
        }
        await this.refreshState();
        await this.refreshLaws();
      } catch (e) {
        this.error = String(e);
      } finally {
        this.awakenBusy = false;
      }
    },

    async refreshPeerInbox() {
      try {
        const r = await fetch('/api/peer-inbox');
        if (!r.ok) return;
        this.peerInbox = await r.json();
      } catch (e) {
        // 静默
      }
    },

    async pushHostProfile() {
      this.hostProfileBusy = true;
      try {
        const r = await fetch('/api/host-profile', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            battery_pct: Number(this.hostProfileForm.battery_pct),
            thermal_hot: !!this.hostProfileForm.thermal_hot,
            bg_restricted: !!this.hostProfileForm.bg_restricted,
          }),
        });
        const d = await r.json().catch(() => ({}));
        if (!r.ok) this.error = d.error || 'host-profile 推送失败';
        await this.refreshState();
      } catch (e) {
        this.error = String(e);
      } finally {
        this.hostProfileBusy = false;
      }
    },

    async sharePeerShortfall() {
      this.peerShareBusy = true;
      try {
        const r = await fetch('/api/peer-inbox/share', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            peer_id: this.peerShareForm.peer_id || 'demo-peer',
            host_crisis: !!this.peerShareForm.host_crisis,
            favored_dim: Number(this.peerShareForm.favored_dim) || 0,
            material: Number(this.peerShareForm.material) || 0.5,
            disk_hot: Number(this.peerShareForm.favored_dim) === 1,
            mem_hot: Number(this.peerShareForm.favored_dim) === 2,
            load_hot: false,
            world_starve: Number(this.peerShareForm.favored_dim) === 2,
            social_starve: Number(this.peerShareForm.favored_dim) === 3,
          }),
        });
        const d = await r.json().catch(() => ({}));
        if (!r.ok) this.error = d.error || 'peer-inbox share 失败';
        await this.refreshPeerInbox();
        await this.refreshState();
        await this.refreshTasks();
      } catch (e) {
        this.error = String(e);
      } finally {
        this.peerShareBusy = false;
      }
    },

    dimLabel(d) {
      if (d === 1 || d === '1') return 'M';
      if (d === 2 || d === '2') return 'R';
      if (d === 3 || d === '3') return 'N';
      return '?';
    },

    // SVG 折线图预计算 (避免 SVG 内 <template x-for> 触发 importNode 错误)
    get trendSeries() {
      const colors = { l1: '#06b6d4', l2: '#8b5cf6', l3: '#10b981', l4: '#f59e0b', l5: '#ef4444' };
      const max = Math.max(1, this.maxTrendValue);
      const out = [];
      for (const name of ['l1', 'l2', 'l3', 'l4', 'l5']) {
        const series = this.trendData?.[name] || [];
        if (series.length === 0) continue;
        const points = series.map((p, i) => {
          const x = 40 + (i * (750 / (series.length - 1 || 1)));
          const y = 180 - (p.count / max * 160);
          return `${x},${y}`;
        }).join(' ');
        out.push({ name, points, stroke: colors[name] || '#94a3b8' });
      }
      return out;
    },
    get proposeEPoints() {
      const hist = this.proposeHistory?.history || [];
      if (hist.length === 0) return '';
      return hist.map((p, i) => {
        const x = 40 + (i * (750 / Math.max(1, hist.length - 1)));
        const y = 200 - (p.e_after * 180);
        return `${x},${y}`;
      }).join(' ');
    },
    get proposeCoefLines() {
      const hist = this.proposeHistory?.history || [];
      if (hist.length === 0) return [];
      const defs = [
        { key: 'mu', color: '#ef4444' },
        { key: 'nu', color: '#f97316' },
        { key: 'sigma', color: '#06b6d4' },
        { key: 'lambda', color: '#facc15' },
      ];
      return defs.map((coef) => ({
        key: coef.key,
        color: coef.color,
        points: hist.map((p, i) => {
          const x = 40 + (i * (750 / Math.max(1, hist.length - 1)));
          const val = (p.coefs && p.coefs[coef.key] != null) ? p.coefs[coef.key] : 0;
          const y = 200 - (val / 0.8 * 180);
          return `${x},${y}`;
        }).join(' '),
      }));
    },
    get proposeHistoryDots() {
      const hist = this.proposeHistory?.history || [];
      return hist.map((p, i) => ({
        key: `p-${p.tick}-${i}`,
        cx: 40 + (i * (750 / Math.max(1, hist.length - 1))),
        cy: 200 - (p.e_after * 180),
        fill: p.e_delta > 0 ? '#10b981' : (p.e_delta < 0 ? '#f43f5e' : '#a855f7'),
      }));
    },
    // Alpine 无法在 SVG 内安全 x-for — 整图序列化为 HTML 字符串
    get trendChartHtml() {
      const grid = '<g stroke="#1e293b" stroke-width="0.5">'
        + '<line x1="40" y1="20" x2="790" y2="20"/>'
        + '<line x1="40" y1="60" x2="790" y2="60"/>'
        + '<line x1="40" y1="100" x2="790" y2="100"/>'
        + '<line x1="40" y1="140" x2="790" y2="140"/>'
        + '<line x1="40" y1="180" x2="790" y2="180"/>'
        + '</g>';
      const lines = this.trendSeries.map((line) =>
        `<polyline points="${line.points}" fill="none" stroke="${line.stroke}" stroke-width="2" stroke-linecap="round"/>`
      ).join('');
      const axis = '<g font-size="9" fill="#64748b" font-family="monospace">'
        + '<text x="40" y="198" text-anchor="middle">0</text>'
        + '<text x="227" y="198" text-anchor="middle">1k</text>'
        + '<text x="415" y="198" text-anchor="middle">2k</text>'
        + '<text x="602" y="198" text-anchor="middle">3k</text>'
        + '<text x="790" y="198" text-anchor="middle">4k</text>'
        + '</g>';
      return `<svg viewBox="0 0 800 200" preserveAspectRatio="none" class="w-full h-full">${grid}${lines}${axis}</svg>`;
    },
    get proposeChartHtml() {
      const grid = '<g stroke="#1e293b" stroke-width="0.5">'
        + '<line x1="40" y1="20" x2="790" y2="20"/>'
        + '<line x1="40" y1="65" x2="790" y2="65"/>'
        + '<line x1="40" y1="110" x2="790" y2="110"/>'
        + '<line x1="40" y1="155" x2="790" y2="155"/>'
        + '<line x1="40" y1="200" x2="790" y2="200"/>'
        + '</g>';
      const yAxis = '<g font-size="9" fill="#64748b" font-family="monospace">'
        + '<text x="35" y="22" text-anchor="end">1.0</text>'
        + '<text x="35" y="67" text-anchor="end">0.75</text>'
        + '<text x="35" y="112" text-anchor="end">0.5</text>'
        + '<text x="35" y="157" text-anchor="end">0.25</text>'
        + '<text x="35" y="202" text-anchor="end">0</text>'
        + '</g>';
      let body = grid + yAxis;
      const ePoints = this.proposeEPoints;
      if (ePoints) {
        body += `<polyline points="${ePoints}" fill="none" stroke="#a855f7" stroke-width="2.5" stroke-linecap="round"/>`;
      }
      for (const coef of this.proposeCoefLines) {
        body += `<polyline points="${coef.points}" fill="none" stroke="${coef.color}" stroke-width="1.5" stroke-dasharray="3,3" stroke-linecap="round" opacity="0.7"/>`;
      }
      for (const dot of this.proposeHistoryDots) {
        body += `<circle cx="${dot.cx}" cy="${dot.cy}" r="3" fill="${dot.fill}" stroke="#0f172a" stroke-width="1"/>`;
      }
      return `<svg viewBox="0 0 800 220" preserveAspectRatio="none" class="w-full h-full">${body}</svg>`;
    },

    // ===== 颜色 / 文本辅助 =====
    eColor() {
      if (!this.state) return 'text-ghw-dim';
      return this.state.E > 0.8 ? 'text-ghw-good'
           : this.state.E > 0.5 ? 'text-ghw-warm'
           : 'text-ghw-bad';
    },
    eHint() {
      if (!this.state) return '';
      return this.state.E > 0.8 ? '高 — 数字生命繁荣'
           : this.state.E > 0.5 ? '中 — 探索中'
           : '低 — 需要关注';
    },
    cpuColor() {
      if (!this.state) return 'text-ghw-text';
      const c = this.state.system.cpu_pct;
      return c > 80 ? 'text-ghw-bad' : c > 50 ? 'text-ghw-warm' : 'text-ghw-good';
    },
    loadColor() {
      if (!this.state) return 'text-ghw-text';
      const l = this.state.system.load_1m;
      return l > 8 ? 'text-ghw-bad' : l > 4 ? 'text-ghw-warm' : 'text-ghw-good';
    },
    valueTrendColor(trend) {
      if (trend == null) return 'text-ghw-dim';
      if (trend < -0.003) return 'text-ghw-bad';
      if (trend > 0.003) return 'text-ghw-good';
      return 'text-ghw-warm';
    },
    valueTrendHint(trend) {
      if (trend == null) return '缓冲未满';
      if (trend < -0.003) return '人类价值下滑 → 加速补救';
      if (trend > 0.003) return '人类价值上升';
      return '平稳';
    },
    trustLevelColor(level) {
      if (level === 'high') return 'text-ghw-good';
      if (level === 'medium') return 'text-ghw-warm';
      if (level === 'low') return 'text-orange-400';
      return 'text-ghw-bad';
    },

    // ===== 自省/人格 辅助 =====
    moodColor() {
      if (!this.state || !this.state.personality) return 'text-ghw-dim';
      const m = this.state.personality.mood;
      if (m === 'thriving') return 'text-ghw-good';
      if (m === 'stable') return 'text-ghw-text';
      if (m === 'wandering') return 'text-ghw-warm';
      if (m === 'struggling') return 'text-ghw-bad';
      if (m === 'dormant') return 'text-slate-500';
      return 'text-ghw-dim';
    },
    moodCN() {
      if (!this.state || !this.state.personality) return '—';
      const m = this.state.personality.mood;
      return {
        thriving: '繁荣 thriving',
        stable: '稳定 stable',
        wandering: '漫游 wandering',
        struggling: '挣扎 struggling',
        dormant: '沉睡 dormant',
      }[m] || m;
    },
    beliefBadgeClass(source) {
      if (source === 'nature') return 'bg-amber-500/20 text-amber-300';
      if (source === 'representation') return 'bg-fuchsia-500/20 text-fuchsia-300';
      if (source === 'material') return 'bg-blue-500/20 text-blue-300';
      return 'bg-slate-500/20 text-ghw-dim';
    },
    taskSourceLabel(source) {
      const m = {
        chat_forced: '@task',
        chat_heuristic: 'chat',
        llm_proposer: 'llm',
        balance: 'balance',
        human: 'human',
        world_sensor: 'world',
        survival_remedy: 'remedy',
        survival_act: 'act',
        metabolism: 'meta',
        world_fetch: 'fetch',
        peer_symbiosis: 'peer',
        unknown: '—',
      };
      return m[source] || source || '—';
    },
    taskSourceClass(source) {
      if (source === 'chat_forced') return 'bg-amber-500/20 text-amber-300 border-amber-500/30';
      if (source === 'chat_heuristic') return 'bg-cyan-500/20 text-cyan-300 border-cyan-500/30';
      if (source === 'llm_proposer') return 'bg-fuchsia-500/20 text-fuchsia-300 border-fuchsia-500/30';
      if (source === 'balance') return 'bg-emerald-500/20 text-emerald-300 border-emerald-500/30';
      if (source === 'human') return 'bg-violet-500/20 text-violet-300 border-violet-500/30';
      if (source === 'world_sensor') return 'bg-orange-500/20 text-orange-300 border-orange-500/30';
      if (source === 'survival_remedy') return 'bg-rose-500/20 text-rose-300 border-rose-500/30';
      if (source === 'survival_act') return 'bg-red-500/20 text-red-300 border-red-500/30';
      if (source === 'metabolism') return 'bg-lime-500/20 text-lime-300 border-lime-500/30';
      if (source === 'world_fetch') return 'bg-teal-500/20 text-teal-300 border-teal-500/30';
      if (source === 'peer_symbiosis') return 'bg-sky-500/20 text-sky-300 border-sky-500/30';
      return 'bg-slate-700 text-ghw-dim border-slate-600';
    },
    taskSourceFilters() {
      return [
        { id: 'all', label: '全部' },
        { id: 'chat_forced', label: '@task' },
        { id: 'chat_heuristic', label: 'chat' },
        { id: 'human', label: 'human' },
        { id: 'llm_proposer', label: 'llm' },
        { id: 'balance', label: 'balance' },
        { id: 'world_sensor', label: 'world' },
        { id: 'survival_remedy', label: 'remedy' },
        { id: 'survival_act', label: 'act' },
        { id: 'metabolism', label: 'meta' },
        { id: 'world_fetch', label: 'fetch' },
        { id: 'peer_symbiosis', label: 'peer' },
        { id: 'unknown', label: '—' },
      ];
    },
    filteredTasks() {
      const list = this.tasks.tasks || [];
      if (this.taskSourceFilter === 'all') return list;
      return list.filter((t) => (t.source || 'unknown') === this.taskSourceFilter);
    },
    taskSourceCount(sourceId) {
      const list = this.tasks.tasks || [];
      if (sourceId === 'all') return list.length;
      return list.filter((t) => (t.source || 'unknown') === sourceId).length;
    },
    evolutionLevelRows() {
      const ea = this.state?.provenance?.evolution_acceptance;
      if (!ea) return [];
      return [
        { key: 'L1', count: ea.l1 ?? 0, approved: null },
        { key: 'L2', count: ea.l2 ?? 0, approved: null },
        { key: 'L3', count: ea.l3 ?? 0, approved: ea.l3_approved ?? 0 },
        { key: 'L4', count: ea.l4 ?? 0, approved: ea.l4_approved ?? 0 },
        { key: 'L5', count: ea.l5 ?? 0, approved: null },
      ];
    },
    steadyGateRows() {
      const st = this.state?.provenance?.evolution_acceptance?.steady;
      if (!st) return [];
      return [
        { key: 'mrn', label: 'M/R/N 平衡', ok: !!st.mrn_balanced },
        { key: 'value', label: '价值趋势', ok: !!st.value_ok },
        { key: 'e', label: 'E≥0.55', ok: !!st.e_ok },
      ];
    },
    taskDimensionRows() {
      const bd = this.tasks?.by_dimension;
      if (!bd) return [];
      const mk = (key, color, b) => ({
        key,
        color,
        pending: b?.pending ?? 0,
        completed: b?.completed ?? 0,
        survival: b?.survival ?? 0,
        evolution_linked: b?.evolution_linked ?? 0,
      });
      return [
        mk('M · material', 'text-blue-400', bd.material),
        mk('R · representation', 'text-fuchsia-400', bd.representation),
        mk('N · nature', 'text-amber-400', bd.nature),
        mk('all', 'text-slate-300', bd.all),
      ];
    },
    goalDimensionClass(dim) {
      if (dim === 'nature') return 'bg-amber-500/20 text-amber-300';
      if (dim === 'representation') return 'bg-fuchsia-500/20 text-fuchsia-300';
      if (dim === 'material') return 'bg-blue-500/20 text-blue-300';
      return 'bg-slate-500/20 text-ghw-dim';
    },
    urgencyColor(u) {
      if (u >= 0.8) return 'text-ghw-bad';
      if (u >= 0.6) return 'text-ghw-warm';
      if (u >= 0.4) return 'text-ghw-text';
      return 'text-ghw-dim';
    },
    async manualPropose() {
      try {
        const r = await fetch('/api/propose');
        if (!r.ok) throw new Error('propose failed');
        await this.refreshState();
      } catch (e) {
        this.error = String(e);
      }
    },
    async manualReflect() {
      try {
        const r = await fetch('/api/reflect');
        if (!r.ok) throw new Error('reflect failed');
        await this.refreshState();
      } catch (e) {
        this.error = String(e);
      }
    },
    async searchMemory() {
      try {
        const q = encodeURIComponent(this.memoryQuery);
        const r = await fetch('/api/memory/search?q=' + q);
        if (!r.ok) throw new Error('search failed: ' + r.status);
        this.memoryResults = await r.json();
      } catch (e) {
        this.error = String(e);
      }
    },
    async refreshTasks() {
      try {
        const r = await fetch('/api/tasks');
        if (!r.ok) return;
        this.tasks = await r.json();
      } catch (e) {
        // 静默
      }
    },
    async submitTaskFeedback(taskId, score) {
      if (this.taskFeedbackBusy) return;
      this.taskFeedbackBusy = true;
      try {
        const body = `task_id=${taskId}&score=${score}`;
        const r = await fetch('/api/task/feedback', { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body });
        if (!r.ok) throw new Error('feedback failed: ' + r.status);
        await this.refreshTasks();
        await this.refreshState();
      } catch (e) {
        this.error = String(e);
      } finally {
        this.taskFeedbackBusy = false;
      }
    },
    async submitHumanTask() {
      if (this.taskSubmitBusy || !this.newTask.title) return;
      this.taskSubmitBusy = true;
      try {
        const params = new URLSearchParams({
          title: this.newTask.title,
          description: this.newTask.description || this.newTask.title,
          required_dimension: this.newTask.dimension || 'all',
          from_human: 'human',
          priority: '8',
        });
        const r = await fetch('/api/tasks', {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: params.toString(),
        });
        if (!r.ok) throw new Error('submit task failed: ' + r.status);
        this.newTask = { title: '', description: '', dimension: 'all' };
        await this.refreshTasks();
        await this.refreshState();
      } catch (e) {
        this.error = String(e);
      } finally {
        this.taskSubmitBusy = false;
      }
    },
    async refreshActions() {
      try {
        const r = await fetch('/api/action/list');
        if (!r.ok) return;
        const data = await r.json();
        this.actions = data.actions || [];
      } catch (e) {
        // 静默
      }
    },
    async runActionNow() {
      if (this.actionRunning) return;
      this.actionRunning = true;
      try {
        const r = await fetch('/api/action/run-now', { method: 'POST' });
        if (!r.ok) throw new Error('run-now failed: ' + r.status);
        await this.refreshState();
        await this.refreshActions();
      } catch (e) {
        this.error = String(e);
      } finally {
        this.actionRunning = false;
      }
    },
    async refreshPeers() {
      try {
        const r = await fetch('/api/peers');
        if (!r.ok) return;
        const data = await r.json();
        this.peers = data;
        // 同步到 peer dashboard (capabilities tab 用)
        this.peerDashboard = data;
      } catch (e) {
        // 静默
      }
    },
    async refreshCapabilities() {
      try {
        const r = await fetch('/api/capabilities');
        if (!r.ok) return;
        this.capabilities = await r.json();
        // 同步刷 L1-L5 趋势 + propose history + 9 宫 deep + 9 宫 history
        await this.refreshTrend();
        await this.refreshProposeHistory();
        await this.refreshNinePalacesHistory();
        // 9 宫 deep 数据 (从 capabilities.nine_palaces_deep 拿)
        if (this.capabilities.nine_palaces_deep) {
          this.ninePalaces = this.capabilities.nine_palaces_deep;
        }
      } catch (e) {
        // 静默
      }
    },
    async refreshTrend() {
      try {
        const r = await fetch('/api/l1l5_trend');
        if (!r.ok) return;
        const data = await r.json();
        this.trendData = {
          l1: data.l1 || [],
          l2: data.l2 || [],
          l3: data.l3 || [],
          l4: data.l4 || [],
          l5: data.l5 || [],
        };
        // max for Y scale
        let m = 1;
        for (const k of ['l1','l2','l3','l4','l5']) {
          const arr = this.trendData[k];
          if (arr && arr.length > 0 && arr[arr.length-1].count > m) m = arr[arr.length-1].count;
        }
        this.maxTrendValue = m;
      } catch (e) {
        // 静默
      }
    },
    async refreshProposeHistory() {
      try {
        const r = await fetch('/api/propose_history');
        if (!r.ok) return;
        this.proposeHistory = await r.json();
      } catch (e) {
        // 静默
      }
    },
    async refreshNinePalacesHistory() {
      try {
        const r = await fetch('/api/nine_palaces_history');
        if (!r.ok) return;
        this.ninePalacesHistory = await r.json();
      } catch (e) {
        // 静默
      }
    },
    async refreshEvolved() {
      try {
        const r = await fetch('/api/evolved');
        if (!r.ok) return;
        const data = await r.json();
        this.evolvedFiles = data.files || [];
      } catch (e) {
        // 静默
      }
    },
    async loadEvolvedFile(name) {
      try {
        const r = await fetch('/api/evolved/' + encodeURIComponent(name));
        if (!r.ok) {
          this.evolvedContent = '// load failed: ' + r.status;
          return;
        }
        this.evolvedContent = await r.text();
        this.evolvedSelected = name;
      } catch (e) {
        this.evolvedContent = '// error: ' + String(e);
      }
    },
    async queryPeer(path, method) {
      try {
        const r = await fetch('/api/peer/query?path=' + encodeURIComponent(path) + '&method=' + method, { method: 'POST' });
        if (!r.ok) throw new Error('query failed: ' + r.status);
        const data = await r.json();
        this.lastPeerResult = JSON.stringify(data, null, 2);
        await this.refreshPeers();
      } catch (e) {
        this.lastPeerResult = 'ERROR: ' + String(e);
      }
    },
    async addPeer(path) {
      if (!path) return;
      await this.queryPeer(path, 'ping');
      this.newPeerPath = '';
    },

    // ===== 数字格式化 =====
    formatNum(n) {
      if (n == null) return '—';
      if (n < 1000) return String(n);
      if (n < 1_000_000) return (n / 1000).toFixed(1) + 'K';
      if (n < 1_000_000_000) return (n / 1_000_000).toFixed(2) + 'M';
      return (n / 1_000_000_000).toFixed(2) + 'B';
    },
    formatTime(ts) {
      if (!ts) return '—';
      const d = new Date(ts * 1000);
      const pad = n => String(n).padStart(2, '0');
      return `${pad(d.getMonth()+1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
    },

    // ===== 初始化 =====
    async init() {
      await this.refreshState();
      await this.refreshLog();
      await this.refreshActions();
      await this.refreshTasks();
      await this.refreshPeers();
      await this.refreshPeerInbox();
      await this.refreshCapabilities();
      await this.refreshEvolved();
      await this.refreshLaws();
      // 轮询
      this._pollTimer = setInterval(async () => {
        await this.refreshState();
        if (this.tab === 'log') await this.refreshLog();
        if (this.tab === 'actions') await this.refreshActions();
        if (this.tab === 'tasks') await this.refreshTasks();
        if (this.tab === 'capabilities') await this.refreshCapabilities();
        if (this.tab === 'evolved') await this.refreshEvolved();
        // status tab 显示同伴 — 每次轮询都更新 (轻量)
        await this.refreshPeers();
        if (this.tab === 'status') await this.refreshPeerInbox();
      }, 3000);
      // 跨 tab 事件: 聊天发送后立即刷新 E (HTMX after-request 触发)
      window.addEventListener('ghw:refresh-state', () => this.refreshState());
    },

    async refreshState() {
      try {
        const r = await fetch('/api/state');
        if (!r.ok) throw new Error('state fetch failed: ' + r.status);
        this.state = await r.json();
        const p = (this.state && this.state.provenance) || {};
        this.saveBlockedHtml = (p.state_contract && p.state_contract.save_blocked)
          ? '<div class="text-sm font-semibold text-rose-200">state 保存已暂停</div><div class="text-xs text-ghw-dim mt-1">磁盘 state 由 <span class="font-mono text-rose-300">' + (p.state_contract.writer || '?') + '</span> 写入 (epoch=' + (p.state_contract.epoch ?? 0) + ')。请勿与 daemon 共用同一 state 文件同时写入；请只保留一个 writer 或分开路径。</div>'
          : '';
        this.ruleProposeLine = p.rule_propose
          ? '规则提议: ' + (p.rule_propose.enabled ? 'on' : 'off') + ' · total=' + (p.rule_propose.total ?? 0) + ' · rules=' + (p.rule_propose.adopted_rules ?? 0)
          : '规则提议: off';
        this.chatInfoLine = p.chat
          ? '最近回复 memory=' + (p.chat.last_memory_injected ? 'on' : 'off') + ' · 往事=' + (p.chat.episode_count ?? 0) + ' · 信念=' + (p.chat.belief_count ?? 0) + ' · 累计 memory 回复=' + (p.chat.replies_with_memory ?? 0)
          : '';
        this.error = null;
      } catch (e) {
        this.error = String(e);
      }
    },

    async refreshLog() {
      try {
        const r = await fetch('/api/log');
        if (!r.ok) return;
        const data = await r.json();
        this.log = data.entries || [];
      } catch (e) {
        // 静默
      }
    },
  };
}

// 供 x-data="ghwApp()" 与 index.html alpine:init 双路径使用
window.ghwApp = ghwApp;

/// phaseProgress() — 9 阶段进度条数据 + milestones 列表
/// Alpine.data 形式注册, 9 个 milestone 跟 capabilities.phase.milestones 对位
function phaseProgress() {
  return {
    milestones: [
      { key: 'basic', phase: 1, name: '基础自我', desc: '有 Episode + 反思 + 行动', reached: false },
      { key: 'peer', phase: 2, name: '多体互联', desc: 'peer link ≥ 1 (需要 ghw-link)', reached: false },
      { key: 'llm', phase: 3, name: 'LLM 提议', desc: 'LLM 接进 Reflection + GoalProposer', reached: false },
      { key: 'l3_approved', phase: 4, name: '自演化', desc: 'L1-L5 真落盘 + 编译通过', reached: false },
      { key: 'enhance', phase: 5, name: '自我完善', desc: 'TemplateEnhancer 跑通 (LLM 完善模板)', reached: false },
      { key: 'six_interfaces', phase: 6, name: '六气', desc: '人/系统/文档/多体/时间/自然 6 接口', reached: false },
      { key: 'seven_reflection', phase: 7, name: '七步反思', desc: '觉察→差异→目标→评估→执行→学习→超越', reached: false },
      { key: 'eight_relations', phase: 8, name: '八种关系', desc: 'GoalGraph ≥ 3 种不同关系 (parent_child/sibling/conflict/depends_on/replaces/enables/inhibits/emerges_from)', reached: false },
      { key: 'nine_palaces', phase: 9, name: '九宫', desc: 'E 方差 < 0.01 持续 64 cycle (M/R/N 平衡)', reached: false },
    ],
    // 8 关系详情 (从 /api/goals/relations 拉)
    relations: [],
    relationsSummary: '',
    relationsDistinct: 0,
    topoOrder: [],
    async refreshRelations() {
      try {
        const r = await fetch('/api/goals/relations');
        if (!r.ok) return;
        const d = await r.json();
        this.relations = d.goals || [];
        this.relationsSummary = d.summary || '';
        this.relationsDistinct = d.distinct || 0;
        this.topoOrder = d.topo || [];
      } catch (e) {
        // 静默
      }
    },
    // 每次 capabilities 变化时同步 milestones
    syncFromCapabilities() {
      const pms = this.$root?.capabilities?.phase?.milestones;
      if (!pms) return;
      for (const m of this.milestones) {
        m.reached = pms[m.key] === true;
      }
    },
    init() {
      // 启动时同步一次, 之后每次 capabilities 更新 (Alpine reactive)
      this.syncFromCapabilities();
      this.refreshRelations();
      // 监听 capabilities 变化
      this.$watch?.(() => JSON.stringify(this.$root?.capabilities?.phase), () => {
        this.syncFromCapabilities();
      });
      // 每 10s refresh relations (8 关系变化慢)
      setInterval(() => this.refreshRelations(), 10000);
    },
  };
}

window.phaseProgress = phaseProgress;
