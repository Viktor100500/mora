#!/bin/zsh
set -eu
MORA_CLOUD_PROJECT="${0:A:h:h}"
MORA_BUILD_ROOT="$MORA_CLOUD_PROJECT/build/CloudIntegration" zsh "$MORA_CLOUD_PROJECT/scripts/build-app.sh"
# Connection details are entered in Mora; never bundle a private project config.
