#!/bin/sh
# Downloads the general n-gram model (azooKey's base_n5_lm on Hugging Face) that the
# personal language model is compared against, and verifies the pinned SHA-256.
# Needed because the submodule only holds Git LFS pointers without git-lfs installed.
set -eu
dir="$(cd "$(dirname "$0")/.." && pwd)/azooKeyMac/Resources/base_n5_lm"
fetch() {
    name="$1"; expected="$2"
    if [ -f "$dir/$name" ] && [ "$(shasum -a 256 "$dir/$name" | cut -d' ' -f1)" = "$expected" ]; then
        echo "ok $name"; return
    fi
    curl -sSL --fail -o "$dir/$name.download" "https://huggingface.co/Miwa-Keita/base_n5_lm/resolve/main/$name"
    actual="$(shasum -a 256 "$dir/$name.download" | cut -d' ' -f1)"
    [ "$actual" = "$expected" ] || { rm -f "$dir/$name.download"; echo "hash mismatch for $name" >&2; exit 1; }
    mv "$dir/$name.download" "$dir/$name"
    echo "fetched $name"
}
fetch lm_c_abc.marisa ab9cfb9b4231b1187934109776339001a9cb089a9d0fa8ed160c79508c8783a3
fetch lm_r_xbx.marisa f9594d23e2f15a8e6d51811f15b23e23bfc7cefd24b8b1c06f3f0366ce5bf555
fetch lm_u_abx.marisa 6656bb6bea01f75a2156009b7b104adbd6bf897cff47635fd907215f2bc727e9
fetch lm_u_xbc.marisa 69f43384dc45fd16f45e19cbdf242e67f5f8433168dadfe2012abb7657d38041
