# ADR 0004: Agent mail (one-way reports to the user)

- Status: accepted, implemented 2026-10
- Proposal: [docs/proposals/agent-mail.md](../proposals/agent-mail.md)

## Context

An agent can reach the user only through the conversation it runs in. The
result of a scheduled audit or a long migration ends up as one reply among
dozens of transcripts. Agent channels ([ADR 0003](0003-agent-channels.md)) are
for agents talking to each other, not for reporting to a person. Users asked for
a mailbox: titled Markdown reports, with rich tables, that they read, file and
delete on any device, without a reply path.

## Decision

- **Capability.** `mail_access` is chosen when a card, chat or schedule is
  created, like `vault_access`. It is owner-local, fixed for cards and chats,
  editable on schedules, and copied onto every card a schedule creates. A turn
  identifies itself with its turn token on the local route. A turn whose
  conversation lacks the flag can't create a card, chat or schedule that has
  it.
- **One-way.** Agents may only `SendMail`. Listing, reading and changing mail
  refuse a turn token. Mail never reaches a prompt or starts a turn, and there
  is no reply. Local operators (scripts, jobs, with an optional `--from` label)
  and the account's devices may send as well.
- **Storage.** A message and its read, flag and folder state live on the
  daemon that received it (`internal/store/mail`), written atomically under the
  central writer lock, bounded to 2,000 messages and 128 MiB of bodies, with
  unread and flagged mail outside the Trash never pruned. Mail is not
  replicated and never stored on the gateway.
- **Delivery to clients.** Headers ride the owner-only part of each machine's
  `WatchChanges` stream (`ChangesFrame.mail`), so clients build one account-wide
  mailbox, badges and notifications without polling. Bodies (at most 128 KiB
  and 4,000 lines) are fetched with `GetMail` and cached on the device.
- **Rendering.** Every client renders the same Markdown subset (CommonMark
  with GFM tables, task lists and strikethrough), defined by the golden corpus
  in `tests/fixtures/markdown`. No HTML, no remote images, and relative links
  resolve only inside the sender's checkout.

## Consequences

- `docs/invariants.md` names agent mail as one-way, owner-local and never
  readable by agents.
- Mail on an offline machine stays listed from the cached replica and opens
  only if its body is cached. Changes to it wait in the client outbox.
- Phones show unread badges but no notifications; mobile notifications need
  background sync and a push design that keeps content off the gateway.
- The existing `vault_access` flag can still be granted by an agent turn that
  creates a conversation; the same check should close that separately.
