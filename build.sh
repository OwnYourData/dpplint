#!/bin/sh
# Builds oydeu/dpplint (linux/amd64, like the SOyA web-cli it contains).
#   ./build.sh                     build with dpp-criteria main
#   ./build.sh <dpp-criteria ref>  build with a given commit or tag
#   DOCKERHUB=1 ./build.sh         build and push
set -eu
REF="${1:-main}"
# A branch or tag is resolved to its commit, so that the Docker build cache
# never reuses a clone of an older dpp-criteria.
RESOLVED=$(git ls-remote https://github.com/OwnYourData/dpp-criteria.git \
  "refs/heads/$REF" "refs/tags/$REF" "refs/tags/$REF^{}" | sort -k2 | tail -n1 | cut -f1)
[ -n "$RESOLVED" ] && REF="$RESOLVED"
echo "dpp-criteria: $REF"
docker build --platform linux/amd64 --build-arg DPP_CRITERIA_REF="$REF" -f docker/Dockerfile -t oydeu/dpplint:latest .
if [ "${DOCKERHUB:-0}" = "1" ]; then
  docker push oydeu/dpplint:latest
fi
