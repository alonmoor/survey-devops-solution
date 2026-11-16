#!/bin/sh
# Problem 4 lab, part A: the build agent builds one "release" of a tiny web app and pushes it
# with the moving tag "latest", as in the assignment (line 73). It prints the digest at the end.
# Runs INSIDE the build-agent pod:
#   kubectl -n agent-lab exec -i build-agent -- env VERSION=v1 sh -s < scripts/local-test/release-build.sh
set -eu
REG=192.168.1.62:5000                                # the lab registry on worker3
IMG=$REG/demo:latest                                 # same tag for every release

# The "app": a web server that answers with its version.
mkdir -p /tmp/rel
printf 'FROM busybox:1.36\nRUN mkdir /www && echo "version=%s" > /www/index.html\nCMD ["httpd", "-f", "-p", "8080", "-h", "/www"]\n' \
  "$VERSION" > /tmp/rel/Dockerfile

# Build, push, then show the digest: the only name that always means THIS build.
docker build -q -t "$IMG" /tmp/rel
docker push -q "$IMG"
echo "pushed $IMG ($VERSION)"
docker inspect --format '{{index .RepoDigests 0}}' "$IMG"
