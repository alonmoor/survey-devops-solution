#!/usr/bin/env bash
# Problem 5 lab setup: a "central" bare repository (stands in for Azure Repos) with the policy hook,
# and a developer clone. Lab only: everything lives in /tmp/git-lab and is recreated on every run.
# Usage (on master, from ~/survey-devops-solution): bash scripts/local-test/git-policy-lab.sh
set -euo pipefail
LAB=/tmp/git-lab
HOOK=$(pwd)/scripts/local-test/pre-receive

# Start clean.
rm -rf "$LAB"
mkdir -p "$LAB"

# The server repository; main is the default branch.
git init -q --bare -b main "$LAB/central.git"

# A developer clone with a lab-only identity.
git clone -q "$LAB/central.git" "$LAB/dev"
cd "$LAB/dev"
git config user.name "dev"
git config user.email "dev@example.test"

# First version of main, pushed BEFORE the hook exists (the repository's initial import).
printf '#!/bin/sh\necho "survey api v1"\n' > app.sh
git add app.sh
git commit -q -m "initial import"
git push -q origin main

# From now on the policy applies.
cp "$HOOK" "$LAB/central.git/hooks/pre-receive"
chmod +x "$LAB/central.git/hooks/pre-receive"
echo "lab ready: server $LAB/central.git, developer clone $LAB/dev"
git log --oneline
