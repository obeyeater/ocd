#!/usr/bin/env bash
#
# Unit tests for OCD <https://github.com/nycksw/ocd>.

setup() {
	PASS=''
	FAIL=''
	TMP=$(mktemp -d)

  OCD_DIR=$(mktemp -d --suffix='_OCD_DIR')
  OCD_HOME=$(mktemp -d --suffix='_OCD_HOME')
  OCD_REPO=$(mktemp -d --suffix='_OCD_REPO')

  OCD_ASSUME_YES="true"  # Non-interactive mode.

  # Create test git repo.
  touch "${OCD_REPO}"/{foo,bar,baz}
  mkdir -p ${OCD_REPO}/a/b/c
  touch "${OCD_REPO}"/a/b/c/qux

  git init ${OCD_REPO}
  if pushd "${OCD_REPO}"; then
    git add .
    git commit -a -m 'testing'
	popd; fi

  # Add an untracked file to the homedir.
  touch "${OCD_HOME}/fred"
}

test_install() {
  . ocd.sh
}

test_file_tracking() {
	# Add file from homedir to the repo.
  ocd-add "${OCD_HOME}"/fred
	test -f "${OCD_DIR}"/fred || echo "failed ${FUNCNAME[0]}"
}

teardown() {
  rm -rf "${OCD_DIR}"
  rm -rf "${OCD_HOME}"
  rm -rf "${OCD_REPO}"
  rm -rf "${TMP}"
}

setup
test_install
test_file_tracking
teardown
