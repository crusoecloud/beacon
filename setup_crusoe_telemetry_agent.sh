#!/bin/bash

# --- Constants ---
UBUNTU_OS_VERSION=$(lsb_release -r -s)
CRUSOE_VM_ID=$(dmidecode -s system-uuid)

# GitHub raw content base URL
GITHUB_RAW_BASE_URL="https://raw.githubusercontent.com/crusoecloud/crusoe-telemetry-agent/main"

# Define paths for config files within the GitHub repository
REMOTE_VECTOR_CONFIG_GPU_VM="config/vector_gpu_vm.yaml"
REMOTE_VECTOR_CONFIG_CPU_VM="config/vector_cpu_vm.yaml"
REMOTE_DCGM_EXPORTER_METRICS_CONFIG="config/dcp-metrics-included.csv"
REMOTE_DOCKER_COMPOSE_GPU_VM_UBUNTU_22="docker/docker-compose-gpu-vm-ubuntu22.04.yaml"
REMOTE_DOCKER_COMPOSE_CPU_VM="docker/docker-compose-cpu-vm.yaml"
REMOTE_CRUSOE_TELEMETRY_SERVICE="systemctl/crusoe-telemetry-agent.service"
SYSTEMCTL_DIR="/etc/systemd/system"
CRUSOE_TELEMETRY_AGENT_DIR="/etc/crusoe/telemetry_agent"
CRUSOE_AUTH_TOKEN_LENGTH=82
ENV_FILE="$CRUSOE_TELEMETRY_AGENT_DIR/.env" # Define the .env file path
CRUSOE_AUTH_TOKEN_REFRESH_ALIAS_PATH="/usr/bin/crusoe_auth_token_refresh"

# --- Helper Functions ---

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

file_exists() {
  [ -f "$1" ]
}

dir_exists() {
  [ -d "$1" ]
}

error_exit() {
  echo "Error: $1" >&2
  exit 1
}

status() {
  # Bold text for status messages
  echo -e "\n\033[1m$1\033[0m"
}

check_root() {
  if [[ $EUID -ne 0 ]]; then
      error_exit "This script must be run as root."
  fi
}

check_os_support() {
  if [[ $UBUNTU_OS_VERSION != "22.04" ]]; then
    error_exit "Ubuntu version $UBUNTU_OS_VERSION is not supported."
  fi
}

install_docker() {
  curl -fsSL https://get.docker.com | sh
}

# --- Main Script ---

# Ensure the script is run as root.
check_root

status "Ensure docker installation."
if command_exists docker; then
  echo "Docker is already installed."
else
  echo "Installing Docker."
  install_docker
fi

# Ensure wget is installed
status "Ensuring wget is installed."
if ! command_exists wget; then
  apt-get update && apt-get install -y wget || error_exit "Failed to install wget."
fi

status "Create telemetry agent target directory."
if ! dir_exists "$CRUSOE_TELEMETRY_AGENT_DIR"; then
  mkdir -p "$CRUSOE_TELEMETRY_AGENT_DIR"
fi

# Download required config files
# if VM has NVIDIA GPUs
if lspci | grep -q "NVIDIA Corporation"; then
  status "Ensure NVIDIA dependencies exist."
  if command_exists dcgmi && command_exists nvidia-ctk; then
    echo "Required NVIDIA dependencies are already installed."
  else
    error_exit "Cannot find required NVIDIA dependencies. Please install them and try again."
  fi

  check_os_support

  status "Download DCGM exporter metrics config."
  wget -q -O "$CRUSOE_TELEMETRY_AGENT_DIR/dcp-metrics-included.csv" "$GITHUB_RAW_BASE_URL/$REMOTE_DCGM_EXPORTER_METRICS_CONFIG" || error_exit "Failed to download $REMOTE_DCGM_EXPORTER_METRICS_CONFIG"

  status "Download GPU Vector config."
  wget -q -O "$CRUSOE_TELEMETRY_AGENT_DIR/vector.yaml" "$GITHUB_RAW_BASE_URL/$REMOTE_VECTOR_CONFIG_GPU_VM" || error_exit "Failed to download $REMOTE_VECTOR_CONFIG_GPU_VM"

  status "Download GPU docker-compose file."
  wget -q -O "$CRUSOE_TELEMETRY_AGENT_DIR/docker-compose.yaml" "$GITHUB_RAW_BASE_URL/$REMOTE_DOCKER_COMPOSE_GPU_VM_UBUNTU_22" || error_exit "Failed to download $REMOTE_DOCKER_COMPOSE_GPU_VM_UBUNTU_22"

