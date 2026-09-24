#!/usr/bin/env bash
# Copy the kit's templates into place, filled in with the values from kit.env.
#
#   apply-template.sh --project           add Docker/Tailscale/CI files to your Spring Boot repo
#                                         (the Windows folder WIN_PROJECT_DIR from kit.env)
#   apply-template.sh --repo-dir <path>   same, for another folder (Windows path C:\... or /mnt/c/...)
#   apply-template.sh --db                create the database stack in ~/apps/<DB_SERVICE_NAME>
#   --force               overwrite files that already exist (the old file is kept as <file>.bak)
#   --kit-env <file>      use another settings file than kit.env (for a second app)
#
# Never touches .env secrets. Prints what you still have to do at the end.
set -euo pipefail
# shellcheck source=wsl/lib.sh
source "$(dirname "$0")/lib.sh"

MODE=; TARGET=; FORCE=; KIT_ENV_FILE="$KIT_DIR/kit.env"
while [ $# -gt 0 ]; do
  case "$1" in
    --project) MODE=repo ;;
    --repo-dir) MODE=repo; TARGET="${2:?}"; shift ;;
    --db) MODE=db ;;
    --force) FORCE=1 ;;
    --kit-env) KIT_ENV_FILE="${2:?}"; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done
[ -n "$MODE" ] || { sed -n '2,12p' "$0"; exit 1; }
detect_kit_user
load_kit_env "$KIT_ENV_FILE"
validate_kit_env
if [ "$MODE" = repo ] && [ -z "$TARGET" ]; then
  TARGET="${WIN_PROJECT_DIR:-}"
  case "$TARGET" in ''|*'\you\'*) die "Set WIN_PROJECT_DIR in kit.env (the Windows folder with your pom.xml), re-run Stage, or use --repo-dir <path>." ;; esac
fi
JAVA_PACKAGE="${JAVA_PACKAGE:-}"
TODO=()

# render SRC DST: fill @@VAR@@ tokens and the #@@DB@@ / #@@MTLS@@ optional lines.
render() {
  local src="$1" dst="$2" tmp
  tmp="$(mktemp)"
  local db_expr='/#@@DB@@$/d' mtls_expr='/#@@MTLS@@$/d'
  [ "$WITH_DB" = yes ] && db_expr='s/[[:space:]]*#@@DB@@$//'
  [ "$WITH_MTLS" = yes ] && mtls_expr='s/[[:space:]]*#@@MTLS@@$//'
  sed -e "$db_expr" -e "$mtls_expr" \
      -e "s|@@SERVICE_NAME@@|$SERVICE_NAME|g" -e "s|@@DB_SERVICE_NAME@@|$DB_SERVICE_NAME|g" \
      -e "s|@@APP_PORT@@|$APP_PORT|g" -e "s|@@JAVA_VERSION@@|$JAVA_VERSION|g" \
      -e "s|@@BRANCH@@|$BRANCH|g" -e "s|@@RUNNER_LABEL@@|$RUNNER_LABEL|g" \
      -e "s|@@HEALTH_PATH@@|$HEALTH_PATH|g" -e "s|@@MTLS_PORT@@|$MTLS_PORT|g" \
      -e "s|@@JAVA_PACKAGE@@|$JAVA_PACKAGE|g" "$src" > "$tmp"
  if grep -q '@@[A-Z_]*@@' "$tmp"; then
    rm -f "$tmp"; die "Unfilled placeholder in $src (kit bug)."
  fi
  place "$tmp" "$dst"
}

# place TMP DST: install TMP at DST unless DST exists with different content (then --force).
place() {
  local tmp="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [ -f "$dst" ] && cmp -s "$tmp" "$dst"; then
    rm -f "$tmp"; echo "  unchanged  ${dst#"$ROOT"/}"; return 0
  fi
  if [ -f "$dst" ] && [ -z "$FORCE" ]; then
    rm -f "$tmp"; warn "exists, kept yours: ${dst#"$ROOT"/} (use --force to replace it; a .bak is kept)"; return 0
  fi
  [ -f "$dst" ] && cp -p "$dst" "$dst.bak"
  cat "$tmp" > "$dst"; rm -f "$tmp"
  case "$dst" in *.sh) chmod +x "$dst" 2>/dev/null || true ;; esac
  echo "  wrote      ${dst#"$ROOT"/}"
}

# append_block SRC DST: append all of SRC to DST once (SRC's first line is a marker comment).
# Appending the whole block keeps its order, so its rules win over earlier lines in DST.
append_block() {
  local src="$1" dst="$2" marker
  marker="$(head -n1 "$src")"
  touch "$dst"
  if grep -qxF -- "$marker" "$dst"; then echo "  unchanged  ${dst#"$ROOT"/}"; return 0; fi
  [ -z "$(tail -c1 "$dst")" ] || echo >> "$dst"
  cat "$src" >> "$dst"
  echo "  updated    ${dst#"$ROOT"/}"
}

