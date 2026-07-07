# Lead Intelligence Pipeline — Web

Next.js (TypeScript) app for the Lead Intelligence Pipeline: the public intake form and, later, the internal reporting dashboard. Deployed on Vercel; talks to Supabase (source of truth) and the n8n-hosted universal webhook that drives enrichment, scoring, and CRM delivery. See the [repo root README/docs](../docs) for full pipeline architecture.

## Development

```bash
npm install
npm run dev
```

Open [http://localhost:3000](http://localhost:3000).

## Scripts

- `npm run dev` — local dev server
- `npm run build` — production build
- `npm run lint` — ESLint
- `npm run typecheck` — TypeScript, no emit
