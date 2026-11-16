#!/usr/bin/env bash
# Test disk kalıplarını Linux'un gerçek mkfs araçlarıyla üretir (Docker gerekir).
# Çıktı: Tests/UzDiscCoreTests/Fixtures/*.img.gz ve manifest.txt
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$PWD/Tests/UzDiscCoreTests/Fixtures"
mkdir -p "$OUT"

docker run --rm --privileged -v "$OUT:/out" ubuntu:24.04 bash -euo pipefail -c '
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq exfatprogs exfat-fuse dosfstools ntfs-3g attr util-linux coreutils >/dev/null

# Örnek ağaç
T=/tree; rm -rf $T; mkdir -p $T
printf "Merhaba UzDisc!\n" > $T/hello.txt
: > $T/empty.bin
mkdir -p "$T/Türkçe Klasör ğüşıöç"
printf "çğıöşü ÇĞİÖŞÜ\n" > "$T/Türkçe Klasör ğüşıöç/çılgın dosya adı.txt"
printf "uzun ad\n" > "$T/Bu çok uzun bir dosya adıdır ve 8.3 biçimine kesinlikle sığmaz - test.txt"
seq 1 400000 > $T/big.txt
mkdir -p $T/a/b/c/d; printf "derin\n" > $T/a/b/c/d/deep.txt
mkdir -p $T/many
for i in $(seq -w 1 300); do printf "dosya %s\n" $i > $T/many/f$i.txt; done
head -c 70000 /dev/urandom > $T/random.bin

populate() { # $1 = bağlama noktası
  cp -r $T/. "$1"/
  # Parçalı dosyalar: iki dosyaya sırayla ekle
  for i in $(seq 1 40); do
    seq $((i*1000)) $((i*1000+999)) >> "$1/frag1.txt"; sync
    seq $((i*2000)) $((i*2000+999)) >> "$1/frag2.txt"; sync
  done
}

mk_manifest() { # $1 = bağlama noktası, $2 = ad
  (cd "$1" && find . -type f ! -path "./System Volume Information/*" -print0 | sort -z | xargs -0 sha256sum | sed "s#  \./#  #") > /out/$2.manifest
}

M=/mnt/x; mkdir -p $M

# exFAT (4 KB küme)
truncate -s 24M /tmp/exfat.img
mkfs.exfat -L UZEXFAT -c 4K /tmp/exfat.img >/dev/null
L=$(losetup -f --show /tmp/exfat.img); mount.exfat-fuse $L $M; populate $M; mk_manifest $M exfat; umount $M; losetup -d $L

# FAT32 (512 B küme, LFN)
truncate -s 40M /tmp/fat32.img
mkfs.fat -F 32 -s 1 -S 512 -n UZFAT32 /tmp/fat32.img >/dev/null
mount -o loop,utf8 /tmp/fat32.img $M; populate $M; mk_manifest $M fat32; umount $M

# FAT16
truncate -s 16M /tmp/fat16.img
mkfs.fat -F 16 -n UZFAT16 /tmp/fat16.img >/dev/null
mount -o loop,utf8 /tmp/fat16.img $M; populate $M; mk_manifest $M fat16; umount $M

# NTFS (ntfs-3g, sıkıştırılmış ve seyrek dosyalarla)
truncate -s 24M /tmp/ntfs.img
mkntfs -F -Q -L UZNTFS /tmp/ntfs.img >/dev/null 2>&1
if ntfs-3g -o compression /tmp/ntfs.img $M 2>/dev/null; then
  populate $M
  mkdir $M/compressed
  setfattr -n system.ntfs_attrib_be -v 0x00000800 $M/compressed
  seq 1 200000 > $M/compressed/seq.txt
  head -c 300000 /dev/urandom > $M/compressed/random.bin
  truncate -s 5M $M/sparse.bin; printf "son\n" >> $M/sparse.bin
  mk_manifest $M ntfs; umount $M
else
  echo "UYARI: ntfs-3g bağlanamadı, ntfs kalıbı atlanıyor" >&2
  rm -f /tmp/ntfs.img
fi

for f in exfat fat32 fat16 ntfs; do [ -f /tmp/$f.img ] && gzip -9c /tmp/$f.img > /out/$f.img.gz; done
ls -la /out
'
