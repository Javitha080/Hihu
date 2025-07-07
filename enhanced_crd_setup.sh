#!/bin/bash
# Enhanced Chrome Remote Desktop Setup Script
# Copyright (c) [2024] [@ravindu644]
# Version: 2.0

set -euo pipefail  # Exit on any error, undefined variables, or pipe failures

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="/var/log/crd_setup.log"
readonly BACKUP_DIR="/var/backups/crd_setup"

# Set DEBIAN_FRONTEND to noninteractive to suppress prompts
export DEBIAN_FRONTEND=noninteractive

# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE"
}

# Print functions with colors
print_success() { echo -e "${GREEN}✓ $1${NC}"; log "INFO" "$1"; }
print_error() { echo -e "${RED}✗ $1${NC}"; log "ERROR" "$1"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; log "WARN" "$1"; }
print_info() { echo -e "${BLUE}ℹ $1${NC}"; log "INFO" "$1"; }

# Error handling
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        print_error "Script failed with exit code $exit_code"
        print_info "Check log file: $LOG_FILE"
    fi
    exit $exit_code
}

trap cleanup EXIT

# Validation functions
validate_username() {
    local username="$1"
    if [[ ! "$username" =~ ^[a-z][-a-z0-9]*$ ]]; then
        print_error "Invalid username. Use lowercase letters, numbers, and hyphens only."
        return 1
    fi
    if getent passwd "$username" > /dev/null 2>&1; then
        print_error "User '$username' already exists."
        return 1
    fi
    return 0
}

