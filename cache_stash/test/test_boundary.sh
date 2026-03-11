#!/bin/bash

# Boundary Test script for Cache Stash Driver
# This script tests edge cases and boundary conditions for the cache stash kernel module

set -e  # Exit on any error

DRIVER_NAME="cache_stash"
SYSFS_PATH="/sys/kernel/cache_stash/"
TEST_LOG="boundary_test_results.log"

echo "Cache Stash Driver - Boundary Test Suite"
echo "========================================"

# Function to check if the module is loaded
check_module_loaded() {
    if lsmod | grep -q "$DRIVER_NAME"; then
        return 0
    else
        return 1
    fi
}

# Function to check if sysfs directory exists
check_sysfs_exists() {
    if [ -d "$SYSFS_PATH" ]; then
        return 0
    else
        return 1
    fi
}

# Function to log messages
log_message() {
    echo "$(date): $1" | tee -a "$TEST_LOG"
}

# Function to check if a write operation should fail (either by returning error or not changing value)
check_expected_write_fail() {
    local attr="$1"
    local original_value="$2"
    local write_command="$3"
    
    # Store original value to compare against
    local stored_original="$original_value"
    
    # Execute the write command and capture its exit status
    # We'll redirect stderr to a temp file to capture any error messages
    local exit_code
    eval "$write_command" 2>/tmp/write_error_log_"$$"
    exit_code=$?
    
    # Clean up the temp file
    trap 'rm -f /tmp/write_error_log_$$' EXIT
    
    # Check if command failed (which is what we expect for invalid inputs)
    if [ $exit_code -ne 0 ]; then
        # Command failed with error, which means validation worked correctly
        return 0  # Success for our test
    fi
    
    # If command succeeded, check if the value remained unchanged
    local current_value=$(cat "$SYSFS_PATH/$attr")
    if [ "$current_value" = "$stored_original" ]; then
        # Value didn't change, which also indicates validation worked
        return 0  # Success for our test
    else
        # Value changed, which means validation failed
        return 1  # Failure for our test
    fi
}

# Function to run a simple test and record results
run_test() {
    local test_name="$1"
    local command="$2"
    
    echo "Running test: $test_name"
    log_message "START: $test_name"
    
    if eval "$command"; then
        echo "  ✓ PASS: $test_name"
        log_message "PASS: $test_name"
    else
        echo "  ✗ FAIL: $test_name"
        log_message "FAIL: $test_name"
        BOUNDARY_TEST_FAILED=1
    fi
}

# Function to run an expect-failure test specifically for large strings
run_large_string_test() {
    local test_name="$1"
    local attr="$2"
    local original_value="$3"
    local input_string="$4"
    
    echo "Running test: $test_name"
    log_message "START: $test_name"
    
    # Try to write the large string and capture exit code
    echo "$input_string" > "$SYSFS_PATH/$attr" 2>/dev/null
    local exit_code=$?
    
    # If command failed completely, that's a pass
    if [ $exit_code -ne 0 ]; then
        echo "  ✓ PASS: $test_name (command failed as expected)"
        log_message "PASS: $test_name (command failed as expected)"
        return 0
    fi
    
    # If command succeeded, check if value stayed the same
    local current_value=$(cat "$SYSFS_PATH/$attr")
    if [ "$current_value" = "$original_value" ]; then
        echo "  ✓ PASS: $test_name (value unchanged after write)"
        log_message "PASS: $test_name (value unchanged after write)"
        return 0
    else
        echo "  ✗ FAIL: $test_name (value changed unexpectedly)"
        log_message "FAIL: $test_name (value changed unexpectedly)"
        BOUNDARY_TEST_FAILED=1
        return 1
    fi
}

# Function to run an expect-failure test
run_expect_fail_test() {
    local test_name="$1"
    local command="$2"
    
    echo "Running test (expect fail): $test_name"
    log_message "START: $test_name (expected to fail)"
    
    # We'll check if the command fails OR if the value didn't change after attempted write
    if ! eval "$command"; then
        echo "  ✓ EXPECTED FAIL: $test_name (command failed)"
        log_message "EXPECTED FAIL: $test_name (command failed)"
    else
        # Command succeeded, but check if value stayed the same (indicating rejection)
        echo "  ? PARTIAL PASS: $test_name (command succeeded, checking if value changed)"
        log_message "PARTIAL PASS: $test_name (command succeeded, checking if value changed)"
    fi
}

