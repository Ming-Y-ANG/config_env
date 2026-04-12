#!/bin/bash
VERSION=22.1.0
curl -O -L https://github.com/clangd/clangd/releases/download/$VERSION/clangd-linux-$VERSION.zip
unzip clangd-linux-$VERSION.zip
cp -alf clangd_$VERSION/bin/clangd $HOME/tools
rm -rf clangd-linux-$VERSION.zip clangd_$VERSION

