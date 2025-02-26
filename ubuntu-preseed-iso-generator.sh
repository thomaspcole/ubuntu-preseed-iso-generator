#!/bin/bash
set -Eeuo pipefail

function cleanup() {
        trap - SIGINT SIGTERM ERR EXIT
        if [ -n "${tmpdir+x}" ]; then
                rm -rf "$tmpdir"
                log "🚽 Deleted temporary working directory $tmpdir"
        fi
}

trap cleanup SIGINT SIGTERM ERR EXIT
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)
[[ ! -x "$(command -v date)" ]] && echo "💥 date command not found." && exit 1
today=$(date +"%Y-%m-%d")

function log() {
        echo >&2 -e "[$(date +"%Y-%m-%d %H:%M:%S")] ${1-}"
}

function die() {
        local msg=$1
        local code=${2-1} # Bash parameter expansion - default exit status 1. See https://wiki.bash-hackers.org/syntax/pe#use_a_default_value
        log "$msg"
        exit "$code"
}

usage() {
        cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-k] [-v] [-p preseed-configuration-file] [-s source-iso-file] [-d destination-iso-file]

💁 This script will create fully-automated Ubuntu 20.04 Focal Fossa installation media.

Available options:

-h, --help          Print this help and exit
-v, --verbose       Print script debug info
-p, --preseed       Path to preseed configuration file.
-k, --no-verify     Disable GPG verification of the source ISO file. By default SHA256SUMS-$today and
                    SHA256SUMS-$today.gpg in ${script_dir} will be used to verify the authenticity and integrity
                    of the source ISO file. If they are not present the latest daily SHA256SUMS will be
                    downloaded and saved in ${script_dir}. The Ubuntu signing key will be downloaded and
                    saved in a new keyring in ${script_dir}
-s, --source        Source ISO file. By default the latest daily ISO for Ubuntu 20.04 will be downloaded
                    and saved as ${script_dir}/ubuntu-original-$today.iso
                    That file will be used by default if it already exists.
-r, --release       Specify the Ubuntu version you would like to use. FOCAL (20.04), IMPISH (21.10), or JAMMY (22.04)
-d, --destination   Destination ISO file. By default ${script_dir}/ubuntu-preseed-$today.iso will be
                    created, overwriting any existing file.
EOF
        exit
}

function parse_params() {
        # default values of variables set from params
        preseed_file=""
        source_iso="" #${script_dir}/ubuntu-original-$today.iso"
        destination_iso="${script_dir}/ubuntu-preseed-$today.iso"
        release_version=""
        use_arm=0
        gpg_verify=1

        while :; do
                case "${1-}" in
                -h | --help) usage ;;
                -v | --verbose) set -x ;;
                -k | --no-verify) gpg_verify=0 ;;
                -p | --preseed)
                        preseed_file="${2-}"
                        shift
                        ;;
                -s | --source)
                        source_iso="${2-}"
                        shift
                        ;;
                -d | --destination)
                        destination_iso="${2-}"
                        shift
                        ;;
                -r | --release)
                        release_version="${2-}"
                        shift
                        ;;
                -a | --arm) use_arm=1 ;;
                -?*) die "Unknown option: $1" ;;
                *) break ;;
                esac
                shift
        done

        log "👶 Starting up..."

        # check required params and arguments
        [[ -z "${preseed_file}" ]] && die "💥 preseed file was not specified."
        [[ ! -f "$preseed_file" ]] && die "💥 preseed file could not be found."

        [[ -z "${release_version}" ]] && die "💥 release version was not specified."

        case $release_version in
                FOCAL)
                if [ ${use_arm} -eq 1 ]; then
                        source_iso="${script_dir}/focal-original-ARM.iso"
                else
                        source_iso="${script_dir}/focal-original-X86.iso"
                fi
                ;;

                IMPISH)
                if [ ${use_arm} -eq 1 ]; then
                        log "⚠️ No arm build for this version. Using X86"
                fi
                source_iso="${script_dir}/impish-original-X86.iso"
                ;;

                JAMMY)
                if [ ${use_arm} -eq 1 ]; then
                        source_iso="${script_dir}/jammy-original-ARM.iso"
                else
                        source_iso="${script_dir}/jammy-original-X86.iso"
                fi                
                ;;

                *) 
                die "💥 Invalid release version."
                ;;
        esac

        destination_iso=$(realpath "${destination_iso}")
        source_iso=$(realpath "${source_iso}")

        return 0
}

ubuntu_gpg_key_id="843938DF228D22F7B3742BC0D94AA3F0EFE21092"

#import config file for sources
source "${script_dir}/versions.cfg"

parse_params "$@"

tmpdir=$(mktemp -d)

