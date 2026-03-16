#!/bin/sh -e
#
# Copyright (C) 2021 Xingwang Liao
#

set -e

dir="$(cd "$(dirname "$0")" ; pwd)"

package_name="frp"
golang_commit="$OPENWRT_GOLANG_COMMIT"

cache_dir=${CACHE_DIR:-"~/cache"}

sdk_url_path=${SDK_URL_PATH:-"https://downloads.openwrt.org/snapshots/targets/x86/64"}
sdk_name=${SDK_NAME:-""}

sdk_home=${SDK_HOME:-"~/sdk"}

sdk_home_dir="$(eval echo "$sdk_home")"

test -d "$sdk_home_dir" || mkdir -p "$sdk_home_dir"

sdk_dir="$(eval echo "$cache_dir/sdk")"
dl_dir="$(eval echo "$cache_dir/dl")"
feeds_dir="$(eval echo "$cache_dir/feeds")"

test -d "$sdk_dir" || mkdir -p "$sdk_dir"
test -d "$dl_dir" || mkdir -p "$dl_dir"
test -d "$feeds_dir" || mkdir -p "$feeds_dir"

cd "$sdk_dir"

rm -f sha256sums.small

if ! wget -q -O sha256sums "$sdk_url_path/sha256sums" ; then
	echo "Can not fetch sha256sums from $sdk_url_path."
	exit 1
fi

sdk_match_pattern='openwrt-sdk-.*Linux-x86_64\.tar\.\(xz\|zst\)$'

if [ -n "$sdk_name" ] ; then
	if ! grep -- "$sdk_name" sha256sums > sha256sums.small 2>/dev/null ; then
		echo "Can not find ${sdk_name} file in sha256sums, falling back to automatic SDK detection."
	fi
fi

if [ ! -s sha256sums.small ] ; then
	grep "$sdk_match_pattern" sha256sums | head -n 1 > sha256sums.small 2>/dev/null || true
	if [ ! -s sha256sums.small ] ; then
		echo "Can not find SDK file in sha256sums."
		exit 1
	fi
fi

sdk_file="$(cut -d' ' -f2 < sha256sums.small | sed 's/*//g')"

if ! sha256sum -c ./sha256sums.small >/dev/null 2>&1 ; then
	wget -q -O "$sdk_file" "$sdk_url_path/$sdk_file"

	if ! sha256sum -c ./sha256sums.small >/dev/null 2>&1 ; then
		echo "SDK can not be verified!"
		exit 1
	fi
fi

cd "$dir"

file "$sdk_dir/$sdk_file"
case "$sdk_file" in
	*.tar.xz)
		tar -Jxf "$sdk_dir/$sdk_file" -C "$sdk_home_dir" --strip=1
		;;
	*.tar.zst)
		tar --zstd -xf "$sdk_dir/$sdk_file" -C "$sdk_home_dir" --strip=1
		;;
	*)
		echo "Unsupported SDK archive format: $sdk_file"
		exit 1
		;;
esac

cd "$sdk_home_dir"

( test -d "dl" && rm -rf "dl" ) || true
( test -d "feeds" && rm -rf "feeds" ) || true

ln -sf "$dl_dir" "dl"
ln -sf "$feeds_dir" "feeds"

cp -f feeds.conf.default feeds.conf

# use github repositories
sed -i \
	-e 's#git.openwrt.org/openwrt/openwrt#github.com/openwrt/openwrt#' \
	-e 's#git.openwrt.org/feed/packages#github.com/openwrt/packages#' \
	-e 's#git.openwrt.org/project/luci#github.com/openwrt/luci#' \
	-e 's#git.openwrt.org/feed/telephony#github.com/openwrt/telephony#' \
	feeds.conf

if ! ./scripts/feeds update -a ; then
	missing_feed_index=0

	for feed in base packages luci routing telephony ; do
		if [ ! -s "feeds/${feed}.index" ] ; then
			missing_feed_index=1
			break
		fi
	done

	if [ "$missing_feed_index" -eq 1 ] ; then
		find "feeds" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
		./scripts/feeds update -a || true
	fi
fi

for feed in base packages luci routing telephony ; do
	if [ ! -s "feeds/${feed}.index" ] ; then
		echo "Feed index feeds/${feed}.index is missing."
		exit 1
	fi
done

( test -d "feeds/packages/net/$package_name" && \
	rm -rf "feeds/packages/net/$package_name" ) || true

# replace golang with version defined in env
if [ -n "$golang_commit" ] ; then
	( test -d "feeds/packages/lang/golang" && \
		rm -rf "feeds/packages/lang/golang" ) || true

	curl "https://codeload.github.com/openwrt/packages/tar.gz/$golang_commit" | \
		tar -xz -C "feeds/packages/lang" --strip=2 "packages-$golang_commit/lang/golang"
fi

ln -sf "$dir" "package/$package_name"

./scripts/feeds install -a

make defconfig

make package/${package_name}/clean
make package/${package_name}/compile V=s

cd "$dir"

find "$sdk_home_dir/bin/" -type f -exec ls -lh {} \;

find "$sdk_home_dir/bin/" -type f \( \
	-name "${package_name}*.ipk" -o \
	-name "${package_name}*.apk" \
\) -exec cp -f {} "$dir" \;
