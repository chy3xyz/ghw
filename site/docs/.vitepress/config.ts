import { defineConfig } from 'vitepress'

export default defineConfig({
  lang: 'en-US',
  title: 'GHW',
  description: 'Goal-Harness-World digital life framework and product runtime',
  cleanUrls: true,
  lastUpdated: true,
  themeConfig: {
    siteTitle: 'GHW',
    nav: [
      { text: 'Guide', link: '/guide/' },
      { text: 'Product Runtime', link: '/product-runtime/' },
      { text: 'API', link: '/api/http' },
      { text: 'Operations', link: '/operations/' },
      { text: 'GitHub', link: 'https://github.com/chy3xyz/ghw' }
    ],
    sidebar: [
      {
        text: 'Getting Started',
        items: [
          { text: 'Overview', link: '/' },
          { text: 'Quick Start', link: '/guide/' },
          { text: 'Core Concepts', link: '/guide/concepts' },
          { text: 'Architecture', link: '/guide/architecture' }
        ]
      },
      {
        text: 'Product Runtime',
        items: [
          { text: 'Capabilities', link: '/product-runtime/' },
          { text: 'ProductIntent', link: '/product-runtime/product-intent' },
          { text: 'KPI & E', link: '/product-runtime/kpi' },
          { text: 'Change, Approval & Audit', link: '/product-runtime/change-loop' },
          { text: 'CRM Case', link: '/product-runtime/crm-case' }
        ]
      },
      {
        text: 'API',
        items: [
          { text: 'HTTP API', link: '/api/http' },
          { text: 'C SDK', link: '/api/sdk' },
          { text: 'State Persistence', link: '/api/state' }
        ]
      },
      {
        text: 'Delivery',
        items: [
          { text: 'Deploy & Operate', link: '/operations/' },
          { text: 'Security Boundaries', link: '/operations/security' },
          { text: 'Roadmap', link: '/roadmap' }
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
