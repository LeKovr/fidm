# This script runned via git hook on push
# See gitolite-ci (https://github.com/LeKovr/gitolite-ci)
# ------------------------------------------------------------------------------

# Check if fidm and fidm_nb are installed system-wide

# ------------------------------------------------------------------------------
chk_ln() {
  local N=$1
  if [ ! -L /usr/local/bin/$N ] ; then
    [ -L $N ] || ln -s $PWD/$N.sh $N
    echo "RUN sudo mv $N /usr/local/bin"
  fi
}

# ------------------------------------------------------------------------------

chk_ln fidm
chk_ln fidm_nb

