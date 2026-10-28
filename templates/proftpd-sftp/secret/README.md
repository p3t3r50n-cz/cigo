# Secret file pattern

This directory is a **documentation pattern**, not a storage location for real
key material. It shows the shape of the file cigo expects. The repository
`.gitignore` keeps everything here out of Git except `README.md` and
`*.example`, so a real file accidentally created here would not be committed -
but keep real secrets outside the repository anyway.

| Secret name | Example file | Generated with |
|---|---|---|
| `SFTP_HOST_PRIVATE_KEY` | `sftp_host_ed25519_key.example` | `ssh-keygen -q -t ed25519 -N ''` |

Create the real file, preferably outside the repository:

```bash
install -d -m 700 /etc/cigo/secrets
(umask 077; ssh-keygen -q -t ed25519 -N '' > /etc/cigo/secrets/sftp_host_ed25519_key)
```

Pass that absolute path:

```bash
./cigo.sh create --name example-01 --template templates/proftpd-sftp \
  --secret-file SFTP_HOST_PRIVATE_KEY=/etc/cigo/secrets/sftp_host_ed25519_key
```

Working from inside this template directory works too: a relative
`--secret-file` path resolves against the current directory. A file created
here is git-ignored.

```bash
cd /path/to/cigo/templates/proftpd-sftp
(umask 077; ssh-keygen -q -t ed25519 -N '' > secret/sftp_host_ed25519_key)
/path/to/cigo/cigo.sh create --name example-01 --template . \
  --secret-file SFTP_HOST_PRIVATE_KEY=secret/sftp_host_ed25519_key
```

Preflight prints the resolved absolute path, so the selected file is always
visible instead of implicit.

Notes:

- Only the private key goes here. Install the matching public key
  (`/etc/cigo/secrets/sftp_host_ed25519_key.pub`) on the clients that connect.
- `ssh-keygen` refuses to overwrite an existing key, which is useful: it will
  not silently replace a key that clients already trust.
- cigo reads the file into the host-only render context as
  `{{ secrets.SFTP_HOST_PRIVATE_KEY }}` and pushes only the rendered file, owned
  by `root:root` with mode `0600`. The plaintext never enters the container.
- One trailing newline (and a preceding CR) is stripped for file secrets.
- `sftp_host_ed25519_key.example` is a placeholder and is not a usable key.
