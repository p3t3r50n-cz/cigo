# Secret file pattern

This directory is a **documentation pattern**, not a storage location for real
key material. It shows the shape of the file cigo expects. The repository
`.gitignore` keeps everything here out of Git except `README.md` and
`*.example`, so a real file accidentally created here would not be committed -
but keep real secrets outside the repository anyway.

| Secret name | Example file | Generated with |
|---|---|---|
| `DB_PASSWORD` | `db_password.example` | `openssl rand -hex 32` |

Create the real file, preferably outside the repository:

```bash
install -d -m 700 /etc/cigo/secrets
(umask 077; openssl rand -hex 32 > /etc/cigo/secrets/db_password)
```

Pass that absolute path:

```bash
./cigo.sh create --name example-01 --template templates/postfix-dovecot-mysql \
  --secret-file DB_PASSWORD=/etc/cigo/secrets/db_password
```

Working from inside this template directory works too: a relative
`--secret-file` path resolves against the current directory. A file created
here is git-ignored.

```bash
cd /path/to/cigo/templates/postfix-dovecot-mysql
(umask 077; openssl rand -hex 32 > secret/db_password)
/path/to/cigo/cigo.sh create --name example-01 --template . \
  --secret-file DB_PASSWORD=secret/db_password
```

Preflight prints the resolved absolute path, so the selected file is always
visible instead of implicit.

Notes:

- Use a hex-only value. It is interpolated into MySQL SQL and into Postfix and
  Dovecot configuration, so quotes, spaces, and `#` characters make the
  generated files harder to read and easier to break.
- The same secret is used in three places: the Postfix MySQL maps, the Dovecot
  SQL config, and the `mailreader` account creation. Rotating the file and
  re-running the template updates all of them.
- A rendered `mail-reader.sql` copy lives in `/run/cigo-mail-reader.sql` only
  for the duration of the run and is removed right after the database update.
- One trailing newline (and a preceding CR) is stripped for file secrets.
- `db_password.example` is a placeholder.
