#!/usr/bin/env bash
# Build the GitHub Pages site into _site/ (or the folder given as $1):
#   index.html                   README.md rendered as a web page
#   windows-selfhost-kit.zip     the kit folder (git archive of HEAD)
#   windows-selfhost-kit.md      the single-file edition (dist/)
# Needs pandoc. Run from a git checkout: tools/bundle.sh --check && site/build.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="${1:-_site}"
REPO_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-xuckless/windows-selfhost-kit}"

rm -rf "$OUT"
mkdir -p "$OUT"
git archive --format=zip --prefix=windows-selfhost-kit/ -o "$OUT/windows-selfhost-kit.zip" HEAD
cp dist/windows-selfhost-kit.md "$OUT/windows-selfhost-kit.md"
cp site/style.css "$OUT/style.css"
sed "s|@@REPO_URL@@|$REPO_URL|g" site/header.html > "$OUT/header.html"
pandoc README.md -f gfm -t html5 --standalone --toc --toc-depth=2 --no-highlight \
  --metadata pagetitle="Windows Self-Host Kit" \
  --metadata description="Host a Spring Boot app on your Windows PC with WSL2, Docker, Tailscale Funnel and GitHub Actions." \
  --css style.css --include-before-body "$OUT/header.html" -o "$OUT/index.html"
rm -f "$OUT/header.html"
touch "$OUT/.nojekyll"
echo "site: built $OUT ($(ls "$OUT" | tr '\n' ' '))"
