# Open-source boundary

Xisper's public repository is an independently buildable product, not a source
dump or a byte-for-byte mirror of the official hosted service.

## Public components

- macOS voice-input client;
- hotkey and native context integrations;
- ASR and LLM provider abstractions;
- self-hostable Cloudflare Workers;
- local history, prompt templates, and vocabulary features;
- landing and administration UI needed by self-hosters.

## Hosted-only concerns

Production credentials, signing material, customer operations, private rollout
configuration, incident data, and provider commercial terms are not published.

## Synchronizing fixes

1. Make each shared feature or fix a focused commit.
2. Review the diff for credentials, infrastructure identifiers, internal URLs,
   customer data, and hosted-only behavior.
3. Cherry-pick or re-implement the approved commit in the destination repository.
4. Run that repository's full CI before merging.

Do not merge or force-push the full public tree over a private checkout. The two
repositories intentionally have different product boundaries.
