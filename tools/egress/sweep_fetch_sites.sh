#!/bin/bash
# Which hosts does the SHIPPED code actually FETCH?
#
# The raw URL sweep is useless on its own: it returns 193 hits for the legacy
# ontology host and 92 for w3.org, and neither is ever fetched. Those are RDF
# namespace URIs --
# identifiers, not addresses. Counting strings that LOOK like URLs is the
# over-reporting half of the source/sampling problem.
#
# So this classifies by CALL SITE: a host counts only if it appears on a line
# that also invokes something that opens a socket.
set -uo pipefail

REPO="${1:-$(git rev-parse --show-toplevel)}"
cd "$REPO" || exit 2

FETCHERS='curl |curl$|wget |docker pull|docker run|pip install|pip3 install|brew install|brew tap|requests\.(get|post)|httpx\.(get|post|Client)|urlopen|reqwest::|\.get\("http|\.post\("http|git clone'

echo "=== FETCH CALL SITES: host <- the fetcher on the same line ==="
git grep -nhE "$FETCHERS" -- install.sh vendor/ scripts/ 2>/dev/null \
  | grep -oE 'https?://[a-zA-Z0-9._-]+' \
  | sed -E 's|https?://||' \
  | sort | uniq -c | sort -rn
echo
echo "=== package-manager fetchers with no literal URL on the line ==="
echo "  (these reach a default registry: the host is implicit, not in the source)"
for f in 'brew install' 'brew tap' 'pip install' 'pip3 install' 'docker pull' 'ollama pull' 'cargo install' 'npm install'; do
    n="$(git grep -cE "$f" -- install.sh vendor/ scripts/ 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')"
    printf '  %-16s %s call site(s)\n' "$f" "$n"
done
echo
echo "=== CONTROL: a fetcher that is definitely present ==="
printf '  lines matching curl: %s\n' "$(git grep -cE 'curl ' -- install.sh 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')"
echo "=== CONTROL: a fetcher that is definitely absent ==="
printf '  lines matching fetchtheinternet: %s\n' "$(git grep -cE 'fetchtheinternet' -- install.sh 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')"