copy_stack_scripts() {  # common scripts for app and db stacks
  local f
  for f in _lib.sh up.sh status.sh down.sh env.sh; do
    render "$KIT_DIR/project-template/scripts/$f" "$ROOT/scripts/$f"
  done
}

# ============================================================================================
if [ "$MODE" = db ]; then
  ROOT="$KIT_HOME/apps/$DB_SERVICE_NAME"
  info "Creating the database stack in $ROOT"
  T="$KIT_DIR/db-template"
  render "$T/docker-compose.yml" "$ROOT/docker-compose.yml"
  render "$T/.env.example" "$ROOT/.env.example"
  render "$T/initdb/01-init.sql" "$ROOT/initdb/01-init.sql"
  render "$T/scripts/stack.env" "$ROOT/scripts/stack.env"
  render "$T/scripts/backup.sh" "$ROOT/scripts/backup.sh"
  render "$T/scripts/psql.sh" "$ROOT/scripts/psql.sh"
  copy_stack_scripts
  [ -f "$ROOT/.env" ] || { cp "$ROOT/.env.example" "$ROOT/.env"; chmod 600 "$ROOT/.env"; echo "  wrote      .env (from .env.example; secrets still empty)"; }
  [ "$(id -u)" -eq 0 ] && chown -R "$KIT_USER:" "$ROOT"
  echo
  pass "Database stack ready in $ROOT"
  next "HUMAN (in Ubuntu):  cd $ROOT && scripts/env.sh secret TS_AUTHKEY && scripts/env.sh secret POSTGRES_PASSWORD --generate"
  next "AGENT:              $ROOT/scripts/up.sh"
  exit 0
fi

# ============================================================================================
# --repo-dir: add the files to the Spring Boot repo (usually the Windows dev checkout)
if [[ "$TARGET" =~ ^[A-Za-z]:[\\/] ]]; then
  command -v wslpath >/dev/null 2>&1 || die "wslpath not found: pass a Linux path like /mnt/c/Users/..."
  TARGET="$(wslpath -a "$TARGET")"
fi
[ -d "$TARGET" ] || die "Folder not found: $TARGET"
ROOT="$(cd "$TARGET" && pwd)"
info "Adding self-hosting files to $ROOT"

[ -f "$ROOT/pom.xml" ] || die "No pom.xml in $ROOT. This kit supports Maven projects (open the folder that contains pom.xml)."
if [ ! -f "$ROOT/mvnw" ] || [ ! -f "$ROOT/.mvn/wrapper/maven-wrapper.properties" ]; then
  die "The Maven wrapper (mvnw + .mvn/wrapper) is missing. Add it, commit it, then run this again:
    cd '$ROOT' && docker run --rm -v \"\$PWD\":/src -w /src maven:3-eclipse-temurin-$JAVA_VERSION mvn -q -N wrapper:wrapper"
fi
[ -d "$ROOT/.git" ] || warn "$ROOT is not a git repository (clone your repo from GitHub first, README Part D)."

# ---- detect Spring Boot major version, main package, java.version ----
BOOT_VERSION="$(awk '/<artifactId>spring-boot-(starter-parent|dependencies)<\/artifactId>/{f=1} f && /<version>/{gsub(/.*<version>|<\/version>.*/,""); print; exit}' "$ROOT/pom.xml")"
[ -n "$BOOT_VERSION" ] || BOOT_VERSION="$(sed -n 's:.*<spring-boot.version>\(.*\)</spring-boot.version>.*:\1:p' "$ROOT/pom.xml" | head -1)"
BOOT_MAJOR="${BOOT_VERSION%%.*}"
case "$BOOT_MAJOR" in
  3|4) pass "Spring Boot $BOOT_VERSION" ;;
  *) warn "Could not detect Spring Boot 3.x or 4.x in pom.xml (found '${BOOT_VERSION:-nothing}'); assuming 4.x."; BOOT_MAJOR=4 ;;
esac
MAIN_FILE="$(grep -rlE --include='*.java' '^[[:space:]]*@SpringBootApplication' "$ROOT/src/main/java" 2>/dev/null | head -1 || true)"
[ -n "$MAIN_FILE" ] || die "No class with @SpringBootApplication found under src/main/java."
JAVA_PACKAGE="$(sed -n 's/^[[:space:]]*package[[:space:]]\{1,\}\([A-Za-z0-9_.]*\)[[:space:]]*;.*/\1/p' "$MAIN_FILE" | head -1)"
[ -n "$JAVA_PACKAGE" ] || die "Could not read the package of $MAIN_FILE"
PKG_DIR="${JAVA_PACKAGE//.//}"
pass "Main class package: $JAVA_PACKAGE"
POM_JAVA="$(sed -n 's:.*<java.version>\([0-9]*\)</java.version>.*:\1:p' "$ROOT/pom.xml" | head -1)"
if [ -n "$POM_JAVA" ] && [ "$POM_JAVA" -gt "$JAVA_VERSION" ]; then
  die "pom.xml needs Java $POM_JAVA but kit.env has JAVA_VERSION=$JAVA_VERSION. Set JAVA_VERSION=$POM_JAVA in kit.env, re-run Stage, then retry."
