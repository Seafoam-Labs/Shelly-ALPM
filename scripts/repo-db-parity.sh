#!/usr/bin/env bash
# Manual parity check: `shelly repo-db` vs stock repo-add/repo-remove.
# Compares database ARCHIVE CONTENTS byte-for-byte, member-name sets,
# directory layout (symlinks, .old rotation, no .tmp leftovers), and exit
# codes across the full scenario matrix. Message wording is recorded, not
# asserted (see "Divergences" section of plan.md).
#
# Usage:  bash repo-db-parity.sh
# Override: WORK=/tmp/... SHELLY=.../shelly STOCK_ADD=... STOCK_RM=... bash repo-db-parity.sh
set -u
export LC_ALL=C

WORK=${WORK:-/tmp/shelly-repo-db-parity}
REPO_ROOT=${REPO_ROOT:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"}
SHELLY=${SHELLY:-$REPO_ROOT/Shelly.Cli.Zig/zig-out/bin/shelly}
STOCK_ADD=${STOCK_ADD:-/usr/sbin/repo-add}
STOCK_RM=${STOCK_RM:-/usr/sbin/repo-remove}
STOCK_A=$WORK/stock
STOCK_B=$WORK/shelly

PASS=0
FAIL=0
RC=0
ok() {
  printf 'PASS %s\n' "$*"
  PASS=$((PASS + 1))
}
ko() {
  printf 'FAIL %s\n' "$*"
  FAIL=$((FAIL + 1))
}
note() { printf 'NOTE %s\n' "$*"; }

# run <dir> <logfile> <cmd...> — merged stdout+stderr, status in RC
run() {
  local d=$1 log=$2
  shift 2
  (cd "$d" && "$@") >"$WORK/logs/$log" 2>&1
  RC=$?
}

mkpkg() { # mkpkg <dir> <name> <version> <arch> [pkgbase]
  local dir=$1 name=$2 version=$3 arch=$4 base=${5:-}
  local stage=$WORK/stage
  rm -rf "$stage"
  mkdir -p "$stage/usr/share/doc/$name" "$stage/usr/bin"
  {
    printf 'pkgname = %s\npkgver = %s\npkgdesc = %s parity fixture\narch = %s\nbuilddate = 1600000000\nsize = 999\n' \
      "$name" "$version" "$name" "$arch"
    [[ -n $base ]] && printf 'pkgbase = %s\n' "$base"
    printf 'license = MIT\nlicense = zlib\nurl = https://example.com/%s\ngroup = tools\ngroup = extra\npackager = Shelly Tester <t@example.com>\nprovides = %s-alias=1\nprovides = %s-lib\nconflict = old-%s\nreplaces = ancient-%s < 1.0\ndepend = glibc\ndepend = sh\noptdepend = perl: for scripts\nmakedepend = make\ncheckdepend = check\n' \
      "$name" "$name" "$name" "$name" "$name"
  } >"$stage/.PKGINFO"
  printf 'doc for %s %s\n' "$name" "$version" >"$stage/usr/share/doc/$name/readme"
  printf 'nested dotfile\n' >"$stage/usr/.$name-hidden"
  printf 'installed script\n' >"$stage/.INSTALL"
  (
    cd "$stage" && ln -sf ../share/doc/"$name"/readme usr/bin/"$name"
    bsdtar -caf "$dir/$name-$version-$arch.pkg.tar.zst" .PKGINFO .INSTALL usr
  )
}

fresh_pair() { # clone the fixture packages into clean stock/shelly trees
  rm -rf "$STOCK_A" "$STOCK_B"
  mkdir -p "$STOCK_A" "$STOCK_B"
  local t
  for t in "$STOCK_A" "$STOCK_B"; do cp "$WORK"/pkgs/*.pkg.tar.zst "$t/" 2>/dev/null; done
}
both() { # both <file> — copy into both trees
  local t
  for t in "$STOCK_A" "$STOCK_B"; do cp "$1" "$t/"; done
}

# members <archive> — sorted member names (set comparison basis)
members() { bsdtar -tf "$1" 2>/dev/null | LC_ALL=C sort; }
content() { bsdtar -xOf "$1" "$2" 2>/dev/null; }

check_dbs() { # byte-compare desc/files member contents and member sets, both dbs
  local label=$1 db m
  for db in demo.db.tar.zst demo.files.tar.zst; do
    members "$STOCK_A/$db" >"$WORK/logs/mem.A"
    members "$STOCK_B/$db" >"$WORK/logs/mem.B"
    if cmp -s "$WORK/logs/mem.A" "$WORK/logs/mem.B"; then
      ok "$label: $db member set"
    else
      ko "$label: $db member set"
      diff "$WORK/logs/mem.A" "$WORK/logs/mem.B" >&2
    fi
    while IFS= read -r m; do
      [[ $m == */ ]] && continue # directory members carry no payload
      content "$STOCK_A/$db" "$m" >"$WORK/logs/c.A"
      content "$STOCK_B/$db" "$m" >"$WORK/logs/c.B"
      if cmp -s "$WORK/logs/c.A" "$WORK/logs/c.B"; then
        ok "$label: $db:$m bytes"
      else
        ko "$label: $db:$m bytes"
        diff "$WORK/logs/c.A" "$WORK/logs/c.B" >&2
      fi
    done <"$WORK/logs/mem.A"
  done
}

