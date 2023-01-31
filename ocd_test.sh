#!/bin/bash
#
# Unit tests for OCD <https://github.com/nycksw/ocd>.

oneTimeSetUp() {
  OCD_DIR=$(mktemp -d --suffix='_OCD_DIR')
  OCD_HOME=$(mktemp -d --suffix='_OCD_HOME')
  OCD_REPO=$(mktemp -d --suffix='_OCD_REPO')

  # Create test git repo.
  touch "${OCD_REPO}/{foo,bar,baz}"
  mkdir -p ${OCD_REPO}/a/b/c
  touch "${OCD_REPO}/a/b/c/qux}"
  git init ${OCD_REPO}
  pushd "${OCD_REPO}"
  git add .
  git commit -a -m 'testing'
  popd

  # Add an untracked file to the homedir.
  touch "${OCD_HOME}/fred"

  # Assume the OCD we want to test is in the same directory as this test.
  basedir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  . ${basedir}/ocd.sh
}

oneTimeTearDown() {
  rm -rf "${OCD_DIR}"
  rm -rf "${OCD_HOME}"
  rm -rf "${OCD_REPO}"
}

. $(command -v shunit2)