if [[ ! "$tmpdir" || ! -d "$tmpdir" ]]; then
        die "💥 Could not create temporary working directory."
else
        log "📁 Created temporary working directory $tmpdir"
fi

log "🔎 Checking for required utilities..."
[[ ! -x "$(command -v xorriso)" ]] && die "💥 xorriso is not installed."
[[ ! -x "$(command -v sed)" ]] && die "💥 sed is not installed."
[[ ! -x "$(command -v curl)" ]] && die "💥 curl is not installed."
[[ ! -x "$(command -v gpg)" ]] && die "💥 gpg is not installed."
[[ ! -f "/usr/lib/ISOLINUX/isohdpfx.bin" ]] && die "💥 isolinux is not installed."
log "👍 All required utilities are installed."

if [ ! -f "${source_iso}" ]; then
        log "🌎 Downloading ISO image for ${release_version}"
         case $release_version in
                FOCAL)
                if [ ${use_arm} -eq 1 ]; then
                        curl -NsSL "${BASE_FOCAL}${ARM_FOCAL}" -o "${source_iso}"
                else
                        curl -NsSL "${BASE_FOCAL}${X86_FOCAL}" -o "${source_iso}"
                fi
                ;;

                IMPISH)
                curl -NsSL "${BASE_IMPISH}${X86_IMPISH}" -o "${source_iso}"
                ;;
                
                JAMMY)
                if [ ${use_arm} -eq 1 ]; then
                        curl -NsSL "${BASE_JAMMY}${ARM_JAMMY}" -o "${source_iso}"
                else
                        curl -NsSL "${BASE_JAMMY}${X86_JAMMY}" -o "${source_iso}"
                fi                
                ;;

                *) 
                die "💥 Invalid release version."
                ;;
        esac
        log "👍 Downloaded and saved to ${source_iso}"
else
        log "☑️ Using existing ${source_iso} file."
        if [ ${gpg_verify} -eq 1 ]; then
                if [ "${source_iso}" != "${script_dir}/ubuntu-original-$today.iso" ]; then
                        log "⚠️ Automatic GPG verification is enabled. If the source ISO file is not the latest daily image, verification will fail!"
                fi
        fi
fi

if [ ${gpg_verify} -eq 1 ]; then
        log "🌎 Downloading SHA256SUMS & SHA256SUMS.gpg files..."

        case $release_version in
                FOCAL)
                curl -NsSL "${BASE_FOCAL}/SHA256SUMS" -o "${script_dir}/SHA256SUMS"
                curl -NsSL "${BASE_FOCAL}/SHA256SUMS.gpg" -o "${script_dir}/SHA256SUMS.gpg"
                ;;

                IMPISH)
                curl -NsSL "${BASE_IMPISH}/SHA256SUMS" -o "${script_dir}/SHA256SUMS"
                curl -NsSL "${BASE_IMPISH}/SHA256SUMS.gpg" -o "${script_dir}/SHA256SUMS.gpg"
                ;;

                JAMMY)
                curl -NsSL "${BASE_JAMMY}/SHA256SUMS" -o "${script_dir}/SHA256SUMS"
                curl -NsSL "${BASE_JAMMY}/SHA256SUMS.gpg" -o "${script_dir}/SHA256SUMS.gpg"
                ;;

                *) 
                die "💥 Invalid release version."
                ;;
        esac


        if [ ! -f "${script_dir}/${ubuntu_gpg_key_id}.keyring" ]; then
                log "🌎 Downloading and saving Ubuntu signing key..."
                gpg -q --no-default-keyring --keyring "${script_dir}/${ubuntu_gpg_key_id}.keyring" --keyserver "hkp://keyserver.ubuntu.com" --recv-keys "${ubuntu_gpg_key_id}"
                log "👍 Downloaded and saved to ${script_dir}/${ubuntu_gpg_key_id}.keyring"
        else
                log "☑️ Using existing Ubuntu signing key saved in ${script_dir}/${ubuntu_gpg_key_id}.keyring"
        fi

        log "🔐 Verifying ${source_iso} integrity and authenticity..."
        gpg -q --keyring "${script_dir}/${ubuntu_gpg_key_id}.keyring" --verify "${script_dir}/SHA256SUMS.gpg" "${script_dir}/SHA256SUMS" 2>/dev/null
        if [ $? -ne 0 ]; then
                rm -f "${script_dir}/${ubuntu_gpg_key_id}.keyring~"
                die "👿 Verification of SHA256SUMS signature failed."
        fi

        rm -f "${script_dir}/${ubuntu_gpg_key_id}.keyring~"
        digest=$(sha256sum "${source_iso}" | cut -f1 -d ' ')
        set +e
        grep -Fq "$digest" "${script_dir}/SHA256SUMS"
        if [ $? -eq 0 ]; then
                log "👍 Verification succeeded."
                set -e
        else
                die "👿 Verification of ISO digest failed."
        fi
