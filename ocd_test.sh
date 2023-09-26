#!/usr/bin/env bash
#shellcheck disable=SC1091,SC2086,SC2164
#
# Unit tests for OCD <https://github.com/nycksw/ocd>.

# Tolerate no bullshit.
set -o errexit   # Exit on error.
set -o nounset   # Don't use undeclared variables.
set -o pipefail  # Catch errs from piped cmds.

OCD_TEST_FAILURES="${OCD_TEST_FAILURES:-}"

test_header() {
  # Info header in green.
  echo -e "\\n\\e[1;32mRUNNING: ${FUNCNAME[1]}\\e[0;0m"
  echo
}

test_fail() {
  # Errors in red.
  echo -e "\\n\\e[1;31mFAILED: ${FUNCNAME[1]}\\n\\e[0;0m" > /dev/stderr
  OCD_TEST_FAILURES="${OCD_TEST_FAILURES}\\n${FUNCNAME[1]}"
}

setup() {
  OCD_USER_HOME=$(mktemp -d --suffix='.OCD_USER_HOME')
  OCD_GIT_DIR="${OCD_USER_HOME}.OCD_GIT_DIR"
  OCD_REPO=$(mktemp -d --suffix='.OCD_REPO')
  export OCD_USER_HOME OCD_GIT_DIR OCD_REPO

  export OCD_ASSUME_YES="true"  # Non-interactive mode.

  export OCD_CONF=${OCD_USER_HOME}/.ocd.conf-unused  # No custom env vars for testing.

  git init --bare "${OCD_REPO}" 2>/dev/null
}

test_install() {
  ./ocd.sh install

  # Create test files in git repo.
  mkdir -p ${OCD_GIT_DIR}/a/b/c
  touch "${OCD_GIT_DIR}"/{foo,bar,baz} "${OCD_GIT_DIR}"/a/b/c/qux
  git -C "${OCD_GIT_DIR}" add .
  git -C "${OCD_GIT_DIR}" commit -a -m "Files for testing."
  git -C "${OCD_GIT_DIR}" push

  # Pull the files we created above to the testing repo.
  ./ocd.sh restore
}

test_file_tracking() {
  test_header
  # Add untracked files to the homedir.
  touch "${OCD_USER_HOME}/fred" "${OCD_USER_HOME}/a/b/c/wilma"

	# Add files from homedir to the repo.
  ./ocd.sh add "${OCD_USER_HOME}"/fred "${OCD_USER_HOME}"/a/b/c/wilma
	test -f "${OCD_GIT_DIR}"/fred || test_fail
	test -f "${OCD_GIT_DIR}"/a/b/c/wilma || test_fail
 
	# Stop tracking a file.
  ./ocd.sh rm "${OCD_USER_HOME}"/fred "${OCD_USER_HOME}"/a/b/c/wilma
	test ! -f "${OCD_GIT_DIR}"/fred || test_fail
	test ! -f "${OCD_GIT_DIR}"/a/b/c/wilma || test_fail
}

test_status() {
  echo "Testing status for untracked file..."
  ./ocd.sh status "${OCD_USER_HOME}"/fred
  if ./ocd.sh status "${OCD_USER_HOME}"/fred | grep -q "is tracked"; then test_fail; fi
  echo "Testing status for tracked file..."
  if ./ocd.sh status "${OCD_USER_HOME}"/bar | grep -q "not tracked"; then test_fail; fi
}

test_backup() {
  ./ocd.sh backup
}

test_export() {
  ./ocd.sh export "${OCD_USER_HOME}"/export.tar.gz
  test -f "${OCD_USER_HOME}"/export.tar.gz || test_fail
}

teardown() {
  test_header
  rm -rf "${OCD_GIT_DIR}"
  rm -rf "${OCD_USER_HOME}"
  rm -rf "${OCD_REPO}"
}

setup
test_install
test_file_tracking
test_status
test_backup
test_export
teardown

if [[ -z "${OCD_TEST_FAILURES}" ]]; then
  echo "All tests passed!"
else
  echo -n "Failures: "
  echo -e "${OCD_TEST_FAILURES}"
fi
