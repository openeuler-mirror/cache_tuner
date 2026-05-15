#!/bin/bash

# Performance Test Script for Cache Stash Driver
# This script tests the performance characteristics of the cache stash kernel module
#
# Usage: ./test_performance.sh [--skip-checks]
#   --skip-checks: Skip module loading and sysfs checks, assume environment is ready

set -e  # Exit on any error

DRIVER_NAME="cache_stash"
SYSFS_PATH="/sys/kernel/cache_stash/"
TEST_LOG="performance_test_results.log"

echo "Cache Stash Driver - Performance Test Script"
echo "============================================"

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

# Function to measure sysfs read operations performance
measure_sysfs_read_performance() {
    local sysfs_file="$1"
    local iterations="${2:-1000}"
    
    if [ ! -f "$sysfs_file" ]; then
        echo "Error: $sysfs_file does not exist"
        return 1
    fi
    
    echo "Measuring sysfs read performance for: $sysfs_file"
    log_message "SYSFS READ PERFORMANCE: $sysfs_file ($iterations iterations)"
    
    # Use a tight loop with minimal shell overhead
    local start_time=$(date +%s%N)
    
    # Execute reads in a subshell to minimize interference
    (
        for i in $(seq 1 $iterations); do
            cat "$sysfs_file" > /dev/null
        done
    )
    
    local end_time=$(date +%s%N)
    local elapsed_ns=$((end_time - start_time))
    local elapsed_ms=$(echo "scale=3; $elapsed_ns / 1000000" | bc -l)
    local avg_us=$(echo "scale=1; $elapsed_ns / $iterations / 1000" | bc -l)
    
    echo "Sysfs read results for $sysfs_file:"
    echo "  Total time: ${elapsed_ms}ms"
    echo "  Average time per read: ${avg_us}μs"
    echo "  Reads per second: $(echo "scale=0; $iterations * 1000000000 / $elapsed_ns" | bc -l)"
    echo ""
    
    log_message "SYSFS READ RESULT: $sysfs_file - Total: ${elapsed_ms}ms, Avg: ${avg_us}μs, Reads/sec: $(echo "scale=0; $iterations * 1000000000 / $elapsed_ns" | bc -l)"
}

# Function to measure sysfs write operations performance
measure_sysfs_write_performance() {
    local sysfs_file="$1"
    local test_value="$2"
    local iterations="${3:-1000}"
    
    if [ ! -f "$sysfs_file" ]; then
        echo "Error: $sysfs_file does not exist"
        return 1
    fi
    
    echo "Measuring sysfs write performance for: $sysfs_file"
    log_message "SYSFS WRITE PERFORMANCE: $sysfs_file ($iterations iterations)"
    
    local start_time=$(date +%s%N)
    
    # Execute writes in a subshell
    (
        for i in $(seq 1 $iterations); do
            echo "$test_value" > "$sysfs_file"
        done
    )
    
    local end_time=$(date +%s%N)
    local elapsed_ns=$((end_time - start_time))
    local elapsed_ms=$(echo "scale=3; $elapsed_ns / 1000000" | bc -l)
    local avg_us=$(echo "scale=1; $elapsed_ns / $iterations / 1000" | bc -l)
    
    echo "Sysfs write results for $sysfs_file:"
    echo "  Total time: ${elapsed_ms}ms"
    echo "  Average time per write: ${avg_us}μs"
    echo "  Writes per second: $(echo "scale=0; $iterations * 1000000000 / $elapsed_ns" | bc -l)"
    echo ""
    
    log_message "SYSFS WRITE RESULT: $sysfs_file - Total: ${elapsed_ms}ms, Avg: ${avg_us}μs, Writes/sec: $(echo "scale=0; $iterations * 1000000000 / $elapsed_ns" | bc -l)"
}