# if VM has no NVIDIA GPUs
else
  # The original script had an error_exit here. If CPU VMs are not supported, this should remain.
  # If they are intended to be supported later, this error_exit should be removed and the following
  # wget commands for CPU configs would be active.
  error_exit "Non-GPU VMs are currently not supported."
  # status "Copy CPU Vector config."
  # wget -q -O "$CRUSOE_TELEMETRY_AGENT_DIR/vector.yaml" "$GITHUB_RAW_BASE_URL/$REMOTE_VECTOR_CONFIG_CPU_VM" || error_exit "Failed to download $REMOTE_VECTOR_CONFIG_CPU_VM"

  # status "Copy CPU docker-compose file."
  # wget -q -O "$CRUSOE_TELEMETRY_AGENT_DIR/docker-compose.yaml" "$GITHUB_RAW_BASE_URL/$REMOTE_DOCKER_COMPOSE_CPU_VM" || error_exit "Failed to download $REMOTE_DOCKER_COMPOSE_CPU_VM"
fi

status "Fetching crusoe auth token."
if [[ -z "$CRUSOE_AUTH_TOKEN" ]]; then
  echo "Command: crusoe monitoring tokens create"
  echo "Please enter the crusoe monitoring token:"
  read -s CRUSOE_AUTH_TOKEN # -s for silent input (no echo)
  echo "" # Add a newline after the silent input for better readability

  if [ "${#CRUSOE_AUTH_TOKEN}" -ne $CRUSOE_AUTH_TOKEN_LENGTH ]; then
    echo "CRUSOE_AUTH_TOKEN should be $CRUSOE_AUTH_TOKEN_LENGTH characters long."
    echo "Use Crusoe CLI to generate a new token:"
    echo "Command: crusoe monitoring tokens create"
    error_exit "CRUSOE_AUTH_TOKEN is invalid. "
  fi
fi

status "Creating .env file with CRUSOE_AUTH_TOKEN and VM_ID."
cat <<EOF > "$ENV_FILE"
CRUSOE_AUTH_TOKEN='${CRUSOE_AUTH_TOKEN}'
VM_ID='${CRUSOE_VM_ID}'
EOF
echo ".env file created at $ENV_FILE"

status "Download crusoe-telemetry-agent.service."
wget -q -O "$SYSTEMCTL_DIR/crusoe-telemetry-agent.service" "$GITHUB_RAW_BASE_URL/$REMOTE_CRUSOE_TELEMETRY_SERVICE" || error_exit "Failed to download $REMOTE_CRUSOE_TELEMETRY_SERVICE"

status "Download crusoe_auth_token_refresh.sh and make it executable command."
wget -q -O "$CRUSOE_TELEMETRY_AGENT_DIR/crusoe_auth_token_refresh.sh" "$GITHUB_RAW_BASE_URL/crusoe_auth_token_refresh.sh" || error_exit "Failed to download crusoe_auth_token_refresh.sh"
chmod +x "$CRUSOE_TELEMETRY_AGENT_DIR/crusoe_auth_token_refresh.sh"
# Create a symbolic link from /usr/bin to the actual script location.
ln -sf "$CRUSOE_TELEMETRY_AGENT_DIR/crusoe_auth_token_refresh.sh" "$CRUSOE_AUTH_TOKEN_REFRESH_ALIAS_PATH"

status "Enable systemctl service for crusoe-telemetry-agent."
echo "systemctl daemon-reload"
systemctl daemon-reload
echo "systemctl enable crusoe-telemetry-agent.service"
systemctl enable crusoe-telemetry-agent.service

status "Setup Complete!"
echo "Run: 'sudo systemctl start crusoe-telemetry-agent' to start monitoring metrics."
echo "Setup finished successfully!"