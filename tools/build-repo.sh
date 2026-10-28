#!/bin/bash
# Rebuild the whole apt site: the live pool plus the new debs, signed
# dists/{stable,dev}. Pages deploys replace the site, so every deb still
# listed live is fetched back first.
# usage: build-repo.sh CHANNEL NEW_DEB_DIR SITE_DIR BASE_URL
# env: SIGNING_FPR, APT_SIGNING_PASSPHRASE (secret key already imported)
set -euo pipefail
CHANNEL=$1 NEW=$2 SITE=$3 BASE=$4
case $CHANNEL in stable | dev) ;; *) echo "bad channel: $CHANNEL" >&2; exit 2 ;; esac
SUITES="stable dev"
ARCHES="amd64 arm64 armhf"
POOL=pool/main/s/schema-init
KEEP_DEV=10
DEB_RE="^schema-init_[A-Za-z0-9.+~-]+_(amd64|arm64|armhf)\.deb$"
HERE=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$SITE/$POOL"
SITE=$(cd "$SITE" && pwd)

# 0 on 200, 1 on 404 (first publish, or a suite never published), else die.
# The query string dodges the Pages CDN cache right after a deploy.
fetch() {
    local code
    code=$(curl -sS -o "$2" -w '%{http_code}' "$1?t=$(date +%s%N)")
    case $code in
    200) return 0 ;;
    404) return 1 ;;
    *) echo "GET $1: HTTP $code" >&2; exit 1 ;;
    esac
}

# Suite membership: an empty marker file $W/<suite>/<deb> per package.
for s in $SUITES; do
    mkdir -p "$W/$s"
    for a in $ARCHES; do
        fetch "$BASE/dists/$s/main/binary-$a/Packages" "$W/Packages" || continue
        sed -n 's/^Filename: //p' "$W/Packages" | while read -r f; do
            b=${f##*/}
            [[ $f == "$POOL/$b" && $b =~ $DEB_RE ]] || { echo "bad Filename in live $s/$a: $f" >&2; exit 1; }
            [ -f "$SITE/$f" ] || fetch "$BASE/$f" "$SITE/$f" || { echo "live $s/$a lists missing $f" >&2; exit 1; }
            : > "$W/$s/$b"
        done
    done
done

for d in "$NEW"/*.deb; do
    b=${d##*/}
    [[ $b =~ $DEB_RE ]] || { echo "bad new deb name: $b" >&2; exit 1; }
    cp "$d" "$SITE/$POOL/$b"
    : > "$W/$CHANNEL/$b"
done

# Newest first by dpkg version order; stable is never pruned.
newest_first() {
    local -a v=() f=()
    local ver file i
    while read -r ver file; do
        i=${#v[@]}
        while [ "$i" -gt 0 ] && dpkg --compare-versions "$ver" gt "${v[i-1]}"; do
            v[i]=${v[i-1]} f[i]=${f[i-1]}
            i=$((i - 1))
        done
        v[i]=$ver f[i]=$file
    done
    [ ${#f[@]} = 0 ] || printf '%s\n' "${f[@]}"
}
for a in $ARCHES; do
    for m in "$W"/dev/*_"$a".deb; do
        [ -e "$m" ] || continue
        b=${m##*/}
        echo "$(dpkg-deb -f "$SITE/$POOL/$b" Version) $b"
    done | newest_first | tail -n +$((KEEP_DEV + 1)) | while read -r b; do
        echo "prune dev: $b"
        rm "$W/dev/$b"
    done
done

for d in "$SITE/$POOL"/*.deb; do
    b=${d##*/}
    [ -e "$W/stable/$b" ] || [ -e "$W/dev/$b" ] || rm "$d"
done

sign() {
    printf '%s' "$APT_SIGNING_PASSPHRASE" | gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 \
        --local-user "$SIGNING_FPR!" --digest-algo SHA512 "$@"
}
for s in $SUITES; do
    mkdir -p "$W/tree-$s/$POOL"
    for m in "$W/$s"/*.deb; do
        [ -e "$m" ] || continue
        cp "$SITE/$POOL/${m##*/}" "$W/tree-$s/$POOL/"
    done
    for a in $ARCHES; do
        out=$SITE/dists/$s/main/binary-$a
        mkdir -p "$out"
        (cd "$W/tree-$s" && apt-ftparchive --arch "$a" packages "$POOL") > "$out/Packages"
        gzip -9nkf "$out/Packages"
    done
    (cd "$SITE/dists/$s" && apt-ftparchive \
        -o APT::FTPArchive::Release::Origin=schema-init \
        -o APT::FTPArchive::Release::Label=schema-init \
        -o APT::FTPArchive::Release::Suite="$s" \
        -o APT::FTPArchive::Release::Codename="$s" \
        -o APT::FTPArchive::Release::Architectures="$ARCHES" \
        -o APT::FTPArchive::Release::Components=main \
        release .) > "$W/Release"
    mv "$W/Release" "$SITE/dists/$s/Release"
    sign --clearsign -o "$SITE/dists/$s/InRelease" "$SITE/dists/$s/Release"
    sign --armor --detach-sign -o "$SITE/dists/$s/Release.gpg" "$SITE/dists/$s/Release"
    # Proves the committed public keyring matches the signing secret.
    gpgv --keyring "$HERE/schema-init-archive-keyring.gpg" "$SITE/dists/$s/InRelease"
    gpgv --keyring "$HERE/schema-init-archive-keyring.gpg" "$SITE/dists/$s/Release.gpg" "$SITE/dists/$s/Release"
    echo "== $s:"; grep -h '^Filename:' "$SITE"/dists/"$s"/main/binary-*/Packages || true
done
cp "$HERE/schema-init-archive-keyring.gpg" "$SITE/"
