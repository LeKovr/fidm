#!/bin/bash
#
#    Copyright (c) 2014 Alexey Kovrizhkin <lekovr@gmail.com>
#
#    fidm_nb.sh - Run fidm nginx batch.
#
# ------------------------------------------------------------------------------
# This script used for manage several static sites via single config file
# Script reads this file (Default: fidm_nb.cfg) and runs fidm for each site
# fidm runs a given command on consup_nginx container.
#
# Copyright (c) 2015 Alexey Kovrizhkin <lekovr+docker@gmail.com>
# The MIT License (MIT)
#
# Requirements:
# * [fidm](https://github.com/LeKovr/fidm)
# * [consup](https://github.com/LeKovr/consup) must be installed in ../ or ../../ or ../../../
# * fidm.yml must exists in the current dir
#
# Configuration:
# ------------------------------------------------------------------------------
# Site list sample:
sites_conf() {
  cat > $1 <<EOF
# site_hostname  document_root_path  document_root_dir
www.example.com/maintenance.html                       # Redirect requests to unknown (not started) hosts HOST to http://www.example.com/maintenance.html?host=HOST
example.com      www.example.com                       # Redirect http://example.com/URI to http://www.example.com/URI (path not started from "/" or ".")
www.example.com  ./../web            www               # Serve www.example.com from relative dir ../web/www (path started from ".")
www.example.com  /usr/share/nginx                      # Serve www.example.com from /usr/share/nginx/html (path started from "/", default dir name)
EOF
}
# ------------------------------------------------------------------------------
# fidm.yml sample:
fidm_conf() {
  cat > $1 <<EOF
# fidm.yml for consup_nginx container
image: consup_nginx
requires:
- consup/nginx mode=common
links:
- consup/consul    # consul.yml
log_dir: log
volume:
- :/home/app
private:
- 80
env:
- LOCALE=ru_RU
- SERVICE=web
dns: 127.0.0.1
detach: true
EOF
}

# ------------------------------------------------------------------------------
# Globals

# fetch only this site from config
[[ "$SITE" ]] || SITE=""

# load sites config from this file
[[ "$CFG" ]] || CFG=fidm_nb.cfg

# fidm uses this config
FIDM_CFG=fidm.yml

# run this cmd
[[ "$CMD" ]] || CMD=start

# ------------------------------------------------------------------------------
# fidm wrapper

fidm_run() {
  local site=$1
  local path=$2
  local html=$3

  # filter for site if given
  [[ "$SITE" ]] && [[ "$SITE" != "$site" ]] && return

  echo "*** SetUp site $site..."
  # convert relative path to absolute
  [[ "$path" == "${path#.}" ]] || path=$PWD${path#.}

  if [[ "$path" != "${path#/}" ]] ; then
    # path starts with "/", static site
    [[ "$html" ]] || html=html
    echo "  Mount path: $path"
    echo "  html dir: $html"
    fidm $CMD mode=www name=$site args_add="--volume=$path:/home/www" args_add="--env=HTML_DIR=$html"

  elif [[ "$path" ]] ; then
    # redirect site
    echo "  Redirect to: $path"
    fidm $CMD mode=redir name=$site args_add="--env=NGINX_REDIR=$path"
  else
    # no path => this site is used for global redirect
    echo "  Global redirect: http://$site"
    # Save site in ENV for nginx frontend container
    export ENV_nginx="--env=NGINX_DEFAULT=http://$site"
  fi
  echo ""
}

# ------------------------------------------------------------------------------
# Run script

# Check config presense
# Don't stop after config creation if $NORESTART set

restart=""
[ -e $FIDM_CFG ] || {
  fidm_conf $FIDM_CFG
  echo "File $FIDM_CFG created with defaults."
  echo "Edit it if needed"
  [[ "$NORESTART" ]] || restart=1
}

[ -e $CFG ] || {
  sites_conf $CFG
  echo "File $CFG created with defaults."
  echo "Edit it and run script again"
  [[ "$NORESTART" ]] || restart="2$repeat"
}

[[ "$restart" ]] && exit 1

# ------------------------------------------------------------------------------

while read line ; do
    s=${line%%#*} # remove endline comments
    [ -n "${s##+([[:space:]])}" ] || continue # ignore line if contains only spaces
    fidm_run $s
done < $CFG
