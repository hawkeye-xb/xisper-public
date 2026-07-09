# Xisper

**English** · [简体中文](./README.zh-CN.md)

> Hold a key, speak, release — your words appear as text in whatever app you're using.

Xisper is a native macOS voice-to-text tool that lives in your menu bar. Press and hold a hotkey, talk, and let go; Xisper streams your speech to a speech-recognition engine, cleans it up with an LLM, and types the result straight into the app you're focused on — your editor, your email, your chat window, anywhere.

This repository is the **full source** of Xisper: the macOS client, the Cloudflare Workers backend, the landing page, and the admin panel.

## Why this exists

Dictation on the Mac has historically meant one of two things: the built-in tool that few people enjoy using, or subscription apps that are expensive and treat your voice as a black box. Xisper was built to be:

- **Fast** — real-time streaming transcription, text inserted the moment you release the key.
- **Affordable** — a pricing model that doesn't punish heavy users.
- **Context-aware** — AI post-processing fixes technical terms, names, and jargon; a translation mode lets you speak one language and type another.
- **Honest about privacy** — we transcribe and post-process; we don't hoard your audio or transcripts. The analytics in the client are behavioral counts only (opt-out available), never your text.

Open-sourcing it is an invitation: see exactly how a production voice-input product is wired end to end, learn from it, or run your own.

## Features

- **Push-to-talk dictation** into any macOS app via a global hotkey.
- **Real-time streaming ASR** with geo-based provider routing.
- **AI post-processing** — polish, hotword/terminology correction, and per-role context.
- **Translation mode** — speak in one language, insert in another.
- **Roles & hotwords** — teach Xisper your domain vocabulary (legal, medical, finance, code…).
- **Auto-updates** via Sparkle.
- **Usage/quota + subscription** billing.

## Architecture

Xisper is a pnpm + Turbo monorepo:

| Package | What it is | Stack |
|---------|-----------|-------|
| `apps/mac-desktop` | Native macOS client (menu-bar app) | Swift, XcodeGen, Sparkle |
| `apps/services` | Backend: auth, ASR proxy, payment | Cloudflare Workers, D1, KV, R2 |
| `apps/ai-worker` | LLM provider abstraction + fallback chain, metering/billing | Cloudflare Workers, D1 |
| `apps/landing` | Marketing / download site | Vue 3, Vite SSG → Cloudflare Pages |
| `apps/admin` | Internal admin panel | — |

External services: **Logto** (identity), **Creem** (payments), **Supabase** (auth/data), **Cloudflare** (Workers/D1/KV/R2/Pages).

## Getting started

Each backend package ships an example environment file — copy it and fill in your own credentials:

```bash
# backend workers — secrets
cp apps/services/.dev.vars.example   apps/services/.dev.vars
cp apps/ai-worker/.dev.vars.example  apps/ai-worker/.dev.vars

# backend workers — Cloudflare config (fill in your own resource IDs)
cp apps/services/wrangler.toml.example   apps/services/wrangler.toml
cp apps/ai-worker/wrangler.toml.example  apps/ai-worker/wrangler.toml

# macOS build machine
cp apps/mac-desktop/.env.build.example apps/mac-desktop/.env.build
```

The `wrangler.toml.example` files use placeholders like `<D1_DATABASE_ID_DEV>` — replace them with your own Cloudflare KV namespace IDs, D1 database IDs, domains, and Logto tenant. The real `wrangler.toml` is gitignored so your IDs never get committed. Never put API keys in `wrangler.toml`; use `wrangler secret put`.

```bash
pnpm install
pnpm dev            # run the workspace in dev
```

To build the macOS client, see `apps/mac-desktop/scripts/build-and-release.sh`.

## License

[MIT](./LICENSE) © 2026 Zhaowen Li ([hawkeye-xb](https://github.com/hawkeye-xb))
