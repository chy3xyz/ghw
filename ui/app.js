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
    log: [],                // 最新 /api/log
    error: null,
    _pollTimer: null,

    // 记忆搜索 (sqlite)
    memoryQuery: '',
    memoryResults: null,

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
      return rows;
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
      await this.refreshCapabilities();
      await this.refreshEvolved();
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
      }, 1000);
      // 跨 tab 事件: 聊天发送后立即刷新 E (HTMX after-request 触发)
      window.addEventListener('ghw:refresh-state', () => this.refreshState());
    },

    async refreshState() {
      try {
        const r = await fetch('/api/state');
        if (!r.ok) throw new Error('state fetch failed: ' + r.status);
        this.state = await r.json();
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

// Alpine 启动后会调 ghwApp(), 但因为 script defer, 这里也直接注册到 window 即可
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
      const pms = window.ghwApp?.capabilities?.phase?.milestones;
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
      this.$watch?.(() => JSON.stringify(window.ghwApp?.capabilities?.phase), () => {
        this.syncFromCapabilities();
      });
      // 每 10s refresh relations (8 关系变化慢)
      setInterval(() => this.refreshRelations(), 10000);
    },
  };
}

window.phaseProgress = phaseProgress;