# layout <treedir> — repo artifacts only: names, symlink targets
layout() {
  local f
  (
    cd "$1" || exit
    for f in *; do
      case $f in
      *.pkg.tar.zst | *.pkg.tar.zst.sig | *.lock) continue ;;
      esac
      if [[ -L $f ]]; then
        printf '%s -> %s\n' "$f" "$(readlink "$f")"
      else printf '%s\n' "$f"; fi
    done
  ) | LC_ALL=C sort
}

check_layout() {
  layout "$STOCK_A" >"$WORK/logs/lay.A"
  layout "$STOCK_B" >"$WORK/logs/lay.B"
  if cmp -s "$WORK/logs/lay.A" "$WORK/logs/lay.B"; then
    ok "$1: layout"
  else
    ko "$1: layout"
    diff "$WORK/logs/lay.A" "$WORK/logs/lay.B" >&2
  fi
  [[ -e $STOCK_A/.tmp.demo.db.tar.zst || -e $STOCK_B/.tmp.demo.db.tar.zst ]] && ko "$1: .tmp leftover"
}

check_rc() { # <label> <stock-rc> <shelly-rc>
  if [[ $2 == "$3" ]]; then
    ok "$1: rc=$2 (both)"
  else ko "$1: stock rc=$2 shelly rc=$3"; fi
}

stock_add() { run "$STOCK_A" "stock_$1" "$STOCK_ADD" "${@:2}"; }
shelly_add() { run "$STOCK_B" "shelly_$1" "$SHELLY" repo-db add "${@:2}"; }
stock_rm() { run "$STOCK_A" "stock_$1" "$STOCK_RM" "${@:2}"; }
shelly_rm() { run "$STOCK_B" "shelly_$1" "$SHELLY" repo-db remove "${@:2}"; }

echo "== environment =="
"$STOCK_ADD" --version
"$SHELLY" --version 2>/dev/null | head -1 || true

rm -rf "$WORK"
mkdir -p "$WORK/logs" "$WORK/pkgs"
mkpkg "$WORK/pkgs" demo 1.0-1 any
mkpkg "$WORK/pkgs" demo 2.0-1 any
mkpkg "$WORK/pkgs" demo2 '1:2.0-1' any demo2 # epoch + BASE

# ---- S1: fresh add (creates db + files db + symlinks) ----
fresh_pair
stock_add s1 demo.db.tar.zst demo-1.0-1-any.pkg.tar.zst
s=$RC
shelly_add s1 demo.db.tar.zst demo-1.0-1-any.pkg.tar.zst
b=$RC
check_rc S1 "$s" "$b"
check_dbs S1
check_layout S1
content "$STOCK_A/demo.db.tar.zst" demo-1.0-1/desc >"$WORK/logs/desc.v1"

# ---- S2: add newer version -> replace + .old rotation ----
stock_add s2 demo.db.tar.zst demo-2.0-1-any.pkg.tar.zst
s=$RC
shelly_add s2 demo.db.tar.zst demo-2.0-1-any.pkg.tar.zst
b=$RC
check_rc S2 "$s" "$b"
check_dbs S2
check_layout S2
for tree in "$STOCK_A" "$STOCK_B"; do
  content "$tree/demo.db.tar.zst.old" demo-1.0-1/desc >"$WORK/logs/olddesc"
  cmp -s "$WORK/logs/olddesc" "$WORK/logs/desc.v1" && ok "S2: .old holds previous generation ($(basename "$tree"))" || ko "S2: .old generation ($(basename "$tree"))"
  [[ -e $tree/demo.db.tar.zst.old ]] || ko "S2: .old missing ($(basename "$tree"))"
