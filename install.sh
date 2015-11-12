#!/bin/sh
# based on https://get.docker.com/ script
set -e
#
# This script is meant for quick & easy install via:
#
#   wget -qO- https://raw.githubusercontent.com/LeKovr/fidm/master/install.sh | sh
# or
#   curl -sSL https://raw.githubusercontent.com/LeKovr/fidm/master/install.sh | sh


prg=fidm
url=https://raw.githubusercontent.com/LeKovr/$prg
ver=v1.1

command_exists() {
    command -v "$@" > /dev/null 2>&1
}

do_install() {

    user="$(id -un 2>/dev/null || true)"

    sh_c='sh -c'
    if [ "$user" != 'root' ]; then
	if command_exists sudo; then
	    sh_c='sudo -E sh -c'
	elif command_exists su; then
	    sh_c='su -c'
	else
	    cat >&2 <<-'EOF'
	    Error: this installer needs the ability to run commands as root.
	    We are unable to find either "sudo" or "su" available to make this happen.
		EOF
	    exit 1
	fi
    fi
    curl=''
    if command_exists curl; then
	curl='curl -sSL'
    elif command_exists wget; then
	curl='wget -qO-'
    elif command_exists busybox && busybox --list-modules | grep -q wget; then
	curl='busybox wget -qO-'
    fi

    $curl $url/$ver/$prg.sh > /tmp/$prg
    chmod +x /tmp/$prg
    $sh_c "mv /tmp/$prg /usr/local/bin/"

}

do_install
