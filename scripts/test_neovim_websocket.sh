#!/usr/bin/env bash

# test_neovim_websocket.sh - Test script for the Claude Code Neovim WebSocket Server
# This script launches Neovim with the plugin and runs MCP protocol tests against it.

set -e

# Source the library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib_claude.sh
source "$SCRIPT_DIR/lib_claude.sh"

# Configuration
TIMEOUT=10 # Maximum time to wait for server in seconds
NVIM_INIT_FILE="/tmp/test_claudecode_init.lua"
NVIM_BUFFER_FILE="/tmp/test_claudecode_buffer.txt"
SAMPLE_FILE="/tmp/sample_file.lua" # File to open in Neovim for testing
NVIM_PID=""
LISTEN_DURATION=10            # How long to listen for messages (seconds)
LOG_DIR="test_neovim_ws_logs" # Directory for log files
TEST_MODE="all"               # Default test mode
WEBSOCKET_PORT=""             # Will be detected from lock file

# Parse command line arguments
usage() {
  echo "Usage: $0 [options] [test-mode]"
  echo
  echo "Options:"
  echo "  -t, --timeout SEC    Timeout for server startup (default: $TIMEOUT)"
  echo "  -l, --listen SEC     Duration to listen for events (default: $LISTEN_DURATION)"
  echo "  -d, --log-dir DIR    Directory for logs (default: $LOG_DIR)"
  echo "  -h, --help           Show this help message"
  echo
  echo "Available test modes:"
  echo "  all                  Run all tests (default)"
  echo "  connect              Test basic connection"
  echo "  toolslist            Test tools/list method"
  echo "  selection            Test selection notifications"
  echo
  echo "Example: $0 selection"
  echo
  exit 1
}

while [[ $# -gt 0 ]]; do
  case $1 in
  -t | --timeout)
    TIMEOUT="$2"
    shift 2
    ;;
  -l | --listen)
    LISTEN_DURATION="$2"
    shift 2
    ;;
  -d | --log-dir)
    LOG_DIR="$2"
    shift 2
    ;;
  -h | --help)
    usage
    ;;
  *)
    TEST_MODE="$1"
    shift
    ;;
  esac
done

# Setup trap to ensure Neovim is killed on exit
cleanup() {
  if [ -n "$NVIM_PID" ] && ps -p "$NVIM_PID" >/dev/null; then
    echo "Cleaning up: Killing Neovim process $NVIM_PID"
    kill "$NVIM_PID" 2>/dev/null || kill -9 "$NVIM_PID" 2>/dev/null
  fi

  if [ -f "$NVIM_INIT_FILE" ]; then
    echo "Removing temporary init file"
    rm -f "$NVIM_INIT_FILE"
  fi

  if [ -f "$NVIM_BUFFER_FILE" ]; then
    echo "Removing temporary buffer file"
    rm -f "$NVIM_BUFFER_FILE"
  fi

  if [ -f "$SAMPLE_FILE" ]; then
    echo "Removing sample file"
    rm -f "$SAMPLE_FILE"
  fi

  echo "Cleanup completed"
}

# Register the cleanup function for various signals
trap cleanup EXIT INT TERM

# Create log directory
mkdir -p "$LOG_DIR"

# Create a sample Lua file for testing
cat >"$SAMPLE_FILE" <<'EOL'
-- Sample Lua file for testing selection notifications

local M = {}

---Main function to perform a task
---@param input string The input string to process
---@return boolean success Whether the operation succeeded
---@return string|nil result The result of the operation
function M.performTask(input)
  if type(input) ~= "string" then
    return false, "Input must be a string"
  end
  
  if #input == 0 then
    return false, "Input cannot be empty"
  end
  
  -- Process the input
  local result = input:upper()
  
  return true, result
end

---Configuration options for the module
M.config = {
  enabled = true,
  timeout = 1000,
  retries = 3,
  log_level = "info"
}

---Initialize the module with given options
---@param opts table Configuration options
---@return boolean success Whether initialization succeeded
function M.setup(opts)
  opts = opts or {}
  
  -- Merge options with defaults
  for k, v in pairs(opts) do
    M.config[k] = v
  end
  
  -- Additional setup logic here
  
  return true
