#!/bin/sh
# Allow a provider request to finish, but never let one local client hold the
# root-owned provider listener forever.
exec timeout 130 /usr/local/bin/provider-broker-handler