fi

# ---- copy the files ----
T="$KIT_DIR/project-template"
for f in Dockerfile docker-compose.yml ts-serve.json .env.example .dockerignore .github/workflows/deploy.yml \
         scripts/stack.env scripts/deploy.sh scripts/healthcheck.sh; do
  render "$T/$f" "$ROOT/$f"
done
copy_stack_scripts
[ -f "$ROOT/certs/.gitkeep" ] || { mkdir -p "$ROOT/certs"; : > "$ROOT/certs/.gitkeep"; echo "  wrote      certs/.gitkeep"; }
append_block "$T/.gitattributes" "$ROOT/.gitattributes"
append_block "$T/gitignore.append" "$ROOT/.gitignore"

# ---- Spring code / pom checks ----
POM="$ROOT/pom.xml"
has_dep() { grep -q "<artifactId>$1</artifactId>" "$POM"; }
has_dep spring-boot-starter-actuator || TODO+=("pom.xml: add spring-boot-starter-actuator (snippet 1 in $KIT_DIR/project-template/spring/pom-snippets.xml). REQUIRED for health checks.")

if [ "$WITH_DB" = yes ]; then
  has_dep postgresql || TODO+=("pom.xml: add the org.postgresql:postgresql driver (snippet 2 in pom-snippets.xml).")
  if grep -rqsE '^[[:space:]]*@ServiceConnection' "$ROOT/src/test/java"; then
    pass "Tests already use Testcontainers (@ServiceConnection found)"
  else
    render "$T/spring/SelfhostTestcontainersConfiguration.boot$BOOT_MAJOR.java" \
           "$ROOT/src/test/java/$PKG_DIR/SelfhostTestcontainersConfiguration.java"
    if [ "$BOOT_MAJOR" = 4 ]; then
      { has_dep spring-boot-testcontainers && has_dep testcontainers-postgresql; } \
        || TODO+=("pom.xml: add the Testcontainers test dependencies (snippet 3a in pom-snippets.xml).")
    else
      { has_dep spring-boot-testcontainers && grep -A1 '<groupId>org.testcontainers</groupId>' "$POM" | grep -q '<artifactId>postgresql</artifactId>'; } \
        || TODO+=("pom.xml: add the Testcontainers test dependencies (snippet 3b in pom-snippets.xml).")
    fi
    TEST_FILE="$(grep -rlE --include='*.java' '^[[:space:]]*@SpringBootTest' "$ROOT/src/test/java" 2>/dev/null | head -1 || true)"
    TODO+=("${TEST_FILE:+${TEST_FILE#"$ROOT"/}: }add  @Import(SelfhostTestcontainersConfiguration.class)  (import org.springframework.context.annotation.Import) to your @SpringBootTest class, so CI tests get a throwaway Postgres.")
  fi
fi

if [ "$WITH_MTLS" = yes ]; then
  render "$KIT_DIR/mtls/spring/MtlsConfig.boot$BOOT_MAJOR.java" "$ROOT/src/main/java/$PKG_DIR/selfhost/MtlsConfig.java"
  render "$KIT_DIR/mtls/spring/MtlsAllowlistFilter.java" "$ROOT/src/main/java/$PKG_DIR/selfhost/MtlsAllowlistFilter.java"
  render "$KIT_DIR/mtls/spring/application-mtls.properties" "$ROOT/src/main/resources/application-mtls.properties"
  if [ "$BOOT_MAJOR" = 4 ]; then
    has_dep spring-boot-starter-restclient || TODO+=("pom.xml: add spring-boot-starter-restclient (snippet 4 in pom-snippets.xml), needed by MtlsConfig.")
  fi
fi

if grep -rqsE '^[[:space:]]*server\.port[[:space:]]*[=:]' "$ROOT/src/main/resources"; then
  TODO+=("src/main/resources: your application config sets server.port. That is fine, the container overrides it with SERVER_PORT=$APP_PORT (from kit.env APP_PORT).")
fi

echo
pass "Template applied to $ROOT"
if [ ${#TODO[@]} -gt 0 ]; then
  echo
  echo "Still to do (AGENT can do these edits):"
  for t in "${TODO[@]}"; do echo "  - $t"; done
fi
cat <<EOF

Then commit and push FROM WINDOWS (PowerShell, in your project folder):
  git add --renormalize .
  git add --chmod=+x mvnw scripts/*.sh
  git add -A
  git status            # review: .env and certs/* must NOT be listed
  git commit -m "Add self-hosting (windows-selfhost-kit)"
  git push
EOF
