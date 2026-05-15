#!/bin/bash

# Test script for Cache Stash Driver
# This script tests the functionality of the cache stash kernel module
#
# Usage: ./test_functional.sh [--skip-checks]
#   --skip-checks: Skip module loading and sysfs checks, assume environment is ready

set -e  # Exit on any error

DRIVER_NAME="cache_stash"
SYSFS_PATH="/sys/kernel/cache_stash/"
TEST_LOG="test_results.log"

echo "Cache Stash Driver - Automated Test Script"
echo "=========================================="

# Check for skip checks parameter
SKIP_CHECKS=false
for arg in "$@"; do
  if [ "$arg" = "--skip-checks" ]; then
    SKIP_CHECKS=true
  fi
done

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
        TEST_FAILED=1
    fi
}

# Function to perform detailed testing of the cache stash functionality
perform_detailed_tests() {
    echo ""
    echo "Performing Detailed Tests:"
    echo "=========================="
    
    # Test 1: Check if all required attributes exist
    echo "Test 1: Checking required sysfs attributes"
    for attr in llc_enable l2_enable l2_target status; do
        if [ -f "$SYSFS_PATH$attr" ]; then
            echo "  ✓ Found $attr"
            log_message "Found $attr"
        else
            echo "  ✗ Missing $attr"
            log_message "MISSING: $attr"
            TEST_FAILED=1
        fi
    done

    # Test 2: Read initial states
    echo ""
    echo "Test 2: Reading initial states"
    run_test "Read LLC enable state" "cat $SYSFS_PATH/llc_enable"
    run_test "Read L2 enable state" "cat $SYSFS_PATH/l2_enable"
    run_test "Read L2 target state" "cat $SYSFS_PATH/l2_target"
    run_test "Read status" "cat $SYSFS_PATH/status"

    # Test 3: Toggle LLC stash enable
    echo ""
    echo "Test 3: Testing LLC stash enable/disable"
    ORIGINAL_LLC_STATE=$(cat "$SYSFS_PATH/llc_enable" | tr -d '\n')
    NEW_LLC_STATE=$((1 - ORIGINAL_LLC_STATE))

    run_test "Write LLC enable ($NEW_LLC_STATE)" "echo $NEW_LLC_STATE > $SYSFS_PATH/llc_enable"
    sleep 0.1
    run_test "Verify LLC state changed" "[ \$(cat $SYSFS_PATH/llc_enable | tr -d '\n') -eq $NEW_LLC_STATE ]"
    run_test "Restore LLC original state ($ORIGINAL_LLC_STATE)" "echo $ORIGINAL_LLC_STATE > $SYSFS_PATH/llc_enable"
    sleep 0.1
    run_test "Verify LLC state restored" "[ \$(cat $SYSFS_PATH/llc_enable | tr -d '\n') -eq $ORIGINAL_LLC_STATE ]"

    # Test 4: Toggle L2 stash enable
    echo ""
    echo "Test 4: Testing L2 stash enable/disable"
    ORIGINAL_L2_STATE=$(cat "$SYSFS_PATH/l2_enable" | tr -d '\n')
    NEW_L2_STATE=$((1 - ORIGINAL_L2_STATE))

    run_test "Write L2 enable ($NEW_L2_STATE)" "echo $NEW_L2_STATE > $SYSFS_PATH/l2_enable"
    sleep 0.1
    run_test "Verify L2 state changed" "[ \$(cat $SYSFS_PATH/l2_enable | tr -d '\n') -eq $NEW_L2_STATE ]"
    run_test "Restore L2 original state ($ORIGINAL_L2_STATE)" "echo $ORIGINAL_L2_STATE > $SYSFS_PATH/l2_enable"
    sleep 0.1
    run_test "Verify L2 state restored" "[ \$(cat $SYSFS_PATH/l2_enable | tr -d '\n') -eq $ORIGINAL_L2_STATE ]"

    # Test 5: Configure L2 target
    echo ""
    echo "Test 5: Testing L2 target configuration"
    ORIGINAL_L2_TARGET=$(head -c 1 "$SYSFS_PATH/l2_target")

    run_test "Configure L2 target to default (0 1)" "echo '0 1' > $SYSFS_PATH/l2_target"
    sleep 0.5
    run_test "Read back L2 target" "cat $SYSFS_PATH/l2_target"

    # Test 6: Check register values in status
    echo ""
    echo "Test 6: Validating register details in status"
    run_test "Status contains LLC register details" "grep -q 'LLC Register' $SYSFS_PATH/status"
    run_test "Status contains L2 register details" "grep -q 'L2 Register' $SYSFS_PATH/status"

    # Test 7: Multiple read/write cycles (stress test)
    echo ""
    echo "Test 7: Stress test - multiple read/writes"
    run_test "Multiple LLC enable toggles" '
    for i in {1..5}; do
      echo 1 > '"$SYSFS_PATH"'llc_enable
      sleep 0.1
      echo 0 > '"$SYSFS_PATH"'llc_enable
      sleep 0.1
    done
    [ -f '"$SYSFS_PATH"'llc_enable ]'

    # Test 8: Multi-threaded access test (concurrent safety)
    echo ""
    echo "Test 8: Multi-threaded concurrent access test"
    
    run_test "Concurrent multi-threaded access (5 threads, 50 iterations each)" "
        perform_concurrent_test 5 50
    "

    # Test 9: Mixed operations test (stability under mixed workload)
    echo ""
    echo "Test 9: Mixed operations stability test"
    
    run_test "Mixed LLC and L2 configuration operations with frequent status reads" "
        perform_mixed_operations_test
    "
}

