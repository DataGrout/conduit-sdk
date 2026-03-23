#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ─── Usage ────────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
Usage: ./publish.sh <bump> [--dry-run]

  bump:      major | minor | patch | <explicit version like 0.2.0>
  --dry-run: validate everything without actually publishing

Examples:
  ./publish.sh patch              # 0.1.0 → 0.1.1, publish all
  ./publish.sh minor              # 0.1.0 → 0.2.0, publish all
  ./publish.sh 1.0.0              # set to 1.0.0, publish all
  ./publish.sh patch --dry-run    # bump + validate only
EOF
  exit 1
}

[[ $# -lt 1 ]] && usage

BUMP="$1"
DRY_RUN=false
[[ "${2:-}" == "--dry-run" ]] && DRY_RUN=true

# ─── Read current version ────────────────────────────────────────────────────

CURRENT=$(grep '^version' rust/Cargo.toml | head -1 | sed 's/.*"\(.*\)"/\1/')
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"

echo "Current version: $CURRENT"

# ─── Compute new version ─────────────────────────────────────────────────────

if [[ "$BUMP" == "major" ]]; then
  NEW_VERSION="$((MAJOR + 1)).0.0"
elif [[ "$BUMP" == "minor" ]]; then
  NEW_VERSION="$MAJOR.$((MINOR + 1)).0"
elif [[ "$BUMP" == "patch" ]]; then
  NEW_VERSION="$MAJOR.$MINOR.$((PATCH + 1))"
elif [[ "$BUMP" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  NEW_VERSION="$BUMP"
else
  echo "Error: invalid bump '$BUMP' — use major, minor, patch, or an explicit version"
  exit 1
fi

echo "New version:     $NEW_VERSION"
echo ""

# ─── Confirm before continuing ────────────────────────────────────────────────

if [[ -t 0 ]]; then
  read -r -p "Continue with version bump to $NEW_VERSION? [y/N] " CONFIRM
  case "${CONFIRM:-}" in
    y|Y|yes|YES)
      ;;
    *)
      echo "Cancelled."
      exit 0
      ;;
  esac
  echo ""
fi

# ─── Version parity check ────────────────────────────────────────────────────

TS_VER=$(grep '"version"' typescript/package.json | head -1 | sed 's/.*"\([0-9][^"]*\)".*/\1/')
PY_VER=$(grep '^version' python/pyproject.toml | head -1 | sed 's/.*"\(.*\)"/\1/')
EX_VER=$(grep '@version' elixir/mix.exs | head -1 | sed 's/.*"\(.*\)"/\1/')
RB_VER=$(grep 'VERSION' ruby/lib/datagrout_conduit/version.rb | sed 's/.*"\(.*\)"/\1/')

if [[ "$CURRENT" != "$TS_VER" || "$CURRENT" != "$PY_VER" || "$CURRENT" != "$EX_VER" || "$CURRENT" != "$RB_VER" ]]; then
  echo "ERROR: versions are out of sync before bump!"
  echo "  Rust:       $CURRENT"
  echo "  TypeScript: $TS_VER"
  echo "  Python:     $PY_VER"
  echo "  Elixir:     $EX_VER"
  echo "  Ruby:       $RB_VER"
  echo ""
  echo "Fix manually, then retry."
  exit 1
fi

# ─── Bump versions across all files ──────────────────────────────────────────

echo "Bumping versions..."

# Rust — Cargo.toml
sed -i '' "s/^version = \"$CURRENT\"/version = \"$NEW_VERSION\"/" rust/Cargo.toml

# TypeScript — package.json
sed -i '' "s/\"version\": \"$CURRENT\"/\"version\": \"$NEW_VERSION\"/" typescript/package.json

# TypeScript — src/index.ts
sed -i '' "s/export const version = '$CURRENT'/export const version = '$NEW_VERSION'/" typescript/src/index.ts

# Python — pyproject.toml
sed -i '' "s/^version = \"$CURRENT\"/version = \"$NEW_VERSION\"/" python/pyproject.toml

# Python — __init__.py
sed -i '' "s/__version__ = \"$CURRENT\"/__version__ = \"$NEW_VERSION\"/" python/src/datagrout/conduit/__init__.py

# Elixir — mix.exs
sed -i '' "s/@version \"$CURRENT\"/@version \"$NEW_VERSION\"/" elixir/mix.exs

# Elixir — lib/datagrout_conduit.ex
sed -i '' "s/@version \"$CURRENT\"/@version \"$NEW_VERSION\"/" elixir/lib/datagrout_conduit.ex

# Ruby — version.rb
sed -i '' "s/VERSION = \"$CURRENT\"/VERSION = \"$NEW_VERSION\"/" ruby/lib/datagrout_conduit/version.rb

echo "  rust/Cargo.toml                          → $NEW_VERSION"
echo "  typescript/package.json                  → $NEW_VERSION"
echo "  typescript/src/index.ts                  → $NEW_VERSION"
echo "  python/pyproject.toml                    → $NEW_VERSION"
echo "  python/src/.../\__init__.py              → $NEW_VERSION"
echo "  elixir/mix.exs                           → $NEW_VERSION"
echo "  elixir/lib/datagrout_conduit.ex          → $NEW_VERSION"
echo "  ruby/lib/datagrout_conduit/version.rb    → $NEW_VERSION"
echo ""

# ─── Verify parity ───────────────────────────────────────────────────────────

VERIFY_RS=$(grep '^version' rust/Cargo.toml | head -1 | sed 's/.*"\(.*\)"/\1/')
VERIFY_TS=$(grep '"version"' typescript/package.json | head -1 | sed 's/.*"\([0-9][^"]*\)".*/\1/')
VERIFY_PY=$(grep '^version' python/pyproject.toml | head -1 | sed 's/.*"\(.*\)"/\1/')
VERIFY_EX=$(grep '@version' elixir/mix.exs | head -1 | sed 's/.*"\(.*\)"/\1/')
VERIFY_RB=$(grep 'VERSION' ruby/lib/datagrout_conduit/version.rb | sed 's/.*"\(.*\)"/\1/')

ALL_MATCH=true
for V in "$VERIFY_RS" "$VERIFY_TS" "$VERIFY_PY" "$VERIFY_EX" "$VERIFY_RB"; do
  [[ "$V" != "$NEW_VERSION" ]] && ALL_MATCH=false
done

if ! $ALL_MATCH; then
  echo "ERROR: version bump failed — files are inconsistent!"
  echo "  Rust:       $VERIFY_RS"
  echo "  TypeScript: $VERIFY_TS"
  echo "  Python:     $VERIFY_PY"
  echo "  Elixir:     $VERIFY_EX"
  echo "  Ruby:       $VERIFY_RB"
  exit 1
fi

echo "Version parity verified across all 5 SDKs: $NEW_VERSION"
echo ""

# ─── Test suite ──────────────────────────────────────────────────────────────

echo "Running unit tests across all SDKs (integration tests skipped — set CONDUIT_TEST_URL to enable)..."
echo ""

echo "═══ Rust ═══"
(cd rust && cargo test --quiet 2>&1)
echo "  cargo test: OK"
echo ""

echo "═══ TypeScript ═══"
(cd typescript && npm install --silent 2>&1 && npx vitest run --reporter=dot 2>&1)
echo "  vitest: OK"
echo ""

echo "═══ Python ═══"
(cd python && python -m pytest -q 2>&1)
echo "  pytest: OK"
echo ""

echo "═══ Elixir ═══"
(cd elixir && mix deps.get --quiet 2>&1 && mix test 2>&1)
echo "  mix test: OK"
echo ""

echo "═══ Ruby ═══"
(cd ruby && bundle install --quiet 2>&1 && bundle exec rake test 2>&1)
echo "  rake test: OK"
echo ""

echo "All tests passed."
echo ""

# ─── Build & validate ────────────────────────────────────────────────────────

echo "═══ Rust ═══"
(cd rust && cargo check --quiet)
echo "  cargo check: OK"

echo ""
echo "═══ TypeScript ═══"
(cd typescript && npm run build --silent)
echo "  npm build: OK"

echo ""
echo "═══ Python ═══"
(cd python && rm -rf dist/ && python -m build 2>&1 | tail -1)
echo "  python build: OK"

echo ""
echo "═══ Elixir ═══"
(cd elixir && mix compile --no-warnings-as-errors 2>&1 | tail -1)
echo "  mix compile: OK"

echo ""
echo "═══ Ruby ═══"
(cd ruby && rm -f datagrout-conduit-*.gem && gem build datagrout-conduit.gemspec 2>&1 | tail -1)
echo "  gem build: OK"

echo ""

# ─── Publish (or dry-run) ────────────────────────────────────────────────────

if $DRY_RUN; then
  echo "─── DRY RUN ───"
  echo ""

  echo "═══ Rust (dry-run) ═══"
  (cd rust && cargo publish --dry-run --quiet 2>&1) || true
  echo ""

  echo "═══ TypeScript (dry-run) ═══"
  (cd typescript && npm pack --dry-run 2>&1) || true
  echo ""

  echo "═══ Python (dry-run) ═══"
  (cd python && twine check dist/* 2>&1) || true
  echo ""

  echo "═══ Elixir (dry-run) ═══"
  echo "  Run 'cd elixir && mix hex.publish --dry-run' manually (requires mix hex.user auth)"
  echo ""

  echo "═══ Ruby (dry-run) ═══"
  (cd ruby && ls -la datagrout-conduit-*.gem 2>&1) || true
  echo ""

  echo "Dry run complete. Review output above, then run without --dry-run to publish."
  echo ""
  echo "To revert the version bump:"
  echo "  git checkout -- rust/Cargo.toml typescript/package.json typescript/src/index.ts python/pyproject.toml python/src/datagrout/conduit/__init__.py elixir/mix.exs elixir/lib/datagrout_conduit.ex ruby/lib/datagrout_conduit/version.rb"
else
  echo "─── PUBLISHING $NEW_VERSION ───"
  echo ""

  FAILED=()

  echo "═══ Rust → crates.io ═══"
  if (cd rust && cargo publish 2>&1); then
    echo "  ✓ Published datagrout-conduit $NEW_VERSION to crates.io"
  else
    echo "  ✗ FAILED — run 'cd rust && cargo publish' manually"
    FAILED+=("rust")
  fi
  echo ""

  echo "═══ TypeScript → npm ═══"
  if (cd typescript && npm publish --access public 2>&1); then
    echo "  ✓ Published @datagrout/conduit $NEW_VERSION to npm"
  else
    echo "  ✗ FAILED — run 'cd typescript && npm publish --access public' manually"
    FAILED+=("typescript")
  fi
  echo ""

  echo "═══ Python → PyPI ═══"
  if (cd python && twine upload dist/* 2>&1); then
    echo "  ✓ Published datagrout-conduit $NEW_VERSION to PyPI"
  else
    echo "  ✗ FAILED — run 'cd python && twine upload dist/*' manually"
    FAILED+=("python")
  fi
  echo ""

  echo "═══ Elixir → hex.pm ═══"
  if (cd elixir && mix hex.publish --yes 2>&1); then
    echo "  ✓ Published datagrout_conduit $NEW_VERSION to hex.pm"
  else
    echo "  ✗ FAILED — run 'cd elixir && mix hex.publish' manually"
    FAILED+=("elixir")
  fi
  echo ""

  echo "═══ Ruby → rubygems.org ═══"
  if (cd ruby && gem push datagrout-conduit-${NEW_VERSION}.gem 2>&1); then
    echo "  ✓ Published datagrout-conduit $NEW_VERSION to rubygems.org"
  else
    echo "  ✗ FAILED — run 'cd ruby && gem push datagrout-conduit-${NEW_VERSION}.gem' manually"
    FAILED+=("ruby")
  fi
  echo ""

  # Git commit + tag after publish
  git add -A
  if ! git diff --cached --quiet; then
    git commit -m "release: v$NEW_VERSION"
  fi

  if git tag -l "v$NEW_VERSION" | grep -q .; then
    echo "Local tag v$NEW_VERSION already exists — deleting and recreating it."
    git tag -d "v$NEW_VERSION"
  fi

  git tag "v$NEW_VERSION"

  echo ""
  if [[ ${#FAILED[@]} -eq 0 ]]; then
    echo "Published v$NEW_VERSION to all registries."
  else
    echo "Published v$NEW_VERSION with ${#FAILED[@]} failure(s): ${FAILED[*]}"
    echo "Fix the above and re-run the individual publish commands."
  fi
  echo "Created local git tag v$NEW_VERSION."
  echo "Run 'git push && git push --tags --force' if you need to replace an existing remote tag."
fi