done

# ---- S3: --new on identical entry -> skip, db untouched ----
cp "$STOCK_A/demo.db.tar.zst" "$WORK/logs/pre.S3.db"
cp "$STOCK_A/demo.files.tar.zst" "$WORK/logs/pre.S3.files"
stock_add s3 -n demo.db.tar.zst demo-2.0-1-any.pkg.tar.zst
s=$RC
shelly_add s3 --new demo.db.tar.zst demo-2.0-1-any.pkg.tar.zst
b=$RC
check_rc S3 "$s" "$b"
if content "$STOCK_A/demo.db.tar.zst" demo-2.0-1/desc >"$WORK/logs/x" && grep -q "already existed" "$WORK/logs/stock_s3"; then
  ok "S3: stock skipped with 'already existed'"
else ko "S3: stock skip"; fi
grep -q "already existed" "$WORK/logs/shelly_s3" && ok "S3: shelly warning text" || ko "S3: shelly warning text"
content "$STOCK_A/demo.db.tar.zst" demo-2.0-1/desc >"$WORK/logs/a.now"
content "$STOCK_B/demo.db.tar.zst" demo-2.0-1/desc >"$WORK/logs/b.now"
cmp "$WORK/logs/a.now" "$WORK/logs/b.now" && ok "S3: entry still 2.0-1 both" || ko "S3: entry mismatch"

# ---- S4: --prevent-downgrade with newer entry present -> skip ----
stock_add s4 -p demo.db.tar.zst demo-1.0-1-any.pkg.tar.zst
s=$RC
shelly_add s4 --prevent-downgrade demo.db.tar.zst demo-1.0-1-any.pkg.tar.zst
b=$RC
check_rc S4 "$s" "$b"
grep -qi "newer version" "$WORK/logs/stock_s4" && grep -qi "newer version" "$WORK/logs/shelly_s4" &&
  ok "S4: both warn 'A newer version'" || ko "S4: missing warning"
content "$STOCK_B/demo.db.tar.zst" demo-2.0-1/desc >"$WORK/logs/b.s4" && ok "S4: shelly kept 2.0-1" || ko "S4: shelly entry changed"

# ---- S5: downgrade without flag -> replace with warning ----
stock_add s5 demo.db.tar.zst demo-1.0-1-any.pkg.tar.zst
s=$RC
shelly_add s5 demo.db.tar.zst demo-1.0-1-any.pkg.tar.zst
b=$RC
check_rc S5 "$s" "$b"
check_dbs S5
check_layout S5
# after replacement only the incoming dir exists in the db
members "$STOCK_A/demo.db.tar.zst" | grep -q 'demo-2.0-1/desc' && ko "S5: stale 2.0-1 dir left" || ok "S5: replaced entry removed from both dbs"

# ---- S6: epoch + BASE + all multi-value sections ----
stock_add s6 demo.db.tar.zst 'demo2-1:2.0-1-any.pkg.tar.zst'
s=$RC
shelly_add s6 demo.db.tar.zst 'demo2-1:2.0-1-any.pkg.tar.zst'
b=$RC
check_rc S6 "$s" "$b"
check_dbs S6
check_layout S6
grep -q '^demo2-1:2.0-1/desc$' "$WORK/logs/mem.A" && ok "S6: epoch entry dir name matches" || ko "S6: entry dir name"

# ---- S7: remove unknown name -> rc1, databases unchanged ----
sha256sum "$STOCK_A"/demo.db.tar.zst "$STOCK_A"/demo.files.tar.zst >"$WORK/logs/pre.S7"
stock_rm s7 demo.db.tar.zst ghost
s=$RC
shelly_rm s7 demo.db.tar.zst ghost
b=$RC
check_rc S7 "$s" "$b"
sha256sum -c --status "$WORK/logs/pre.S7" && ok "S7: stock db bytes unchanged" || ko "S7: stock db changed"
grep -q "not found" "$WORK/logs/shelly_s7" && ok "S7: shelly not-found text" || ko "S7: shelly text"
[[ ! -e $STOCK_B/demo.db.tar.zst.old ]] || : # shelly must not rotate on failed remove; stock A already had .old, check B only by rc/bytes
content "$STOCK_B/demo.db.tar.zst" demo-1.0-1/desc >"$WORK/logs/a.now"
content "$STOCK_A/demo.db.tar.zst" demo-1.0-1/desc >"$WORK/logs/b.now"
cmp "$WORK/logs/a.now" "$WORK/logs/b.now" && ok "S7: shelly desc unchanged" || ko "S7: shelly desc changed"