# Function to perform concurrent multi-threaded access test
perform_concurrent_test() {
    local thread_count=${1:-5}
    local iterations_per_thread=${2:-50}
    local sysfs_path="$SYSFS_PATH"
    
    echo "Starting concurrent test with $thread_count threads, $iterations_per_thread iterations each"
    
    # Function to run in background threads
    concurrent_worker() {
        local thread_id=$1
        local iter_count=$2
        local path=$3
        
        echo "Thread $thread_id starting concurrent test..."
        
        for i in $(seq 1 $iter_count); do
            # Random operations to simulate real-world usage
            case $((RANDOM % 6)) in
                0) echo 1 > "$path/llc_enable" ;;
                1) echo 0 > "$path/llc_enable" ;;
                2) echo 1 > "$path/l2_enable" ;;
                3) echo 0 > "$path/l2_enable" ;;
                4) echo "0 1" > "$path/l2_target" ;;
                5) cat "$path/status" > /dev/null ;;
            esac
            
            # Small delay to allow interleaving
            sleep 0.0$((RANDOM % 100))
        done
        
        echo "Thread $thread_id completed"
    }
    export -f concurrent_worker
    
    # Start background threads
    local pids=()
    for thread in $(seq 1 $thread_count); do
        concurrent_worker $thread $iterations_per_thread "$sysfs_path" &
        pids+=($!)
    done
    
    # Wait for all threads to complete
    for pid in "${pids[@]}"; do
        wait $pid
    done
    
    # Verify system integrity after concurrent access
    [ -f "$sysfs_path/llc_enable" ] && [ -f "$sysfs_path/l2_enable" ] && [ -f "$sysfs_path/l2_target" ]
}

# Function to perform mixed operations test
perform_mixed_operations_test() {
    local sysfs_path="$SYSFS_PATH"
    
    # Save original states
    local original_llc=$(cat "$sysfs_path/llc_enable" | tr -d '\n')
    local original_l2_enable=$(cat "$sysfs_path/l2_enable" | tr -d '\n')
    local original_l2_target=$(cat "$sysfs_path/l2_target")
    
    echo "Testing mixed LLC and L2 configuration operations"
    
    # Perform mixed operations simultaneously
    echo 1 > "$sysfs_path/llc_enable" &
    echo "0 1" > "$sysfs_path/l2_target" &
    echo 1 > "$sysfs_path/l2_enable" &
    wait
    
    # Verify final states are consistent
    sleep 0.5
    local llc_state=$(cat "$sysfs_path/llc_enable" | tr -d '\n')
    local l2_enable_state=$(cat "$sysfs_path/l2_enable" | tr -d '\n')
    
    if [ "$llc_state" != "1" ] || [ "$l2_enable_state" != "1" ]; then
        echo "Mixed operations test failed: unexpected final states"
        return 1
    fi
    
    echo "Testing frequent status reads during configuration"
    
    # Start background configuration
    (
        for i in {1..10}; do
            echo $((i % 2)) > "$sysfs_path/llc_enable"
            sleep 0.05
        done
    ) &
    local config_pid=$!
    
    # Frequently read status during configuration
    local status_read_count=0
    while kill -0 $config_pid 2>/dev/null; do
        cat "$sysfs_path/status" > /dev/null
        status_read_count=$((status_read_count + 1))
        sleep 0.02
    done
    
    wait $config_pid
    
    if [ $status_read_count -le 20 ]; then
        echo "Insufficient status reads during configuration: $status_read_count"
        return 1
    fi
    
    # Restore original states
    echo "$original_llc" > "$sysfs_path/llc_enable"
    echo "$original_l2_enable" > "$sysfs_path/l2_enable"
    echo "$original_l2_target" > "$sysfs_path/l2_target"
    sleep 0.5
    
    # Verify system state consistency
    local current_llc=$(cat "$sysfs_path/llc_enable" | tr -d '\n')
    local current_l2_enable=$(cat "$sysfs_path/l2_enable" | tr -d '\n')
    
    [ "$current_llc" = "$original_llc" ] && [ "$current_l2_enable" = "$original_l2_enable" ]
}

# Check if we have root privileges
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (with sudo)"
    exit 1
fi

# Initialize log file
echo "Starting tests at $(date)" > "$TEST_LOG"
log_message "Test script started"

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

echo "All prerequisites met. Starting tests..."

# Initialize failure flag
TEST_FAILED=0

perform_detailed_tests

# Final status report
echo ""
echo "Final Status Check:"
echo "==================="
echo "LLC Enable: $(cat $SYSFS_PATH/llc_enable)"
echo "L2 Enable: $(cat $SYSFS_PATH/l2_enable)"
echo "L2 Target: $(cat $SYSFS_PATH/l2_target)"

# Summary
echo ""
echo "Test Summary:"
echo "============="
if [ $TEST_FAILED -eq 0 ]; then
    echo "✓ All tests PASSED"
    log_message "OVERALL: ALL TESTS PASSED"
else
    echo "✗ Some tests FAILED"
    log_message "OVERALL: SOME TESTS FAILED"
fi

echo ""
echo "Test results logged to $TEST_LOG"

# Optionally unload the module after tests
if [ "$SKIP_CHECKS" = false ]; then
    read -p "Unload module after tests? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rmmod "$DRIVER_NAME"
        echo "Module unloaded"
    fi
else
    echo "Running with --skip-checks, manual cleanup required if needed"
fi

exit $TEST_FAILED