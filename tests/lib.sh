# Shared helpers for the cigo integration tests.
#
# The suite is plain Bash on purpose: cigo itself has no build step and only
# needs bash, lxc, jq and python3-jinja2 on the host, so the tests require
# nothing more. Cases run against a real LXD server and create containers with
# a unique prefix, then delete them again.

CIGO_IT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CIGO="$CIGO_IT_ROOT/cigo.sh"
FIXTURES="$CIGO_IT_ROOT/tests/fixtures"

: "${CIGO_IT_IMAGE:=ubuntu:24.04}"
: "${CIGO_IT_PREFIX:=cigo-it-$$}"

fail() {
    printf '  FAIL: %s\n' "$*" >&2
    exit 1
}

pass() {
    printf '  ok: %s\n' "$*"
}

assert_eq() {
    local expected=$1 actual=$2 what=${3:-value}
    [[ $actual == "$expected" ]] || fail "$what: expected [$expected], got [$actual]"
    pass "$what"
}

assert_contains() {
    local haystack=$1 needle=$2 what=${3:-output}
    [[ $haystack == *"$needle"* ]] || fail "$what: missing [$needle]"
    pass "$what"
}

assert_not_contains() {
    local haystack=$1 needle=$2 what=${3:-output}
    [[ $haystack != *"$needle"* ]] || fail "$what: unexpectedly contains [$needle]"
    pass "$what"
}

assert_file_mode() {
    local ct=$1 path=$2 mode=$3 actual
    actual=$(ct_run "$ct" "stat -c %a $path") || fail "cannot stat $path in $ct"
    [[ $actual == "$mode" ]] || fail "$path mode: expected [$mode], got [$actual]"
    pass "$path mode is $mode"
}

assert_owner() {
    local ct=$1 path=$2 owner=$3 actual
    actual=$(ct_run "$ct" "stat -c %U:%G $path") || fail "cannot stat $path in $ct"
    [[ $actual == "$owner" ]] || fail "$path owner: expected [$owner], got [$actual]"
    pass "$path owner is $owner"
}

assert_no_container() {
    local name=$1
    if lxc info "$name" >/dev/null 2>&1; then
        fail "container $name should not exist"
    fi
    pass "container $name was not created"
}

ct_run() {
    local ct=$1 command=$2
    lxc exec "$ct" -- sh -c "$command" </dev/null
}

ct_name() {
    printf '%s-%s' "$CIGO_IT_PREFIX" "$1"
}

# A container created by a case must be deleted by the runner even when the
# case fails half-way, so every created name is recorded first.
register_ct() {
    printf '%s\n' "$1" >> "$IT_STATE_DIR/containers"
}

# cigo create with the test image and no interactive prompts.
cigo_create() {
    local name=$1 template=$2
    shift 2
    "$CIGO" create --name "$name" --template "$template" --image "$CIGO_IT_IMAGE" --yes "$@"
}

require_lxd() {
    command -v lxc >/dev/null 2>&1 || fail "lxc is not installed"
    lxc info >/dev/null 2>&1 || fail "LXD is not reachable"
}

require_jinja2() {
    python3 -c 'import jinja2' >/dev/null 2>&1 ||
        fail "python3-jinja2 is required on the host"
}

# Run a command that must succeed; the output is returned for assertions and
# printed when it fails, so a broken command never hides its own error.
cigo_expect_ok() {
    local output
    if ! output=$("$@" 2>&1); then
        printf '%s\n' "$output" >&2
        fail "command failed: $*"
    fi
    printf '%s' "$output"
}

cigo_expect_fail() {
    local output
    if output=$("$@" 2>&1); then
        printf '%s\n' "$output" >&2
        fail "command unexpectedly succeeded: $*"
    fi
    printf '%s' "$output"
}