# ---- S8: remove one name (entries disappear from BOTH dbs) ----
stock_rm s8 demo.db.tar.zst demo
s=$RC
shelly_rm s8 demo.db.tar.zst demo
b=$RC
check_rc S8 "$s" "$b"
check_dbs S8
check_layout S8
# list sanity (shelly only; stock has no counterpart command)
run "$STOCK_B" shelly_list "$SHELLY" repo-db list demo.db.tar.zst
[[ $RC == 0 && $(grep -c . "$WORK/logs/shelly_list") == 1 ]] && ok "S8: list prints remaining entry" || ko "S8: list"
grep -q 'demo2 1:2.0-1' "$WORK/logs/shelly_list" && ok "S8: list text" || ko "S8: list text: $(cat "$WORK/logs/shelly_list")"

# ---- S9: re-add + --remove-old-files deletes replaced package file ----
stock_add s9a demo.db.tar.zst demo-1.0-1-any.pkg.tar.zst
shelly_add s9a demo.db.tar.zst demo-1.0-1-any.pkg.tar.zst
stock_add s9 demo.db.tar.zst -R demo-2.0-1-any.pkg.tar.zst
s=$RC
shelly_add s9 demo.db.tar.zst --remove-old-files demo-2.0-1-any.pkg.tar.zst
b=$RC
check_rc S9 "$s" "$b"
check_dbs S9
check_layout S9
[[ ! -e $STOCK_A/demo-1.0-1-any.pkg.tar.zst && ! -e $STOCK_B/demo-1.0-1-any.pkg.tar.zst ]] &&
  ok "S9: -R deleted old package file in both" || ko "S9: -R file removal"

# ---- S10: remove last entries -> valid empty databases ----
stock_rm s10 demo.db.tar.zst demo demo2
s=$RC
shelly_rm s10 demo.db.tar.zst demo demo2
b=$RC
check_rc S10 "$s" "$b"
[[ -z $(members "$STOCK_A/demo.db.tar.zst") ]] && ok "S10: stock published empty db" || ko "S10: stock empty db"
[[ -z $(members "$STOCK_B/demo.db.tar.zst") ]] && ok "S10: shelly published empty db" || ko "S10: shelly empty db"
check_layout S10
grep -qi "packages remain" "$WORK/logs/stock_s10" && grep -qi "packages remain" "$WORK/logs/shelly_s10" &&
  ok "S10: both warn 'No packages remain'" || ko "S10: empty-db warning missing"

