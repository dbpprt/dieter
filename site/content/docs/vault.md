---
title: "Vault (passwords & TOTP)"
linkTitle: "Vault"
description: "Share logins and TOTP secrets between your machines end-to-end encrypted, and let chosen agent tasks use them."
group: "Workflows"
weight: 24
slug: "vault"
---

The vault stores accounts that you and your agents need for automation: a
name, optional URLs, a username, a password, a TOTP secret and notes. It is
shared by every machine of your account. Items replicate through the peer store
only as ciphertext, so the gateway never sees a password, name or URL.

## Create the vault and add machines

Run this once, on any daemon host:

```sh
dieter vault init
```

The command prints a **recovery key** once. Keep it offline. Dieter never stores
it, and it can unlock the vault on any of your machines.

On each additional machine, after peer sync has replicated the vault:

```sh
dieter vault join
```

The command prints a join code. On a machine that is already a member, check
that it shows the same code, then approve:

```sh
dieter vault status                       # lists pending members and their codes
dieter vault approve MEMBER_ID --code CODE
```

Each machine computes the code from its own view of the vault and the new
machine's key. If anything on the way substitutes a key, the codes do not
match. To join without another member online, use the recovery key:

```sh
dieter vault join --recovery-key-stdin < recovery.txt
```

`dieter vault remove-member MEMBER_ID` revokes a machine and rotates to a new
vault key it never receives. A removed machine keeps anything it already
decrypted, so change those passwords too, and unenroll a lost machine.
`dieter vault rotate --recovery-key` replaces the recovery key.

## Add and use items

The CLI never accepts a secret as a command-line argument. Read it from a file
or stdin, type it at a no-echo prompt, or let the daemon generate it:

```sh
printf '%s' "$PASSWORD" | dieter vault add --name GitHub \
  --url https://github.com/login --username me --password-file -
dieter vault add --name "Staging admin" --url https://staging.example.com --prompt
dieter vault add --name "New service" --username bot --generate --length 32
dieter vault edit GitHub --totp-file totp.txt       # otpauth:// URI or base32 secret
```

```sh
dieter vault list --url https://gist.github.com     # also matches subdomains
dieter vault totp GitHub                            # current code
dieter vault exec GitHub --env GH_USER=username --env GH_PASS=password -- ./login.sh
dieter vault get GitHub --field password --reveal   # prints the secret
```

`exec` runs the command without a shell, puts the fields into its environment
only, passes stdin, stdout and stderr through, and returns its exit status.
Prefer it over `get`, so secrets do not reach logs or transcripts.

## Let agents use the vault

Agents can use the vault only in conversations created with vault access. The
setting is chosen at creation and can't be changed later on that conversation:

```sh
dieter card create --project P --board B --title "Renew certificates" \
  --workspace worktree --vault
dieter chat create --project P --title "Check invoices" --workspace project --vault
dieter schedule create ... --vault        # every card it creates gets access
```

The native apps show the same option when you create a task, chat or schedule.
There are no interactive approvals. Every agent turn receives a short-lived
token that identifies its conversation. The token expires when the turn ends.
With vault access, the agent can list, read, add and edit items. It can't
change membership, keys or the audit log. Agents in other conversations are
denied.

When an agent reveals a password, Dieter redacts that value from the stored
transcript for the rest of the turn. The model provider still receives the
tool output, which is another reason to prefer `exec`.

`dieter vault audit` lists this machine's vault access: who asked, from which
conversation and route, for which item and fields, and whether it was allowed.
The audit log never contains secret values.

## Security notes

- Each machine holds a hybrid post-quantum member key (ML-KEM-768 with X25519)
  in `DIETER_HOME/vault/member.json`, readable only by your user. The vault keys
  are sealed to each member's key. Items are encrypted with AES-256-GCM and
  bound to the vault and item IDs.
- Vault commands that return decrypted content refuse the gateway relay route,
  because the gateway can read relayed payloads. Run them on a member machine,
  or use `--machine` over a direct TLS or WebRTC route.
- Agents run as your user without a sandbox. Vault access rules guard against
  accidental use and leave an audit trail, but an agent that reads your files
  directly can bypass them. Grant vault access only to work that needs it.
- Back up the recovery key, not `DIETER_HOME`. A copy of `DIETER_HOME` contains
  the member key and the encrypted vault.
