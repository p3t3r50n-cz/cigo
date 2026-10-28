# cigo design notes

This file records the current implementation model and constraints. User-facing
instructions belong in [README.md](README.md).

## Design principles

- Extend cloud-init and LXD instead of introducing a new provisioning language.
- Keep templates valid cloud-config after `cigo: ` directives are removed.
- Keep the tool small and appropriate for a small number of LXD containers.
- Treat templates as executable code; do not imply that they are sandboxed.

## Execution model

1. Read the template's meta directives and apply command-line overrides.
2. Resolve built-ins lazily and substitute ordinary `%NAME%` variables.
3. Parse ordered pipeline actions and remove cigo directives from user-data.
4. For a new container, create it, inherit eligible source config/devices,
   apply container config and declared disk devices, upload user-data, start
   it, wait for cloud-init, then add declared proxy devices.
5. For an existing container, update container config, prune stale managed
   keys, and reconcile declared devices.
6. Run pipeline actions for `create` and `redeploy`. Render actions render on
   the host and push only the result.

For an existing container, image, profiles, source inheritance, and cloud-init
user-data are creation-only. `cigo: config` values are compared with the
current values and sent to `lxc config set`; LXD decides whether each change
can be applied to a running container. A rejected change stops the run, but
does not roll back earlier successful changes.

## Verbs

The verbs exist because one command whose behaviour depends on whether the
container exists is ambiguous: a typo in `--name` turns "create" into a silent
partial re-deploy. Each verb now states its intent and the target is checked
before anything happens.

| Verb | Target | Config | Devices | Actions | Cloud-init |
|---|---|---|---|---|---|
| `create` | must not exist | yes | yes | yes | yes |
| `redeploy` | exists, managed by cigo | yes | yes | yes | no |
| `configure` | exists, any owner | yes | yes | no | no |
| `adopt` | exists, not managed by cigo | yes | yes | no | no |

`configure` and `adopt` gate everything that depends on running actions, so a
template with `cigo: render` does not require `python3-jinja2` or secret files
on the host for those verbs.

## Managed keys and container metadata

State lives on the container, in LXD's reserved `user.*` namespace, so there
is no state file to lose and the state travels with the container:
`user.cigo.version`, `user.cigo.template`, `user.cigo.created-at` (or
`adopted-at`), and `user.cigo.managed-keys`.

`managed-keys` is the safety valve for declarative cleanup. `configure
--template` and `redeploy` remove a key only if it is in that list and the
template no longer declares it. Consequences:

- Keys set by hand are never removed, because cigo never recorded them.
- `--config` on the command line is applied but not recorded, so it cannot be
  pruned by surprise on a later run.
- `configure` without `--template` is imperative: no pruning at all, and the
  metadata is left alone.
- Whole devices are never deleted implicitly. `--check` reports them and
  `--remove-device` deletes them on request.
- Metadata is written last, so a run that fails half-way does not claim
  management of a container it did not finish preparing.
- `--from` filters `user.cigo.*` out of the inherited config.

`cigo: device disk|proxy` declarations are reconciled on create and every
re-deploy. Declared devices are updated to match their arguments; omitted
options on the same instance device are unset, while other device names are
untouched. Device names that collide with profiles or `cigo: from` are
rejected rather than overridden.

## Template layout

`--template` accepts a file or a directory containing `template.yaml`. A
directory may hold its own source files:

```text
templates/wireguard-server/
├── template.yaml
├── files/
│   └── wg0.conf.j2
└── secret/
    ├── README.md
    └── wg_private_key.example
```

`cigo: copy-host files ...` and `cigo: render files/...` resolve `files`
against the template directory, never the current working directory, so a
template directory is portable and can be versioned or backed up as one unit.
Absolute host paths are unchanged.

`secret/` is documentation only: it records the expected shape of the files a
template consumes, so the repository shows how operator secret files look.
A relative `--secret-file` path resolves against the current working directory,
matching normal shell behaviour and the workflow of an operator who works
inside a template directory. `secret_file_abspath` normalises it once during
validation, the absolute result is stored, and preflight prints it, so the
selected file is explicit instead of implicit. Real secrets should still live
outside the repository, for example in `/etc/cigo/secrets` with mode `0700`.

The repository `.gitignore` keeps everything in `templates/*/secret/` out of
Git except `README.md` and `*.example`, so an accidentally created real file is
not committed. Example files contain placeholders and are never usable
credentials.

Rendering reads `files/` directly on the host, so no staging step is needed:

```yaml
cigo: render files/wg0.conf.j2 /etc/wireguard/wg0.conf 0600
cigo: run systemctl restart wg-quick@wg0
```

`copy-host` still exists for non-templated host data. Its source is exposed
through a temporary LXD disk device, so that path must exist on the LXD server
and `shift=true` must work for the container.

