#!/usr/bin/env bash
# Validates the project and produces a deployable release.
# No custom image is built — the official docker-mailserver image is used as-is;
# this script verifies config, pins the image digest, and packages the project.
#
#   ./scripts/build.sh                 validate prd + uat (no Docker needed)
#   ./scripts/build.sh --pull          also pull the image and record its digest in release.lock
#   ./scripts/build.sh --package       also create dist/gbsmtpservice-<version>.tar.gz
#
# Typical release:  ./scripts/build.sh --pull --package

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PULL=0; PACKAGE=0
for arg in "$@"; do
  case "$arg" in
    --pull) PULL=1 ;;
    --package) PACKAGE=1 ;;
    *) die "Unknown option: $arg" ;;
  esac
done

failures=0

log "Shell syntax"
for f in "$ROOT_DIR"/scripts/*.sh; do
  if bash -n "$f"; then ok "$(basename "$f")"; else failures=$((failures+1)); fi
  if grep -q $'\r' "$f"; then
    warn "$(basename "$f") has Windows (CRLF) line endings — it will not run on Linux"; failures=$((failures+1))
  fi
done
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x -S warning "$ROOT_DIR"/scripts/*.sh && ok "shellcheck clean" || failures=$((failures+1))
fi

for env in prd uat; do
  log "Config: $env"
  (
    load_env "$env"
    validate_lists || exit 1
    ok "$(mailboxes | wc -l | tr -d ' ') mailboxes, $(aliases | wc -l | tr -d ' ') aliases, domains: $(domains | paste -sd' ' -)"
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
      "${COMPOSE[@]}" config -q && ok "docker-compose.yml renders for $env"
    else
      warn "docker compose not available — skipped compose validation"
    fi
  ) || failures=$((failures+1))
done

# PRD and UAT must not share mail domains
overlap="$(comm -12 <(load_env prd; domains) <(load_env uat; domains))"
if [[ -n "$overlap" ]]; then
  warn "PRD and UAT both serve: $overlap — UAT must use separate (uatmail.) domains"; failures=$((failures+1))
fi

[[ $failures -eq 0 ]] || die "$failures check(s) failed"

if [[ $PULL -eq 1 ]]; then
  require_cmd docker
  log "Pulling images and pinning digests"
  {
    echo "# Image digests recorded by scripts/build.sh on $(date '+%F %T')"
    for env in prd uat; do
      (
        load_env "$env"
        img="ghcr.io/docker-mailserver/docker-mailserver:${DMS_VERSION:-latest}"
        docker pull -q "$img" >/dev/null
        echo "$env $img $(docker image inspect -f '{{index .RepoDigests 0}}' "$img")"
      )
    done
  } > "$ROOT_DIR/release.lock"
  ok "release.lock written"; sed 's/^/    /' "$ROOT_DIR/release.lock"
fi

if [[ $PACKAGE -eq 1 ]]; then
  VERSION="$(git -C "$ROOT_DIR" describe --tags --always --dirty 2>/dev/null || date +%Y%m%d%H%M)"
  mkdir -p "$ROOT_DIR/dist"
  OUT="$ROOT_DIR/dist/gbsmtpservice-$VERSION.tar.gz"
  log "Packaging $OUT"
  tar -czf "$OUT" -C "$ROOT_DIR" \
    --exclude='./data' --exclude='./secrets' --exclude='./dist' --exclude='./.git' --exclude='./dns' \
    .
  ok "Package: dist/$(basename "$OUT") ($(du -h "$OUT" | cut -f1))"
  echo "    Deploy:  scp $OUT user@server:/opt/  &&  tar -xzf ... -C /opt/gbsmtpservice"
fi

ok "Build checks passed"
