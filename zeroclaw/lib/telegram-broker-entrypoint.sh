#!/bin/sh
# Bound one typed Telegram request; the long-polling watcher has its own
# timeout and does not use this entrypoint.
exec timeout 20 /usr/local/bin/tg-broker-handler
