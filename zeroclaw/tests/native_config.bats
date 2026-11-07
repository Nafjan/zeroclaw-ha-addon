#!/usr/bin/env bats

@test "native config renderer validates its graph and persistence lifecycle" {
  run python3 -m unittest discover \
    -s "$BATS_TEST_DIRNAME/../native" \
    -p 'test_config.py' -v
  [ "$status" -eq 0 ]
}
