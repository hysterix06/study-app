#!/bin/zsh
# One-time setup: lets codesign use your signing key without asking for the Mac's password on every build.
# macOS asks because the key only trusts Apple's command-line tools ("apple-tool:"), while codesign identifies itself
# as "apple:". This adds "apple:". It asks for your login password once, here in Terminal.
# Usage: scripts/trust-signing-key.sh   (SIGN_IDENTITY picks a certificate, as in build-app.sh)
set -euo pipefail

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
if [[ -z "$IDENTITY" ]]; then
  echo "No signing certificate found. build-app.sh signs ad hoc, which needs no key." >&2
  exit 1
fi
# The private key carries the certificate's name without the team ID: "Apple Development: Name".
LABEL="$(printf '%s' "$IDENTITY" | sed 's/ ([^)]*)$//')"
security set-key-partition-list -S apple-tool:,apple: -s -l "$LABEL" "$HOME/Library/Keychains/login.keychain-db" >/dev/null
echo "codesign can now sign with \"$LABEL\" without asking."
