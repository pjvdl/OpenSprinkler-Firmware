#!/bin/bash

# Network Connectivity Monitor for Debian
# Monitors network connectivity and logs status changes

# Configuration
INTERVAL=30                   # Check interval in seconds
LOG_FILE="/var/log/network_monitor.log"  # Log file path
HOSTS=("8.8.8.8" "1.1.1.1")   # Default hosts to ping (Google DNS, Cloudflare DNS)
PING_COUNT=2                  # Number of ping packets to send
PING_TIMEOUT=3                # Ping timeout in seconds
ALERT_ON_FAILURE=true         # Alert when connectivity is lost
ALERT_ON_RECOVERY=true        # Alert when connectivity is restored
REBOOT_ON_FAILURE=true        # Reboot system when network is down
FAILURE_THRESHOLD=6           # Number of consecutive failures before reboot (6 * 30s = 3m)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to log messages
log_message() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message" | tee -a "$LOG_FILE"
}

# Function to check network connectivity
check_connectivity() {
    local host="$1"
    if ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$host" > /dev/null 2>&1; then
        return 0  # Success
    else
        return 1  # Failure
    fi
}

# Function to get default gateway
get_default_gateway() {
    ip route | grep default | awk '{print $3}' | head -n 1
}

# Function to get network interface status
get_interface_status() {
    local interface=$(ip route | grep default | awk '{print $5}' | head -n 1)
    if [ -n "$interface" ]; then
        if ip link show "$interface" | grep -q "state UP"; then
            echo "UP"
        else
            echo "DOWN"
        fi
    else
        echo "UNKNOWN"
    fi
}

# Function to check all hosts
check_all_hosts() {
    local all_up=true
    local failed_hosts=()
    
    for host in "${HOSTS[@]}"; do
        if ! check_connectivity "$host"; then
            all_up=false
            failed_hosts+=("$host")
        fi
    done
    
    if [ "$all_up" = true ]; then
        return 0
    else
        return 1
    fi
}

# Function to display network information
display_network_info() {
    local gateway=$(get_default_gateway)
    local interface=$(ip route | grep default | awk '{print $5}' | head -n 1)
    local interface_status=$(get_interface_status)
    local ip_address=$(ip -4 addr show "$interface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)
    
    echo "Network Interface: $interface"
    echo "Interface Status: $interface_status"
    echo "IP Address: ${ip_address:-N/A}"
    echo "Default Gateway: ${gateway:-N/A}"
    echo "Monitoring Hosts: ${HOSTS[*]}"
    echo "Check Interval: ${INTERVAL}s"
    echo "----------------------------------------"
}

# Main monitoring loop
main() {
    local previous_status="unknown"
    local current_status="unknown"
    local consecutive_failures=0
    
    # Check if running as root for system log file
    if [ "$EUID" -ne 0 ] && [ "$LOG_FILE" = "/var/log/network_monitor.log" ]; then
        LOG_FILE="./network_monitor.log"
        echo -e "${YELLOW}Warning: Not running as root. Using local log file: $LOG_FILE${NC}"
    fi
    
    # Create log file if it doesn't exist
    touch "$LOG_FILE"
    
    echo "Network Connectivity Monitor Started"
    echo "Press Ctrl+C to stop"
    display_network_info
    
    log_message "Network monitor started"
    if [ "$REBOOT_ON_FAILURE" = true ]; then
        log_message "Reboot enabled: System will reboot after $FAILURE_THRESHOLD consecutive failures"
    fi
    
    # Trap Ctrl+C for graceful exit
    trap 'log_message "Network monitor stopped"; exit 0' INT TERM
    
    while true; do
        if check_all_hosts; then
            current_status="up"
            consecutive_failures=0  # Reset failure counter on success
            
            if [ "$previous_status" != "up" ]; then
                if [ "$ALERT_ON_RECOVERY" = true ]; then
                    echo -e "${GREEN}[$(date '+%H:%M:%S')] Network connectivity RESTORED${NC}"
                    log_message "Network connectivity RESTORED"
                fi
                previous_status="up"
            fi
        else
            current_status="down"
            consecutive_failures=$((consecutive_failures + 1))
            
            if [ "$previous_status" != "down" ]; then
                if [ "$ALERT_ON_FAILURE" = true ]; then
                    echo -e "${RED}[$(date '+%H:%M:%S')] Network connectivity LOST${NC}"
                    log_message "Network connectivity LOST"
                    
                    # Additional diagnostics
                    local gateway=$(get_default_gateway)
                    local interface_status=$(get_interface_status)
                    log_message "Diagnostics - Gateway: ${gateway:-N/A}, Interface Status: $interface_status"
                fi
                previous_status="down"
            fi
            
            # Check if we should reboot
            if [ "$REBOOT_ON_FAILURE" = true ] && [ "$consecutive_failures" -ge "$FAILURE_THRESHOLD" ]; then
                log_message "Network connectivity lost for $((consecutive_failures * INTERVAL)) seconds. Rebooting system..."
                echo -e "${RED}[$(date '+%H:%M:%S')] Network down for $((consecutive_failures * INTERVAL))s - REBOOTING SYSTEM${NC}"
                
                # Wait a moment for log to flush
                sleep 2
                
                # Reboot the system
                /sbin/reboot
                exit 0
            fi
        fi
        
        sleep "$INTERVAL"
    done
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -i|--interval)
            INTERVAL="$2"
            shift 2
            ;;
        -l|--log)
            LOG_FILE="$2"
            shift 2
            ;;
        -h|--hosts)
            IFS=',' read -ra HOSTS <<< "$2"
            shift 2
            ;;
        --no-reboot)
            REBOOT_ON_FAILURE=false
            shift
            ;;
        --failure-threshold)
            FAILURE_THRESHOLD="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  -i, --interval SECONDS    Set check interval (default: 5)"
            echo "  -l, --log FILE            Set log file path (default: /var/log/network_monitor.log)"
            echo "  -h, --hosts HOSTS         Comma-separated list of hosts to ping (default: 8.8.8.8,1.1.1.1)"
            echo "  --no-reboot               Disable automatic reboot on network failure"
            echo "  --failure-threshold NUM   Number of consecutive failures before reboot (default: 6)"
            echo "  --help                    Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0 -i 10 -l /tmp/monitor.log"
            echo "  $0 -h 8.8.8.8,1.1.1.1,192.168.1.1"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Run main function
main

