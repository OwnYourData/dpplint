#!/bin/sh
# Starts the local SOyA repository and the SOyA web-cli (both bound to the
# container, not exposed), then the dpplint API on port 3000.
# "init.sh test" runs the test suite instead of the API.
set -e
cd /usr/src/app
node docker/serve_structures.js structures 9000 &
(cd /app && PORT=8080 REPO_BASE_URL=http://127.0.0.1:9000 node dist/index.js > /tmp/web-cli.log 2>&1) &
export SECRET_KEY_BASE="${SECRET_KEY_BASE:-$(ruby -rsecurerandom -e 'puts SecureRandom.hex(64)')}"

if [ "${1:-}" = "test" ]; then
  shift
  RAILS_ENV=test exec bin/rails test "$@"
fi
exec bin/rails server -b 0.0.0.0 -p 3000