end

return M
EOL

# Create a temporary init.lua file for testing
cat >"$NVIM_INIT_FILE" <<'EOL'
-- Minimal init.lua for testing the WebSocket server
vim.cmd('set rtp+=.')
require('claude_agents').setup({
  auto_start = true,
  log_level = "debug",
  track_selection = true
})

-- Function to perform test operations once the server is running
function perform_test_operations()
  -- Open the sample file
  vim.cmd('edit ' .. os.getenv('SAMPLE_FILE'))
  
  -- Make some selections to trigger selection_changed events
  vim.defer_fn(function()
    -- Select the performTask function
    vim.api.nvim_win_set_cursor(0, {9, 0})
    vim.cmd('normal! V12j')
    vim.defer_fn(function()
      -- Move cursor to a specific position
      vim.api.nvim_win_set_cursor(0, {25, 10})
      vim.defer_fn(function()
        -- Select the config table
        vim.api.nvim_win_set_cursor(0, {27, 0})
        vim.cmd('normal! V5j')
      end, 500)
    end, 500)
  end, 1000)
end

-- Schedule test operations after a delay to ensure server is running
vim.defer_fn(perform_test_operations, 2000)
EOL

# Function to find the most recently created lockfile
# We use our own version here since we need to check the actual file on disk
# to detect when the Neovim plugin creates a new lockfile
find_newest_lockfile() {
  local lockfile_dir="$CLAUDE_LOCKFILE_DIR"

  if [ "$(uname)" = "Darwin" ]; then
    # macOS version
    find "$lockfile_dir" -name "*.lock" -type f -exec stat -f "%m %N" {} \; 2>/dev/null | sort -nr | head -n 1 | awk '{print $2}'
  else
    # Linux version
    find "$lockfile_dir" -name "*.lock" -type f -exec stat -c "%Y %n" {} \; 2>/dev/null | sort -nr | head -n 1 | awk '{print $2}'
  fi
}

# Record initial state of lockfiles
echo "Checking for existing Claude IDE lock files..."
INITIAL_NEWEST_LOCKFILE=$(find_newest_lockfile)
INITIAL_MTIME=0
if [ -n "$INITIAL_NEWEST_LOCKFILE" ]; then
  if [ "$(uname)" = "Darwin" ]; then
    # macOS version
    INITIAL_MTIME=$(stat -f "%m" "$INITIAL_NEWEST_LOCKFILE")
  else
    # Linux version
    INITIAL_MTIME=$(stat -c "%Y" "$INITIAL_NEWEST_LOCKFILE")
  fi
  echo "Found existing lock file: $INITIAL_NEWEST_LOCKFILE (mtime: $INITIAL_MTIME)"
else
  echo "No existing lock files found."
fi

# Start Neovim with the plugin in the background
echo "Starting Neovim with Claude Code plugin..."
SAMPLE_FILE="$SAMPLE_FILE" nvim -u "$NVIM_INIT_FILE" &
NVIM_PID=$!

# Wait for a new lockfile to appear
echo "Waiting for WebSocket server to start..."
PORT=""
ELAPSED=0

while [[ -z $PORT && $ELAPSED -lt $TIMEOUT ]]; do
  NEWEST_LOCKFILE=$(find_newest_lockfile)

  if [ -n "$NEWEST_LOCKFILE" ]; then
    if [ "$(uname)" = "Darwin" ]; then
      # macOS version
      NEWEST_MTIME=$(stat -f "%m" "$NEWEST_LOCKFILE")
    else
      # Linux version
      NEWEST_MTIME=$(stat -c "%Y" "$NEWEST_LOCKFILE")
    fi

    # If this is a new lockfile that wasn't there before or is newer than our initial check
    if [ "$NEWEST_MTIME" -gt "$INITIAL_MTIME" ]; then
      LOCKFILE="$NEWEST_LOCKFILE"
      PORT=$(basename "$LOCKFILE" .lock)

      if [[ $PORT =~ ^[0-9]+$ ]]; then
        break
      else
        echo "Found lock file with invalid port format: $PORT"
      fi
    fi
  fi

  sleep 1
  ((ELAPSED++))
  echo "Waiting for server... ($ELAPSED/$TIMEOUT seconds)"
