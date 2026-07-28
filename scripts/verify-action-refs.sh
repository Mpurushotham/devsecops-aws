#!/usr/bin/env bash
# Verify every `uses:` reference in .github/workflows/ resolves to a real tag or
# branch.
#
# actionlint validates workflow syntax but does not check that a pinned ref
# exists upstream. A non-existent ref does not fail at parse time: the job dies
# during "Set up job" with no useful message, which is a slow and confusing way
# to discover a typo like `@0.33.1` where the tag is `@v0.33.1`.
#
# Requires: gh (authenticated).
set -uo pipefail

status=0

# Local reusable workflows (./.github/...) are checked by actionlint, not here.
refs=$(grep -rhoE 'uses: +[a-zA-Z0-9._-]+/[a-zA-Z0-9._/-]+@[a-zA-Z0-9._-]+' .github/workflows/ \
  | sed -E 's/uses: +//' | sort -u)

while IFS= read -r ref; do
  [ -n "$ref" ] || continue

  path="${ref%@*}"
  tag="${ref#*@}"

  # Subdirectory actions such as github/codeql-action/init live in the
  # owner/repo above them, so keep only the first two path segments.
  owner=$(printf '%s' "$path" | cut -d/ -f1)
  repo=$(printf '%s' "$path" | cut -d/ -f2)
  slug="${owner}/${repo}"

  if gh api "repos/${slug}/git/ref/tags/${tag}" >/dev/null 2>&1 \
    || gh api "repos/${slug}/git/ref/heads/${tag}" >/dev/null 2>&1; then
    printf '  ok       %s\n' "$ref"
  else
    printf '  MISSING  %s\n' "$ref"
    status=1
  fi
done <<<"$refs"

if [ "$status" -ne 0 ]; then
  echo
  echo "One or more action references do not resolve upstream." >&2
  echo "A common cause is omitting the 'v' prefix, or pinning a major tag" >&2
  echo "(@v4) that the project does not publish as a moving tag." >&2
fi

exit "$status"