# Function to measure mixed operations performance
measure_mixed_operations_performance() {
    local operation_name="$1"
    local operation_script="$2"
    local iterations="${3:-100}"
    
    echo "Measuring mixed operations performance: $operation_name"
    log_message "MIXED OPERATIONS TEST: $operation_name ($iterations iterations)"
    
    local start_time=$(date +%s%N)
    
    # Execute the operation script in a subshell
    (
        eval "$operation_script"
    )
    
    local end_time=$(date +%s%N)
    local elapsed_ns=$((end_time - start_time))
    local elapsed_ms=$(echo "scale=3; $elapsed_ns / 1000000" | bc -l)
    local avg_us=$(echo "scale=1; $elapsed_ns / $iterations / 1000" | bc -l)
    
    echo "Mixed operations results for $operation_name:"
    echo "  Total time: ${elapsed_ms}ms"
    echo "  Average time per operation: ${avg_us}μs"
    echo "  Operations per second: $(echo "scale=0; $iterations * 1000000000 / $elapsed_ns" | bc -l)"
    echo ""
    
    log_message "MIXED OPERATIONS RESULT: $operation_name - Total: ${elapsed_ms}ms, Avg: ${avg_us}μs, Ops/sec: $(echo "scale=0; $iterations * 1000000000 / $elapsed_ns" | bc -l)"
}

# Function to perform detailed performance tests
perform_performance_tests() {
    echo ""
    echo "Performing Performance Tests:"
    echo "============================="
    
    # Test 1: Sysfs Read Performance
    echo "Test 1: Measuring sysfs read performance"
    
    measure_sysfs_read_performance "$SYSFS_PATH/llc_enable" 1000
    measure_sysfs_read_performance "$SYSFS_PATH/l2_enable" 1000
    measure_sysfs_read_performance "$SYSFS_PATH/l2_target" 1000
    measure_sysfs_read_performance "$SYSFS_PATH/status" 100
    
    # Test 2: Sysfs Write Performance
    echo ""
    echo "Test 2: Measuring sysfs write performance"
    
    measure_sysfs_write_performance "$SYSFS_PATH/llc_enable" "1" 100
    measure_sysfs_write_performance "$SYSFS_PATH/llc_enable" "0" 100
    measure_sysfs_write_performance "$SYSFS_PATH/l2_enable" "1" 100
    measure_sysfs_write_performance "$SYSFS_PATH/l2_enable" "0" 100
    measure_sysfs_write_performance "$SYSFS_PATH/l2_target" "0 1" 100
    
    # Test 3: Mixed Operations Performance
    echo ""
    echo "Test 3: Measuring mixed operations performance"
    
    # LLC enable/disable sequence
    measure_mixed_operations_performance "LLC Enable/Disable Sequence" "
        for i in \$(seq 1 $iterations); do
            echo 1 > '$SYSFS_PATH/llc_enable'
            echo 0 > '$SYSFS_PATH/llc_enable'
        done
    " 50
    
    # L2 enable/disable sequence
    measure_mixed_operations_performance "L2 Enable/Disable Sequence" "
        for i in \$(seq 1 $iterations); do
            echo 1 > '$SYSFS_PATH/l2_enable'
            echo 0 > '$SYSFS_PATH/l2_enable'
        done
    " 50
    
    # L2 target configuration
    measure_mixed_operations_performance "L2 Target Configuration" "
        for i in \$(seq 1 $iterations); do
            echo '0 1' > '$SYSFS_PATH/l2_target'
        done
    " 50
    
    # Complex mixed operations
    measure_mixed_operations_performance "Complex Mixed Operations" "
        for i in \$(seq 1 $iterations); do
            case \$((RANDOM % 3)) in
                0) echo \$((RANDOM % 2)) > '$SYSFS_PATH/llc_enable' ;;
                1) echo \$((RANDOM % 2)) > '$SYSFS_PATH/l2_enable' ;;
                2) echo '0 1' > '$SYSFS_PATH/l2_target' ;;
            esac
        done
    " 100
    
    echo ""
    echo "Performance testing completed"
}

# Check if we have root privileges
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (with sudo)"
    exit 1
fi

# Initialize log file
echo "Starting performance tests at $(date)" > "$TEST_LOG"
log_message "Performance test script started"

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

echo "All prerequisites met. Starting performance tests..."

perform_performance_tests

# Summary
echo ""
echo "Performance Test Summary:"
echo "========================"
echo "Tests completed. Detailed results logged to $TEST_LOG"
echo "Performance metrics recorded for LLC operations, L2 operations, and status queries."

exit 0