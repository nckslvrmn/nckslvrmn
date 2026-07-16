#!/usr/bin/env bash
# Prints the built /resume/ page to PDF with a headless Chromium-based browser.
# Usage: build-resume-pdf.sh <built-site-dir> <output-pdf>
set -euo pipefail

SITE_DIR=${1:?usage: build-resume-pdf.sh <built-site-dir> <output-pdf>}
OUTPUT=${2:?usage: build-resume-pdf.sh <built-site-dir> <output-pdf>}
PORT=${PORT:-8000}

CHROME=$(command -v google-chrome || command -v chromium-browser || command -v chromium || command -v brave || true)
if [ -z "$CHROME" ]; then
  echo "a chromium-based browser is required to build the PDF" >&2
  exit 1
fi

python3 -m http.server "$PORT" --directory "$SITE_DIR" >/dev/null 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID' EXIT

for _ in {1..20}; do
  curl -fsS "http://127.0.0.1:$PORT/resume/index.html" >/dev/null 2>&1 && break
  sleep 0.2
done

mkdir -p "$(dirname "$OUTPUT")"
OUTPUT=$(realpath -m "$OUTPUT")

"$CHROME" --headless=new --disable-gpu --no-sandbox \
  --run-all-compositor-stages-before-draw --virtual-time-budget=5000 \
  --no-pdf-header-footer --print-to-pdf="$OUTPUT" \
  "http://127.0.0.1:$PORT/resume/?pdf=1"
