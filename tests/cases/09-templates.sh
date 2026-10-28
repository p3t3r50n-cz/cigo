#!/usr/bin/env bash
# Every bundled template must at least parse, resolve its variables and render
# its files against a real LXD server. No container is created.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source ./lib.sh

work=$(mktemp -d "${TMPDIR:-/tmp}/cigo-it-templates.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
printf 'template-test-secret\n' > "$work/secret"
chmod 600 "$work/secret"

# Templates that reference containers or host paths from one specific
# environment cannot be validated in a generic suite.
skip="lamp-p84-u24"

# Secrets required by individual templates.
secret_args() {
    case $1 in
        wireguard-server) printf -- '--secret-file\nWG_PRIVATE_KEY=%s\n' "$work/secret" ;;
        proftpd-sftp) printf -- '--secret-file\nSFTP_HOST_PRIVATE_KEY=%s\n' "$work/secret" ;;
        postfix-dovecot-mysql) printf -- '--secret-file\nDB_PASSWORD=%s\n' "$work/secret" ;;
        *) printf '' ;;
    esac
}

checked=0
for template_dir in "$CIGO_IT_ROOT"/templates/*/; do
    template=$(basename "$template_dir")
    [[ " $skip " == *" $template "* ]] && continue

    mapfile -t args < <(secret_args "$template")
    name=$(ct_name "tpl-$template")
    output=$(cigo_expect_ok "$CIGO" create --name "$name" --template "$template_dir" \
        --image "$CIGO_IT_IMAGE" --dry-run "${args[@]}")
    assert_contains "$output" "Dry run complete" "$template validated"
    assert_contains "$output" "Template: " "$template resolved"
    assert_no_container "$name"
    checked=$((checked + 1))
done

((checked > 0)) || fail "no templates were validated"
printf '  ok: %s templates validated\n' "$checked"
