#!/usr/bin/env bash
# =============================================================================
# update-pins.sh - lista, elige y fija las versiones de Herdr y Gentle AI de la imagen
#
#   scripts/update-pins.sh list [herdr|gentle-ai|all] [N]   Últimas N (por defecto 5) versiones estables
#   scripts/update-pins.sh choose <herdr|gentle-ai>         Muestra las últimas 5 y te deja elegir cuál fijar
#   scripts/update-pins.sh set <herdr|gentle-ai> <versión>  Fija esa versión (ej.: set herdr 0.9.3)
#   scripts/update-pins.sh latest [herdr|gentle-ai|all]     Fija la última estable, sin preguntar
#
# Reescribe Dockerfile, docker-compose.yml y env.example de forma consistente. Para Herdr toma el
# SHA256 de cada binario de linux (GitHub lo publica como "digest"); Gentle AI se verifica en el build
# con el checksums.txt de su release. Si algo falla no toca ningún archivo.
# Variables: GITHUB_TOKEN (opcional, sube el límite de la API), PINS_ROOT y PINS_FETCH (pruebas).
# =============================================================================
set -Eeuo pipefail

ROOT="${PINS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DEFAULT_COUNT=5

die()  { echo "[error] $*" >&2; exit 1; }
info() { echo "==> $*"; }
usage() { awk 'NR >= 3 { if ($0 ~ /^# =+$/) exit; print }' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

repo_of() {
  case "$1" in
    herdr)     echo "herdrdev/herdr" ;;
    gentle-ai) echo "Gentleman-Programming/gentle-ai" ;;
    *) die "Herramienta desconocida: $1 (usa herdr o gentle-ai)" ;;
  esac
}
version_key_of() { case "$1" in herdr) echo HERDR_VERSION ;; gentle-ai) echo GENTLE_AI_VERSION ;; esac; }

