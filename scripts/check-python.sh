#!/bin/bash
#
# Python Version Checker for AI Audiobook Fast
#
# This script finds a suitable Python installation (3.10, 3.11, or 3.12)
# by checking various locations: system, Homebrew, pyenv.
#
# Usage:
#   source scripts/check-python.sh
#   PYTHON_CMD=$(find_suitable_python)
#   if [[ -n "$PYTHON_CMD" ]]; then
#       echo "Found: $PYTHON_CMD"
#   fi
#

# Get Python version as a comparable number (e.g., "3.11" -> 311)
get_python_major_minor() {
    local python_cmd="$1"
    if command -v "$python_cmd" >/dev/null 2>&1 || [[ -x "$python_cmd" ]]; then
        "$python_cmd" --version 2>&1 | sed 's/Python //' | awk -F. '{print $1$2}'
    else
        echo "0"
    fi
}

# Check if a Python version is compatible (3.10, 3.11, or 3.12)
is_compatible_python() {
    local version_num="$1"
    [[ "$version_num" -ge 310 ]] && [[ "$version_num" -le 312 ]]
}

# Find a suitable Python command
# Returns the command/path to use, or empty string if none found
find_suitable_python() {
    local candidates=()
    local version_num

    # Priority 1: Homebrew Python (most reliable on macOS)
    # Check both Apple Silicon and Intel paths
    local brew_pythons=(
        "/opt/homebrew/bin/python3.12"
        "/opt/homebrew/bin/python3.11"
        "/opt/homebrew/bin/python3.10"
        "/usr/local/bin/python3.12"
        "/usr/local/bin/python3.11"
        "/usr/local/bin/python3.10"
    )

    for py in "${brew_pythons[@]}"; do
        if [[ -x "$py" ]]; then
            version_num=$(get_python_major_minor "$py")
            if is_compatible_python "$version_num"; then
                echo "$py"
                return 0
            fi
        fi
    done

    # Priority 2: pyenv (if user has it set up)
    if command -v pyenv >/dev/null 2>&1; then
        # Check pyenv shims
        local pyenv_root
        pyenv_root=$(pyenv root 2>/dev/null || echo "$HOME/.pyenv")

        for v in 3.12 3.11 3.10; do
            local pyenv_python="$pyenv_root/versions/${v}.*/bin/python3"
            # Use glob to find any patch version
            for py in $pyenv_python; do
                if [[ -x "$py" ]]; then
                    version_num=$(get_python_major_minor "$py")
                    if is_compatible_python "$version_num"; then
                        echo "$py"
                        return 0
                    fi
                fi
            done
        done
    fi

    # Priority 3: Versioned python commands in PATH
    for v in 3.12 3.11 3.10; do
        if command -v "python$v" >/dev/null 2>&1; then
            version_num=$(get_python_major_minor "python$v")
            if is_compatible_python "$version_num"; then
                echo "python$v"
                return 0
            fi
        fi
    done

    # Priority 4: Generic python3 command (might be 3.13+, but check anyway)
    if command -v python3 >/dev/null 2>&1; then
        version_num=$(get_python_major_minor "python3")
        if is_compatible_python "$version_num"; then
            echo "python3"
            return 0
        fi
    fi

    # No compatible Python found
    return 1
}

# Print diagnostic info about available Python versions
diagnose_python() {
    echo "Python installations found:"
    echo ""

    # Check system python3
    if command -v python3 >/dev/null 2>&1; then
        echo "  python3: $(python3 --version 2>&1) [$(which python3)]"
    fi

    # Check versioned pythons
    for v in 3.10 3.11 3.12 3.13; do
        if command -v "python$v" >/dev/null 2>&1; then
            echo "  python$v: $(python$v --version 2>&1) [$(which python$v)]"
        fi
    done

    # Check Homebrew pythons
    echo ""
    echo "Homebrew installations:"
    for py in /opt/homebrew/bin/python3.* /usr/local/bin/python3.*; do
        if [[ -x "$py" ]] && [[ ! "$py" == *"*"* ]]; then
            echo "  $py: $($py --version 2>&1)"
        fi
    done

    # Check pyenv
    if command -v pyenv >/dev/null 2>&1; then
        echo ""
        echo "pyenv versions:"
        pyenv versions 2>/dev/null | head -10
    fi
}

# If run directly, diagnose the system
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    diagnose_python
    echo ""
    PYTHON_CMD=$(find_suitable_python)
    if [[ -n "$PYTHON_CMD" ]]; then
        echo "Recommended Python: $PYTHON_CMD"
        echo "Version: $($PYTHON_CMD --version 2>&1)"
    else
        echo "No compatible Python (3.10-3.12) found!"
        exit 1
    fi
fi