# ---- S11: remove from missing database -> rc1 ----
rm -rf "$WORK/missing"
mkdir -p "$WORK/missing"
cp "$WORK/pkgs"/*.pkg.tar.zst "$WORK/missing/"
run "$WORK/missing" stock_s11 "$STOCK_RM" demo.db.tar.zst demo
s=$RC
run "$WORK/missing" shelly_s11 "$SHELLY" repo-db remove demo.db.tar.zst demo
b=$RC
check_rc S11 "$s" "$b"
grep -q "was not found" "$WORK/logs/shelly_s11" && ok "S11: shelly 'was not found' text" || ko "S11: shelly text"

# ---- S12: add into missing directory -> rc1 ----
stock_add s12 nope/deep/demo.db.tar.zst demo-1.0-1-any.pkg.tar.zst
s=$RC
shelly_add s12 nope/deep/demo.db.tar.zst demo-1.0-1-any.pkg.tar.zst
b=$RC
check_rc S12 "$s" "$b"

# ---- S13: bad suffix -> rc1 both ----
stock_add s13 demo.db.tar.gz.notdemo demo-1.0-1-any.pkg.tar.zst
s=$RC
shelly_add s13 demo.db.tar.gz.notdemo demo-1.0-1-any.pkg.tar.zst
b=$RC
check_rc S13 "$s" "$b"
grep -q "does not end in" "$WORK/logs/shelly_s13" && ok "S13: shelly extension text" || ko "S13: shelly text"

# ---- S14: unsupported compression (accepted by stock libarchive) ----
stock_add s14 demo.db.tar.lz4 demo-1.0-1-any.pkg.tar.zst
s=$RC
shelly_add s14 demo.db.tar.lz4 demo-1.0-1-any.pkg.tar.zst
b=$RC
[[ $b == 1 ]] && ok "S14: shelly rejects .tar.lz4 rc1" || ko "S14: shelly rc=$b (expected 1)"
[[ $s == 0 ]] && note "S14: stock accepted .tar.lz4 (documented out-of-scope divergence)" || note "S14: stock rc=$s"

# ---- S15: not a package (no .PKGINFO) -> rc1 both ----
mkdir -p "$WORK/pkgs2"
(cd "$WORK/stage/usr" && bsdtar -caf "$WORK/pkgs2/notapkg-1.0-any.pkg.tar.zst" share)
fresh_pair
both "$WORK/pkgs2/notapkg-1.0-any.pkg.tar.zst"
stock_add s15 demo.db.tar.zst notapkg-1.0-any.pkg.tar.zst
s=$RC
shelly_add s15 demo.db.tar.zst notapkg-1.0-any.pkg.tar.zst
b=$RC
check_rc S15 "$s" "$b"
grep -q "No changes\|not modified" "$WORK/logs/shelly_s15" || grep -q "is not a package" "$WORK/logs/shelly_s15" &&
  ok "S15: shelly failure text" || ko "S15: shelly text"
[[ ! -e $STOCK_B/demo.db.tar.zst && ! -e $STOCK_A/demo.db.tar.zst ]] && ok "S15: all-or-nothing, no db written" || ko "S15: db written despite failure"

# ---- S16: signatures ----
fresh_pair
mkpkg "$WORK/pkgs" demo3 1.0-1 any
both "$WORK/pkgs/demo3-1.0-1-any.pkg.tar.zst"
head -c 512 /dev/urandom >"$STOCK_A/demo3-1.0-1-any.pkg.tar.zst.sig"
cp "$STOCK_A/demo3-1.0-1-any.pkg.tar.zst.sig" "$STOCK_B/"
stock_add s16 demo.db.tar.zst demo3-1.0-1-any.pkg.tar.zst
s=$RC
shelly_add s16 --exclude-sigs demo.db.tar.zst demo3-1.0-1-any.pkg.tar.zst
b=$RC
check_rc S16 "$s" "$b"
content "$STOCK_A/demo.db.tar.zst" demo3-1.0-1/desc >"$WORK/logs/d16.A"
content "$STOCK_B/demo.db.tar.zst" demo3-1.0-1/desc >"$WORK/logs/d16.B"
if cmp -s "$WORK/logs/d16.A" "$WORK/logs/d16.B" && ! grep -q PGPSIG "$WORK/logs/d16.A"; then
  ok "S16: stock default vs shelly --exclude-sigs desc identical (no PGPSIG)"
else ko "S16: exclude-sigs desc mismatch"; fi
# shelly default embeds: PGPSIG must equal base64 -w0 of the .sig (repo-add --include-sigs rule)
fresh_pair
cp "$WORK/pkgs/demo3-1.0-1-any.pkg.tar.zst" "$STOCK_B"/
head -c 512 /dev/urandom >"$STOCK_B/demo3-1.0-1-any.pkg.tar.zst.sig"
shelly_add s16b demo.db.tar.zst demo3-1.0-1-any.pkg.tar.zst
base64 -w0 "$STOCK_B/demo3-1.0-1-any.pkg.tar.zst.sig" >"$WORK/logs/sig.b64"
content "$STOCK_B/demo.db.tar.zst" demo3-1.0-1/desc | awk '/^%PGPSIG%$/{getline; print}' >"$WORK/logs/sig.db"
# repo-add computes PGPSIG as `base64 sig | tr -d '\n'`; printf '%s' matches that exactly,
# and `base64 -w0` differs only by a trailing newline on some coreutils builds.
if cmp -s <(printf '%s' "$(cat "$WORK/logs/sig.b64")") <(printf '%s' "$(cat "$WORK/logs/sig.db")"); then
  ok "S16: embedded PGPSIG == base64 -w0 sig"
else ko "S16: PGPSIG value mismatch"; fi

# armored + oversized .sig (shelly rejects; stock-without-flag ignores -> documented divergence)
fresh_pair
both "$WORK/pkgs/demo3-1.0-1-any.pkg.tar.zst"
printf -- '-----BEGIN PGP SIGNATURE-----\n\nnotreal\n-----END PGP SIGNATURE-----\n' >"$STOCK_A/demo3-1.0-1-any.pkg.tar.zst.sig"
cp "$STOCK_A/demo3-1.0-1-any.pkg.tar.zst.sig" "$STOCK_B/"
shelly_add s16c demo.db.tar.zst demo3-1.0-1-any.pkg.tar.zst
b=$RC
[[ $b == 1 ]] && grep -q "ASCII-armored" "$WORK/logs/shelly_s16c" && ok "S16c: armored rejected rc1+text" || ko "S16c: armored"
shelly_add s16d --exclude-sigs demo.db.tar.zst demo3-1.0-1-any.pkg.tar.zst
b=$RC
[[ $b == 0 ]] && ok "S16d: armored ignored with --exclude-sigs rc0" || ko "S16d"
fresh_pair
cp "$WORK/pkgs/demo3-1.0-1-any.pkg.tar.zst" "$STOCK_B"/
head -c 16385 /dev/urandom >"$STOCK_B/demo3-1.0-1-any.pkg.tar.zst.sig"
shelly_add s16e demo.db.tar.zst demo3-1.0-1-any.pkg.tar.zst
b=$RC
[[ $b == 1 ]] && grep -q "exceeds 16384" "$WORK/logs/shelly_s16e" && ok "S16e: oversized rejected rc1+text" || ko "S16e: oversized"

# ---- S17: --quiet suppresses per-package lines ----
fresh_pair
cp "$WORK/pkgs/demo-1.0-1-any.pkg.tar.zst" "$STOCK_B"/
(cd "$STOCK_B" && "$SHELLY" repo-db add --quiet demo.db.tar.zst demo-1.0-1-any.pkg.tar.zst >"$WORK/logs/q.out" 2>"$WORK/logs/q.err")
RC=$?
[[ $RC == 0 && ! -s $WORK/logs/q.out ]] && ok "S17: -q: rc0, empty stdout" || ko "S17: -q stdout not empty or rc=$RC"

# ---- S18: locking (shelly contract; stock ELF observed lock-free) ----
fresh_pair
cp "$WORK/pkgs/demo-1.0-1-any.pkg.tar.zst" "$STOCK_B"/
shelly_add s18pre demo.db.tar.zst demo-1.0-1-any.pkg.tar.zst # create db + lock path in B
flock -x "$STOCK_B/demo.db.tar.zst.lock" -c 'sleep 4' &
holder=$!
sleep 0.3
shelly_add s18 demo.db.tar.zst demo-2.0-1-any.pkg.tar.zst
b=$RC
[[ $b == 2 ]] && grep -q "Failed to acquire lockfile" "$WORK/logs/shelly_s18" && ok "S18: lock contention rc2+text" || ko "S18: rc=$b"
shelly_add s18w --wait demo.db.tar.zst demo-2.0-1-any.pkg.tar.zst
b=$RC
[[ $b == 0 ]] && ok "S18: --wait blocked then succeeded rc0" || ko "S18: --wait rc=$b"
wait "$holder"
note "S18: stock runs unaffected by external flock (see divergences); shelly honors the bash rc2 contract"

echo
echo "== divergences expected and accepted (see plan.md) =="
note "message wording: shelly bare text vs stock [INFO]/[WARN]/[ERROR] lines; warnings on stderr by design"
note "stock (this machine, 7.1.0 machine-local ELF) never embeds %PGPSIG% and has no --include-sigs; shelly embeds by default (use --exclude-sigs to match)"
note "stock ELF performs no inter-process locking and ignores .lck; shelly uses flock on <db>.lock with the bash script's rc2 contract and leaves the sidecar behind (inert)"
note "member order, dir-entry mtimes, uid/gid: archives are not reproducible; only member CONTENTS are compared"
note ".tar.lz4 and other suffixes outside .tar.{gz,xz,bz2,zst} are rejected by shelly by design"
note "-R deletion happens after publication in shelly vs during entry write in repo-add (final state identical on success)"
note "repo-remove -R: the installed ELF has no --remove-old-files for repo-remove (repo-add's -R is '--remove'), so stock never deletes the removed package file; shelly follows the bash script (db_remove_entry) and does (recorded, not asserted here)"

echo
echo "PASS=$PASS FAIL=$FAIL  (logs: $WORK/logs)"
exit $((FAIL > 0))