done

if [[ -z $PORT ]]; then
  echo "Error: Server did not start within $TIMEOUT seconds."
  exit 1
fi

echo "Server started on port $PORT (lockfile: $LOCKFILE)"
WEBSOCKET_PORT="$PORT"

# MCP connection message
MCP_CONNECT='{
  "jsonrpc": "2.0",
  "id": "1",
  "method": "mcp.connect",
  "params": {
    "protocolVersion": "2024-11-05",
    "capabilities": {
      "tools": {}
    },
    "clientInfo": {
      "name": "neovim-test-client",
      "version": "1.0.0"
    }
  }
}'

# Test functions
test_connection() {
  local log_file="$LOG_DIR/connection_test.jsonl"
  local pretty_log="$LOG_DIR/connection_test_pretty.txt"

  echo "=== Running Connection Test ==="
  echo "Logs: $log_file"
  echo

  # Clear previous log files
  true >"$log_file"
  true >"$pretty_log"

  echo "Connecting to WebSocket server at ws://127.0.0.1:$WEBSOCKET_PORT/"
  echo "Sending connection message..."
  echo

  # Send connection message and capture response
  local response
  response=$(echo "$MCP_CONNECT" | websocat -n1 "ws://127.0.0.1:$WEBSOCKET_PORT/")

  # Log the request and response
  echo "$MCP_CONNECT" >>"$log_file"
  echo "$response" >>"$log_file"
  {
    echo -e "\n--- Connection Request ---"
    echo "$MCP_CONNECT" | jq '.'
    echo -e "\n--- Connection Response ---"
    echo "$response" | jq '.' 2>/dev/null || echo "Invalid JSON: $response"
  } >>"$pretty_log"

  # Display and analyze the response
  echo "Response:"
  echo "$response"
  echo

  if echo "$response" | grep -q '"id":"1"'; then
    echo "✅ Received response to our connection request!"

    # Extract server info if present
    local server_info
    server_info=$(echo "$response" | jq -r '.result.serverInfo // "Not provided"' 2>/dev/null)
    local protocol
    protocol=$(echo "$response" | jq -r '.result.protocolVersion // "Not provided"' 2>/dev/null)

    echo "Server info: $server_info"
    echo "Protocol version: $protocol"
  else
    echo "⚠️ No direct response to our connection request"

    if echo "$response" | grep -q '"method":"selection_changed"'; then
      echo "📝 Received a selection_changed notification instead (this is normal)"
    fi
  fi

  echo "=== Connection Test Completed ==="
  echo
}

test_tools_list() {
  local log_file="$LOG_DIR/tools_list_test.jsonl"
  local pretty_log="$LOG_DIR/tools_list_test_pretty.txt"

  echo "=== Running Tools List Test ==="
  echo "Logs: $log_file"
  echo

  # Clear previous log files
  true >"$log_file"
  true >"$pretty_log"

  # Create tools/list request
  local request='{
    "jsonrpc": "2.0",
    "id": "tools-list-test",
    "method": "tools/list",
    "params": {}
  }'

  echo "Connecting to WebSocket server at ws://127.0.0.1:$WEBSOCKET_PORT/"
  echo "Sending tools/list request..."
  echo

  # Send request and capture response
  local response
  response=$(echo "$request" | websocat -n1 "ws://127.0.0.1:$WEBSOCKET_PORT/")

  # Log the request and response
  echo "$request" >>"$log_file"
  echo "$response" >>"$log_file"
  {
    echo -e "\n--- Tools List Request ---"
    echo "$request" | jq '.'
    echo -e "\n--- Tools List Response ---"
    echo "$response" | jq '.' 2>/dev/null || echo "Invalid JSON: $response"
  } >>"$pretty_log"

  # Display and analyze the response
  echo "Response received."

  if echo "$response" | grep -q '"error"'; then
    local error_code
    error_code=$(echo "$response" | jq -r '.error.code // "unknown"' 2>/dev/null)
    local error_message
    error_message=$(echo "$response" | jq -r '.error.message // "unknown"' 2>/dev/null)
    echo "❌ Error response: Code $error_code - $error_message"
  elif echo "$response" | grep -q '"result"'; then
    echo "✅ Successful response with tools list!"

    # Extract and count tools
    local tools_count
    tools_count=$(echo "$response" | jq '.result.tools | length' 2>/dev/null)
    echo "Found $tools_count tools in the response."

    # List the tool names
    echo "Tool names:"
    echo "$response" | jq -r '.result.tools[].name' 2>/dev/null | sort | sed 's/^/  - /'
  elif echo "$response" | grep -q '"method":"selection_changed"'; then
    echo "⚠️ Received selection_changed notification instead of response"
  else
    echo "⚠️ Unexpected response format"
  fi

  echo "=== Tools List Test Completed ==="
  echo
  echo "For full details, see: $pretty_log"
  echo
}

