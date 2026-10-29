#!/bin/bash
# build-repo.sh against a fake live site. Run in a throwaway container:
#   podman run --rm --platform linux/amd64 -v "$PWD":/repo:ro debian:trixie bash /repo/tests/test-build-repo.sh
set -u
export DEBIAN_FRONTEND=noninteractive
apt-get update -q >/dev/null && apt-get install -yq --no-install-recommends \
    gnupg gpgv apt-utils curl dpkg-dev python3 ca-certificates >/dev/null || exit 1
T=$(mktemp -d)
export GNUPGHOME=$T/gnupg
install -d -m 700 "$GNUPGHOME"
printf 'Key-Type: eddsa\nKey-Curve: ed25519\nKey-Usage: sign\nName-Real: test\nPassphrase: s3cret\n%%commit\n' > "$T/kp"
gpg --batch --gen-key "$T/kp" 2>/dev/null
export SIGNING_FPR=$(gpg --with-colons -K | awk -F: '$1 == "fpr" { print $10; exit }') APT_SIGNING_PASSPHRASE=s3cret
cp -r /repo "$T/r"
gpg --export "$SIGNING_FPR" > "$T/r/schema-init-archive-keyring.gpg"
fails=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fails=1; }

# Serves a directory; for X with X.truncate beside it, promises 100 more bytes
# than it sends, so curl exits 18 after a 200.
cat > "$T/srv.py" <<'PY'
import http.server, os, sys
class H(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        p = self.translate_path(self.path)
        if os.path.exists(p + ".truncate"):
            data = open(p, "rb").read()
            self.send_response(200)
            self.send_header("Content-Length", str(len(data) + 100))
            self.end_headers()
            self.wfile.write(data)
            self.wfile.flush()
            self.close_connection = True
            return
        super().do_GET()
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", 8000), lambda *a: H(*a, directory=sys.argv[1])).serve_forever()
PY
P=
serve() { [ -z "$P" ] || kill "$P"; python3 "$T/srv.py" "$1" & P=$!; sleep 1; }
build() { bash "$T/r/tools/build-repo.sh" "$1" "$2" "$3" http://127.0.0.1:8000 > "$T/out" 2>&1; }

mk() {
    local d=$T/src/$1_$2
    mkdir -p "$d/DEBIAN" "$3"
    printf 'Package: schema-init\nVersion: %s\nArchitecture: %s\nMaintainer: t <t@t>\nDescription: t\n' "$1" "$2" > "$d/DEBIAN/control"
    dpkg-deb -b --root-owner-group "$d" "$3/schema-init_$1_$2.deb" >/dev/null
}
for i in 1 2 3 4 5 6; do for a in amd64 arm64 armhf; do mk "0.4.20-1.$((1330 + i)).20261028gitabc$i" $a "$T/n1"; done; done
for i in 7 8 9 10 11 12; do for a in amd64 arm64 armhf; do mk "0.4.20-1.$((1330 + i)).20261028gitabc$i" $a "$T/n2"; done; done
for a in amd64 arm64 armhf; do mk 0.4.20-1 $a "$T/st"; done
mk 0.4.20-1.1400.20261028gitzzz amd64 "$T/n3"

# 1. first publish: nothing live, every 404 is fine
mkdir "$T/empty"; serve "$T/empty"
if build stable "$T/st" "$T/s1" && grep -q 'live site: 0' "$T/out"; then ok "first publish on an empty site"; else cat "$T/out"; bad "first publish"; fi
# 2. normal update on top of it
serve "$T/s1"
if build dev "$T/n1" "$T/s2" && grep -q 'live site: 1' "$T/out" \
    && [ "$(grep -c ^Package "$T/s2/dists/stable/main/binary-amd64/Packages")" = 1 ]; then ok "update keeps stable"; else cat "$T/out"; bad "update"; fi
serve "$T/s2"
if build dev "$T/n2" "$T/s3" && [ "$(grep -c '^prune dev' "$T/out")" = 6 ]; then ok "prune to 10 per arch"; else cat "$T/out"; bad "prune"; fi

# 3. live site missing one Packages: fatal, no signed output
cp -r "$T/s3" "$T/live"; rm "$T/live/dists/stable/main/binary-arm64/Packages"; serve "$T/live"
if build dev "$T/n3" "$T/s4"; then bad "missing Packages accepted"; elif grep -q 'live site has no stable/arm64 Packages' "$T/out" && [ ! -e "$T/s4/dists/dev/InRelease" ]; then ok "missing Packages on a live site is fatal"; else cat "$T/out"; bad "missing Packages: wrong failure"; fi

# 4. truncated deb transfer: curl exit 18 is fatal
rm -rf "$T/live"; cp -r "$T/s3" "$T/live"
d=$(ls "$T"/live/pool/main/s/schema-init/*_armhf.deb | head -1); : > "$d.truncate"; serve "$T/live"
if build dev "$T/n3" "$T/s5"; then bad "truncated deb accepted"; elif grep -q 'curl exit 18' "$T/out"; then ok "truncated deb is fatal"; else cat "$T/out"; bad "truncated: wrong failure"; fi

# 5. deb that does not match the live Packages SHA256: fatal
rm -rf "$T/live"; cp -r "$T/s3" "$T/live"
d=$(ls "$T"/live/pool/main/s/schema-init/*_arm64.deb | head -1); printf x >> "$d"; serve "$T/live"
if build dev "$T/n3" "$T/s6"; then bad "corrupt deb accepted"; elif grep -q 'sha256 mismatch' "$T/out"; then ok "sha256 mismatch is fatal"; else cat "$T/out"; bad "sha256: wrong failure"; fi

# 6. an unreadable new dev deb: dpkg-deb failure in the prune loop is fatal
serve "$T/s3"
mkdir "$T/n4"; printf 'not a deb' > "$T/n4/schema-init_0.4.20-1.1500.20261028gitbad_amd64.deb"
if build dev "$T/n4" "$T/s7"; then bad "garbage deb accepted"; elif grep -q 'no Version in' "$T/out"; then ok "dpkg-deb failure in prune is fatal"; else cat "$T/out"; bad "garbage: wrong failure"; fi

# 7. DROP removes a dev build from the index and the pool, keeps the rest
for h in 1111111 2222222; do mk "0.4.20-1.1600.20261028git$h" amd64 "$T/n5_$h"; done
serve "$T/s3"; build dev "$T/n5_1111111" "$T/s8"; serve "$T/s8"; build dev "$T/n5_2222222" "$T/s9"; serve "$T/s9"
if DROP=1111111 build dev "$T/n3" "$T/s10" && ! grep -q git1111111 "$T/s10/dists/dev/main/binary-amd64/Packages" \
    && grep -q git2222222 "$T/s10/dists/dev/main/binary-amd64/Packages" && ! ls "$T"/s10/pool/main/s/schema-init/*git1111111* >/dev/null 2>&1; then
    ok "DROP removes one dev build"; else cat "$T/out"; bad "DROP"; fi
# 8. a DROP hash matching nothing is fatal (typo guard)
if DROP=fffffff build dev "$T/n3" "$T/s11"; then bad "unmatched DROP accepted"; elif grep -q 'matches no dev deb' "$T/out"; then ok "unmatched DROP is fatal"; else cat "$T/out"; bad "unmatched DROP: wrong failure"; fi

kill "$P"
[ "$fails" = 0 ] && echo "test-build-repo: all ok"
exit $fails
