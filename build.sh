#!/bin/bash

platform=`uname`
if [[ $platform == 'Darwin' ]]; then
	# To install greadlink
	# brew install greadlink
	READLINK=`which greadlink`
else
	READLINK=`which readlink`
fi

docker --version; rc=$?
if [ $rc -ne 0 ]; then
  # Somehow, this is important even though we already have `setup_remote_docker`.
  VER="18.06.1-ce"
  curl -L -o /tmp/docker-$VER.tgz https://download.docker.com/linux/static/stable/x86_64/docker-$VER.tgz
  tar -xz -C /tmp -f /tmp/docker-$VER.tgz
  mv /tmp/docker/* /usr/bin
  docker --version
fi

### Install awscli. Used for pushing container images to ECR.
### You may want to set these environment variables:
### 
###     AWS_ACCESS_KEY_ID
###     AWS_SECRET_ACCESS_KEY
###
# apt update && apt install -y python-pip python-dev
# pip install --user awscli
# export PATH=${PATH}:${HOME}/.local/bin
# aws --version

# Extract commit range (or single commit).
COMMIT_RANGE_SEP="..."
if [[ "x$CI_COMMIT_BEFORE_SHA" == "x" ]]; then
  # CI_COMMIT_BEFORE_SHA defined 
  GIT_COMMIT_NUMBER=`git log --oneline | wc -l | bc`
  if [[ $GIT_COMMIT_NUMBER == "1" ]]; then 
    # 4b825dc642cb6eb9a060e54bf8d69288fbee4904 is magic id which is always exists
    CI_COMMIT_BEFORE_SHA="4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    COMMIT_RANGE_SEP=" "
  else
    CI_COMMIT_BEFORE_SHA=`git rev-parse HEAD~1`
  fi
fi
if [[ "x$CI_COMMIT_SHA" == "x" ]]; then
  # CI_COMMIT_SHA is not defined
  CI_COMMIT_SHA=`git rev-parse HEAD`
fi

COMMIT_RANGE="${CI_COMMIT_BEFORE_SHA}${COMMIT_RANGE_SEP}${CI_COMMIT_SHA}"

# This is the list of all makefiles that we've already built. We don't include the 
# root makefile by default.
BUILT=`${READLINK} -e ${PWD}/Makefile`
echo "${BUILT}" > builtlist

# Main build function. Takes a directory as input.
build () {
  echo "Build input = $1"
  DIRNAME=`echo $1`
  MKFILE=`echo "${DIRNAME}/Makefile"`
  SLASHES=${PWD//[^\/]/}

  # Try walking up the path until we find a makefile.
  for (( n=${#SLASHES}; n>0; --n )); do
    if [ -f $MKFILE ]; then
      echo "Found Makefile in ${DIRNAME}"
      break
    else
      DIRNAME="${DIRNAME}/.."
      MKFILE=`echo "${DIRNAME}/Makefile"`
    fi
  done
  
  # Get the full path of the makefile.
  MKFILE_FULL=`${READLINK} -e ${MKFILE}`
  
  # Build only if it's not on our list of built makefiles.
  BUILT=$(<builtlist)
  if [[ $BUILT != *"${MKFILE_FULL}"* ]]; then
    echo "Build ${DIRNAME} (${MKFILE_FULL})"
    
    # Main build command.
    INCLUDE_MAKEFILE=$MKFILE make release   
    # Add item to our list of built makefiles.
    BUILT=`echo "${BUILT};${MKFILE_FULL}"`
    echo "${BUILT}" > builtlist
  else
    echo "Skip ${MKFILE_FULL} (already built, or root)"
  fi
}

# Prebuild function. Takes a file as input.
processline () {
  line=$1
  echo "Process ${line}"

  if [[ $line == vendor* ]] || [[ $line == pkg* ]]; then
    # The changed line is common. We will iterate through all dirs except hidden ones, 'vendor',
    # and 'pkg' to see if build is necessary.
    find . -type d -not -path "*/\.*" | grep -v 'vendor' | grep -v 'pkg' | while read item; do
      # Get the current package's full list of golang dependencies (recursive).
      PKG_GODEPS=`go list -f '{{ .Deps }}' $item`
      
      if [ $? -eq 0 ]; then
        LINE_DIR=`dirname $line`

        # See if this package has a dependency with the changed file. If so, proceed with build.
        if [[ $PKG_GODEPS = *"${LINE_DIR}"* ]]; then
          echo "'${item}' has a dependency with '${LINE_DIR}'"
          # Remove the './' prefix (output from 'find' command).
          TO_BUILD=`echo "${item}" | cut -c 3-`
          build $TO_BUILD
        fi
      fi
    done
  else
    # The changed line belongs to either a service or cmd.
    TO_BUILD=`dirname $line`
    build $TO_BUILD
  fi
}

echo "Commit range ${COMMIT_RANGE}"

if [[ $COMMIT_RANGE != *"..."* ]]; then
  # Walk through each changed file within the commit.
  echo "No commit range? (${COMMIT_RANGE})"
  git diff-tree --no-commit-id --name-only -r $COMMIT_RANGE | while read line; do
    processline $line
    echo "-"
  done
else
  # Walk through each changed file within the commit range.
  echo "Proper commit range = ${COMMIT_RANGE}"
  git diff --name-only $COMMIT_RANGE | while read line; do
    processline $line
    echo "-"
  done
fi