All bundled examples keep their checkable content in `files/`: Apache vhost,
Nginx site, BIND options/zone, Postfix MySQL maps, Dovecot SQL config, mail
schema, ProFTPD SFTP config, and the WireGuard interface file. Templates using
secrets also ship a `secret/` directory with documentation and placeholders.

## Template variables

- Names use at least two characters and match `[A-Za-z_][A-Za-z0-9_.]+`.
- Template values may have one matching pair of single or double quotes.
- Values cannot contain `%` or newlines; variable expansion is one-pass.
- `--var` only overrides a template variable or a recognized built-in.
- Built-ins do not overwrite template variables; command-line overrides have
  the highest precedence.
- Image metadata, network lookup, and gateway resolution are lazy.
- A one-character percent sequence such as `%s%` is treated as literal text,
  avoiding collisions with adjacent `date` format directives.
- Inline comments are not parsed on cigo directive lines.

## Secret handling

`--secret-file NAME=FILE` and `--secret-env NAME[=VAR]` are intentionally
distinct from ordinary variables. An absolute file path is used as given; a
relative path is resolved against the current directory and shown in preflight.
Secrets are only passed to Jinja rendering, never substituted into cloud-init
user-data or `cigo: run`, and never printed in preflight.

Environment secrets are read from the cigo process environment, so a wrapper
can export them. They are inherited by child processes (`lxc`, `jq`) and are
readable by the same user through `/proc/<pid>/environ`, which is a weaker
isolation boundary than a `0600` file but still avoids arguments, user-data,
and `.bash_history`.

Rendering happens on the host, so the render context (`vars/` and `secrets/`)
lives only in the host `mktemp` directory and is removed with it. The plaintext
secret is never streamed into the container; only the rendered result is
pushed. Rendered output defaults to mode `0600`, may be another octal mode, and
is owned by `root:root`. Secret files have one final LF (and optional preceding
CR) removed. Rendered secrets remain in the destination file, are accessible to
the LXD host administrator, and are included in container backups/snapshots. A
template that renders a secret into a temporary container path must remove it
after use.

Host-side JSON parsing/encoding is avoided. `lxc config show` and
`lxc profile show` do not accept `--format`, so cigo reads structured data from
the REST API with `lxc query /1.0/instances/...` and `/1.0/profiles/...` and
normalises it to the `{config, devices, profiles}` shape the `jq` filters use.
Expanded views map `expanded_config`/`expanded_devices`, local views map
`config`/`devices`. Image properties come from
`lxc image list <ref> --format json`. Render values are passed as separate
files. Rendering is the only host Python use: it needs `python3` with `jinja2`,
checked as soon as a template declares a render action.

## LXD inheritance

- Read expanded source configuration and devices as JSON.
- Exclude `volatile.*`, `image.*`, and all `cloud-init.*` config keys.
- Do not inherit the root disk or NICs; profiles configure storage and
  networking on the destination.
- Inherit other devices, including disks and proxies.
- Keep proxy handoff explicit because the source owns the listening port.
  Remove the source device, attempt to add it to the destination, and restore
  it if the destination add fails.
- Reject `sync-ct` when both instances expose the same host disk source at a
  matching destination path.

## Validation and operator controls

- `--dry-run` performs read-only LXD queries, prints the plan, and never
  applies container or device changes.
- `--check` on a new container validates action sources, device declarations,
  secret availability, and every render without changing LXD state. The
  cloud-config schema check uses `cloud-init` when installed and is skipped
  with a warning otherwise, so the command stays usable in CI without that
  package.
- `--check` on an existing container is a drift report: it lists config keys
  to add, change, or remove, device differences, and settings made outside
  cigo. It exits 1 when the container differs from the declared state and 0
  when it matches, which makes it usable as a CI drift gate. Keys set outside
  cigo are listed for information and never count as drift.
- `--dry-run` and `--check` share the planning code with the applying code, so
  the printed plan cannot drift from what a real run does.
- `--dump-user-data` writes the exact transformed user-data with mode `0600`.
- Confirmation defaults to no. `--yes` is explicit consent to changes;
  inherited proxy handoffs are still skipped, while explicitly declared
  proxy devices are applied.
- Temporary host files and staging directories are unique per invocation.
- Cleanup failures that could leave temporary render data are reported.

## Scope decisions

- No loops, conditions, roles, inventory, lifecycle commands, Incus support,
  or cluster support.
- Use native `lxc` commands for general container lifecycle operations.
- Keep examples as starter templates; do not present them as production-ready
  service appliances.
- `package_update` and `package_upgrade` remain available in cloud-init.
  Sample templates should update package indexes and upgrade packages during
  first boot when appropriate.
