#!/usr/bin/env bash
# configure changes live LXD state without running pipeline actions, prunes only
# keys cigo wrote earlier, and stays imperative when no template is given.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source ./lib.sh

name=$(ct_name configure)
register_ct "$name"

work=$(mktemp -d "${TMPDIR:-/tmp}/cigo-it-configure.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/tpl" "$work/one" "$work/two"
cp -r "$FIXTURES/basic/files" "$work/tpl/files"
printf 'from-one\n' > "$work/one/marker.txt"
printf 'from-two\n' > "$work/two/marker.txt"

# A template variant that declares one extra key and one device.
cat > "$work/tpl/template.yaml" <<'YAML'
#cloud-config
cigo: profile default
cigo: config limits.memory=192MiB
cigo: config boot.autostart=true
cigo: var GREETING=hello
cigo: var DATA_DIR=/tmp
cigo: device disk it-data source=%DATA_DIR% path=/mnt/it-data
cigo: render files/app.conf.j2 /etc/cigo-it/app.conf 0640
package_update: false
package_upgrade: false
YAML

cigo_create "$name" "$FIXTURES/basic" >/dev/null
assert_eq "hello" "$(ct_run "$name" "sed -n 's/^greeting = //p' /etc/cigo-it/app.conf")" \
    "initial render"

# configure changes only LXD state: the rendered file must keep its old value.
output=$(cigo_expect_ok "$CIGO" configure --name "$name" --template "$work/tpl" \
    --var "DATA_DIR=$work/one" --var GREETING=changed --yes)
assert_contains "$output" "Configuration applied" "configure reported"
assert_contains "$output" "does not run them" "configure notes skipped actions"
assert_eq "hello" "$(ct_run "$name" "sed -n 's/^greeting = //p' /etc/cigo-it/app.conf")" \
    "configure does not run render actions"
assert_eq "192MiB" "$(lxc config get "$name" limits.memory)" "configure applies config"
assert_eq "true" "$(lxc config get "$name" boot.autostart)" "configure applies new key"
assert_eq "boot.autostart,limits.memory" "$(lxc config get "$name" user.cigo.managed-keys)" \
    "managed keys grow"
assert_eq "$work/one" "$(lxc config device get "$name" it-data source)" "configure adds device"

# Declarative configure prunes a key cigo wrote that is no longer declared.
output=$(cigo_expect_ok "$CIGO" configure --name "$name" --template "$FIXTURES/basic" --yes)
assert_contains "$output" "Removed container config: boot.autostart" "stale managed key pruned"
assert_eq "" "$(lxc config get "$name" boot.autostart 2>/dev/null || true)" \
    "pruned key is gone"
assert_eq "limits.memory" "$(lxc config get "$name" user.cigo.managed-keys)" \
    "managed keys shrink"

# A key set outside cigo must survive both configure and redeploy.
lxc config set "$name" boot.autostart.priority 7
cigo_expect_ok "$CIGO" configure --name "$name" --template "$FIXTURES/basic" --yes >/dev/null
assert_eq "7" "$(lxc config get "$name" boot.autostart.priority)" "unmanaged key preserved"

# Imperative configure: exactly what was asked, managed-keys untouched.
cigo_expect_ok "$CIGO" configure --name "$name" --config limits.cpu=2 \
    --unset boot.autostart.priority --yes >/dev/null
assert_eq "2" "$(lxc config get "$name" limits.cpu)" "imperative --config applied"
assert_eq "" "$(lxc config get "$name" boot.autostart.priority 2>/dev/null || true)" \
    "imperative --unset applied"
assert_eq "limits.memory" "$(lxc config get "$name" user.cigo.managed-keys)" \
    "imperative configure leaves managed keys alone"

# Conflicts and empty invocations are refused before anything is written.
output=$(cigo_expect_fail "$CIGO" configure --name "$name" --template "$FIXTURES/basic" \
    --unset limits.memory --yes)
assert_contains "$output" "conflicts with a config key declared" "unset conflict refused"
assert_eq "192MiB" "$(lxc config get "$name" limits.memory)" "refused run changed nothing"

output=$(cigo_expect_fail "$CIGO" configure --name "$name" --yes)
assert_contains "$output" "Nothing to configure" "empty configure refused"

output=$(cigo_expect_fail "$CIGO" configure --name "$name" --unset user.cigo.version --yes)
assert_contains "$output" "cigo metadata" "metadata keys are not removable"

# Whole devices are never removed implicitly; --remove-device does it.
output=$(cigo_expect_ok "$CIGO" configure --name "$name" --template "$FIXTURES/basic" --yes)
assert_not_contains "$output" "Removed device" "configure keeps undeclared devices"
assert_contains "$(lxc config device show "$name")" "it-data:" "device still present"
cigo_expect_ok "$CIGO" configure --name "$name" --remove-device it-data --yes >/dev/null
assert_not_contains "$(lxc config device show "$name")" "it-data:" "device removed on request"

# The prompt shows [Y/n], so an empty answer must accept; a closed stdin must
# cancel instead of being read as consent.
printf '\n' | "$CIGO" configure --name "$name" --config limits.cpu=3 >/dev/null 2>&1 ||
    fail "empty answer should accept the displayed default"
assert_eq "3" "$(lxc config get "$name" limits.cpu)" "empty answer applied the change"

set +e
"$CIGO" configure --name "$name" --config limits.cpu=5 < /dev/null >/dev/null 2>&1
status=$?
set -e
assert_eq "1" "$status" "closed stdin cancels"
assert_eq "3" "$(lxc config get "$name" limits.cpu)" "cancelled run changed nothing"
