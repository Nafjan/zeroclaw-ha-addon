#!/usr/bin/env bats

@test "native state migration preserves archives and recovers interrupted preparation" {
  run env PYTHONPATH="$BATS_TEST_DIRNAME/.." python3 -m unittest discover \
    -s "$BATS_TEST_DIRNAME/../native" \
    -p 'test_migrate.py' -v
  [ "$status" -eq 0 ]
}
