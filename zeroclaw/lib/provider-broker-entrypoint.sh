#!/bin/sh
# The handler has a shorter total deadline so classified fallback can finish
# before this outer guard, while a stalled local client cannot hold the root
# provider listener forever.
exec timeout 75 /usr/local/bin/provider-broker-handler
