#!/bin/bash
#
# macOS Setup Script for AI Audiobook Fast
#
# This script handles all the setup steps:
# 1. Check/install Homebrew
# 2. Check/install FFmpeg
# 3. Check/install Python 3.10-3.12 (not 3.13+)
# 4. Check/install Node.js 18+
# 5. Create Python virtual environment
# 6. Install Python dependencies
# 7. Install CLI dependencies
# 8. Optionally pre-download TTS models
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
DIM='\033[2m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Get the project root directory (parent of scripts/)
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ============================================================================
# Helper Functions
# ============================================================================

print_banner() {
    echo ""
    echo -e "${MAGENTA}${BOLD}"
    echo "  ╔═══════════════════════════════════════════════════════════╗"
    echo "  ║                                                           ║"
    echo "  ║   🎧  AI Audiobook Fast - Setup                           ║"
    echo "  ║                                                           ║"
    echo "  ║   Transform EPUBs into Beautiful Audiobooks with AI       ║"
    echo "  ║                                                           ║"
    echo "  ╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_step() {
    echo ""
    echo -e "${CYAN}${BOLD}▶ $1${NC}"
}

print_success() {
    echo -e "  ${GREEN}✔${NC} $1"
}

print_warning() {
    echo -e "  ${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "  ${RED}✘${NC} $1"
}

print_info() {
    echo -e "  ${DIM}$1${NC}"
}

print_highlight() {
    echo -e "  ${WHITE}${BOLD}$1${NC}"
}

press_enter_to_continue() {
    echo ""
    echo -e "${DIM}Press Enter to continue...${NC}"
    read -r
}

# Check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Get Python version as a comparable number (e.g., 3.11.4 -> 311)
get_python_version_num() {
    local python_cmd="$1"
    if command_exists "$python_cmd"; then
        "$python_cmd" --version 2>&1 | sed 's/Python //' | awk -F. '{print $1$2}'
    else
        echo "0"
    fi
}

# ============================================================================
# Step 1: Check/Install Homebrew
# ============================================================================

