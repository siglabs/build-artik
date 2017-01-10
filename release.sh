#!/bin/bash

set -e

FULL_BUILD=false
VERIFIED_BOOT=false
SECURE_BOOT=false
VBOOT_KEYDIR=
VBOOT_ITS=
SKIP_CLEAN=
SKIP_FEDORA_BUILD=
BUILD_CONF=
PREBUILT_VBOOT_DIR=
DEPLOY=false

print_usage()
{
	echo "-h/--help         Show help options"
	echo "-c/--config       Config file path to build ex) -c config/artik5.cfg"
	echo "-v/--fullver      Pass full version name like: -v A50GC0E-3AF-01030"
	echo "-d/--date		Release date: -d 20150911.112204"
	echo "-m/--microsd	Make a microsd bootable image"
	echo "-u/--url		Specify an url for downloading rootfs"
	echo "-C		fed-artik-build configuration file"
	echo "--full-build	Full build with generating fedora rootfs"
	echo "--local-rootfs	Copy fedora rootfs from local file instead of downloading"
	echo "--vboot		Generated verified boot image"
	echo "--vboot-keydir	Specify key directoy for verified boot"
	echo "--vboot-its	Specify its file for verified boot"
	echo "--sboot		Generated signed boot image"
	echo "--skip-clean	Skip fedora local repository clean"
	echo "--skip-fedora-build	Skip fedora build"
	echo "--prebuilt-vboot	Specify prebuilt directory path for vboot"
	echo "--deploy-all	Deploy release"
	exit 0
}

error()
{
	JOB="$0"              # job name
	LASTLINE="$1"         # line of error occurrence
	LASTERR="$2"          # error code
	echo "ERROR in ${JOB} : line ${LASTLINE} with exit code ${LASTERR}"
	exit 1
}

parse_options()
{
	for opt in "$@"
	do
		case "$opt" in
			-h|--help)
				print_usage
				shift ;;
			-c|--config)
				CONFIG_FILE="$2"
				shift ;;
			-v|--fullver)
				BUILD_VERSION="$2"
				shift ;;
			-d|--date)
				BUILD_DATE="$2"
				shift ;;
			-m|--microsd)
				MICROSD_IMAGE=-m
				shift ;;
			-u|--url)
				SERVER_URL="-s $2"
				shift ;;
			-C)
				BUILD_CONF="-C $2"
				shift ;;
			--full-build)
				FULL_BUILD=true
				shift ;;
			--local-rootfs)
				LOCAL_ROOTFS="$2"
				shift ;;
			--sboot)
				SECURE_BOOT=true
				shift ;;
			--vboot)
				VERIFIED_BOOT=true
				shift ;;
			--vboot-keydir)
				VBOOT_KEYDIR="$2"
				shift ;;
			--vboot-its)
				VBOOT_ITS="$2"
				shift ;;
			--skip-clean)
				SKIP_CLEAN=--skip-clean
				shift ;;
			--skip-fedora-build)
				SKIP_FEDORA_BUILD=--skip-build
				shift ;;
			--prebuilt-vboot)
				PREBUILT_VBOOT_DIR=`readlink -e "$2"`
				shift ;;
			--deploy-all)
				DEPLOY=true
				shift ;;
			*)
				shift ;;
		esac
	done
}

package_check()
{
	command -v $1 >/dev/null 2>&1 || { echo >&2 "${1} not installed. Please install \"sudo apt-get install $2\""; exit 1; }
}

gen_artik_release()
{
	if [ "$ARTIK_RELEASE_LEGACY" != "1" ]; then
		cat > $TARGET_DIR/artik_release << __EOF__
BUILD_VERSION=
BUILD_DATE=
BUILD_UBOOT=
BUILD_KERNEL=
MODEL=
WIFI_FW=${WIFI_FW}
BT_FW=${BT_FW}
ZIGBEE_FW=${ZIGBEE_FW}
SE_FW=${SE_FW}
__EOF__
	else
		cat > $TARGET_DIR/artik_release << __EOF__
RELEASE_VERSION=
RELEASE_DATE=
RELEASE_UBOOT=
RELEASE_KERNEL=
MODEL=
WIFI_FW=${WIFI_FW}
BT_FW=${BT_FW}
ZIGBEE_FW=${ZIGBEE_FW}
__EOF__
	fi
}

fill_artik_release()
{
	upper_model=$(echo -n ${TARGET_BOARD} | awk '{print toupper($0)}')
	sed -i "s/_VERSION=.*/_VERSION=${BUILD_VERSION}/" ${TARGET_DIR}/artik_release
	sed -i "s/_DATE=.*/_DATE=${BUILD_DATE}/" ${TARGET_DIR}/artik_release
	sed -i "s/MODEL=.*/MODEL=${upper_model}/" ${TARGET_DIR}/artik_release
}

trap 'error ${LINENO} ${?}' ERR
parse_options "$@"

package_check curl curl
package_check kpartx kpartx
package_check make_ext4fs android-tools-fsutils
package_check arm-linux-gnueabihf-gcc gcc-arm-linux-gnueabihf

if [ "$CONFIG_FILE" != "" ]
then
	. $CONFIG_FILE
fi

if [ "$BUILD_DATE" == "" ]; then
	BUILD_DATE=`date +"%Y%m%d.%H%M%S"`
fi

if [ "$BUILD_VERSION" == "" ]; then
	BUILD_VERSION=UNRELEASED
