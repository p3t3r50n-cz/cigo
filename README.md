# cigo — a minimal cloud-init wrapper for LXD

The name combines **CI** (continuous integration) and **GO**. The idea is
simple: run cigo, then get on with your work.

cigo is a small Bash wrapper around `cloud-init` and `lxc`. It is intended for
small labs and infrastructures with a handful to a few dozen single-purpose
containers. It does not replace Ansible or Terraform and deliberately has no
loops, conditions, roles, or inventory.

The template remains a normal cloud-config file. cigo adds only what is
missing for this use case: container settings before first boot, ordered
post-boot actions, repeatable re-deploys, simple data transfer, and safe
transfer of render-only secrets.

cigo has four verbs, one per intent:

| Verb | Target | Applies |
|---|---|---|
| `create` | a container that must not exist | config, devices, cloud-init, actions |
| `redeploy` | an existing cigo-managed container | config, devices, actions |
| `configure` | any existing container | config and devices only |
| `adopt` | an existing container cigo did not create | config and devices, then marks it managed |

The verb never guesses: `create` refuses to touch an existing container and
`redeploy` refuses to take over a foreign one.

## Requirements

On the host:

- Bash
- LXD client (`lxc`)
- `jq` (used to read LXD's JSON from `lxc query`)
- Python 3 with Jinja2 (`python3-jinja2`) for `cigo: render`; `configure` and
  `adopt` never render, so they do not need it
- `cloud-init` is optional. When it is installed, `--check` and `--dry-run`
  also validate the rendered cloud-config schema; when it is missing, that
  single check is skipped with a warning

In the container:

- an image with cloud-init (official Ubuntu images include it)
- `rsync` and `tar` for copy/sync actions

Rendering runs on the host and only the result is pushed into the container, so
no container needs Python or Jinja2.

## Quick start

```bash
./cigo.sh create --name web-01 --template templates/lamp
```

For automation:

```bash
./cigo.sh create --name web-01 --template templates/lamp --yes
```

Later, to push template changes into the running container:

```bash
./cigo.sh redeploy --name web-01 --template templates/lamp          # config + actions
./cigo.sh configure --name web-01 --template templates/lamp         # config only
./cigo.sh configure --name web-01 --config limits.memory=4GiB       # one-off key
```

To take over a container that already exists:

```bash
./cigo.sh adopt --name old-web --template templates/lamp
```

Confirmations show their default (`[Y/n]`), so pressing Enter accepts. `--yes`
skips them entirely, which is what scripts should use. Proxy devices inherited from a source container
are always skipped in this mode because they can conflict with the source.

## Bootstrap and pipeline

| Layer | Contents | When it runs |
|---|---|---|
| **Bootstrap** | The remaining cloud-config (`packages`, `write_files`, `bootcmd`, etc.) | First boot only |
| **Pipeline** | `cigo: ...` actions | On every cigo invocation |

Cloud-init does not run again after creation. Put repeatable package
installation, file transfer, rendering, and commands in the cigo pipeline.
Use cloud-config for first-boot setup that genuinely belongs to bootstrap.

An existing container is only ever touched by the verb that names it:

- `redeploy` applies `cigo: config` values, reconciles declared devices, and
  runs pipeline actions.
- `configure` applies `cigo: config` values and declared devices only. It
  never runs actions and never touches cloud-init, which makes it fast and
  safe on a running container.
- `adopt` does what `configure` does and then records that cigo manages the
  container.

LXD decides whether a changed key or device property can be updated while the
container is running; if it rejects a change, cigo stops with an explicit
error. Earlier changes in the same run may already have applied.

## Container metadata and managed keys

cigo stores a little state on the container itself, in LXD's reserved `user.*`
namespace. No state file is created on the host.

```console
$ lxc config show web-01 | grep user.cigo
  user.cigo.created-at: 2026-10-28T13:29:48Z
  user.cigo.managed-keys: limits.cpu,limits.memory
  user.cigo.template: lamp
  user.cigo.version: 0.2.1
```

`user.cigo.managed-keys` lists the config keys cigo has written. It is what
makes declarative cleanup safe:

- `configure --template` and `redeploy` remove a key only when cigo wrote it
  earlier and the template no longer declares it. Keys you set by hand are
  never pruned.
- `--config` on the command line is a one-off override. It is applied but
  never recorded as managed, so a later run cannot silently delete it.
- `configure` without `--template` is imperative: it applies exactly the
  given `--config`, `--unset`, and `--remove-device` values, prunes nothing,
  and leaves the metadata untouched.
- Whole devices are never removed implicitly. A device the template no longer
  declares is reported by `--check` and removed only with
  `--remove-device NAME`.

`--from` never inherits `user.cigo.*`, so a new container cannot inherit
another container's identity.

## Template format

`--template` accepts either a YAML file or a directory containing
`template.yaml`. A directory can also ship its own source files, which keeps
each template self-contained and easy to back up:

```text
templates/wireguard-server/
├── template.yaml
└── files/
    └── wg0.conf.j2
```

```yaml
# template.yaml
cigo: packages wireguard
cigo: render files/wg0.conf.j2 /etc/wireguard/wg0.conf 0600
cigo: run systemctl restart wg-quick@wg0
```

A relative `copy-host`/`sync-host`/`render` source resolves against the
directory that contains `template.yaml`, so
`--template templates/wireguard-server` works the same from every current
directory. Absolute sources are used as given.

The `.j2` file is read on every run, so editing it is applied by a re-deploy
instead of being frozen at first boot. Keep first-boot-only content in
cloud-config, and put anything that a re-deploy must refresh into the pipeline.
Either layout is supported (`files/` is optional), but every bundled example
uses a directory.

A template starts with `#cloud-config`. cigo directives must begin at column
one, with no YAML indentation or comment marker:

```yaml
#cloud-config
cigo: image ubuntu:24.04
cigo: profile default
cigo: config limits.memory=2GiB
cigo: device disk web-data source=/srv/www path=/var/www shift=true
cigo: device proxy web-http listen=tcp:0.0.0.0:8080 connect=tcp:127.0.0.1:80
cigo: packages apache2
cigo: run systemctl enable --now apache2

package_update: true
package_upgrade: true
```

Before cloud-init receives the file, cigo removes unindented `cigo: ` lines.
The rest must be valid cloud-config. Comment out a directive to disable it:

```yaml
# cigo: run systemctl restart apache2
```

Indented directives are rejected. Directives are single lines and do not
support inline comments; put comments on their own lines.

### Directives

| Directive | Meaning |
|---|---|
| `cigo: image IMAGE` | Image used for `lxc init`; default is `ubuntu:24.04` |
| `cigo: profile PROFILE` | LXD profile; may be repeated |
| `cigo: config KEY=VALUE` | Container config applied before first boot and attempted during re-deploy |
| `cigo: device disk NAME KEY=VALUE...` | Declare an LXD host disk bind mount |
| `cigo: device proxy NAME KEY=VALUE...` | Declare an LXD proxy port/socket device |
| `cigo: var NAME=VALUE` | Template variable, substituted on the host |
| `cigo: from CONTAINER` | Inherit eligible config and non-network devices when creating a new container |
| `cigo: packages PKG...` | Install missing packages as a pipeline action |
| `cigo: copy-host SOURCE DEST` | Copy host files into the container without deleting destination files |
| `cigo: sync-host SOURCE DEST` | Sync a host directory; delete destination files absent from source |
| `cigo: copy-ct CONTAINER PATH` | Copy a path from another container |
| `cigo: sync-ct CONTAINER PATH` | Sync a directory from another container |
| `cigo: render HOST_FILE CONTAINER_PATH [MODE]` | Render Jinja2 on the host and push the result; default mode is `0600` |
| `cigo: run COMMAND` | Run a command in the container using `sh -c` |
| `cigo: timeout SECONDS` | Cloud-init wait timeout; default is 900 seconds |
| `cigo: log MODE` | `journal`, `cloud-init`, `output`, `both`, or `none` |

Meta directives (`image`, `profile`, `config`, `device`, `var`, `from`,
`timeout`, and `log`) are read before actions. Pipeline actions run in
declaration order after cloud-init completes:

```yaml
cigo: run ipsec start
cigo: copy-host /srv/app /srv/app
cigo: run systemctl restart apache2
```

Commands in `cigo: run` are not made idempotent automatically. The template
author is responsible for making repeated execution safe.

### LXD disk and proxy devices

Declare instance devices directly in the template:

```yaml
# Bind mount a directory from the LXD host into the container.
cigo: device disk web-data source=/srv/www/example path=/var/www/example shift=true

# Forward a host TCP port to a service in this container.
cigo: device proxy web-http listen=tcp:0.0.0.0:8080 connect=tcp:127.0.0.1:80
```

The syntax passes `KEY=VALUE` options to LXD's native device commands. Disk
`source` and container `path` must be absolute; the source path is resolved on
the LXD host, not necessarily the machine running the client. Paths and option
values containing spaces are not supported. Add LXD-supported options such as
`readonly=true` to disk devices as needed.

On create, disk devices are added before the first start; proxy devices are
added after cloud-init completes. On every `redeploy` and `configure`, cigo
ensures each declared device exists and updates its options to match the
template. Options on that same instance device which are omitted from the
declaration are removed. Whole devices are left alone: dropping a device from
a template never deletes it, `--check` reports it, and `--remove-device NAME`
deletes it on request. Use unique names: cigo refuses to manage devices
defined by an LXD profile or also inherited through `cigo: from`.

Proxy listen conflicts are errors; cigo will not silently change a declared
port or remove another device to free it. LXD may reject a device change that
cannot be applied to a running container. Earlier device changes in the same
run are not rolled back. `--check` and `--dry-run` show and validate the
declarations without applying them; LXD still performs final validation when
a device is added or updated.

## Command-line options

```text
cigo.sh create    --name NAME --template FILE.yaml [options]
cigo.sh redeploy  --name NAME --template FILE.yaml [options]
cigo.sh configure --name NAME [--template FILE.yaml] [options]
cigo.sh adopt     --name NAME --template FILE.yaml [options]
```

```text
--name NAME
--template FILE|DIR      required except for configure
--image IMAGE            create only
--from CONTAINER         create only
--profile PROFILE        create only; repeatable, replaces all template profiles
--config KEY=VALUE       repeatable; merges by key and overrides the template
--unset KEY              configure, redeploy; repeatable
--remove-device NAME     configure, redeploy; repeatable
--var NAME=VALUE         repeatable; overrides a variable already in the template
--secret-file NAME=FILE  repeatable; secret is available only to render
--secret-env NAME[=VAR]  repeatable; secret is read from the environment
--timeout SECONDS        create only
--log MODE               create only
--dry-run
--check
--dump-user-data FILE    create only
-y, --yes
-V, --version
```

Command-line options override matching template directives. `--config` merges
by key; `--profile` replaces the complete profile list. Options that cannot
mean anything for a verb are rejected rather than ignored.

`--dry-run` prints the plan without changing LXD state. For `create` it also
exercises every render and, when the host has `cloud-init`, validates the
rendered user-data schema. For an existing container it prints the same diff
as `--check` and exits 0.

`--check` changes nothing. For `create` it validates everything it can: action
inputs, device declarations, secret availability, and every render, so an
undefined variable or a broken template fails here. For an existing container
it is a drift report:

```console
$ ./cigo.sh configure --name web-01 --template templates/lamp --check
=== Config ===
  ~ limits.memory: 256MiB -> 192MiB
=== Devices ===
  = device web-http listen=tcp:0.0.0.0:8080
=== Not managed by cigo ===
  ? boot.autostart = true  (set outside cigo)
Drift detected: web-01 differs from the declared state.
$ echo $?
1
```

Exit codes: `0` when nothing would change, `1` when the container differs or
a validation fails, `2` for a usage error. Keys set outside cigo are listed
for information and never count as drift.

The cloud-config schema check needs the `cloud-init` command on the host. When
it is missing, only that check is skipped and reported as a warning; `--check`
still exercises everything else and exits successfully.

`--dump-user-data FILE` writes the transformed cloud-config, after variable
substitution and directive removal, with file mode `0600`. It can be combined
with either validation option.

## Variables and secrets

Ordinary variables use `%NAME%` syntax and are substituted on the host before
user-data is uploaded. Names must contain at least two characters and may
contain letters, digits, underscores, and dots. One-character percent
sequences (such as `%s%` inside `date +%s%N`) are left untouched. Values may
not contain `%` or newlines. Matching surrounding single or double quotes on
`cigo: var` values are removed. A missing multi-character variable is an
error.

```yaml
cigo: var PHP_VERSION=8.4
cigo: packages php%PHP_VERSION%-cli
```

`--var` can override a variable defined by the template or a built-in; it
cannot silently introduce a misspelled new variable. Built-ins include:

| Variable | Value |
|---|---|
| `%cigo.name%` | Container name |
| `%cigo.image%` | Selected image |
| `%cigo.image_version%` | Image version |
| `%cigo.image_codename%` | Image release codename |
| `%cigo.image_os%` | Image operating system |
| `%cigo.arch%` | Image architecture |
| `%cigo.host%` | Hostname of the machine running cigo |
| `%cigo.gateway%` | IPv4 gateway for the selected LXD network |
| `%cigo.template%` | Template path |
| `%cigo.date%` | Invocation timestamp (`YYYYMMDDhhmmss`) |

Image details and network gateway are looked up only when needed. Image
metadata may require a remote query.

### Secrets

Do not put passwords, private keys, or other secrets in `cigo: var`, `--var`,
`cigo: config`, `cigo: run`, or cloud-init user-data. Those values may appear
in preflight output, shell history, LXD configuration, or cloud-init logs.

Secrets are instead supplied through `--secret-file` (read from a protected
host file) or `--secret-env` (read from an environment variable). Both are
available only in the Jinja render context as `secrets` and are never
substituted into user-data or command arguments. Preflight shows only the
secret name and its source, never the value.

```bash
install -d -m 700 /etc/cigo/secrets
(umask 077; ssh-keygen -q -t ed25519 -N '' \
  -f /etc/cigo/secrets/sftp_host_ed25519_key)

./cigo.sh create --name sftp-01 --template templates/proftpd-sftp \
  --secret-file SFTP_HOST_PRIVATE_KEY=/etc/cigo/secrets/sftp_host_ed25519_key

# NAME reads the variable of the same name; NAME=VAR maps to another name.
 DB_PASSWORD=mojeHeslo ./cigo.sh create --name mail-01 \
  --template templates/postfix-dovecot-mysql --secret-env DB_PASSWORD

WG_PRIVATE_KEY=$(wg genkey) ./cigo.sh create --name vpn-01 \
  --template templates/wireguard-server --secret-env WG_PRIVATE_KEY
```

A relative `--secret-file` path follows normal shell semantics: it resolves
against the current working directory, so working inside a template directory
behaves as expected. cigo prints the resolved absolute path in preflight, so
the selected file is never implicit:

```text
Secret files (values are not displayed; render-only):
  DB_PASSWORD  (file: /etc/cigo/secrets/db_password)
```

Prefer keeping real secret files outside the repository, for example under
`/etc/cigo/secrets` with mode `0700`.

The bundled WireGuard, ProFTPD, and mail templates ship a `secret/` directory
as a **pattern only** - it documents the expected shape of each file and
contains placeholders:

```text
templates/wireguard-server/secret/
├── README.md                 pattern documentation
└── wg_private_key.example    placeholder, not a usable key
```

Never commit key material. The repository `.gitignore` keeps everything in
those directories out of Git except `README.md` and `*.example`.

```jinja2
database_password = "{{ secrets.DB_PASSWORD }}"
```

The value is copied into a private host-only render directory that is removed
when cigo exits; the plaintext secret never enters the container. Only the
rendered result is pushed, owned by `root:root`, and the destination mode
defaults to `0600`:

```yaml
cigo: render files/config.ini.j2 /srv/app/config.ini 0640
cigo: run chown root:www-data /srv/app/config.ini
```

One final LF (and a preceding CR) is removed from each secret file, making
files created by common command-line tools usable without adding a newline to
the rendered value. Embedded newlines are preserved. An environment value is
used verbatim; a trailing newline therefore belongs to the value, so strip it
in the shell when needed (`DB_PASSWORD=$(<./db-password)`).

`--secret-env` is convenient for wrappers and CI, and a leading space keeps
the command out of `.bash_history`. Its weakness is that an environment
variable is inherited by every child process cigo starts (`lxc`, `jq`) and is
readable by the same user through `/proc/<pid>/environ`. It is broadly
equivalent to a `0600` file for a local operator, but it is more exposed than
`--secret-file` on a shared or multi-user host. Prefer `--secret-file` there.

Choose the output mode and ownership deliberately. A rendered secret remains
accessible to the LXD host administrator and is included in container
backups/snapshots. Neither option is a secret store or an isolation boundary.

The environment is read when the plan is validated and again when render
context is written, so a missing variable fails the run before LXD changes
anything.

## Inheriting from a container

`cigo: from SOURCE` is for creating a replacement container, for example when
migrating to a newer OS. It copies eligible configuration and devices, but
not the source OS or its cloud-init configuration.

- Config keys beginning with `volatile.`, `image.`, or `cloud-init.` are
  excluded.
- The `root` device and network devices are not copied; the new container gets
  storage and networking from its own profiles.
- Other devices, including disk bind mounts and proxy devices, are considered
  for inheritance.
- A setting defined by the new template or `--config` overrides the source.
- Inherited proxy devices are handled after the new container starts because the source
  may still own the listening port. Choose a handoff, a different port, skip,
  or quit. A failed handoff attempts to restore the device on the source.
- `--yes` skips inherited proxy devices and prints manual commands.

Explicitly declared devices can be reapplied without the source container
being available; only a new `create --from` needs it.

## Copy and sync semantics

| Action | Direction | Behavior |
|---|---|---|
| `copy-host` | Host → container | `rsync -a`, no deletion |
| `sync-host` | Host → container | `rsync -a --delete` |
| `copy-ct` | Container → container | Copy without deletion |
| `sync-ct` | Container → container | Sync with deletion |

Host paths are mounted temporarily as disk devices with `shift=true`; the
device is removed after the action, including on failure. A relative source is
resolved against the template directory. The host path must exist on the
machine that runs the LXD server, which matters when the `lxc` client talks to
a remote LXD. Container-to-container transfers use a unique temporary staging
directory in the target. Paths containing spaces are not supported. `sync-*`
requires a directory and an existing source. `sync-ct` refuses a destination
path mounted from the same host disk source in both containers to avoid
syncing a directory onto itself.

Copy into a temporary location, render from it, and remove it when the source
must stay fresh across re-deploys. Cleanup only runs if the earlier actions
succeed, so prefer a path under `/run` in the container, which is cleared on
reboot, and keep secrets out of the copied files.

## Rendering Jinja2 templates

`cigo: render HOST_FILE CONTAINER_PATH [MODE]` renders **on the host** and
pushes only the result into the container. The source is a host file (a
relative path resolves against the template directory), the destination is an
absolute path inside the container, and the mode defaults to `0600`. Missing
parent directories are created. The destination is replaced through a sibling
temporary file, so a failed transfer cannot leave a half-written file, and the
pushed file is owned by `root:root`.

Rendering on the host means no container needs Python or Jinja2, the plaintext
secret never enters the container, and a bad template fails before LXD state
changes. The host needs `python3-jinja2`; cigo checks it as soon as the
template declares a render action, and `--check`/`--dry-run` perform the render
without pushing anything.

Ordinary variables are available as `{{ PHP_VERSION }}`. Built-ins with
dotted names are also available with underscores (for example
`{{ cigo_gateway }}`), and the complete ordinary-variable map is available as
`{{ vars['cigo.gateway'] }}`. Render-only secrets are available in
`{{ secrets['DB_PASSWORD'] }}` or `{{ secrets.DB_PASSWORD }}`. Missing values
are errors (`StrictUndefined`).

Files rendered from the template directory are re-read on every run. Content
baked into cloud-config `write_files` is different: that runs only on first
boot, and host-substituted `%VAR%` text inside it is replaced once and then
frozen. Keep first-boot-only files there and everything else in `files/`.
Actions that re-render a configuration must also reload or restart the affected
service (`systemctl restart`, `reload-or-restart`, or a reload) so a re-deploy
actually applies the new file.

## Packages and logs

`cigo: packages` checks each package with `dpkg -s` and installs only missing
packages. If anything is missing, it runs `apt-get update` and installs the
missing set. Package removal and upgrades are not implied by this action.

Cloud-init logs stream while cigo waits. The default is the system journal;
choose `cloud-init`, `output`, `both`, or `none` to change the source.

## Example templates

The `templates/` directory contains example configurations. Every example uses
the template-directory layout (`template.yaml` plus optional `files/`), so run
them by directory name:

```bash
./cigo.sh create --name web-01 --template templates/apache-hosting
```

- `lamp/` — Apache, PHP, and MySQL for a small LAMP deployment.
- `mysql-server/` — a standalone MySQL server.
- `apache-hosting/` — Apache virtual-host hosting; the vhost is rendered from
  `files/vhost.conf.j2`.
- `nginx-proxy/` — an Nginx reverse proxy; the site file is rendered from
  `files/site.conf.j2`.
- `proftpd-sftp/` — ProFTPD SFTP with local Linux accounts.
- `postfix-dovecot-mysql/` — Postfix and Dovecot with MySQL-backed virtual
  mailboxes; the schema, SQL maps, and Dovecot SQL config live in `files/`.
- `wireguard-server/` — a WireGuard endpoint; host networking and firewall
  integration are operator tasks.
- `bind-dns/` — an authoritative BIND DNS server; `files/` holds the options,
  zone declaration, and zone data.
- `php-hosting-apache/` — PHP 8.2 hosting: Apache with mod_php, common
  extensions and Postfix for local mail.
- `lamp-p80-u22/` — LAMP on Ubuntu 22.04 with PHP 8.0, used as the source in
  the migration example below.
- `lamp-p84-u24/` — migrates the previous container to Ubuntu 24.04 with
  `cigo: from lamp-p80-u22`, so create `lamp-p80-u22` first if you want to run
  this example end to end. Its first `cigo: run` steps assume the source
  container exists.

Because configuration lives in `files/`, these values can change on a
re-deploy instead of being frozen at first boot: `--var SITE_DOMAIN=shop.test`,
`--var UPSTREAM_URL=http://backend.lxd:8080`, `--var DNS_ZONE=lab.test` with
`--var DNS_IP=...`, `--var WG_PORT=5181`, or `--var SFTP_PORT=2222`. The
pipeline re-copies, re-renders, and reloads or restarts the affected service.

These are starter examples, not hardened, production-ready appliances. Public
mail, DNS, VPN, and file-transfer services need environment-specific DNS,
firewall, TLS, abuse controls, monitoring, backups, and operating procedures.
Before using the ProFTPD or WireGuard examples, provide the required private
key with `--secret-file` or `--secret-env`; each of those templates has a
`secret/README.md` describing the expected file. The mail example requires a
`DB_PASSWORD` secret (use a hex-only value, for example from
`openssl rand -hex 32`), then creates the `mailreader` MySQL account and
starter schema. Add virtual-domain/mailbox records and domain-specific DNS
records before use. Its starter intentionally does not enable authenticated
SMTP submission; add and test that only after configuring trusted TLS
certificates.

Generate suitable secret files without printing their contents, preferably
outside the repository:

```bash
install -d -m 700 /etc/cigo/secrets
(umask 077; ssh-keygen -q -t ed25519 -N '' \
  -f /etc/cigo/secrets/sftp_host_ed25519_key)
(umask 077; wg genkey > /etc/cigo/secrets/wg_private_key)
(umask 077; openssl rand -hex 32 > /etc/cigo/secrets/db_password)
```

Pass them by name:
`SFTP_HOST_PRIVATE_KEY=/etc/cigo/secrets/sftp_host_ed25519_key`,
`WG_PRIVATE_KEY=/etc/cigo/secrets/wg_private_key`, or
`DB_PASSWORD=/etc/cigo/secrets/db_password`. A relative path also works and
resolves against the current directory.

## Trust and security

A cigo template is executable infrastructure code. Cloud-init commands run as
root in the container; `cigo: run` executes shell commands; `copy-host` can
expose host paths through LXD devices; and LXD administrators have broad host
control. Templates are not sandboxed or cryptographically signed. Use only
templates you wrote or reviewed, and inspect them before running them.

Secrets passed with `--secret-file` or `--secret-env` are not a substitute for
protecting the host, LXD daemon, target container, rendered files, and backups.

## Testing

The integration suite runs against a real LXD server. It is plain Bash with no
extra dependencies, because cigo itself needs nothing beyond bash, `lxc`, `jq`
and `python3-jinja2`:

```bash
./tests/run.sh                 # every case
./tests/run.sh 03 05           # only cases whose filename matches
CIGO_IT_KEEP=1 ./tests/run.sh  # keep containers and print their names
CIGO_IT_IMAGE=... ./tests/run.sh
```

Containers are named with a unique prefix and deleted by the runner, including
when a case fails, so existing containers are never touched. The suite covers:

| Case | What it guards |
|---|---|
| `01-dry-run` | the plan is printed, renders are executed, nothing is created |
| `02-check` | valid templates pass; a broken render fails before any change |
| `03-create-and-render` | rendered files reach the container with the right content, mode and owner |
| `04-redeploy` | config and rendered files are updated in place |
| `05-secrets` | file and environment secrets render, stay out of the output, and produce `0600` files |
| `06-devices` | declared devices are created, mounted and reconciled; the gateway built-in resolves |
| `07-from` | config and devices are inherited, and the template override wins |
| `08-errors` | invalid input fails with a clear message and creates nothing |
| `09-templates` | every bundled template parses and renders against real LXD |
| `10-verbs` | `create`/`redeploy`/`configure` refuse the wrong target; `adopt` stamps metadata; create-only options are rejected |
| `11-configure` | `configure` skips actions, prunes only keys cigo wrote, keeps manual keys, and removes devices only on request |
| `12-drift` | `--check` exits 1 on drift and 0 when clean; `--dry-run` prints the same plan and changes nothing |

Cases marked in the table only exercise the fast path (fixtures that install no
packages), so the whole suite finishes in about four minutes. Deploying the real
service templates — which install Apache, BIND or Postfix — is a separate,
slower tier that is not part of the default run yet.

## Scope and limitations

- Cloud-init runs only on first boot; bootstrap is not replayed on re-deploy.
- There is no checkpoint or automatic rollback. A failed create can leave an
  incomplete container; inspect it or delete it explicitly with LXD.
- `cigo: run` idempotency is the template author's responsibility.
- cigo does not create snapshots automatically.
- cigo manages config keys it wrote itself; it never removes settings that were
  made by hand.
- cigo is designed for small LXD environments, not as a replacement for
  Ansible, Terraform, Incus, or a full configuration-management system.

## License

cigo is distributed under the GNU General Public License, version 3. See
[LICENSE](LICENSE).

## Author

Petr Palacký — <http://palacky.net>
