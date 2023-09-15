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

  # Option "more info" line with a hanging indentation.
  if [[ -n "${1:-}" ]]; then
    echo -e "${1}"
  fi

  echo
}

test_fail() {
  # Errors in red.
  echo -e "\\n\\e[1;31mFAILED: ${FUNCNAME[1]}\\n\\e[0;0m" > /dev/stderr
  OCD_TEST_FAILURES="${OCD_TEST_FAILURES}\\n${FUNCNAME[1]}"
}

setup() {
  OCD_DIR=$(mktemp -d --suffix='.OCD_DIR')
  OCD_HOME=$(mktemp -d --suffix='.OCD_HOME')
  OCD_REPO=$(mktemp -d --suffix='.OCD_REPO')

  export OCD_ASSUME_YES="true"  # Non-interactive mode.

  git init --bare "${OCD_REPO}"
}

test_install() {
  . ocd.sh

  # Create test files in git repo.
  mkdir -p ${OCD_DIR}/a/b/c
  touch "${OCD_DIR}"/{foo,bar,baz} "${OCD_DIR}"/a/b/c/qux
  git -C "${OCD_DIR}" add .
  git -C "${OCD_DIR}" commit -a -m "Files for testing."
  git -C "${OCD_DIR}" push

  # Pull the files we created above to the testing repo.
  ocd-restore
}

test_file_tracking() {
  # Add untracked files to the homedir.
  touch "${OCD_HOME}/fred" "${OCD_HOME}/a/b/c/wilma"

	# Add files from homedir to the repo.
  ocd-add "${OCD_HOME}"/fred "${OCD_HOME}"/a/b/c/wilma
	test -f "${OCD_DIR}"/fred || test_fail
	test -f "${OCD_DIR}"/a/b/c/wilma || test_fail
 
	# Stop tracking a file.
  ocd-rm "${OCD_HOME}"/fred "${OCD_HOME}"/a/b/c/wilma
	test ! -f "${OCD_DIR}"/fred || test_fail
	test ! -f "${OCD_DIR}"/a/b/c/wilma || test_fail
}

test_status() {
  echo "Testing status for untracked file..."
  if [[ $(ocd-status "${OCD_HOME}"/fred) != "untracked" ]]; then test_fail; fi
  echo "Testing status for tracked file..."
  if [[ $(ocd-status "${OCD_HOME}"/bar) != "tracked" ]]; then test_fail; fi
}

test_backup() {
  ocd-backup
}

test_export() {
  ocd-export "${OCD_HOME}"/export.tar.gz
  test -f "${OCD_HOME}"/export.tar.gz || test_fail
}

teardown() {
  test_header
  rm -rf "${OCD_DIR}"
  rm -rf "${OCD_HOME}"
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
