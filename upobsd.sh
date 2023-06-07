#!/bin/ksh
#
# Copyright (c) 2017-2018 Sebastien Marie <semarie@online.fr>
# Copyright (c) 2023 Solène Rapenne <solene@perso.pw>
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
#
set -eu
PATH='/sbin:/bin:/usr/sbin:/usr/bin'

VERBOSE=0
MIRROR=$(sed -e '/^$/d' -e '/^#/d' -e 'q' /etc/installurl)
ARCH=$(uname -m)
SIGNIFY_KEY=''
AUTO='no'
RESPONSE_FILE=''
OUTPUT="${PWD}/bsd.rd"

# get kernel version
set -A _KERNV -- $(sysctl -n kern.version | sed 's/^OpenBSD \([0-9]\)\.\([0-9]\)\([^ ]*\).*/\1.\2 \1\2 \3/;q')
if ((${#_KERNV[*]} == 2)) ; then
	OS_VERSION=${_KERNV[0]}
else
	OS_VERSION='snapshots'
fi
SIGNIFY_VERSION=${_KERNV[1]}

UID=$(id -u)
WRKDIR=''

uo_usage() {
	echo "usage: ${0##*/} [-v] [-m mirror] [-V version] [-a arch] [-p signify-key] [-i install-response-file] [-u upgrade-response-file] [-o output]" >&2
	exit 1
}

uo_cleanup() {
	trap "" 1 2 3 13 15 ERR
	set +e

	if [[ -d "${WRKDIR}" ]]; then
		rm -f -- \
			"${WRKDIR}/bsd.rd" \
			"${WRKDIR}/bsd" \
			"${WRKDIR}/ramdisk"

		[[ -d "${WRKDIR}/ramdisk.d" ]] && \
			rmdir -- "${WRKDIR}/ramdisk.d"

		rmdir -- "${WRKDIR}" || \
			uo_err 1 "cleanup failed: ${WRKDIR}"
	fi
}

uo_err() {
	local exitcode=${1}
	shift

	echo "error: ${@}" >&2
	uo_cleanup

	exit ${exitcode}
}

uo_trap() {
	uo_cleanup
	exit 1
}
trap "uo_trap" 1 2 3 13 15 ERR

uo_verbose() {
	[[ ${VERBOSE} != 0 ]] && echo "${@}"
}

uo_ftp() {
	local dest=${1}
	local url=${2}

	ftp -V -o "${WRKDIR}/${dest}" -- "${url}"
}

uo_download() {
	local url="${MIRROR}/${OS_VERSION}/${ARCH}"

	uo_verbose "downloading bsd.rd (and SHA256.sig): ${url}"

	uo_ftp SHA256.sig "${url}/SHA256.sig"
	uo_ftp bsd.rd "${url}/bsd.rd"

	uo_check_signature
}

uo_check_signature() {
	[ -r "${WRKDIR}/SHA256.sig" ] || \
		uo_err 2 "uo_check_signature: no SHA256.sig in WRKDIR"

	if [ -z "${SIGNIFY_KEY}" ]; then
		uo_signify \
			"/etc/signify/openbsd-${SIGNIFY_VERSION}-base.pub" \
			"/etc/signify/openbsd-$(( ${SIGNIFY_VERSION} + 1 ))-base.pub"
	else
		uo_signify "${SIGNIFY_KEY}"
	fi
}

uo_signify() {
	local signify_all_keys="$*"

	while [[ $# != 0 ]]; do
		local signify_key=${1}

		echo "checking signature: ${signify_key}"

		[ -e "${signify_key}" ] || \
			uo_err 1 "uo_check_signature: file not found: ${signify_key}"

		if ( cd "${WRKDIR}" && \
			signify -qC -p "${signify_key}" -x SHA256.sig bsd.rd ) ; then
			break
		fi

		shift
	done

	if [[ $# = 0 ]]; then
		uo_err 1 "invalid signature: ${signify_all_keys}"
	else
		uo_verbose "signature is valid"
	fi
}

uo_priv() {
	local SUDO=

	[[ ${UID} -ne 0 ]] && SUDO="doas --"

	${SUDO} "$@"
}

uo_addfile() {
	local dest=${1}
	local src=${2}
	local vnd_n=0

	[ -r "${WRKDIR}/bsd.rd" ] || uo_err 2 "uo_addfile: no bsd.rd in WRKDIR"
	[ -r "${src}" ] || uo_err 1 "file not found: ${src}"

	uo_verbose "adding response file: ${dest}: ${src}"

	# uncompress the bsd.rd file
	zcat "$WRKDIR/bsd.rd" > "$WRKDIR/bsd"

	# extract ramdisk from bsd.rd
	rdsetroot -x "${WRKDIR}/bsd" "${WRKDIR}/ramdisk"

	# create mountpoint
	mkdir "${WRKDIR}/ramdisk.d"

	# prepare ramdisk for mounting
	while ! uo_priv vnconfig "vnd${vnd_n}" "${WRKDIR}/ramdisk"; do
		vnd_n=$(( vnd_n + 1 ))

		[[ ${vnd_n} > 4 ]] && \
			uo_err 1 "no more vnd device available"
	done

	# mount ramdisk
	if ! uo_priv mount -o nodev,nosuid,noexec "/dev/vnd${vnd_n}a" "${WRKDIR}/ramdisk.d"; then
		uo_priv vnconfig -u "vnd${vnd_n}" || true

		uo_err 1 "unable to mount: /dev/vnd${vnd_n}a"
	fi

	# copy the file
	if ! uo_priv install -m 644 -o root -g wheel -- \
		"${src}" "${WRKDIR}/ramdisk.d/${dest}"; then

		uo_priv umount "/dev/vnd${vnd_n}a" || true
		uo_priv vnconfig -u "vnd${vnd_n}" || true

		uo_err 1 "unable to copy: ${src}: ramdisk.d/${dest}"
	fi

	# umount vndX
	if ! uo_priv umount "/dev/vnd${vnd_n}a" ; then
		uo_priv vnconfig -u "vnd${vnd_n}" || true

		uo_err 1 "unable to umount: /dev/vnd${vnd_n}a"
	fi

	# unconfigure vndX
	if ! uo_priv vnconfig -u "vnd${vnd_n}" ; then
		uo_err 1 "unable to unconfigure: vnd${vnd_n}"
	fi

	# mountpoint cleanup (ensure it is empty)
	rmdir "${WRKDIR}/ramdisk.d"

	# put ramdisk back in bsd.rd
	rdsetroot "${WRKDIR}/bsd" "${WRKDIR}/ramdisk"

	# compress back
	gzip "${WRKDIR}/bsd"
  	mv "${WRKDIR}/bsd.gz" "${WRKDIR}/bsd.rd"
}

uo_output() {
	[ -r "${WRKDIR}/bsd.rd" ] || uo_err 2 "uo_output: no bsd.rd in WRKDIR"

	uo_verbose "copying bsd.rd: ${OUTPUT}"
	mv -- "${WRKDIR}/bsd.rd" "${OUTPUT}"
}

# parse command-line
while getopts 'hvm:V:a:p:i:u:o:f:' arg; do
	case "${arg}" in
	v)	VERBOSE=1 ;;
	i)	AUTO='install'; RESPONSE_FILE="${OPTARG}" ;;
	u)	AUTO='upgrade'; RESPONSE_FILE="${OPTARG}" ;;
	o)	OUTPUT="${OPTARG}" ;;
	f)      FILE="${OPTARG}" ;;
	*)	uo_usage ;;
	esac
done

shift $(( OPTIND -1 ))
[[ $# -ne 0 ]] && uo_usage

[[ -n "${RESPONSE_FILE}" && ! -e ${RESPONSE_FILE} ]] && \
	uo_err 1 "file not found: ${RESPONSE_FILE}"

# create working directory
WRKDIR=$(mktemp -dt upobsd.XXXXXXXXXX) || \
	uo_err 1 "unable to create temporary directory"

[[ ! -f "${FILE}" ]] && \
        uo_err 1 "can't find ${FILE}"

cp "${FILE}" "${WRKDIR}/bsd.rd"

# add response-file if requested
[[ ${AUTO} != 'no' ]] && \
	uo_addfile "auto_${AUTO}.conf" "${RESPONSE_FILE}"

# place bsd.rd where asked
uo_output

# cleanup
uo_cleanup
