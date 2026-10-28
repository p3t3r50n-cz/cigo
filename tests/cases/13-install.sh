#!/usr/bin/env bash
# cigo must work from PATH. A symlink resolves to the real script, so the
# bundled templates are found from any working directory; a plain copy has no
# templates next to it and therefore needs an explicit template path.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source ./lib.sh

work=$(mktemp -d "${TMPDIR:-/tmp}/cigo-it-install.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin" "$work/elsewhere"
ln -s "$CIGO" "$work/bin/cigo.sh"
name=$(ct_name install)

output=$(cd "$work/elsewhere" && cigo_expect_ok "$work/bin/cigo.sh" create --name "$name" \
    --template lamp --check)
assert_contains "$output" "Template check passed" "bundled template found through a symlink"

output=$(cd "$work/elsewhere" && cigo_expect_ok "$work/bin/cigo.sh" create --name "$name" \
    --template templates/lamp --check)
assert_contains "$output" "Template check passed" "templates/ prefix resolved through a symlink"

# Render sources are resolved against the template directory, so they must
# follow the symlink as well.
output=$(cd "$work/elsewhere" && cigo_expect_ok "$work/bin/cigo.sh" create --name "$name" \
    --template bind-dns --dry-run)
assert_contains "$output" "would render" "render sources resolved through a symlink"

cp -- "$CIGO" "$work/bin/cigo-copy"
output=$(cd "$work/elsewhere" && cigo_expect_fail "$work/bin/cigo-copy" create --name "$name" \
    --template lamp --check)
assert_contains "$output" "Cannot read template" "a copy carries no bundled templates"

output=$(cd "$work/elsewhere" && cigo_expect_ok "$work/bin/cigo-copy" create --name "$name" \
    --template "$CIGO_IT_ROOT/templates/lamp" --check)
assert_contains "$output" "Template check passed" "a copy works with an explicit template path"
assert_no_container "$name"
