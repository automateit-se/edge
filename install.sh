#!/usr/bin/env bash
# Installs the edge reverse proxy on the Debian host and connects the IoT Open dashboard to it.
# Safe to run again. Changes nothing in Cloudflare: after this, the tunnel still points at the
# dashboard on port 8080 until its public hostname rule is switched to http://localhost:80.
#   sudo bash install.sh
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/automateit-se/edge.git}"
EDGE_DIR="${EDGE_DIR:-/opt/edge}"
DASH_DIR="${DASH_DIR:-/opt/iotopen-dashboard}"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31mFEL: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "kör som root: sudo bash $0"
command -v docker >/dev/null || fail "Docker saknas"

if ss -ltnH '( sport = :80 )' | grep -q .; then
  docker ps --format '{{.Names}}' | grep -qx edge || fail "något annat lyssnar redan på port 80: $(ss -ltnpH '( sport = :80 )')"
fi

log "Docker-nätet edge"
docker network inspect edge >/dev/null 2>&1 || docker network create edge >/dev/null
docker network inspect edge --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}'

log "Hämtar konfigurationen till $EDGE_DIR"
if [ -d "$EDGE_DIR/.git" ]; then
  git -C "$EDGE_DIR" fetch --quiet origin main
  git -C "$EDGE_DIR" reset --quiet --hard origin/main
else
  git clone --quiet "$REPO_URL" "$EDGE_DIR"
fi
install -m 0755 "$EDGE_DIR/bin/edge-update" /usr/local/sbin/edge-update

if [ -d "$DASH_DIR" ]; then
  OVERRIDE="$DASH_DIR/compose.local.yml"
  if ! grep -q 'aliases: \[iotopen-dashboard\]' "$OVERRIDE"; then
    log "Ansluter dashboarden till nätet edge"
    cp "$OVERRIDE" "$OVERRIDE.bak-edge"
    cat >> "$OVERRIDE" <<'EOF'
    networks:
      default:
      edge:
        aliases: [iotopen-dashboard]

networks:
  edge:
    external: true
EOF
  fi
  (cd "$DASH_DIR" && docker compose -f docker-compose.yml -f compose.local.yml up -d dashboard)
fi

log "Startar edge"
(cd "$EDGE_DIR" && docker compose pull --quiet && docker compose up -d --remove-orphans)
for _ in $(seq 1 20); do
  curl -fsS http://127.0.0.1/healthz >/dev/null 2>&1 && break
  sleep 1
done
docker exec edge nginx -t

log "Kontroller"
ok=true
check() { # beskrivning host sökväg förväntad-kod
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $2" "http://127.0.0.1$3")"
  if [ "$code" = "$4" ]; then echo "  OK    $1 (HTTP $code)"; else echo "  FEL   $1 (HTTP $code, väntade $4)"; ok=false; fi
}
check "edge svarar"                     localhost               /healthz      200
check "okänt namn ger 404"              okand.automateit.se     /             404
check "dashboard.automateit.se via edge" dashboard.automateit.se /config.json 200
check "dashboardens hälsa via edge"     dashboard.automateit.se /healthz      200
$ok || fail "någon kontroll misslyckades, se ovan. Cloudflare är inte ändrat, så dashboarden fungerar som förut."

cat <<'EOF'

Edge är installerad och svarar på 127.0.0.1:80. Inget är ändrat i Cloudflare än:
dashboard.automateit.se går fortfarande direkt till port 8080.

Nästa steg (i Cloudflare): *.automateit.se -> http://localhost:80 i tunneln, och en DNS-post *.automateit.se.
Ny konfiguration från GitHub:  sudo edge-update
Loggar:                        docker logs -f edge
EOF
