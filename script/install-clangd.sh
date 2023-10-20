#!/bin/bash
curl -O -L https://github.com/clangd/clangd/releases/download/16.0.2/clangd-linux-16.0.2.zip
unzip clangd-linux-16.0.2.zip
cp -alf clangd_16.0.2/bin/clangd $HOME/tools
rm -rf clangd-linux-16.0.2.zip clangd_16.0.2

