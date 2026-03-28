#!/usr/bin/env bash
# =============================================================================
# interactive.sh — Interactive input helper functions
# =============================================================================
# Assumes colors.sh has been sourced.
# =============================================================================

# Ask a question with a default value
# Usage: result=$(ask "Prompt text" "default_value")
ask() {
  local prompt="$1"
  local default="$2"
  local answer

  if [[ -n "$default" ]]; then
    printf "  ${BOLD}%s${NC} ${DIM}[%s]${NC}: " "$prompt" "$default"
  else
    printf "  ${BOLD}%s${NC}: " "$prompt"
  fi

  read -r answer
  echo "${answer:-$default}"
}

# Ask for a password (hidden input)
# Usage: result=$(ask_password "Prompt text")
ask_password() {
  local prompt="$1"
  local answer

  printf "  ${BOLD}%s${NC}: " "$prompt"
  read -rs answer
  echo "" >&2  # newline after hidden input
  echo "$answer"
}

# Ask a yes/no question
# Usage: if ask_yes_no "Continue?" "y"; then ...
ask_yes_no() {
  local prompt="$1"
  local default="${2:-y}"
  local hint

  if [[ "$default" == "y" ]]; then
    hint="Y/n"
  else
    hint="y/N"
  fi

  while true; do
    printf "  ${BOLD}%s${NC} ${DIM}[%s]${NC}: " "$prompt" "$hint"
    local answer
    read -r answer
    answer="${answer:-$default}"

    case "$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *)     printf "  ${YELLOW}Please answer y or n${NC}\n" ;;
    esac
  done
}

# Ask the user to choose from a list of options
# Usage: result=$(ask_choice "Prompt" "option1" "option2" "option3")
# The first option is the default
ask_choice() {
  local prompt="$1"
  shift
  local options=("$@")
  local default="${options[0]}"

  printf "  ${BOLD}%s${NC}\n" "$prompt"
  local i
  for i in "${!options[@]}"; do
    local marker=""
    if [[ "${options[$i]}" == "$default" ]]; then
      marker=" ${DIM}(default)${NC}"
    fi
    printf "    ${CYAN}%d)${NC} %s%s\n" "$((i + 1))" "${options[$i]}" "$marker"
  done
  printf "  ${BOLD}Choice${NC} ${DIM}[1]${NC}: "

  local answer
  read -r answer
  answer="${answer:-1}"

  # Validate numeric input
  if [[ "$answer" =~ ^[0-9]+$ ]] && [[ $answer -ge 1 ]] && [[ $answer -le ${#options[@]} ]]; then
    echo "${options[$((answer - 1))]}"
  else
    echo "$default"
  fi
}

# Ask for a file path with validation
# Usage: result=$(ask_file "Prompt" "/default/path" "required|optional")
ask_file() {
  local prompt="$1"
  local default="$2"
  local required="${3:-required}"

  while true; do
    local answer
    answer=$(ask "$prompt" "$default")

    if [[ -z "$answer" ]] && [[ "$required" == "optional" ]]; then
      echo ""
      return 0
    fi

    if [[ -z "$answer" ]]; then
      printf "  ${RED}A file path is required${NC}\n"
      continue
    fi

    # Expand ~ to $HOME
    answer="${answer/#\~/$HOME}"

    if [[ -f "$answer" ]]; then
      echo "$answer"
      return 0
    else
      printf "  ${RED}File not found: %s${NC}\n" "$answer"
      if [[ "$required" == "optional" ]]; then
        if ask_yes_no "Skip this?" "y"; then
          echo ""
          return 0
        fi
      fi
    fi
  done
}

# Generate a random password of given length
generate_password() {
  local length="${1:-24}"
  # Use only alphanumeric + safe special chars to avoid shell escaping issues
  LC_ALL=C tr -dc 'A-Za-z0-9!@#%^_+=' < /dev/urandom | head -c "$length" 2>/dev/null || \
  openssl rand -base64 "$length" | head -c "$length"
}

# Ask for a password with option to generate
# Usage: result=$(ask_password_or_generate "Prompt" "24")
ask_password_or_generate() {
  local prompt="$1"
  local length="${2:-24}"

  printf "  ${BOLD}%s${NC}\n" "$prompt"
  printf "    ${CYAN}1)${NC} Generate random password ${DIM}(recommended)${NC}\n"
  printf "    ${CYAN}2)${NC} Enter manually\n"
  printf "  ${BOLD}Choice${NC} ${DIM}[1]${NC}: "

  local choice
  read -r choice
  choice="${choice:-1}"

  case "$choice" in
    1)
      local pw
      pw=$(generate_password "$length")
      printf "  ${DIM}Generated: %s${NC}\n" "$pw" >&2
      echo "$pw"
      ;;
    2)
      ask_password "  Enter password"
      ;;
    *)
      local pw
      pw=$(generate_password "$length")
      printf "  ${DIM}Generated: %s${NC}\n" "$pw" >&2
      echo "$pw"
      ;;
  esac
}

# Show a confirmation summary and ask to proceed
# Usage: confirm_summary "Header" "key1=value1" "key2=value2" ...
confirm_summary() {
  local header="$1"
  shift

  echo ""
  print_separator
  printf "${BOLD}${CYAN}%s${NC}\n" "$header"
  print_separator

  for item in "$@"; do
    local key="${item%%=*}"
    local value="${item#*=}"
    # Mask passwords/tokens
    if [[ "$key" =~ [Pp]assword|[Tt]oken|[Ss]ecret|[Kk]ey ]]; then
      if [[ -n "$value" ]]; then
        local masked
        masked="$(echo "$value" | head -c 3)***"
        printf "  ${BOLD}%-28s${NC} %s\n" "$key" "$masked"
      else
        printf "  ${BOLD}%-28s${NC} ${DIM}(not set)${NC}\n" "$key"
      fi
    else
      printf "  ${BOLD}%-28s${NC} %s\n" "$key" "${value:-(not set)}"
    fi
  done

  print_separator
  echo ""

  if ask_yes_no "Proceed with these settings?" "y"; then
    return 0
  else
    return 1
  fi
}

# Validate a non-empty input
validate_not_empty() {
  local value="$1"
  local field_name="$2"
  if [[ -z "$value" ]]; then
    log_error "$field_name cannot be empty"
    return 1
  fi
  return 0
}

# Validate an email address (basic)
validate_email() {
  local email="$1"
  if [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    return 0
  else
    log_error "Invalid email address: $email"
    return 1
  fi
}

# Validate a domain name (basic)
validate_domain() {
  local domain="$1"
  if [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
    return 0
  else
    log_error "Invalid domain: $domain"
    return 1
  fi
}

# Validate an integer within a range
validate_integer_range() {
  local value="$1"
  local min="$2"
  local max="$3"
  local field_name="$4"

  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    log_error "$field_name must be a number"
    return 1
  fi
  if [[ $value -lt $min ]] || [[ $value -gt $max ]]; then
    log_error "$field_name must be between $min and $max"
    return 1
  fi
  return 0
}