validate_password() {
    local password="$1"
    if [[ ${#password} -lt 8 ]]; then
        print_error "Password must be at least 8 characters long."
        return 1
    fi
    return 0
}

validate_pin() {
    local pin="$1"
    if [[ ! "$pin" =~ ^[0-9]{6,}$ ]]; then
        print_error "PIN must be 6 or more digits."
        return 1
    fi
    return 0
}

# Network troubleshooting function
troubleshoot_network() {
    print_info "Running network diagnostics..."
    
    # Check network interfaces
    print_info "Active network interfaces:"
    ip addr show | grep -E "(inet|UP|DOWN)" | head -10
    
    # Check default route
    print_info "Default route:"
    ip route show default
    
    # Check DNS resolution
    print_info "DNS servers:"
    cat /etc/resolv.conf | grep nameserver
    
    # Check if we can reach local gateway
    local gateway=$(ip route show default | awk '/default/ { print $3 }')
    if [[ -n "$gateway" ]]; then
        if ping -c 1 -W 3 "$gateway" &> /dev/null; then
            print_success "Can reach gateway: $gateway"
        else
            print_error "Cannot reach gateway: $gateway"
        fi
    fi
    
    print_info "Network diagnostics completed"
}

# Check system requirements
check_system_requirements() {
    print_info "Checking system requirements..."
    
    # Check if running on Ubuntu/Debian
    if ! command -v apt-get &> /dev/null; then
        print_error "This script requires a Debian/Ubuntu system with apt package manager."
        exit 1
    fi
    
    # Check architecture
    local arch=$(dpkg --print-architecture)
    if [[ "$arch" != "amd64" ]]; then
        print_warning "This script is designed for amd64 architecture. Current: $arch"
    fi
    
    # Check available disk space (minimum 2GB)
    local available_space=$(df / | awk 'NR==2 {print $4}')
    if [[ $available_space -lt 2097152 ]]; then # 2GB in KB
        print_error "Insufficient disk space. At least 2GB required."
        exit 1
    fi
    
    # Check internet connectivity with multiple methods
    print_info "Testing internet connectivity..."
    local internet_available=false
    
    # Method 1: Try ping to multiple reliable hosts
    local test_hosts=("8.8.8.8" "1.1.1.1" "google.com" "ubuntu.com")
    for host in "${test_hosts[@]}"; do
        if ping -c 1 -W 3 "$host" &> /dev/null; then
            internet_available=true
            print_success "Internet connection verified via $host"
            break
        fi
    done
    
    # Method 2: Try wget/curl if ping fails
    if [[ "$internet_available" == false ]]; then
        if command -v wget &> /dev/null; then
            if wget --spider --timeout=10 --tries=1 https://google.com &> /dev/null; then
                internet_available=true
                print_success "Internet connection verified via wget"
            fi
        elif command -v curl &> /dev/null; then
            if curl --connect-timeout 10 --max-time 15 -s https://google.com &> /dev/null; then
                internet_available=true
                print_success "Internet connection verified via curl"
            fi
        fi
    fi
    
    # Method 3: Check if we can resolve DNS
    if [[ "$internet_available" == false ]]; then
        if nslookup google.com &> /dev/null || dig google.com &> /dev/null; then
            internet_available=true
            print_success "Internet connection verified via DNS lookup"
        fi
    fi
    
    if [[ "$internet_available" == false ]]; then
        print_warning "Cannot verify internet connection, but continuing..."
        print_info "Please ensure you have internet access for package downloads"
        
        # Offer network troubleshooting
        read -p "Would you like to run network diagnostics? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            troubleshoot_network
        fi
        
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_error "Internet connection required for installation"
            exit 1
        fi
    fi
    
    print_success "System requirements check passed"
}

# Create backup
create_backup() {
    print_info "Creating backup of important files..."
    mkdir -p "$BACKUP_DIR"
    
    # Backup important files
    local files_to_backup=("/etc/passwd" "/etc/group" "/etc/sudoers")
    for file in "${files_to_backup[@]}"; do
        if [[ -f "$file" ]]; then
            cp "$file" "$BACKUP_DIR/$(basename "$file").bak"
        fi
    done
    
    print_success "Backup created at $BACKUP_DIR"
}

# Enhanced user creation with better security
create_user() {
    print_info "Creating user and setting up environment..."
    
    local username password confirm_password
    
    # Get username with validation
    while true; do
        read -p "Enter username: " username
        if validate_username "$username"; then
            break
        fi
    done
    
    # Get password with validation and confirmation
    while true; do
        read -s -p "Enter password: " password
        echo
        if validate_password "$password"; then
            read -s -p "Confirm password: " confirm_password
            echo
            if [[ "$password" == "$confirm_password" ]]; then
                break
            else
                print_error "Passwords do not match. Please try again."
            fi
        fi
    done
    
    # Create user with home directory
    if useradd -m -s /bin/bash "$username"; then
        print_success "User '$username' created successfully"
    else
        print_error "Failed to create user '$username'"
        exit 1
    fi
    
    # Add user to sudo group
    if usermod -aG sudo "$username"; then
        print_success "User added to sudo group"
    else
        print_error "Failed to add user to sudo group"
        exit 1
    fi
    
    # Set password
    if echo "$username:$password" | chpasswd; then
        print_success "Password set successfully"
    else
        print_error "Failed to set password"
        exit 1
    fi
    
    # Enhanced .bashrc setup
    local bashrc_file="/home/$username/.bashrc"
    cat >> "$bashrc_file" << EOF

# Custom PATH additions
export PATH=\$PATH:/home/$username/.local/bin
export PATH=\$PATH:/opt/google/chrome-remote-desktop

# Chrome Remote Desktop environment
export CHROME_REMOTE_DESKTOP_DEFAULT_DESKTOP_SIZES=1920x1080
export DISPLAY=:20

# Useful aliases
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias ..='cd ..'
alias ...='cd ../..'
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'

# Git aliases (if git is installed)
if command -v git &> /dev/null; then
    alias gs='git status'
    alias ga='git add'
    alias gc='git commit'
    alias gp='git push'
    alias gl='git log --oneline'
fi
EOF
    
    # Set proper ownership
    chown -R "$username":"$username" "/home/$username"
    
    # Export username for other functions
    export CREATED_USERNAME="$username"
    
    print_success "User environment configured successfully"
}

# Enhanced storage setup with better error handling
setup_storage() {
    local username="$1"
    print_info "Setting up storage for user '$username'..."
    
    # Create storage directory
    if mkdir -p /storage; then
        print_success "Storage directory created"
    else
        print_error "Failed to create storage directory"
        return 1
    fi
    
    # Set permissions
    chmod 755 /storage
    chown "$username":"$username" /storage
    
    # Create user storage directory
    local user_storage="/home/$username/storage"
    mkdir -p "$user_storage"
    chown "$username":"$username" "$user_storage"
    
    # Create bind mount
    if mount --bind /storage "$user_storage"; then
        print_success "Storage bind mount created"
    else
        print_error "Failed to create storage bind mount"
        return 1
    fi
    
    # Add to fstab for persistence
    local fstab_entry="/storage /home/$username/storage none bind 0 0"
    if ! grep -q "$fstab_entry" /etc/fstab; then
        echo "$fstab_entry" >> /etc/fstab
        print_success "Storage mount added to fstab"
    fi
    
    print_success "Storage setup completed"
}

# Enhanced RDP setup with better package management
setup_rdp() {
    local username="$CREATED_USERNAME"
    print_info "Setting up Chrome Remote Desktop for user '$username'..."
    
    # Update package list with retry logic
    print_info "Updating package repositories..."
    local max_retries=3
    local retry_count=0
    
    while [[ $retry_count -lt $max_retries ]]; do
        if apt update; then
            print_success "Package repositories updated"
            break
        else
            ((retry_count++))
            if [[ $retry_count -lt $max_retries ]]; then
                print_warning "Failed to update repositories, retrying... ($retry_count/$max_retries)"
                sleep 5
            else
                print_error "Failed to update package repositories after $max_retries attempts"
                print_info "This might be due to network issues or repository problems"
                read -p "Continue anyway? (y/N): " -n 1 -r
                echo
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    exit 1
                fi
            fi
        fi
    done
    
    # Install Firefox ESR
    print_info "Installing Firefox ESR..."
    add-apt-repository ppa:mozillateam/ppa -y
    apt update
    apt install --assume-yes firefox-esr
    
    # Install essential packages
    print_info "Installing essential packages..."
    local essential_packages=(
        "dbus-x11" "dbus" "xvfb" "xserver-xorg-video-dummy" "xbase-clients"
        "python3-packaging" "python3-psutil" "python3-xdg" "libgbm1"
        "libutempter0" "libfuse2" "nload" "qbittorrent" "ffmpeg" "gpac"
        "fonts-lklug-sinhala" "wget" "curl" "vim" "htop" "tree" "zip" "unzip"
        "software-properties-common" "apt-transport-https" "ca-certificates"
        "gnupg" "lsb-release"
    )
    
    for package in "${essential_packages[@]}"; do
        if apt install --assume-yes "$package"; then
            print_success "Installed $package"
        else
            print_warning "Failed to install $package, continuing..."
        fi
    done
    
    # Install desktop environment
    print_info "Installing XFCE desktop environment..."
    add-apt-repository universe -y
    apt update
    
    local desktop_packages=(
        "xfce4" "desktop-base" "xfce4-terminal" "xfce4-session"
        "xfce4-panel" "xfce4-settings" "xfce4-taskmanager"
        "xfce4-screenshooter" "xfce4-clipman" "thunar" "ristretto"
        "xscreensaver" "lightdm" "lightdm-gtk-greeter"
    )
    
    for package in "${desktop_packages[@]}"; do
        if apt install --assume-yes "$package"; then
            print_success "Installed $package"
        else
            print_warning "Failed to install $package, continuing..."
        fi
    done
    
    # Configure desktop session
    echo "exec /etc/X11/Xsession /usr/bin/xfce4-session" > /etc/chrome-remote-desktop-session
    
    # Remove conflicting packages
    apt remove --assume-yes gnome-terminal 2>/dev/null || true
    
    # Disable lightdm service
    systemctl disable lightdm.service 2>/dev/null || true
    
    # Download and install Chrome Remote Desktop
    print_info "Installing Chrome Remote Desktop..."
    local crd_deb="/tmp/chrome-remote-desktop_current_amd64.deb"
    
    if wget -O "$crd_deb" "https://dl.google.com/linux/direct/chrome-remote-desktop_current_amd64.deb"; then
        print_success "Downloaded Chrome Remote Desktop package"
    else
        print_error "Failed to download Chrome Remote Desktop package"
        exit 1
    fi
    
    if dpkg --install "$crd_deb"; then
        print_success "Chrome Remote Desktop installed"
    else
        print_info "Fixing dependencies..."
        apt install --assume-yes --fix-broken
        print_success "Dependencies fixed"
    fi
    
    # Add user to chrome-remote-desktop group
    if usermod -aG chrome-remote-desktop "$username"; then
        print_success "User added to chrome-remote-desktop group"
    else
        print_error "Failed to add user to chrome-remote-desktop group"
        exit 1
    fi
    
    # Setup Chrome Remote Desktop
    print_info "Setting up Chrome Remote Desktop authentication..."
    echo
    print_info "Please visit: https://remotedesktop.google.com/headless"
    print_info "1. Sign in with your Google account"
    print_info "2. Click on 'Set up via SSH'"
    print_info "3. Copy the command that starts with 'DISPLAY='"
    echo
    
    local crd_command pin
    
    while true; do
        read -p "Paste the CRD command here: " crd_command
        if [[ "$crd_command" =~ ^DISPLAY= ]]; then
            break
        else
            print_error "Invalid command. Please paste the full command starting with 'DISPLAY='"
        fi
    done
    
    while true; do
        read -p "Enter a PIN for CRD (6 or more digits): " pin
        if validate_pin "$pin"; then
            break
        fi
    done
    
    # Execute CRD setup command as the user
    if su - "$username" -c "$crd_command --pin=$pin"; then
        print_success "Chrome Remote Desktop configured successfully"
    else
        print_error "Failed to configure Chrome Remote Desktop"
        exit 1
    fi
    
    # Start Chrome Remote Desktop service
    if systemctl enable chrome-remote-desktop@"$username".service; then
        print_success "Chrome Remote Desktop service enabled"
    else
        print_warning "Failed to enable Chrome Remote Desktop service"
    fi
    
    if systemctl start chrome-remote-desktop@"$username".service; then
        print_success "Chrome Remote Desktop service started"
    else
        print_warning "Failed to start Chrome Remote Desktop service"
    fi
    
    # Setup storage
    setup_storage "$username"
    
    # Cleanup
    rm -f "$crd_deb"
    
    print_success "RDP setup completed successfully"
}

# System optimization
optimize_system() {
    print_info "Optimizing system performance..."
    
    # Configure swappiness
    echo "vm.swappiness=10" >> /etc/sysctl.conf
    
    # Configure Chrome Remote Desktop
    local crd_config="/etc/opt/chrome/native-messaging-hosts/com.google.chrome.remote_desktop.json"
    if [[ -f "$crd_config" ]]; then
        print_success "Chrome Remote Desktop configuration found"
    fi
    
    # Cleanup package cache
    apt autoremove --assume-yes
    apt autoclean
    
    print_success "System optimization completed"
}

# Status check function
check_status() {
    local username="$CREATED_USERNAME"
    print_info "Checking system status..."
    
    # Check user
    if id "$username" &>/dev/null; then
        print_success "User '$username' exists"
    else
        print_error "User '$username' not found"
    fi
    
    # Check Chrome Remote Desktop service
    if systemctl is-active --quiet chrome-remote-desktop@"$username".service; then
        print_success "Chrome Remote Desktop service is running"
    else
        print_warning "Chrome Remote Desktop service is not running"
    fi
    
    # Check storage mount
    if mountpoint -q "/home/$username/storage"; then
        print_success "Storage mount is active"
    else
        print_warning "Storage mount is not active"
    fi
    
    # Display connection info
    print_info "Connection Information:"
    print_info "- Visit: https://remotedesktop.google.com/access"
    print_info "- Username: $username"
    print_info "- Desktop Environment: XFCE"
    print_info "- Default Resolution: 1920x1080"
}

# Enhanced keep-alive with status monitoring
keep_alive() {
    local username="$CREATED_USERNAME"
    print_info "Starting enhanced keep-alive monitor..."
    print_info "Press Ctrl+C to stop monitoring"
    
    local count=0
    while true; do
        ((count++))
        
        # Basic alive message
        echo "$(date '+%Y-%m-%d %H:%M:%S') - System alive (cycle $count)"
        
        # Periodic status check (every 30 minutes)
        if ((count % 6 == 0)); then
            print_info "Performing periodic status check..."
            
            # Check Chrome Remote Desktop service
            if ! systemctl is-active --quiet chrome-remote-desktop@"$username".service; then
                print_warning "Chrome Remote Desktop service is down, attempting restart..."
                systemctl restart chrome-remote-desktop@"$username".service
            fi
            
            # Check storage mount
            if ! mountpoint -q "/home/$username/storage"; then
                print_warning "Storage mount is down, attempting remount..."
                mount --bind /storage "/home/$username/storage"
            fi
            
            # Log system resources
            local memory_usage=$(free | grep Mem | awk '{printf "%.1f%%", $3/$2 * 100.0}')
            local disk_usage=$(df / | awk 'NR==2 {print $5}')
            log "INFO" "System resources - Memory: $memory_usage, Disk: $disk_usage"
        fi
        
        sleep 300  # Sleep for 5 minutes
    done
}

# Main execution
main() {
    print_info "Starting Enhanced Chrome Remote Desktop Setup Script v2.0"
    print_info "Log file: $LOG_FILE"
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        print_info "Please run: sudo $0"
        exit 1
    fi
    
    # Initialize log file
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
    
    # Main setup steps
    check_system_requirements
    create_backup
    create_user
    setup_rdp
    optimize_system
    check_status
    
    print_success "Setup completed successfully!"
    print_info "You can now connect to your desktop using Chrome Remote Desktop"
    
    # Ask if user wants to start keep-alive
    echo
    read -p "Do you want to start the keep-alive monitor? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        keep_alive
    else
        print_info "Setup completed. You can manually start the keep-alive monitor later."
        print_info "To check status: systemctl status chrome-remote-desktop@$CREATED_USERNAME.service"
    fi
}

# Run main function
main "$@"
