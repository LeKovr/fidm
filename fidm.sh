#!/bin/bash
#
#    Copyright (c) 2014 Alexey Kovrizhkin <lekovr@gmail.com>
#
#    fidm.sh - Fig inspired Docker manager
#    https://github.com/LeKovr/fidm
#
# ------------------------------------------------------------------------------
app_help() {
  local err=$1
  [[ "$err" ]] && echo "Error: $err"

  cat <<EOF
  ***********************************************************************
    fidm.sh - Fig inspired Docker manager

  Usage:
    fidm.sh COMMAND CONFIG[.yml] [-a] [var=value]

  Where:

    COMMAND is one from
      build   - build docker image
      start   - name docker container with suffix MODE, run it and its dependencies
      stop    - stop docker container with suffix MODE and dependencies
      rm      - remove docker container 
      init    - create new config with defaults

    CONFIG    - config file with fidm vars and docker run args

    -a        - key to process dependencies also, used in "stop" and "rm" commands

    var=value - fidm params which will replace config and default values

  Examples:

    fidm.sh build postgres

    fidm.sh start pgws mode=dev
    fidm.sh stop modperl -a

EOF
  exit 1
}

# ------------------------------------------------------------------------------
# create config file sample
app_config() {
  local file=$1 ; shift # config filename
  local name=$1 ; shift # config name

  [ -f $file ] && app_help "File $file already exists"
  cat > $file <<EOCFG
# ===============================================================================
# fidm config for ${cfg[name]}
# -------------------------------------------------------------------------------
# Generated by fidm.sh init ${cfg[name]}
# ===============================================================================

# -------------------------------------------------------------------------------
# Image build info
# -------------------------------------------------------------------------------

# Dockerfile dir for fidm build
# build: ${cfg[build]}

# docker hub login for docker pull
# or image prefix for docker build
#creator: ${cfg[creator]}

# project name (container name prefix)
#project: ${cfg[project]}

# image name
#name: ${cfg[name]}

# image tag (container name suffix)
#mode: ${cfg[mode]}

# docker image release [latest]
#release: ${cfg[release]}

# docker image name (project_name)
#image: ${cfg[image]}


# -------------------------------------------------------------------------------
# Image exchange info
# -------------------------------------------------------------------------------

# fidm args for start/stop required images (autostarted)
#requires:
#- consul mode=v2.01      # consul.yml
#- ../statsd mode=master  # statsd.yml

# fidm args for start/stop linked containers with autostart
#links:
#- common/postgres    # postgres.yml

# Use this container as DNS if link them
#hasdns: 1

# -------------------------------------------------------------------------------
# Image run info
# -------------------------------------------------------------------------------

# ip to bind publish ports
#bind_ip: 127.0.0.2
#bind_device: wlan2
#bind_host: web.dev

# publish ports
#publish:
#- 8500

# ip to bind random private ports
#local_ip: 127.0.7.7

# private ports, map to local_ip:random_port
#private:
#- 3142

# mount volume
# $log_dir/$name_$mode:/var/log/supervisor
#log_dir: var/log

# add MODE as hostname suffix
#host_use_mode: 1

# -------------------------------------------------------------------------------
# Direct docker run args
# -------------------------------------------------------------------------------

#volume:
# if left part does not begins with "/", add work dir
#- app/pgws:/home/app

# Linked containers without autostart
#link:
#- consup_consul_main:consul

#env:
#- LOCALE=ru_RU
#- TZ=Europe/Moscow

# Daemon
#detach: true

# Interactive
#interactive: true
#tty: true
#rm: true

# -------------------------------------------------------------------------------
EOCFG
  echo "Config file $file generated"
}
# ------------------------------------------------------------------------------
# Проверка, что docker содержит образ с заданным именем
image_registered() {
  $DOCKER ps -a | grep -Eq "$1 +\$" > /dev/null
}

# ------------------------------------------------------------------------------
# Проверка, что docker стартовал образ с заданным именем
image_started() {
  $DOCKER ps | grep -Eq '$1(\s|$)' > /dev/null
}

# ------------------------------------------------------------------------------
# Создать образ и присвоить ему тег
image_create() {
  local arg=""
  [[ ${cfg[dockerfile]} == "Dockerfile" ]] || arg="-f ${cfg[build]}/${cfg[dockerfile]}"
  $DOCKER build -t ${cfg[creator]}/${cfg[image]}:${cfg[release]} $arg ${cfg[build]}
}

