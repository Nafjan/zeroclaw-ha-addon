#!/usr/bin/env bats

run_file="$BATS_TEST_DIRNAME/../run.sh"

setup() {
    command -v jq >/dev/null 2>&1 || skip "routine runner tests require jq"

    routines="$BATS_TEST_TMPDIR/routines"
    mkdir -p "$routines"
    invocations="$BATS_TEST_TMPDIR/invocations"
    : > "$invocations"
    export invocations

    gate="$BATS_TEST_TMPDIR/ha-action-guarded"
    cat > "$gate" <<'SCRIPT'
#!/bin/sh
printf '%s|%s\n' "$1" "$2" >> "$invocations"
case "$1" in
    test/fail|test/pending) exit 1 ;;
    *) exit 0 ;;
esac
SCRIPT
    chmod +x "$gate"

    runner="$BATS_TEST_TMPDIR/ha-run-routine"
    awk '
        index($0, "cat > /usr/local/bin/ha-run-routine") == 1 { inside=1; next }
        inside && $0 == "SCRIPT" { exit }
        inside { print }
    ' "$run_file" \
        | sed -e "s|/usr/local/bin/ha-action-guarded|$gate|g" \
              -e "s|/data/routines|$routines|g" > "$runner"
    chmod +x "$runner"
}

write_routine() {
    printf '%s\n' "$2" > "$routines/$1.json"
}

@test "valid one-step and 32-step routines execute exactly the stored steps" {
    write_routine one '{"name":"one","steps":[{"service":"test/ok","payload":{"n":1}}]}'
    jq -nc '{name:"max",steps:[range(0;32)|{service:"test/ok",payload:{n:.}}]}' > "$routines/max.json"

    run "$runner" one
    [ "$status" -eq 0 ]
    run "$runner" max
    [ "$status" -eq 0 ]

    [ "$(wc -l < "$invocations" | tr -d ' ')" -eq 33 ]
    [ "$(grep -c '^test/ok|' "$invocations")" -eq 33 ]
}

@test "routine execution ignores injected stdin and EOF cannot suppress stored steps" {
    write_routine demo '{"name":"demo","steps":[{"service":"test/first","payload":{}},{"service":"test/second","payload":{}}]}'
    stdin_file="$BATS_TEST_TMPDIR/injected-step"
    printf '%s\n' '{"service":"test/injected","payload":{}}' > "$stdin_file"

    run "$runner" demo < "$stdin_file"
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$invocations" | tr -d ' ')" -eq 2 ]
    run grep -F 'test/injected|' "$invocations"
    [ "$status" -ne 0 ]
    run grep -F 'test/first|' "$invocations"
    [ "$status" -eq 0 ]
    run grep -F 'test/second|' "$invocations"
    [ "$status" -eq 0 ]
}

@test "routine failure or pending result stops before the next stored step" {
    write_routine stop '{"name":"stop","steps":[{"service":"test/ok","payload":{}},{"service":"test/fail","payload":{}},{"service":"test/after","payload":{}}]}'

    run "$runner" stop
    [ "$status" -ne 0 ]
    [ "$(wc -l < "$invocations" | tr -d ' ')" -eq 2 ]
    run grep -F 'test/after|' "$invocations"
    [ "$status" -ne 0 ]
}

@test "invalid, oversized, over-limit, and symlink routines invoke no actions" {
    write_routine malformed '{"name":"malformed","steps":[{"service":"test/ok"}]}'
    jq -nc '{name:"too_many",steps:[range(0;33)|{service:"test/ok",payload:{}}]}' > "$routines/too_many.json"
    printf '%s' '{"name":"oversized","steps":[{"service":"test/ok","payload":{}}]}' > "$routines/oversized.json"
    printf '%131100s' '' | tr ' ' x >> "$routines/oversized.json"
    write_routine valid '{"name":"valid","steps":[{"service":"test/ok","payload":{}}]}'
    ln -s "$routines/valid.json" "$routines/symlink.json"

    for name in malformed too_many oversized symlink; do
        : > "$invocations"
        run "$runner" "$name"
        [ "$status" -ne 0 ]
        [ ! -s "$invocations" ]
    done
}