# GET a la API de GitHub (PINS_FETCH la sustituye en las pruebas)
fetch() {
  local url="$1"
  if [[ -n "${PINS_FETCH:-}" ]]; then "$PINS_FETCH" "$url"; return; fi
  local -a auth=(); [[ -n "${GITHUB_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
  curl -fsSL --retry 2 --connect-timeout 10 --max-time 30 -H "Accept: application/vnd.github+json" "${auth[@]}" "$url"
}

# "versión<TAB>fecha" de las releases estables (v<x>.<y>.<z>, sin prerelease/draft), la más nueva primero
stable_versions() {   # stable_versions <herramienta> <N>
  local repo body; repo="$(repo_of "$1")"
  body="$(fetch "https://api.github.com/repos/$repo/releases?per_page=30")" || die "No pude consultar las releases de $1 en GitHub."
  printf '%s' "$body" | perl -MJSON::PP -e '
    local $/; my $r = decode_json(<STDIN>); my @v;
    for my $x (@$r) {
      next if $x->{prerelease} || $x->{draft};
      next unless ($x->{tag_name} // "") =~ /^v(\d+)\.(\d+)\.(\d+)$/;
      my ($a, $b, $c) = ($1, $2, $3); my $d = substr($x->{published_at} // "", 0, 10);
      push @v, [$a, $b, $c, "$a.$b.$c", $d];
    }
    for my $x (sort { $b->[0] <=> $a->[0] || $b->[1] <=> $a->[1] || $b->[2] <=> $a->[2] } @v) { print "$x->[3]\t$x->[4]\n" }
  ' | head -n "$2"
}

# SHA256 de los binarios linux de Herdr de una versión: "amd64 arm64"
herdr_digests() {
  local body; body="$(fetch "https://api.github.com/repos/herdrdev/herdr/releases/tags/v$1")" || die "La versión $1 de herdr no existe en GitHub."
  printf '%s' "$body" | perl -MJSON::PP -e '
    local $/; my $r = decode_json(<STDIN>); my %d;
    for my $a (@{ $r->{assets} // [] }) {
      next unless ($a->{digest} // "") =~ /^sha256:([0-9a-f]{64})$/;
      $d{$a->{name}} = $1;
    }
    exit 3 unless $d{"herdr-linux-x86_64"} && $d{"herdr-linux-aarch64"};
    print "$d{q(herdr-linux-x86_64)} $d{q(herdr-linux-aarch64)}\n";
  ' || die "La release $1 de herdr no trae binarios de linux con checksum publicado; no se puede fijar."
}

gentle_exists() {
  local body; body="$(fetch "https://api.github.com/repos/Gentleman-Programming/gentle-ai/releases/tags/v$1")" || die "La versión $1 de gentle-ai no existe en GitHub."
  printf '%s' "$body" | perl -MJSON::PP -e 'local $/; my $r = decode_json(<STDIN>); exit($r->{prerelease} ? 3 : 0)' \
    || die "La versión $1 de gentle-ai es una prerelease; elige una estable."
}

current_pin() { sed -n -E "s/^ARG $1=\"?([^\" ]*)\"?.*/\1/p" "$ROOT/Dockerfile" | head -n1; }

# Reescribe CLAVE=valor en Dockerfile (ARG), docker-compose.yml (build arg con valor por defecto) y env.example
write_pin() {   # write_pin <CLAVE> <valor>
  export K="$1" V="$2"
  perl -pi -e 's/^ARG \Q$ENV{K}\E=.*/ARG $ENV{K}=$ENV{V}/' "$ROOT/Dockerfile"
  perl -pi -e 's/^(\s+\Q$ENV{K}\E: \$\{\Q$ENV{K}\E:-)[^}]*(\}.*)$/$1$ENV{V}$2/' "$ROOT/docker-compose.yml"
  perl -pi -e 's/^\Q$ENV{K}\E=.*/$ENV{K}=$ENV{V}/' "$ROOT/env.example"
  unset K V
}

check_targets() {   # cada clave debe existir en los 3 archivos: si no, no se escribe nada
  local k
  for k in "$@"; do
    grep -qE "^ARG $k=" "$ROOT/Dockerfile" || die "Dockerfile no tiene ARG $k"
    grep -qE "^[[:space:]]+$k: \\\$\{$k:-" "$ROOT/docker-compose.yml" || die "docker-compose.yml no reenvía $k"
    grep -qE "^$k=" "$ROOT/env.example" || die "env.example no documenta $k"
  done
}

valid_version() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

set_pin() {   # set_pin <herramienta> <versión>
  local tool="$1" ver="${2#v}" amd arm
  repo_of "$tool" >/dev/null
  valid_version "$ver" || die "Versión inválida: '$2' (formato esperado: 1.2.3)"
  case "$tool" in
    herdr)
      read -r amd arm < <(herdr_digests "$ver")
      check_targets HERDR_VERSION HERDR_SHA256_AMD64 HERDR_SHA256_ARM64
      write_pin HERDR_VERSION "$ver"; write_pin HERDR_SHA256_AMD64 "$amd"; write_pin HERDR_SHA256_ARM64 "$arm"
      info "herdr fijado en $ver (sha256 amd64 ${amd:0:12}…, arm64 ${arm:0:12}…)" ;;
    gentle-ai)
      gentle_exists "$ver"
      check_targets GENTLE_AI_VERSION
      write_pin GENTLE_AI_VERSION "$ver"
      info "gentle-ai fijado en $ver (se verifica en el build con el checksums.txt de su release)" ;;
  esac
}

print_list() {   # print_list <herramienta> <N>
  local tool="$1" n="$2" cur i=0 v d mark
  cur="$(current_pin "$(version_key_of "$tool")")"
  echo "Últimas $n versiones estables de $tool:"
  while IFS=$'\t' read -r v d; do
    i=$((i + 1)); mark=""; [[ "$v" == "$cur" ]] && mark="  ← fijada"
    printf '  %d) %s  %s%s\n' "$i" "$v" "$d" "$mark"
  done < <(stable_versions "$tool" "$n")
  (( i > 0 )) || die "No encontré releases estables de $tool."
}

cmd_list() {
  local tool="${1:-all}" n="${2:-$DEFAULT_COUNT}" t
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || die "N debe ser un número: $n"
  if [[ "$tool" == all ]]; then for t in herdr gentle-ai; do print_list "$t" "$n"; done
  else repo_of "$tool" >/dev/null; print_list "$tool" "$n"; fi
}

cmd_choose() {
  local tool="${1:-}" choice versions
  [[ -n "$tool" ]] || die "Indica la herramienta: choose herdr | choose gentle-ai"
  repo_of "$tool" >/dev/null
  versions="$(stable_versions "$tool" "$DEFAULT_COUNT" | cut -f1)"
  [[ -n "$versions" ]] || die "No encontré releases estables de $tool."
  print_list "$tool" "$DEFAULT_COUNT"
  read -rp "Elige 1-$(wc -l <<< "$versions" | tr -d ' ') (Enter cancela): " choice || true
  [[ -n "$choice" ]] || { info "Cancelado; no se cambió nada."; return 0; }
  [[ "$choice" =~ ^[1-9][0-9]*$ ]] || die "Opción inválida: $choice"
  choice="$(sed -n "${choice}p" <<< "$versions")"
  [[ -n "$choice" ]] || die "Ese número no está en la lista."
  set_pin "$tool" "$choice"
}

cmd_latest() {
  local tool="${1:-all}" t v
  for t in herdr gentle-ai; do
    [[ "$tool" == all || "$tool" == "$t" ]] || continue
    v="$(stable_versions "$t" 1 | cut -f1)"
    [[ -n "$v" ]] || die "No encontré releases estables de $t."
    set_pin "$t" "$v"
  done
  [[ "$tool" == all ]] || repo_of "$tool" >/dev/null
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    list)    cmd_list "$@" ;;
    choose)  cmd_choose "$@" ;;
    set)     [[ $# -eq 2 ]] || die "Uso: set <herdr|gentle-ai> <versión>"; set_pin "$1" "$2" ;;
    latest)  cmd_latest "$@" ;;
    -h|--help|help|"") usage ;;
    *) usage >&2; die "Comando desconocido: $cmd" ;;
  esac
}

main "$@"