# ------------------------------------------------------------------------------
# remove container with given name
# called after image_stop
image_remove() {
  local tag=$1

  # container already stopped so we get not empty string if it exists
  local RUNNING=$($DOCKER inspect --format="{{ .State.Running }}" $tag 2> /dev/null)

  if [[ "$RUNNING" ]]; then
    echo "Removing tag $tag..."
    $DOCKER rm $tag
  else
    echo "Tag $tag does not exists"
  fi
}

# ------------------------------------------------------------------------------
# Whole script main goal - call docker run with all given args
image_start() {
  local tag=$1

  local host=${cfg[name]}
  [[ "${cfg[host_use_mode]}" ]] && host="${host}_${cfg[mode]}"
  local varname="ENV_${host//[-.]/_}" # get args from env, replace '-' in var name
  eval var=\$$varname
  [[ "$DEBUG" == "3" ]] && echo "VAR: $varname ($var)"
  $DOCKER run --hostname=$host --name=$tag --env=MODE=${cfg[mode]} --env=NODENAME=$host \
    ${cfg[args]} $var ${cfg[creator]}/${cfg[image]}:${cfg[release]} ${cfg[cmd]}
}

# ------------------------------------------------------------------------------
image_stop() {
  local tag=$1  ; shift
  local work_dir=$1
  if image_started $tag ; then
    echo "Stopping $tag..."
    $DOCKER stop $tag
  else
    echo "Tag $tag is not active"
  fi
  # Stop dependencies
  alldeps=("${requires[@]}" "${links[@]}")
  [[ "$cmd_ext" == "-a" ]] && for (( i = 0 ; i < ${#alldeps[@]} ; i++ )) ; do app_run $work_dir $cmd ${alldeps[$i]} ; done

}

# ------------------------------------------------------------------------------
# parse .yml file and fill cfg array 
config_parse() {
  local config=$1 ; shift
  local root_dir=$1 ; shift
  [ -e $config ] || return
  local args=${cfg[args]}
  while read line ; do
    # Skip comments
    s=${line%%#*} # remove endline comments
    [ -n "${s##+([[:space:]])}" ] || continue # ignore line if contains only spaces

    # Fetch var & value
    if [[ $s != "${s%%:}" ]] ; then  # last char is ':'
      key=${s%%:}
      [[ "$DEBUG" == "2" ]] && echo "Found key $key"
      val=""
    elif [[ $s != "${s#- }" ]] ; then # line begins with '- '
      val=${s#([[:space:]])} # remove prefix spaces
      val=${s#- } # remove prefix dash
      [[ "$DEBUG" == "2" ]] && echo "Found value1: $key=$val"
    else # line in form "KEY: VALUE"
      key=${s%:*} # remove val
      val=${s#*:[[:space:]]} # remove key
      [[ "$DEBUG" == "2" ]] && echo "Found value2: $key=$val"
    fi
    [[ "$val" ]] || continue

    # Process var & value

    # cut fidm params
    for t in build dockerfile creator project release image mode name bind_ip local_ip hasdns log_dir host_use_mode cmd; do
      if [[ "$key" == "$t" ]] ; then
        cfg[$key]=$val
        val=""
        break
      fi
    done
    [[ "$val" ]] || continue

    if [[ "$key" == "requires" ]] ; then
      requires=("${requires[@]}" "$val")
    elif [[ "$key" == "links" ]] ; then
      links=("${links[@]}" "$val")
    elif [[ "$key" == "bind_device" ]] ; then
      # set ip from device name
      # http://stackoverflow.com/questions/6829605/putting-ip-address-into-bash-variable-is-there-a-better-way
      local bind_ip=$(ip -f inet -o addr show $val|cut -d\  -f 7 | cut -d/ -f 1)
      cfg[bind_ip]=$bind_ip
    elif [[ "$key" == "bind_host" ]] ; then
      # set ip from host name
      # http://unix.stackexchange.com/questions/20784/how-can-i-resolve-a-hostname-to-an-ip-address-in-a-bash-script
      local bind_ip=$(getent hosts $val | cut -d' ' -f1)
      cfg[bind_ip]=$bind_ip
    elif [[ "$key" == "publish" ]] ; then
      # bind port to given ip
      if [[ "$val" != "${val/:}" ]] ; then # line contains ':' (both ports)
        args="$args --$key=${cfg[bind_ip]}:$val"
      else
        local port_number=${val%/udp} # remove proto, TODO: add /tcp support
        args="$args --$key=${cfg[bind_ip]}:$port_number:$val"
      fi
    elif [[ "$key" == "private" ]] ; then
      # bind port to localhost
      args="$args --publish=${cfg[local_ip]}::$val"
    elif [[ "$key" == "volume" ]] ; then
      # add pwd if host path is relative
      if [[ "$val" == "${val#/}" ]] ; then # line does not begin with '/'
        val=$root_dir/$val
      fi
      args="$args --$key=$val"
    elif [[ "$key" ]] ; then
      args="$args --$key=$val"
    else
      echo "WARN: Ignored line: $s"
    fi
  done < $config

  cfg[args]=$args
}

# ------------------------------------------------------------------------------

app_run() {
  local run_at=$1  ; shift  # config file work dir or .
  local cmd=$1     ; shift  # start | stop | build | rm
  local file=$1             # filename[.yml]

  local cmd_ext   # extra command arg like "stop XX all"
  if [[ "$file" == "${file/=/}" ]] ; then
    shift         # name given
    if [[ "$file" == "-a" ]] ; then
      cmd_ext=$file # get extra
      file=""       # 2d arg is -a
    else
      cmd_ext=$1    # get extra
      [[ "$cmd_ext" == "-a" ]] && shift # rm arg3 from $@ if know it
    fi
  else
    file=""       # 2d arg is var
  fi
  # config filename
  local config_file
  local current_dir=$run_at
  [[ "$run_at" == "." ]] && current_dir=$PWD
  for prefix in "$current_dir/" "../" "../../" "../../../" ; do # look at current, parent and grandparent dir
    for f in "" ".yml" "fidm.yml" ; do      # add nothing, ext or default name
      [[ "$file" ]] || { [[ "$f" != "fidm.yml" ]] && continue ; } # do not check $prefix/ and $prefix/.yml
      local n="$prefix$file"
      #[[ "$n" == "." ]] || n="$n."
      #    echo "Check $n$f"
      [ -f "$n$f" ] && { config_file="$n$f" ; break ; }
      [[ "$file" == "${file%.yml}" ]] || break # only one check if name has ext
    done
    [[ "$config_file" ]] && break           # file found
    [[ "$run_at" == "." ]] && break         # search parents only for includes
  done
  if [[ "$config_file" ]] ; then
    config_file=$(readlink -f $config_file) # normalize path
  else
    [[ "$file" ]] || file=fidm
    [[ "$file" == "${file%.yml}" ]] && file=${file}.yml
    config_file=$current_dir/${file}
    echo "== Config file $file does not exists. Using defaults ($config_file)"
  fi
  local noext=${config_file%.yml}           # remove .yml if any
  local work_dir=$(dirname $noext)          # all paths are relative to config file
  local project_def=$(basename $work_dir)   # PROJECT/NAME[/fidm].yml
  local name_def=$(basename $noext)         # PROJECT/NAME[/fidm].yml
  if [[ "$name_def" == "fidm" ]] ; then
    name_def=$project_def
    project_def=$(basename $(dirname $work_dir))
  fi

  local -A cfg                      # associative array
  local -a requires links alldeps   # indexed arrays
  local i                           # array index for loops

  [ -f ~/.fidmrc ] && . ~/.fidmrc
  [ -f .fidmrc ] && . .fidmrc

  # echo "Parsing config $config_file ..."
  config_parse $config_file $work_dir

  # Get vars from args
  for v in "$@" ; do
    local var_split=(${v//=/ })
    local rm_add=${var_split[0]%_add} # if name=XX_add then add value to var XX
    local value=""
    local key=$rm_add
    [[ "$rm_add" != "${var_split[0]}" ]] && [[ "${cfg[$key]}" ]] && value="${cfg[$key]} "
    if [[ "${var_split[2]}" ]] ; then
      if [[ "${var_split[3]}" ]] ; then
        cfg[$key]="$value${var_split[1]}=${var_split[2]}=${var_split[3]}"
      else
        cfg[$key]="$value${var_split[1]}=${var_split[2]}"
      fi
    else
      cfg[$key]="$value${var_split[1]}"
    fi
  done


  # Set defaults
  [[ "${cfg[creator]}" ]] || x=$($DOCKER_INFO info 2>/dev/null | grep Username) cfg[creator]=${x#*: }  
  [[ "${cfg[project]}" ]] || cfg[project]=$project_def
  [[ "${cfg[name]}"    ]] || cfg[name]=$name_def
  [[ "${cfg[build]}"   ]] || cfg[build]="Dockerfiles/${cfg[name]}"
  [[ "${cfg[dockerfile]}"   ]] || cfg[dockerfile]="Dockerfile"
  [[ "${cfg[release]}" ]] || cfg[release]="latest"
  [[ "${cfg[image]}"   ]] || cfg[image]=${cfg[project]}_${cfg[name]}
  [[ "${cfg[mode]}"    ]] || cfg[mode]=$(cd $work_dir && git rev-parse --abbrev-ref HEAD 2> /dev/null)
  [[ "${cfg[mode]}"    ]] || cfg[mode]="main"

  # setup log volume
  if [[ "${cfg[log_dir]}" ]] ; then
    # add pwd if host path is relative
    local val=${cfg[log_dir]}
    if [[ $val == "${val#/}" ]] ; then # line does not begin with '/'
      val=$work_dir/$val
    fi
    local d=$val/${cfg[name]}_${cfg[mode]}
    [ -d $d ] || mkdir -p $d
    cfg[args]="${cfg[args]} --volume=$d:/var/log/supervisor"
  fi

  local tag=${cfg[project]}_${cfg[name]}_${cfg[mode]}

  if [[ "$DEBUG" ]] ; then
    cat <<EOF
  ***************************************

  Config file:  $config_file
  Container:    $tag
  Work dir:     $work_dir
  Command:      $cmd

EOF

    # echo all cfg[]
    for t in ${!cfg[*]} ; do echo -e "  $t: \t${cfg[$t]}" ; done
    # echo required configs

    if [[ ${#requires[@]} ]] ; then
      echo "Required images:"
      for (( i = 0 ; i < ${#requires[@]} ; i++ )) ; do
        echo "  ${requires[$i]}"
      done
    fi
    if [[ ${#links[@]} ]] ; then
      echo "Linked images:"
      for (( i = 0 ; i < ${#links[@]} ; i++ )) ; do
        echo "  ${links[$i]}"
      done
    fi
  fi

  LINK="$tag:${cfg[name]}" # save data for parent

  case "$cmd" in
    start)
      # Start dependencies
      for (( i = 0 ; i < ${#requires[@]} ; i++ )) ; do
        app_run $work_dir $cmd ${requires[$i]}
      done

      # Start links
      for (( i = 0 ; i < ${#links[@]} ; i++ )) ; do
        local LINK="" # child container name
        local IP=""   # child has DNS at $IP
        app_run $work_dir $cmd ${links[$i]}
        cfg[args]="${cfg[args]} --link=$LINK"
        [[ "$IP" ]] && cfg[args]="${cfg[args]} --dns=$IP"
      done

      # Start main 
      if image_started $tag ; then
        echo "Tag $tag is active"
      elif image_registered $tag ; then
        echo "Starting $tag..."
        $DOCKER start $tag
      else
        echo "Creating $tag..."
        image_start $tag
      fi
      # save my ip for parent if I have DNS
      [[ "${cfg[hasdns]}" ]] && IP=$($DOCKER inspect --format '{{ .NetworkSettings.IPAddress }}' $tag)
      ;;
    stop)
      image_stop $tag $work_dir
      ;;
    build)
      image_create || exit 1
      ;;
    rm)
      image_stop $tag $work_dir
      image_remove $tag
      # rm dependencies
      alldeps=("${requires[@]}" "${links[@]}")
      [[ "$cmd_ext" == "-a" ]] && for (( i = 0 ; i < ${#alldeps[@]} ; i++ )) ; do app_run $work_dir $cmd ${alldeps[$i]} ; done
      ;;
    init)
      app_config $config_file ${cfg[name]} || exit 1
      ;;
    *)
      app_help
      ;;
  esac

}

# ------------------------------------------------------------------------------
# Program body
# ------------------------------------------------------------------------------

DOCKER=$(which docker.io) || DOCKER=$(which docker)
DOCKER_INFO=$DOCKER
[[ "$DEBUG" == "9" ]] && DOCKER="echo $DOCKER"
#DEBUG="" # 1 - show args, 2 - show parse details

app_run . "$@"
# ------------------------------------------------------------------------------

exit