test_selection() {
  local log_file="$LOG_DIR/selection_test.jsonl"
  local pretty_log="$LOG_DIR/selection_test_pretty.txt"

  echo "=== Running Selection Notification Test ==="
  echo "Logs: $log_file"
  echo

  # Clear previous log files
  true >"$log_file"
  true >"$pretty_log"

  echo "Connecting to WebSocket server at ws://127.0.0.1:$WEBSOCKET_PORT/"
  echo "Listening for selection_changed events for $LISTEN_DURATION seconds..."
  echo "Automatic selections will be made in the Neovim instance."
  echo

  # Connect and listen for messages
  (
    # Send an initial message to establish connection
    echo '{"jsonrpc":"2.0","id":"selection-test","method":"mcp.connect","params":{"protocolVersion":"2024-11-05"}}'

    # Keep the connection open
    sleep "$LISTEN_DURATION"
  ) | websocat "ws://127.0.0.1:$WEBSOCKET_PORT/" | tee >(cat >"$log_file") | {
    # Process received messages
    local selection_count=0

    while IFS= read -r line; do
      # Check if this is a selection_changed notification
      if echo "$line" | grep -q '"method":"selection_changed"'; then
        ((selection_count++))
        echo "📝 Received selection_changed notification #$selection_count"

        # Extract some details
        local is_empty
        is_empty=$(echo "$line" | jq -r '.params.selection.isEmpty // "unknown"' 2>/dev/null)
        local file_path
        file_path=$(echo "$line" | jq -r '.params.filePath // "unknown"' 2>/dev/null)
        local text_length
        text_length=$(echo "$line" | jq -r '.params.text | length // 0' 2>/dev/null)

        echo "  File: $file_path"
        echo "  Empty selection: $is_empty"
        echo "  Text length: $text_length characters"
        echo

        # Log to pretty log
        echo -e "\n--- Selection Changed Notification #$selection_count ---" >>"$pretty_log"
        echo "$line" | jq '.' >>"$pretty_log" 2>/dev/null || echo "Invalid JSON: $line" >>"$pretty_log"
      else
        echo "Received non-selection message:"
        echo "$line" | jq '.' 2>/dev/null || echo "$line"
        echo

        # Log to pretty log
        echo -e "\n--- Other Message ---" >>"$pretty_log"
        echo "$line" | jq '.' >>"$pretty_log" 2>/dev/null || echo "Invalid JSON: $line" >>"$pretty_log"
      fi
    done

    echo "Received $selection_count selection_changed notifications."
  }

  echo "=== Selection Notification Test Completed ==="
  echo
  echo "For full details, see: $pretty_log"
  echo
}

# Run selected tests
run_tests() {
  case "$TEST_MODE" in
  "all")
    test_connection
    test_tools_list
    test_selection
    ;;
  "connect")
    test_connection
    ;;
  "toolslist")
    test_tools_list
    ;;
  "selection")
    test_selection
    ;;
  *)
    echo "Unknown test mode: $TEST_MODE"
    echo "Available modes: all, connect, toolslist, selection"
    exit 1
    ;;
  esac
}

# Execute the tests
run_tests

echo "All tests completed."
echo "Log files are available in: $LOG_DIR"

# Cleanup will be handled by the trap on exit
