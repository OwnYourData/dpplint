#!/bin/sh
# Builds oydeu/dpplint (linux/amd64, like the SOyA web-cli it contains).
#   ./build.sh                     build with dpp-criteria main
#   ./build.sh <dpp-criteria ref>  build with a given commit or tag
#   DOCKERHUB=1 ./build.sh         build, push and write the pushed digest
#                                  into kubernetes/deployment.yaml
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
  # The deployment runs the image by its digest, so that all replicas run the
  # same image until the manifest names a new one.
  DIGEST=$(docker inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' oydeu/dpplint:latest |
    grep '^oydeu/dpplint@sha256:' | head -n 1)
  [ -n "$DIGEST" ] || { echo "no digest for oydeu/dpplint:latest after the push" >&2; exit 1; }
  sed -i.bak "s#image: oydeu/dpplint[@:].*#image: $DIGEST#" kubernetes/deployment.yaml
  rm -f kubernetes/deployment.yaml.bak
  grep -q "image: $DIGEST\$" kubernetes/deployment.yaml ||
    { echo "kubernetes/deployment.yaml does not name $DIGEST" >&2; exit 1; }
  echo "kubernetes/deployment.yaml: image $DIGEST"
fi