else
        log "🤞 Skipping verification of source ISO."
fi
log "🔧 Extracting ISO image..."
xorriso -osirrox on -indev "${source_iso}" -extract / "$tmpdir" &>/dev/null
chmod -R u+w "$tmpdir"
rm -rf "$tmpdir/"'[BOOT]'
log "👍 Extracted to $tmpdir"

log "🧩 Adding preseed parameters to kernel command line..."

# These are for UEFI mode
sed -i -e 's,file=/cdrom/preseed/ubuntu.seed maybe-ubiquity quiet splash,file=/cdrom/preseed/custom.seed auto=true priority=critical boot=casper automatic-ubiquity quiet splash noprompt noshell,g' "$tmpdir/boot/grub/grub.cfg"
sed -i -e 's,file=/cdrom/preseed/ubuntu.seed maybe-ubiquity iso-scan/filename=${iso_path} quiet splash,file=/cdrom/preseed/custom.seed auto=true priority=critical boot=casper automatic-ubiquity quiet splash noprompt noshell,g' "$tmpdir/boot/grub/loopback.cfg"

# This one is used for BIOS mode
txtcfgpath=""
if [ $release_version == "FOCAL" ]; then
        txtcfgpath="$tmpdir/isolinux/txt.cfg"
else
        txtcfgpath="/dev/null"
fi

cat <<EOF > "$txtcfgpath"
default live-install
label live-install
menu label ^Install Ubuntu
kernel /casper/vmlinuz
append  file=/cdrom/preseed/custom.seed auto=true priority=critical boot=casper automatic-ubiquity initrd=/casper/initrd quiet splash noprompt noshell ---
EOF

log "👍 Added parameters to UEFI and BIOS kernel command lines."

log "🧩 Adding preseed configuration file..."
cp "$preseed_file" "$tmpdir/preseed/custom.seed"
log "👍 Added preseed file"

log "👷 Updating $tmpdir/md5sum.txt with hashes of modified files..."
# Using the full list of hashes causes long delays at boot.
# For now, just include a couple of the files we changed.
md5=$(md5sum "$tmpdir/boot/grub/grub.cfg" | cut -f1 -d ' ')
echo "$md5  ./boot/grub/grub.cfg" > "$tmpdir/md5sum.txt"
md5=$(md5sum "$tmpdir/boot/grub/loopback.cfg" | cut -f1 -d ' ')
echo "$md5  ./boot/grub/loopback.cfg" >> "$tmpdir/md5sum.txt"
log "👍 Updated hashes."

log "📦 Repackaging extracted files into an ISO image..."
cd "$tmpdir"
case $release_version in
        FOCAL)
        xorriso -as mkisofs -r -V "ubuntu-preseed-$today" -J -b isolinux/isolinux.bin -c isolinux/boot.cat -no-emul-boot -boot-load-size 4 -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin -boot-info-table -input-charset utf-8 -eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot -isohybrid-gpt-basdat -o "${destination_iso}" . &>/dev/null
        ;;

        IMPISH)
        orig="${source_iso}"
        mbr=$OLDPWD/$release_version.mbr
        efi=$OLDPWD/$release_version.efi

        # Extract the MBR template
        dd if="$orig" bs=1 count=446 of="$mbr"

        # Extract EFI partition image
        skip=$(/sbin/fdisk -l "$orig" | fgrep '.iso2 ' | awk '{print $2}')
        size=$(/sbin/fdisk -l "$orig" | fgrep '.iso2 ' | awk '{print $4}')
        dd if="$orig" bs=512 skip="$skip" count="$size" of="$efi"

        xorriso -as mkisofs -r -V "ubuntu-preseed-$today" -iso-level 3 -partition_offset 16 --grub2-mbr "$mbr" --mbr-force-bootable -append_partition 2 0xEF "$efi" -appended_part_as_gpt -c /boot.catalog -b /boot/grub/i386-pc/eltorito.img -no-emul-boot -boot-load-size 4 -boot-info-table --grub2-boot-info -eltorito-alt-boot -e '--interval:appended_partition_2:all::' -no-emul-boot -o "${destination_iso}" . &>/dev/null
        ;;

        JAMMY)
        xorriso -as mkisofs -r -V "ubuntu-preseed-$today" -o "${destination_iso}" . &>/dev/null
        ;;

        *) 
        die "💥 Invalid release version."
        ;;
esac
cd "$OLDPWD"
log "👍 Repackaged into ${destination_iso}"

die "✅ Completed." 0
