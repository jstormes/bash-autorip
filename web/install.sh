#!/bin/bash
#
# Autorip Web Dashboard Installer
#
# This script installs the Autorip Web Dashboard on a fresh Linux system.
# It handles Node.js installation, file deployment, and systemd service setup.
#
# Usage:
#   sudo bash install.sh
#
# Or make executable first:
#   chmod +x install.sh
#   sudo ./install.sh
#

set -e

# Configuration
INSTALL_DIR="/opt/autorip-web"
STATE_DIR="/var/lib/autorip"
SERVICE_NAME="autorip-web"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

print_header() {
    echo
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  Autorip Web Dashboard Installer${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo
}

print_step() {
    echo -e "${YELLOW}>>> $1${NC}"
}

print_success() {
    echo -e "${GREEN}[OK] $1${NC}"
}

print_error() {
    echo -e "${RED}[ERROR] $1${NC}"
}

print_info() {
    echo -e "    $1"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        echo
        echo "Usage:"
        echo "  sudo bash $0"
        echo
        echo "Or make executable first:"
        echo "  chmod +x $0"
        echo "  sudo ./$0"
        exit 1
    fi
}

# Check and install Node.js
install_nodejs() {
    print_step "Checking for Node.js..."

    if command -v node &>/dev/null; then
        NODE_VERSION=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
        if [[ $NODE_VERSION -ge 18 ]]; then
            print_success "Node.js $(node -v) found"
            return 0
        else
            print_info "Node.js $(node -v) found but version 18+ required"
        fi
    fi

    print_step "Installing Node.js 20.x..."

    # Detect package manager and install
    if command -v apt-get &>/dev/null; then
        # Debian/Ubuntu
        print_info "Detected Debian/Ubuntu system"

        # Check if curl is available
        if ! command -v curl &>/dev/null; then
            apt-get update
            apt-get install -y curl
        fi

        curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
        apt-get install -y nodejs

    elif command -v dnf &>/dev/null; then
        # Fedora/RHEL 8+
        print_info "Detected Fedora/RHEL system"
        dnf install -y nodejs

    elif command -v yum &>/dev/null; then
        # CentOS/RHEL 7
        print_info "Detected CentOS/RHEL system"

        if ! command -v curl &>/dev/null; then
            yum install -y curl
        fi

        curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
        yum install -y nodejs

    elif command -v pacman &>/dev/null; then
        # Arch Linux
        print_info "Detected Arch Linux system"
        pacman -Sy --noconfirm nodejs npm

    else
        print_error "Cannot automatically install Node.js on this system"
        echo
        echo "Please install Node.js 18 or higher manually:"
        echo "  https://nodejs.org/en/download/"
        echo
        exit 1
    fi

    # Verify installation
    if command -v node &>/dev/null; then
        NODE_VERSION=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
        if [[ $NODE_VERSION -ge 18 ]]; then
            print_success "Node.js $(node -v) installed successfully"
        else
            print_error "Node.js installation failed or wrong version"
            exit 1
        fi
    else
        print_error "Node.js installation failed"
        exit 1
    fi
}

# Create directories
create_directories() {
    print_step "Creating directories..."

    # Installation directory
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR/lib"
    mkdir -p "$INSTALL_DIR/public"
    print_info "Created $INSTALL_DIR"

    # State directory for status files
    mkdir -p "$STATE_DIR/status"
    chmod 755 "$STATE_DIR"
    chmod 755 "$STATE_DIR/status"
    print_info "Created $STATE_DIR"

    print_success "Directories created"
}

# Copy application files
copy_files() {
    print_step "Copying application files..."

    # Copy main files
    cp "$SCRIPT_DIR/server.js" "$INSTALL_DIR/"
    cp "$SCRIPT_DIR/package.json" "$INSTALL_DIR/"
    print_info "Copied server files"

    # Copy lib modules
    cp "$SCRIPT_DIR/lib/"*.js "$INSTALL_DIR/lib/"
    print_info "Copied library modules"

    # Copy public files (frontend)
    cp "$SCRIPT_DIR/public/"* "$INSTALL_DIR/public/"
    print_info "Copied frontend files"

    # Set permissions
    chmod 755 "$INSTALL_DIR/server.js"
    chmod 644 "$INSTALL_DIR/package.json"
    chmod 644 "$INSTALL_DIR/lib/"*.js
    chmod 644 "$INSTALL_DIR/public/"*

    print_success "Application files copied"
}

# Install npm dependencies
install_dependencies() {
    print_step "Installing npm dependencies..."

    cd "$INSTALL_DIR"
    npm install --production --no-optional 2>&1 | while read line; do
        print_info "$line"
    done

    print_success "Dependencies installed"
}

# Install systemd service
install_service() {
    print_step "Installing systemd service..."

    # Create service file
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" << 'EOF'
[Unit]
Description=Autorip Web Dashboard
Documentation=https://github.com/jstormes/bash-autorip
After=network.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/opt/autorip-web
ExecStart=/usr/bin/node /opt/autorip-web/server.js

# Environment variables (customize as needed)
# Port to listen on
Environment=AUTORIP_WEB_PORT=8080
# Bind address: 127.0.0.1 for localhost only, 0.0.0.0 for all interfaces
Environment=AUTORIP_WEB_HOST=0.0.0.0
# Directory where autorip.sh writes status files
Environment=AUTORIP_STATUS_DIR=/var/lib/autorip/status
# History file location
Environment=AUTORIP_HISTORY_FILE=/var/lib/autorip/history.json
# Drive statistics file
Environment=AUTORIP_DRIVE_STATS_FILE=/var/lib/autorip/drive_stats.json
# Directory containing autorip log files
Environment=AUTORIP_LOG_DIR=/tmp
# Seconds without heartbeat before detecting a crash (5 minutes)
Environment=AUTORIP_CRASH_TIMEOUT=300
# Automatically reset crashed drives when safe
Environment=AUTORIP_AUTO_RESET=true

# Restart configuration
Restart=always
RestartSec=5

# Security settings
# Running as root is required for bus reset functionality
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/autorip /tmp

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=autorip-web

[Install]
WantedBy=multi-user.target
EOF

    print_info "Created /etc/systemd/system/${SERVICE_NAME}.service"

    # Reload systemd
    systemctl daemon-reload
    print_info "Reloaded systemd daemon"

    # Enable service
    systemctl enable "$SERVICE_NAME"
    print_info "Enabled $SERVICE_NAME service"

    print_success "Systemd service installed"
}

# Start service
start_service() {
    print_step "Starting service..."

    systemctl start "$SERVICE_NAME"

    # Wait a moment for startup
    sleep 2

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        print_success "Service started successfully"
    else
        print_error "Service failed to start"
        echo
        echo "Check logs with:"
        echo "  sudo journalctl -u $SERVICE_NAME -n 50 --no-pager"
        exit 1
    fi
}

# Update autorip.sh
update_autorip() {
    print_step "Checking autorip.sh..."

    AUTORIP_PATH="/usr/local/bin/autorip.sh"

    if [[ -f "$AUTORIP_PATH" ]]; then
        # Check if it has the web interface status reporting
        if grep -q "STATUS_DIR" "$AUTORIP_PATH"; then
            print_success "autorip.sh already has web interface support"
        else
            print_info "autorip.sh needs to be updated for web interface support"
            print_info "Copy the updated autorip.sh from this repository:"
            print_info "  sudo cp autorip.sh /usr/local/bin/"
        fi
    else
        print_info "autorip.sh not found at $AUTORIP_PATH"
        print_info "Install it with:"
        print_info "  sudo cp autorip.sh /usr/local/bin/"
        print_info "  sudo chmod +x /usr/local/bin/autorip.sh"
    fi
}

# Print completion message
print_completion() {
    # Get the configured host and port
    local HOST=$(grep "AUTORIP_WEB_HOST=" /etc/systemd/system/${SERVICE_NAME}.service | cut -d'=' -f3)
    local PORT=$(grep "AUTORIP_WEB_PORT=" /etc/systemd/system/${SERVICE_NAME}.service | cut -d'=' -f3)
    HOST=${HOST:-0.0.0.0}
    PORT=${PORT:-8080}

    # Get local IP
    local LOCAL_IP=$(hostname -I | awk '{print $1}')

    echo
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Installation Complete!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo
    echo "Dashboard URLs:"
    if [[ "$HOST" == "0.0.0.0" ]]; then
        echo "  Local:   http://localhost:${PORT}"
        [[ -n "$LOCAL_IP" ]] && echo "  Network: http://${LOCAL_IP}:${PORT}"
    else
        echo "  http://${HOST}:${PORT}"
    fi
    echo
    echo "Useful commands:"
    echo "  sudo systemctl status $SERVICE_NAME    # Check service status"
    echo "  sudo systemctl restart $SERVICE_NAME   # Restart service"
    echo "  sudo systemctl stop $SERVICE_NAME      # Stop service"
    echo "  sudo journalctl -u $SERVICE_NAME -f    # View live logs"
    echo
    echo "Configuration:"
    echo "  Service file: /etc/systemd/system/${SERVICE_NAME}.service"
    echo "  Edit with:    sudo systemctl edit $SERVICE_NAME"
    echo
    echo "To restrict access to localhost only, edit the service file and change:"
    echo "  Environment=AUTORIP_WEB_HOST=127.0.0.1"
    echo "Then run: sudo systemctl restart $SERVICE_NAME"
    echo
}

# Main installation flow
main() {
    print_header
    check_root
    install_nodejs
    create_directories
    copy_files
    install_dependencies
    install_service
    start_service
    update_autorip
    print_completion
}

# Run main
main "$@"
