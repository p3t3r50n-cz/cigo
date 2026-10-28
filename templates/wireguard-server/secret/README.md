# Secret file pattern

This directory is a **documentation pattern**, not a storage location for real
key material. It shows the shape of the file cigo expects. The repository
`.gitignore` keeps everything here out of Git except `README.md` and
`*.example`, so a real file accidentally created here would not be committed -
but keep real secrets outside the repository anyway.

| Secret name | Example file | Generated with |
|---|---|---|
| `WG_PRIVATE_KEY` | `wg_private_key.example` | `wg genkey` |

Create the real file, preferably outside the repository:

```bash
install -d -m 700 /etc/cigo/secrets
(umask 077; wg genkey > /etc/cigo/secrets/wg_private_key)
```

Pass that absolute path:

```bash
./cigo.sh create --name example-01 --template templates/wireguard-server \
  --secret-file WG_PRIVATE_KEY=/etc/cigo/secrets/wg_private_key
```

Working from inside this template directory works too: a relative
`--secret-file` path resolves against the current directory. A file created
here is git-ignored.

```bash
cd /path/to/cigo/templates/wireguard-server
(umask 077; wg genkey > secret/wg_private_key)
/path/to/cigo/cigo.sh create --name example-01 --template . \
  --secret-file WG_PRIVATE_KEY=secret/wg_private_key
```

Preflight prints the resolved absolute path, so the selected file is always
visible instead of implicit.

Notes:

- cigo reads the file into the host-only render context as
  `{{ secrets.WG_PRIVATE_KEY }}`; it is never printed, never placed in cloud-init
  user-data, never passed as a command argument, and never copied into the
  container. Only the rendered file is pushed.
- One trailing newline (and a preceding CR) is stripped for file secrets, so
  `wg genkey > file` and `echo ... > file` both work.
- Prefer `--secret-env WG_PRIVATE_KEY` in wrappers and CI; see the main README
  for the trade-offs.
- `wg_private_key.example` is a placeholder and will not produce a working
  tunnel.
