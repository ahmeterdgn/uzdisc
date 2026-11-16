#!/usr/bin/env bash
# README ekran görüntüleri için örnek içerikli exFAT kalıbı üretir → build/demo/Demo-Disk.img
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/demo
OUT="$PWD/build/demo"

docker run --rm --privileged -v "$OUT:/out" ubuntu:24.04 bash -euo pipefail -c '
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq exfatprogs exfat-fuse util-linux coreutils imagemagick >/dev/null 2>&1
IMG=/out/Demo-Disk.img
rm -f $IMG; truncate -s 3G $IMG
mkfs.exfat -L "Demo Disk" $IMG >/dev/null
L=$(losetup -f --show $IMG); M=/mnt/d; mkdir -p $M; mount.exfat-fuse $L $M

img() { # img <yol> <tarih>  — gerçek görsel (küçük resimler için)
  mkdir -p "$(dirname "$M/$1")"
  convert -size 1600x1100 plasma:fractal -blur 0x2 -modulate 100,140 "/tmp/x.${1##*.}" 2>/dev/null || convert -size 1600x1100 gradient:"#2b5876"-"#4e4376" "/tmp/x.${1##*.}"
  cp "/tmp/x.${1##*.}" "$M/$1"; touch -d "$2" "$M/$1"
}
f() { # f <yol> <boyut> <tarih>
  mkdir -p "$(dirname "$M/$1")"
  head -c "$2" /dev/urandom > "$M/$1"
  touch -d "$3" "$M/$1"
}
img "Fotoğraflar/Tatil 2026/IMG_4182.jpg" "2026-08-14 10:21"
img "Fotoğraflar/Tatil 2026/IMG_4183.jpg" "2026-08-14 10:22"
img "Fotoğraflar/Tatil 2026/IMG_4187.jpg" "2026-08-14 18:40"
f "Fotoğraflar/Tatil 2026/IMG_4201.MOV"  48000000 "2026-08-15 20:05"
img "Fotoğraflar/Tatil 2026/IMG_4210.jpg" "2026-08-16 09:12"
img "Fotoğraflar/Tatil 2026/Panorama_Kaş.jpg" "2026-08-16 19:31"
img "Fotoğraflar/Tatil 2026/IMG_4233.jpg" "2026-08-17 12:03"
img "Fotoğraflar/Tatil 2026/IMG_4240.jpg" "2026-08-17 17:44"
f "Fotoğraflar/Mezuniyet/DSC_0912.NEF"   26000000 "2026-06-28 15:10"
f "Fotoğraflar/Mezuniyet/DSC_0913.NEF"   25500000 "2026-06-28 15:11"
img "Fotoğraflar/Profil.png" "2026-03-02 11:00"
f "Belgeler/Tez_Son_Hali_v7.docx"         1840000 "2026-11-12 23:48"
f "Belgeler/Tez_Sunumu.key"              38000000 "2026-11-13 02:15"
f "Belgeler/Fatura_Ekim_2026.pdf"          212000 "2026-10-31 09:30"
f "Belgeler/Kira_Sözleşmesi.pdf"           980000 "2026-01-05 14:20"
f "Belgeler/Bütçe 2026.xlsx"               164000 "2026-11-01 21:07"
f "Belgeler/CV_2026.pdf"                   148000 "2026-09-18 16:45"
f "Belgeler/notlar.txt"                      4200 "2026-11-15 22:10"
f "Projeler/uzdisc/main.swift"              12000 "2026-11-16 18:30"
f "Projeler/web-sitesi.zip"              74000000 "2026-10-20 13:55"
f "Projeler/oyun-prototipi/oyun.js"         58000 "2026-09-02 20:12"
f "Müzik/Barış Manço - Gülpembe.flac"    31000000 "2025-12-24 19:00"
f "Müzik/Sezen Aksu - Firuze.mp3"         8600000 "2025-12-24 19:02"
f "Müzik/Tarkan - Kuzu Kuzu.m4a"          7900000 "2025-12-24 19:05"
f "Videolar/Düğün_Videosu_Final.mp4"    420000000 "2026-07-04 23:59"
f "Videolar/Ekran Kaydı 2026-11-02.mov"  96000000 "2026-11-02 14:31"
f "Yedekler/iPhone_Yedek_2026-10.zip"   180000000 "2026-10-28 03:00"
f "Yedekler/Telefon Rehberi.vcf"            48000 "2026-10-28 03:01"
f "README.txt"                               1200 "2026-11-16 09:00"
for d in Fotoğraflar/Mezuniyet "Fotoğraflar/Tatil 2026" Fotoğraflar Belgeler Projeler/uzdisc Projeler/oyun-prototipi Projeler Müzik Videolar Yedekler; do touch -d "2026-11-14 12:00" "$M/$d"; done
sync; umount $M; losetup -d $L
ls -la /out
'