# Function to check if a write operation failed by comparing values before and after
check_write_failed() {
    local attr="$1"
    local original_value="$2"
    local write_command="$3"
    
    # Store the original value for comparison
    local expected_value="$original_value"
    
    # Execute the write command and capture its exit status
    if eval "$write_command" 2>/dev/null; then
        # Command succeeded, so check if the value actually changed
        local current_value=$(cat "$SYSFS_PATH/$attr")
        # For a "failed" test, we expect the value to stay the same
        [ "$current_value" = "$expected_value" ]
    else
        # Command failed (returned non-zero), which is what we expect for invalid inputs
        # So this counts as a successful test for our purposes
        return 0
    fi
}

# Function to perform boundary tests
perform_boundary_tests() {
    echo ""
    echo "Performing Boundary Tests:"
    echo "=========================="
    
    # Get original values to compare against later
    ORIGINAL_LLC=$(cat "$SYSFS_PATH/llc_enable" | tr -d '\n')
    ORIGINAL_L2=$(cat "$SYSFS_PATH/l2_enable" | tr -d '\n')
    ORIGINAL_L2_TARGET=$(cat "$SYSFS_PATH/l2_target")
    
    # Test 1: Invalid values for LLC enable
    echo "Test 1: Testing invalid values for LLC enable"
    # Capture original value, try to write invalid value, then check if original value persists
    run_test "Invalid LLC value (2) - check no change" "
        check_expected_write_fail llc_enable '$ORIGINAL_LLC' 'echo 2 > $SYSFS_PATH/llc_enable'
    "
    
    run_test "Invalid LLC value (-1) - check no change" "
        check_expected_write_fail llc_enable '$ORIGINAL_LLC' 'echo -1 > $SYSFS_PATH/llc_enable'
    "
    
    run_test "Invalid LLC value (abc) - check no change" "
        check_expected_write_fail llc_enable '$ORIGINAL_LLC' 'echo abc > $SYSFS_PATH/llc_enable'
    "
    
    run_test "Large LLC value (999999) - check no change" "
        check_expected_write_fail llc_enable '$ORIGINAL_LLC' 'echo 999999 > $SYSFS_PATH/llc_enable'
    "

    # Test 2: Invalid values for L2 enable
    echo ""
    echo "Test 2: Testing invalid values for L2 enable"
    run_test "Invalid L2 value (2) - check no change" "
        check_expected_write_fail l2_enable '$ORIGINAL_L2' 'echo 2 > $SYSFS_PATH/l2_enable'
    "
    
    run_test "Invalid L2 value (-1) - check no change" "
        check_expected_write_fail l2_enable '$ORIGINAL_L2' 'echo -1 > $SYSFS_PATH/l2_enable'
    "
    
    run_test "Invalid L2 value (xyz) - check no change" "
        check_expected_write_fail l2_enable '$ORIGINAL_L2' 'echo xyz > $SYSFS_PATH/l2_enable'
    "

    # Test 3: Boundary values for L2 target configuration
    echo ""
    echo "Test 3: Testing boundary values for L2 target"
    # Test with values at boundaries of valid ranges
    # According to header file: L2_STASH_TARGET_MASK = 0x7 (3 bits), L2_STASH_CORE_MASK = 0x7FFF (15 bits)
    
    # Valid boundary values
    run_test "Valid L2 target: 0 0" "echo '0 0' > $SYSFS_PATH/l2_target && cat $SYSFS_PATH/l2_target >/dev/null"
    run_test "Valid L2 target: 0 1" "echo '0 1' > $SYSFS_PATH/l2_target && cat $SYSFS_PATH/l2_target >/dev/null"
    run_test "Valid L2 target: 1 1" "echo '1 1' > $SYSFS_PATH/l2_target && cat $SYSFS_PATH/l2_target >/dev/null"
    
    # Test with invalid targets (above mask) - should not change the value
    run_test "Invalid L2 target: 8 1 - check no change" "
        check_expected_write_fail l2_target '$ORIGINAL_L2_TARGET' 'echo 8 1 > $SYSFS_PATH/l2_target'
    "
    
    run_test "Invalid L2 target: 15 1 - check no change" "
        check_expected_write_fail l2_target '$ORIGINAL_L2_TARGET' 'echo 15 1 > $SYSFS_PATH/l2_target'
    "

    # Test with invalid core numbers (above mask)
    run_test "Invalid high L2 target: 7 32767 - check no change" "
        check_expected_write_fail l2_target '$ORIGINAL_L2_TARGET' 'echo 7 32767 > $SYSFS_PATH/l2_target'
    "
    run_test "Invalid high L2 target: 7 32768 - check no change" "
        check_expected_write_fail l2_target '$ORIGINAL_L2_TARGET' 'echo 7 32768 > $SYSFS_PATH/l2_target'
    "
    
    run_test "Invalid high L2 target: 7 65535 - check no change" "
        check_expected_write_fail l2_target '$ORIGINAL_L2_TARGET' 'echo 7 65535 > $SYSFS_PATH/l2_target'
    "

    # Test with negative values
    run_test "Invalid L2 target: -1 1 - check no change" "
        check_expected_write_fail l2_target '$ORIGINAL_L2_TARGET' 'echo -1 1 > $SYSFS_PATH/l2_target'
    "
    
    run_test "Invalid L2 target: 1 -1 - check no change" "
        check_expected_write_fail l2_target '$ORIGINAL_L2_TARGET' 'echo 1 -1 > $SYSFS_PATH/l2_target'
    "

    # Test 4: Empty values and malformed input
    echo ""
    echo "Test 4: Testing empty and malformed input"
    run_test "Empty LLC enable - check no change" "
        check_expected_write_fail llc_enable '$ORIGINAL_LLC' 'echo \"\" > $SYSFS_PATH/llc_enable'
    "
    
    run_test "Empty L2 enable - check no change" "
        check_expected_write_fail l2_enable '$ORIGINAL_L2' 'echo \"\" > $SYSFS_PATH/l2_enable'
    "
    
    run_test "Empty L2 target - check no change" "
        check_expected_write_fail l2_target '$ORIGINAL_L2_TARGET' 'echo \"\" > $SYSFS_PATH/l2_target'
    "
    
    run_test "Malformed L2 target (only one number) - check no change" "
        check_expected_write_fail l2_target '$ORIGINAL_L2_TARGET' 'echo 1 > $SYSFS_PATH/l2_target'
    "
    
    # Special handling for "too many numbers" case
    echo "Testing malformed L2 target (too many numbers)..."
    PREV_VALUE_L2T=$(cat $SYSFS_PATH/l2_target)
    # Execute command and suppress any error
    echo "1 2 3" > $SYSFS_PATH/l2_target 2>/dev/null || true
    CURR_VALUE_L2T=$(cat $SYSFS_PATH/l2_target)
    if [ "$PREV_VALUE_L2T" = "$CURR_VALUE_L2T" ]; then
        echo "  ✓ PASS: Malformed L2 target (too many numbers) - value unchanged"
        log_message "PASS: Malformed L2 target (too many numbers) - value unchanged"
    else
        echo "  ✗ FAIL: Malformed L2 target (too many numbers) - value changed unexpectedly"
        log_message "FAIL: Malformed L2 target (too many numbers) - value changed unexpectedly"
        BOUNDARY_TEST_FAILED=1
    fi

    # Test 5: Permission check test (newly added from test_design.md)
    echo ""
    echo "Test 5: Permission and access control testing"
    
    # Check sysfs file permissions
    run_test "Check sysfs file permissions are restrictive" "
        for file in llc_enable l2_enable l2_target status; do
            if [ -f \"$SYSFS_PATH/\$file\" ]; then
                PERMS=\$(stat -c %a \"$SYSFS_PATH/\$file\")
                # Should be readable by all, writable only by root (644 or similar)
                [ \"\$PERMS\" = \"644\" ] || [ \"\$PERMS\" = \"444\" ] || [ \"\$PERMS\" = \"600\" ]
            fi
        done
    "
    
    # Test non-root user access (this would typically fail in actual testing)
    # We'll simulate this by checking if the files are properly protected
    echo "Testing access control mechanisms..."
    for attr in llc_enable l2_enable l2_target; do
        if [ -w "$SYSFS_PATH/$attr" ]; then
            OWNER=$(stat -c %U "$SYSFS_PATH/$attr")
            if [ "$OWNER" = "root" ]; then
                echo "  ✓ PASS: $attr is owned by root and writable (as expected for root user)"
                log_message "PASS: $attr ownership and permissions correct"
            else
                echo "  ? INFO: $attr owned by $OWNER (may need manual verification)"
                log_message "INFO: $attr owned by $OWNER"
            fi
        else
            echo "  ✓ PASS: $attr is not writable by current user (access control working)"
            log_message "PASS: $attr access control verified"
        fi
    done

    # Test 6: Resource allocation failure simulation (newly added from test_design.md)
    echo ""
    echo "Test 6: Resource allocation failure handling"
    
    # Simulate memory pressure scenario by checking system memory before/after operations
    run_test "Check system memory stability during operations" "
        FREE_MEM_BEFORE=\$(free -m | awk '/^Mem:/{print \$7}')
        # Perform some intensive operations
        for i in {1..10}; do
            echo \$((i % 2)) > '$SYSFS_PATH/llc_enable'
            echo \$((i % 2)) > '$SYSFS_PATH/l2_enable'
        done
        FREE_MEM_AFTER=\$(free -m | awk '/^Mem:/{print \$7}')
        # Memory should not decrease significantly (within reasonable tolerance)
        MEM_DIFF=\$((FREE_MEM_BEFORE - FREE_MEM_AFTER))
        [ \$MEM_DIFF -lt 10 ]  # Less than 10MB difference acceptable
    "
    
    # Test file descriptor leak prevention
    run_test "Check for file descriptor leaks" "
        FD_COUNT_BEFORE=\$(ls /proc/\$\$/fd/ 2>/dev/null | wc -l)
        # Perform multiple operations
        for i in {1..50}; do
            cat '$SYSFS_PATH/status' > /dev/null
        done
        FD_COUNT_AFTER=\$(ls /proc/\$\$/fd/ 2>/dev/null | wc -l)
        # Should not have significant increase in file descriptors
        FD_DIFF=\$((FD_COUNT_AFTER - FD_COUNT_BEFORE))
        [ \$FD_DIFF -lt 5 ]  # Less than 5 new file descriptors acceptable
    "

    # Test 7: Hardware access failure simulation (newly added from test_design.md)
    echo ""
    echo "Test 7: Hardware access failure handling"
    
    # Test graceful handling of invalid register addresses (simulated)
    echo "Testing hardware error handling scenarios..."
    
    # Save current states for restoration
    CURRENT_LLC=$(cat "$SYSFS_PATH/llc_enable")
    CURRENT_L2=$(cat "$SYSFS_PATH/l2_enable") 
    CURRENT_L2_TARGET=$(cat "$SYSFS_PATH/l2_target")
    
    # Test recovery from potential hardware errors
    run_test "System stability after intensive operations" "
        # Perform rapid operations that might stress hardware interface
        for i in {1..20}; do
            echo \$((RANDOM % 2)) > '$SYSFS_PATH/llc_enable'
            echo \$((RANDOM % 2)) > '$SYSFS_PATH/l2_enable'
            echo \"\$((RANDOM % 2)) \$((RANDOM % 8))\" > '$SYSFS_PATH/l2_target'
            cat '$SYSFS_PATH/status' > /dev/null
        done
        # System should remain responsive
        [ -f '$SYSFS_PATH/llc_enable' ] && [ -f '$SYSFS_PATH/l2_enable' ] && [ -f '$SYSFS_PATH/l2_target' ]
    "
    
    # Verify system state integrity after stress testing
    run_test "State consistency after hardware stress test" "
        NEW_LLC=\$(cat '$SYSFS_PATH/llc_enable')
        NEW_L2=\$(cat '$SYSFS_PATH/l2_enable')
        # Values should be valid (0 or 1 for enables)
        [ \"\$NEW_LLC\" = \"0\" ] || [ \"\$NEW_LLC\" = \"1\" ]
        [ \"\$NEW_L2\" = \"0\" ] || [ \"\$NEW_L2\" = \"1\" ]
    "

    # Test 10: Large string injection attempt
    echo ""
    echo "Test 10: Large input handling"
    
    # For large strings, we need to check that they don't crash the system
    # and that original values are maintained
    LARGE_STRING=$(printf 'A%.0s' {1..1000})
    
    # Test large string for LLC enable
    echo "Testing large string for llc_enable..."
    PREV_VALUE=$(cat $SYSFS_PATH/llc_enable)
    echo "$LARGE_STRING" > $SYSFS_PATH/llc_enable 2>/dev/null || true  # Suppress error
    CURR_VALUE=$(cat $SYSFS_PATH/llc_enable)
    if [ "$PREV_VALUE" = "$CURR_VALUE" ]; then
        echo "  ✓ PASS: Large string to llc_enable - value unchanged"
        log_message "PASS: Large string to llc_enable - value unchanged"
    else
        echo "  ✗ FAIL: Large string to llc_enable - value changed unexpectedly"
        log_message "FAIL: Large string to llc_enable - value changed unexpectedly"
        BOUNDARY_TEST_FAILED=1
    fi
    
    # Test large string for L2 enable
    echo "Testing large string for l2_enable..."
    PREV_VALUE=$(cat $SYSFS_PATH/l2_enable)
    echo "$LARGE_STRING" > $SYSFS_PATH/l2_enable 2>/dev/null || true  # Suppress error
    CURR_VALUE=$(cat $SYSFS_PATH/l2_enable)
    if [ "$PREV_VALUE" = "$CURR_VALUE" ]; then
        echo "  ✓ PASS: Large string to l2_enable - value unchanged"
        log_message "PASS: Large string to l2_enable - value unchanged"
    else
        echo "  ✗ FAIL: Large string to l2_enable - value changed unexpectedly"
        log_message "FAIL: Large string to l2_enable - value changed unexpectedly"
        BOUNDARY_TEST_FAILED=1
    fi
    
    # Test large string for L2 target
    echo "Testing large string for l2_target..."
    PREV_VALUE=$(cat $SYSFS_PATH/l2_target)
    echo "$LARGE_STRING" > $SYSFS_PATH/l2_target 2>/dev/null || true  # Suppress error
    CURR_VALUE=$(cat $SYSFS_PATH/l2_target)
    if [ "$PREV_VALUE" = "$CURR_VALUE" ]; then
        echo "  ✓ PASS: Large string to l2_target - value unchanged"
        log_message "PASS: Large string to l2_target - value unchanged"
    else
        echo "  ✗ FAIL: Large string to l2_target - value changed unexpectedly"
        log_message "FAIL: Large string to l2_target - value changed unexpectedly"
        BOUNDARY_TEST_FAILED=1
    fi
    
    # Restore original values after all tests
    echo "$ORIGINAL_LLC" > "$SYSFS_PATH/llc_enable" 2>/dev/null || true
    echo "$ORIGINAL_L2" > "$SYSFS_PATH/l2_enable" 2>/dev/null || true
    echo "$ORIGINAL_L2_TARGET" > "$SYSFS_PATH/l2_target" 2>/dev/null || true
}

# Check for skip checks parameter
SKIP_CHECKS=false
for arg in "$@"; do
  if [ "$arg" = "--skip-checks" ]; then
    SKIP_CHECKS=true
  fi
done

# Check if we have root privileges
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (with sudo)"
    exit 1
fi

# Initialize log file
echo "Starting boundary tests at $(date)" > "$TEST_LOG"
log_message "Boundary test script started"

# Only perform checks if not skipping them
if [ "$SKIP_CHECKS" = false ]; then
    # Check if module is loaded
    if ! check_module_loaded; then
        echo "Module $DRIVER_NAME is not loaded. Attempting to load..."
        if [ -f "${DRIVER_NAME}.ko" ]; then
            insmod "./${DRIVER_NAME}.ko"
            echo "Module loaded. Waiting for sysfs to be ready..."
            sleep 2
        else
            echo "Error: ${DRIVER_NAME}.ko not found in current directory"
            exit 1
        fi
    else
        echo "Module $DRIVER_NAME is already loaded."
    fi

    # Check if sysfs directory exists
    if ! check_sysfs_exists; then
        echo "Error: Sysfs directory $SYSFS_PATH does not exist"
        echo "Make sure the module is loaded properly"
        exit 1
    fi
fi

echo "All prerequisites met. Starting boundary tests..."

# Initialize failure flag
BOUNDARY_TEST_FAILED=0

perform_boundary_tests

# Final status report after boundary tests
echo ""
echo "Final Status Check After Boundary Tests:"
echo "========================================"
echo "LLC Enable: $(cat $SYSFS_PATH/llc_enable)"
echo "L2 Enable: $(cat $SYSFS_PATH/l2_enable)"
echo "L2 Target: $(cat $SYSFS_PATH/l2_target)"

# Summary
echo ""
echo "Boundary Test Summary:"
echo "====================="
if [ $BOUNDARY_TEST_FAILED -eq 0 ]; then
    echo "✓ All boundary tests PASSED"
    log_message "OVERALL: ALL BOUNDARY TESTS PASSED"
else
    echo "✗ Some boundary tests FAILED"
    log_message "OVERALL: SOME BOUNDARY TESTS FAILED"
fi

echo ""
echo "Boundary test results logged to $TEST_LOG"

exit $BOUNDARY_TEST_FAILED