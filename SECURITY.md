# Security policy

## Reporting a vulnerability

Please do not open a public issue for suspected vulnerabilities or accidental
secret exposure. Email `support@hawkeye-xb.com` with:

- the affected component and revision;
- reproduction steps or a proof of concept;
- the expected impact;
- any suggested mitigation.

We will acknowledge a report as soon as practical and coordinate disclosure
after a fix is available. Do not access other users' data or disrupt a deployed
service while testing.

## Supported code

Security fixes target the latest revision of `main`. Self-hosters are responsible
for provider configuration, Cloudflare resources, secrets, access policies, and
timely deployment of updates.

## Deployment baseline

- Keep all API keys in Cloudflare secrets.
- Set an explicit `ALLOWED_ORIGINS` allowlist.
- Remove `ADMIN_SETUP_SECRET` after creating the initial administrator.
- Creem is the default payment provider. Paddle may be enabled only with its
  API token, catalog price and webhook secret configured; Polar remains disabled
  until signature verification lands.
- Do not enable content-level logging for audio, transcripts, prompts, selected
  text, OAuth callbacks, or tokens.
