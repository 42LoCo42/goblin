#!/bin/sh
set -eu
live="/run/s6/live"

status() {
	active="$(mktemp -p /run/s6)"
	trap 'rm -f "$active"' EXIT
	s6-rc -l "$live" -a list >"$active"

	s6-rc-db -l "$live" list services |
		grep -v '^s6rc-' |
		sort |
		while read -r i; do
			if grep -qF "$i" "$active"; then
				printf "\e[1;32m UP \e[m\t%s\n" "$i"
			else
				printf "\e[1;31mDOWN\e[m\t%s\n" "$i"
			fi
		done

	s6-rc-db -l "$live" list bundles |
		sort |
		while read -r i; do
			printf "\e[1;34mBNDL\e[m\t%s: " "$i"
			find \
				"$live/compiled/src/$i/contents.d" \
				-type f -exec basename -a {} + |
				sort |
				tr '\n' ' '
			echo
		done
}

change() {
	set +e
	s6-rc -l "$live" "$1" "$2"
	code="$?"
	status
	exit $code
}

usage() {
	cat <<EOF
Usage: $0 [mode]
    status                   Prints all services (with up/down state) and bundles
    start|up|u <service>     Starts the given service
    stop|down|d <service>    Stops the given service
    help                     Print this help
EOF
}

op="${1-status}"
case "$op" in
status) status ;;
start | up | u) change start "$2" ;;
stop | down | d) change stop "$2" ;;
help | --help | h | -h) usage ;;
*)
	exec >&2
	echo "Unknown operation '$op'"
	usage
	exit 1
	;;
esac
