#!/bin/bash
# Shim for backward compatibility — logic is now in manage.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/manage.sh" prepare "$@"
