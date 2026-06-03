# Fetch the license for a GitHub repo and classify it as MIT, Apache-2.0,
# or fall back to the SPDX identifier returned by the API.
# Usage: LICENSE=$(gh_license "owner/repo")
gh_license() {
  local repo="$1"
  local resp text spdx

  resp=$(curl -sL "https://api.github.com/repos/${repo}/license")
  text=$(echo "$resp" | jq -r '.content // ""' | tr -d '\n' | base64 -d 2>/dev/null || true)
  spdx=$(echo "$resp" | jq -r '.license.spdx_id // "Unknown"')

  if echo "$text" | grep -qi "mit license\|permission is hereby granted"; then
    echo "MIT"
  elif echo "$text" | grep -qi "apache license.*version 2\|apache-2\.0"; then
    echo "Apache-2.0"
  else
    echo "$spdx"
  fi
}
