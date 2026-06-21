import { defineConfig } from 'vitepress'

export default defineConfig({
  lang: 'zh-CN',
  title: 'GHW',
  description: 'Goal-Harness-World digital life framework and product runtime',
  cleanUrls: true,
  lastUpdated: true,
  themeConfig: {
    siteTitle: 'GHW',
    nav: [
      { text: '指南', link: '/guide/' },
      { text: '产品底座', link: '/product-runtime/' },
      { text: 'API', link: '/api/http' },
      { text: '运维', link: '/operations/' },
      { text: 'GitHub', link: 'https://github.com/Knot3-Labs/ghw' }
    ],
    sidebar: [
      {
        text: '开始',
        items: [
          { text: '项目概览', link: '/' },
          { text: '快速开始', link: '/guide/' },
          { text: '核心概念', link: '/guide/concepts' },
          { text: '架构总览', link: '/guide/architecture' }
        ]
      },
      {
        text: '产品数字生命底座',
        items: [
          { text: '能力总览', link: '/product-runtime/' },
          { text: 'ProductIntent', link: '/product-runtime/product-intent' },
          { text: 'KPI 与 E', link: '/product-runtime/kpi' },
          { text: '变更、审批与审计', link: '/product-runtime/change-loop' },
          { text: 'CRM 场景', link: '/product-runtime/crm-case' }
        ]
      },
      {
        text: '接口',
        items: [
          { text: 'HTTP API', link: '/api/http' },
          { text: 'C SDK', link: '/api/sdk' },
          { text: '状态持久化', link: '/api/state' }
        ]
      },
      {
        text: '交付',
        items: [
          { text: '部署与运行', link: '/operations/' },
          { text: '安全边界', link: '/operations/security' },
          { text: '路线图', link: '/roadmap' }
        ]
      }
    ],
    search: {
      provider: 'local'
    },
    footer: {
      message: 'LLM is fuel, not the brain.',
      copyright: 'MIT Licensed'
    }
  }
})
