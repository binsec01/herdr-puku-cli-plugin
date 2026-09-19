#!/bin/sh
# Seed the puku-cli -> Herdr integration: seed the agent-detection override
# into herdr's config dir. The puku-cli hook itself is registered via
# `puku-cli plugin install` (see README), NOT by editing settings.json.
. "$(dirname "$0")/common.sh"
set -e
ensure_agent_detection
echo "puku-cli <-> Herdr integration ready."
echo "If you haven't already: puku-cli plugin install /home/rahat/development/herdr-puku-cli-plugin/puku-plugin"
