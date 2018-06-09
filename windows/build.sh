#!/bin/bash

set -e

# Run from within MSYS/Cygwin

rtver=2.5.1-1
rtarch="rubyinstaller-${rtver}-x86.7z"
rtsrc="https://github.com/oneclick/rubyinstaller2/releases/download/rubyinstaller-${rtver}/${rtarch}"

_rt=`pwd`/$rtarch
_gem=`pwd`/../*gem

dist=dist
rt=$dist/ruby

rm -rf $dist

[[ -f $rtarch ]] || wget $rtsrc

mkdir -p $dist

(
	cd $dist
	7z x $_rt
	mv rubyinstaller* ruby
)

(
	cd $dist/ruby/bin
	cmd /c gem.cmd install $_gem
)

(
	cd $rt
	rm -rf include share/doc lib/{pkgconfig,*.a} lib/ruby/gems/*/{cache,doc}/*
)
#