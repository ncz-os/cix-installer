#!/bin/sh
pid=/var/run/brltty.pid
[ -r $pid ] && kill -0 `cat $pid` && exit 0

stty cols 80 < /dev/tty1
echo debconf-set debian-installer/framebuffer false > /lib/debian-installer.d/S20brltty
rm -f /lib/debian-installer.d/S19brltty

if [ -f /var/run/brltty-Xorg ]
then
	rm /var/run/brltty-Xorg
(
	XORG=""
	while [ -z "$XORG"  ]
	do
		XORG=`pidof Xorg`
		sleep 1
	done
	kill "$XORG"
) &
(
	BTERM=""
	while [ -z "$BTERM"  ]
	do
		BTERM=`pidof bterm`
		sleep 1
	done
	kill "$BTERM"
) &
(
	MAIN=""
	while [ -z "$MAIN"  ]
	do
		MAIN=`pidof main-menu`
		sleep 1
	done
	kill "$MAIN"

	DEBCONF=""
	while [ -z "$DEBCONF"  ]
	do
		DEBCONF=`pidof debconf`
		sleep 1
	done
	kill "$DEBCONF"
) &
fi

exec /bin/brltty -P $pid "$@"