check_homebrew() {
    print_step "Step 1/7: Checking for Homebrew..."

    if command_exists brew; then
        print_success "Homebrew is installed"
        print_info "$(brew --version | head -1)"
        return 0
    fi

    print_warning "Homebrew is not installed"
    echo ""
    echo -e "  Homebrew is a package manager for macOS that makes it easy to"
    echo -e "  install software like FFmpeg, Python, and Node.js."
    echo ""
    echo -e "  ${BOLD}Would you like to install Homebrew?${NC}"
    echo -e "  ${DIM}(This will run the official Homebrew installer)${NC}"
    echo ""

    read -p "  Install Homebrew? [Y/n]: " -n 1 -r
    echo ""

    if [[ $REPLY =~ ^[Nn]$ ]]; then
        print_error "Homebrew is required to continue."
        echo ""
        echo -e "  You can install it manually by running:"
        echo -e "  ${CYAN}/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"${NC}"
        exit 1
    fi

    echo ""
    echo -e "  ${YELLOW}Installing Homebrew...${NC}"
    echo -e "  ${DIM}(This may take a few minutes and ask for your password)${NC}"
    echo ""

    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    # Add Homebrew to PATH for Apple Silicon Macs
    if [[ -f "/opt/homebrew/bin/brew" ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi

    if command_exists brew; then
        print_success "Homebrew installed successfully!"
    else
        print_error "Homebrew installation failed"
        exit 1
    fi
}

# ============================================================================
# Step 2: Check/Install FFmpeg
# ============================================================================

check_ffmpeg() {
    print_step "Step 2/7: Checking for FFmpeg..."

    if command_exists ffmpeg; then
        print_success "FFmpeg is installed"
        print_info "$(ffmpeg -version 2>&1 | head -1)"
        return 0
    fi

    print_warning "FFmpeg is not installed"
    echo ""
    echo -e "  FFmpeg is required for creating MP3 audiobook files."
    echo ""

    read -p "  Install FFmpeg via Homebrew? [Y/n]: " -n 1 -r
    echo ""

    if [[ $REPLY =~ ^[Nn]$ ]]; then
        print_error "FFmpeg is required to continue."
        echo ""
        echo -e "  You can install it manually by running:"
        echo -e "  ${CYAN}brew install ffmpeg${NC}"
        exit 1
    fi

    echo ""
    echo -e "  ${YELLOW}Installing FFmpeg...${NC}"
    echo ""

    brew install ffmpeg

    if command_exists ffmpeg; then
        print_success "FFmpeg installed successfully!"
    else
        print_error "FFmpeg installation failed"
        exit 1
    fi
}

# ============================================================================
# Step 3: Check/Install Python 3.10-3.12
# ============================================================================

check_python() {
    print_step "Step 3/7: Checking Python version..."

    # Source the Python checker script to find suitable Python
    source "$PROJECT_ROOT/scripts/check-python.sh"
    PYTHON_CMD=$(find_suitable_python)

    if [[ -n "$PYTHON_CMD" ]]; then
        local version
        version=$("$PYTHON_CMD" --version 2>&1)
        print_success "Found compatible Python: $version"
        print_info "Location: $(which "$PYTHON_CMD" 2>/dev/null || echo "$PYTHON_CMD")"
        export PYTHON_CMD
        return 0
    fi

    # No suitable Python found
    print_warning "No compatible Python found (need 3.10, 3.11, or 3.12)"

    # Check what versions are installed
    local current_version=""
    if command_exists python3; then
        current_version=$(python3 --version 2>&1)
        print_info "Current Python: $current_version"
    fi

    echo ""
    echo -e "  The Kokoro TTS engine requires Python 3.10, 3.11, or 3.12."
    echo -e "  ${DIM}(Python 3.13+ is not yet supported by Kokoro)${NC}"
    echo ""

    read -p "  Install Python 3.12 via Homebrew? [Y/n]: " -n 1 -r
    echo ""

    if [[ $REPLY =~ ^[Nn]$ ]]; then
        print_error "A compatible Python version is required to continue."
        echo ""
        echo -e "  You can install it manually by running:"
        echo -e "  ${CYAN}brew install python@3.12${NC}"
        exit 1
    fi

    echo ""
    echo -e "  ${YELLOW}Installing Python 3.12...${NC}"
    echo ""

    brew install python@3.12

    # Find the newly installed Python
    PYTHON_CMD=$(find_suitable_python)

    if [[ -n "$PYTHON_CMD" ]]; then
        print_success "Python 3.12 installed successfully!"
        export PYTHON_CMD
    else
        print_error "Python installation failed"
        exit 1
    fi
}

# ============================================================================
# Step 4: Check/Install Node.js 18+
# ============================================================================

check_nodejs() {
    print_step "Step 4/7: Checking Node.js version..."

    if command_exists node; then
        local version
        version=$(node --version | sed 's/v//')
        local major
        major=$(echo "$version" | cut -d. -f1)

        if [[ "$major" -ge 18 ]]; then
            print_success "Node.js v$version is installed"
            return 0
        else
            print_warning "Node.js v$version is too old (need 18+)"
        fi
    else
        print_warning "Node.js is not installed"
    fi

    echo ""
    echo -e "  Node.js 18+ is required for the interactive CLI."
    echo ""

    read -p "  Install Node.js via Homebrew? [Y/n]: " -n 1 -r
    echo ""

    if [[ $REPLY =~ ^[Nn]$ ]]; then
        print_error "Node.js 18+ is required to continue."
        echo ""
        echo -e "  You can install it manually by running:"
        echo -e "  ${CYAN}brew install node${NC}"
        exit 1
    fi

    echo ""
    echo -e "  ${YELLOW}Installing Node.js...${NC}"
    echo ""

    brew install node

    if command_exists node; then
        print_success "Node.js installed successfully!"
    else
        print_error "Node.js installation failed"
        exit 1
    fi
}

# ============================================================================
# Step 5: Create Python Virtual Environment
# ============================================================================

setup_python_venv() {
    print_step "Step 5/7: Setting up Python virtual environment..."

    local venv_path="$PROJECT_ROOT/.venv"

    if [[ -d "$venv_path" ]] && [[ -f "$venv_path/bin/python" ]]; then
        # Check if existing venv has compatible Python
        local venv_version
        venv_version=$("$venv_path/bin/python" --version 2>&1 | sed 's/Python //' | awk -F. '{print $1$2}')

        if [[ "$venv_version" -ge 310 ]] && [[ "$venv_version" -le 312 ]]; then
            print_success "Virtual environment already exists with Python $("$venv_path/bin/python" --version 2>&1 | sed 's/Python //')"
            return 0
        else
            print_warning "Existing virtual environment has incompatible Python version"
            print_info "Recreating with Python ${PYTHON_CMD}..."
            rm -rf "$venv_path"
        fi
    fi

    echo -e "  ${DIM}Creating virtual environment with ${PYTHON_CMD}...${NC}"

    "$PYTHON_CMD" -m venv "$venv_path"

    if [[ -f "$venv_path/bin/python" ]]; then
        print_success "Virtual environment created at .venv/"
    else
        print_error "Failed to create virtual environment"
        exit 1
    fi
}

# ============================================================================
# Step 6: Install Python Dependencies
# ============================================================================

install_python_deps() {
    print_step "Step 6/7: Installing Python dependencies..."

    local venv_path="$PROJECT_ROOT/.venv"
    local pip="$venv_path/bin/pip"

    echo -e "  ${DIM}This will install the Kokoro TTS engine and other dependencies.${NC}"
    echo -e "  ${DIM}The download is about 200MB.${NC}"
    echo ""

    # Upgrade pip first
    "$pip" install --upgrade pip -q

    # Install requirements
    echo -e "  ${YELLOW}Installing packages...${NC}"
    "$pip" install -r "$PROJECT_ROOT/requirements.txt"

    print_success "Python dependencies installed"
}

# ============================================================================
# Step 7: Install CLI Dependencies
# ============================================================================

install_cli_deps() {
    print_step "Step 7/7: Installing CLI dependencies..."

    cd "$PROJECT_ROOT/cli"

    if [[ -d "node_modules" ]]; then
        print_info "node_modules already exists, running npm install to update..."
    fi

    echo -e "  ${YELLOW}Running npm install...${NC}"
    npm install

    print_success "CLI dependencies installed"
    cd "$PROJECT_ROOT"
}

# ============================================================================
# Optional: Install MLX Backend
# ============================================================================

offer_mlx_install() {
    echo ""
    echo -e "${CYAN}${BOLD}▶ Optional: Install MLX Backend${NC}"
    echo ""
    echo -e "  MLX is Apple's optimized ML framework for Apple Silicon."
    echo -e "  It provides significantly faster TTS inference (often >20x real-time)"
    echo -e "  compared to PyTorch on M1/M2/M3/M4 Macs."
    echo ""
    echo -e "  ${DIM}Note: MLX only works on Apple Silicon Macs.${NC}"
    echo ""

    read -p "  Install MLX-Audio backend? [y/N]: " -n 1 -r
    echo ""

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo ""
        echo -e "  ${YELLOW}Installing MLX-Audio...${NC}"
        echo -e "  ${DIM}(This may take a few minutes)${NC}"
        echo ""

        local venv_pip="$PROJECT_ROOT/.venv/bin/pip"
        "$venv_pip" install -r "$PROJECT_ROOT/requirements-mlx.txt"

        print_success "MLX backend installed!"
        print_info "You can select it in the CLI under 'Backend' configuration."
    else
        print_info "Skipping MLX installation. You can install it later with:"
        print_info "  pip install -r requirements-mlx.txt"
    fi
}

# ============================================================================
# Optional: Pre-download TTS Models
# ============================================================================

offer_model_download() {
    echo ""
    echo -e "${CYAN}${BOLD}▶ Optional: Pre-download TTS Models${NC}"
    echo ""
    echo -e "  The AI voice model (~1GB) will download automatically on first use,"
    echo -e "  but you can download it now to avoid waiting later."
    echo ""

    read -p "  Download model now? [y/N]: " -n 1 -r
    echo ""

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo ""
        echo -e "  ${YELLOW}Downloading Kokoro TTS model...${NC}"
        echo -e "  ${DIM}(This may take a few minutes depending on your connection)${NC}"
        echo ""

        local venv_python="$PROJECT_ROOT/.venv/bin/python"
        "$venv_python" "$PROJECT_ROOT/scripts/download-models.py"

        print_success "Model downloaded successfully!"
    else
        print_info "Skipping model download. It will download on first use."
    fi
}

# ============================================================================
# Success Message
# ============================================================================

print_success_message() {
    echo ""
    echo -e "${GREEN}${BOLD}"
    echo "  ╔═══════════════════════════════════════════════════════════╗"
    echo "  ║                                                           ║"
    echo "  ║   ✨  Setup Complete!                                     ║"
    echo "  ║                                                           ║"
    echo "  ╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
    echo -e "  ${WHITE}${BOLD}To start making audiobooks:${NC}"
    echo ""
    echo -e "  ${CYAN}cd cli && npm run dev${NC}"
    echo ""
    echo -e "  ${DIM}Or with Apple Silicon GPU acceleration:${NC}"
    echo -e "  ${CYAN}cd cli && npm run dev:mps${NC}"
    echo ""
    echo -e "  ${DIM}──────────────────────────────────────────────────────────${NC}"
    echo ""
    echo -e "  ${WHITE}${BOLD}What you can do:${NC}"
    echo -e "  • Drop EPUB files into the interactive interface"
    echo -e "  • Choose from 11+ AI voices (American & British)"
    echo -e "  • Adjust speech speed (0.75x to 1.5x)"
    echo -e "  • Process multiple books at once"
    echo ""
    echo -e "  ${DIM}Need help? Check the README or open an issue on GitHub.${NC}"
    echo ""
}

# ============================================================================
# Main Setup Flow
# ============================================================================

main() {
    print_banner

    echo -e "  Welcome! This script will set up everything you need to convert"
    echo -e "  EPUB books into AI-generated audiobooks."
    echo ""
    echo -e "  ${WHITE}${BOLD}What will be installed:${NC}"
    echo -e "  • Homebrew (macOS package manager)"
    echo -e "  • FFmpeg (for MP3 encoding)"
    echo -e "  • Python 3.12 (if needed)"
    echo -e "  • Node.js (for the interactive CLI)"
    echo -e "  • Python packages (~200MB)"
    echo -e "  • Node.js packages"
    echo ""
    echo -e "  ${DIM}The TTS model (~1GB) downloads automatically on first use.${NC}"

    press_enter_to_continue

    # Run all setup steps
    check_homebrew
    check_ffmpeg
    check_python
    check_nodejs
    setup_python_venv
    install_python_deps
    install_cli_deps
    offer_mlx_install
    offer_model_download

    print_success_message
}

# Run main if this script is executed directly (not sourced for testing)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] || [[ "${BASH_SOURCE[0]}" == *"setup-macos.sh" ]]; then
    main
fi
