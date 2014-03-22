#!/bin/bash
CC=gdc

INC=include/vtrack
LIB=obj/vtrack

mkdir -p build/$INC build/$LIB build/bin 2>/dev/null
rm -rf build/$INC/* build/$LIB/* build/bin/* 2>/dev/null

pushd build
for bn in mpwrap; do
	ofn=${bn}.o
	CMD0="$CC -g -o $ofn -c -fversion=Linux -I../../eudorina/build/include/ -L../../eudorina/build/lib/ -fintfc -fintfc-dir=${INC} ../src/${bn}.d"
	CMD1="ar rcs ${LIB}/lib${bn}.a $ofn"
	echo $CMD0; $CMD0
	echo $CMD1; $CMD1
	rm $ofn
done

popd

for bn in wr; do
	CMD0="gdc -g -o build/bin/${bn} -Ibuild/include/ -I../eudorina/build/include/ -Lbuild/obj/vtrack/ -L../eudorina/build/lib/eudorina/ -fversion=Linux src/${bn}.d -lmpwrap -lio -ltext -llogging"
	echo $CMD0; $CMD0
done
