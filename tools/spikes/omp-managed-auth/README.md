# OMP on managed accounts: spike drivers

Offline probes for [docs/proposals/omp-managed-accounts.md](../../../docs/proposals/omp-managed-accounts.md).
They run the pinned Oh My Pi in a throwaway home with fake tokens against a
loopback stand-in for the Anthropic and ChatGPT Codex backends. No real
credential is used, and the logs keep only token fingerprints.

- `probe.sh`: main and advisor roles on two injected credentials (print and ACP
  mode), overlay precedence, role pinning, advisor effort.
- `refresh-probe.sh`: credentials only from `models.yml` `apiKey: "!command"`;
  an expired first token per provider must be replaced after a 401.
- `resume-probe.sh`: L5, a stored session resumed with constant launch args
  onto another provider (overlay vs. ACP `model`/`thinking` options).
- `fake-upstream.mjs`, `acp-probe.mjs`, `token-helper.sh`: the pieces both use.
- `live/`: real-account checks L1–L4. `account-token.mjs` is the live stand-in
  for `dieter provider token --turn` (reads this machine's Claude Code Keychain
  item or Codex `auth.json`, asks the provider's own tool to refresh, prints
  only the access token); `live-turn.sh` runs one OMP ACP turn on it;
  `expire-claude-login.mjs` ages a throwaway login (refuses anything outside
  `tmp/omp-managed-auth/`).
- `results/2026-11-27/`: summaries of the runs quoted in the proposal.

Setup and commands are in the proposal's Appendix A.