fi

export BUILD_DATE=$BUILD_DATE
export BUILD_VERSION=$BUILD_VERSION

export TARGET_DIR=$TARGET_DIR/$BUILD_VERSION/$BUILD_DATE

sudo ls > /dev/null 2>&1

mkdir -p $TARGET_DIR

gen_artik_release

if [ "$PREBUILT_VBOOT_DIR" == "" ]; then
	./build_uboot.sh
	./build_kernel.sh

	if $VERIFIED_BOOT ; then
		if [ "$VBOOT_ITS" == "" ]; then
			VBOOT_ITS=$PREBUILT_DIR/kernel_fit_verify.its
		fi
		if [ "$VBOOT_KEYDIR" == "" ]; then
			echo "Please specify key directory using --vboot-keydir"
			exit 0
		fi
		./mkvboot.sh $TARGET_DIR $VBOOT_KEYDIR $VBOOT_ITS
	fi
else
	find $PREBUILT_VBOOT_DIR -maxdepth 1 -type f -exec cp -t $TARGET_DIR {} +
fi

fill_artik_release

if $SECURE_BOOT ; then
	./mksboot.sh $TARGET_DIR
fi

./mksdboot.sh

./mkbootimg.sh

if $FULL_BUILD ; then
	if [ "$BASE_BOARD" != "" ]; then
		FEDORA_TARGET_BOARD=$BASE_BOARD
	else
		FEDORA_TARGET_BOARD=$TARGET_BOARD
	fi

	FEDORA_NAME=fedora-arm-$FEDORA_TARGET_BOARD-rootfs-$BUILD_VERSION-$BUILD_DATE
	if [ "$FEDORA_PREBUILT_RPM_DIR" != "" ]; then
		PREBUILD_ADD_CMD="-r $FEDORA_PREBUILT_RPM_DIR"
	fi
	./build_fedora.sh $BUILD_CONF -o $TARGET_DIR -b $FEDORA_TARGET_BOARD \
		-p $FEDORA_PACKAGE_FILE -n $FEDORA_NAME $SKIP_CLEAN $SKIP_FEDORA_BUILD \
		-k fedora-arm-${FEDORA_TARGET_BOARD}.ks \
		$PREBUILD_ADD_CMD

	MD5_SUM=$(md5sum $TARGET_DIR/${FEDORA_NAME}.tar.gz | awk '{print $1}')
	FEDORA_TARBALL=${FEDORA_NAME}-${MD5_SUM}.tar.gz
	mv $TARGET_DIR/${FEDORA_NAME}.tar.gz $TARGET_DIR/$FEDORA_TARBALL
	cp $TARGET_DIR/$FEDORA_TARBALL $TARGET_DIR/rootfs.tar.gz
else
	if [ "$LOCAL_ROOTFS" == "" ]; then
		./release_rootfs.sh -b $TARGET_BOARD $SERVER_URL
	else
		cp $LOCAL_ROOTFS $TARGET_DIR/rootfs.tar.gz
	fi
fi

./mksdfuse.sh $MICROSD_IMAGE
if $DEPLOY; then
	mkdir $TARGET_DIR/sdboot
	./mksdfuse.sh -m
	mv $TARGET_DIR/${TARGET_BOARD}_sdcard-*.img $TARGET_DIR/sdboot
fi

if $DEPLOY && [ "$HWTEST_MFG_PATH" != "" ]; then
	mkdir $TARGET_DIR/hwtest
	if [ "$HWTEST_ROOTFS_PATH" == "" ]; then
		HWTEST_ROOTFS_PATH=$TARGET_DIR/rootfs.tar.gz
	fi
	if [ "$HWTEST_IMAGE_PATH" == "" ]; then
		HW_ARGS=" --hwtest-rootfs $HWTEST_ROOTFS_PATH --hwtest-mfg $HWTEST_MFG_PATH"
	else
		HW_ARGS=" -f $HWTEST_IMAGE_PATH"
	fi
	./mksdhwtest.sh $HW_ARGS
	if [ "$HWTEST_RECOVERY_IMAGE" == "1" ]; then
		./mksdhwtest.sh $HW_ARGS --recovery
	fi
	mv $TARGET_DIR/${TARGET_BOARD}_hwtest*.img $TARGET_DIR/hwtest
fi

./mkrootfs_image.sh $TARGET_DIR

if [ -e $PREBUILT_DIR/flash_all_by_fastboot.sh ]; then
	cp $PREBUILT_DIR/flash_all_by_fastboot.sh $TARGET_DIR
	[ -e $PREBUILT_DIR/partition.txt ] && cp $PREBUILT_DIR/partition.txt $TARGET_DIR
else
	cp flash_all_by_fastboot.sh $TARGET_DIR
fi

cp expand_rootfs.sh $TARGET_DIR

if [ -e $PREBUILT_DIR/$TARGET_BOARD/u-boot-recovery.bin ]; then
	cp $PREBUILT_DIR/$TARGET_BOARD/u-boot-recovery.bin $TARGET_DIR
fi

if [ "$BUILD_VERSION" != "UNRELEASED" ]; then
	./release_bsp_source.sh -b $TARGET_BOARD -v $BUILD_VERSION -d $BUILD_DATE
fi

ls -al $TARGET_DIR

echo "ARTIK release information"
cat $TARGET_DIR/artik_release
