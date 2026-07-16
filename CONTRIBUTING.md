# Contributing

Thanks for helping improve Xisper.

## Development setup

1. Install Node.js 18 or newer and enable Corepack.
2. Run `pnpm install --frozen-lockfile`.
3. Copy only the example configuration files you need and replace placeholders.
4. Run `pnpm build` before opening a pull request. If you touch a package with a
   type-check script, run that package's check and report any baseline failures.

The native client requires macOS, Xcode, and XcodeGen. Never commit signing
identities, notarization credentials, real Cloudflare IDs, or provider keys.

## Pull requests

- Keep changes focused and explain user-visible behavior.
- Include tests for security boundaries and pure logic when practical.
- Treat audio, transcripts, selected text, window titles, OAuth callbacks, and
  tokens as sensitive. They must not appear in logs or fixtures.
- Keep hosted-service-specific operations behind interfaces so the public build
  remains independently buildable.

## Private/public synchronization

The public repository is not a mirror of the hosted product. Shared fixes may be
cherry-picked between repositories after review. Never force-push one repository
over the other or copy production configuration into this repository.
