require("tests.busted_setup")

describe("WebSocket handshake authentication", function()
  local handshake

  before_each(function()
    handshake = require("claude_agents.server.handshake")
  end)

  after_each(function()
    package.loaded["claude_agents.server.handshake"] = nil
  end)

  describe("validate_upgrade_request with authentication", function()
    local valid_request_base = table.concat({
      "GET /websocket HTTP/1.1",
      "Host: localhost:8080",
      "Upgrade: websocket",
      "Connection: upgrade",
      "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
      "Sec-WebSocket-Version: 13",
      "",
      "",
    }, "\r\n")

    it("should accept valid request with correct auth token", function()
      local expected_token = "550e8400-e29b-41d4-a716-446655440000"
      local request_with_auth = table.concat({
        "GET /websocket HTTP/1.1",
        "Host: localhost:8080",
        "Upgrade: websocket",
        "Connection: upgrade",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13",
        "x-claude-code-ide-authorization: " .. expected_token,
        "",
        "",
      }, "\r\n")

      local is_valid, headers = handshake.validate_upgrade_request(request_with_auth, expected_token)

      assert.is_true(is_valid)
      assert.is_table(headers)
      assert.equals(expected_token, headers["x-claude-code-ide-authorization"])
    end)

    it("should reject request with missing auth token when required", function()
      local expected_token = "550e8400-e29b-41d4-a716-446655440000"

      local is_valid, error_msg = handshake.validate_upgrade_request(valid_request_base, expected_token)

      assert.is_false(is_valid)
      assert.equals("Missing authentication header: x-claude-code-ide-authorization", error_msg)
    end)

    it("should reject request with incorrect auth token", function()
      local expected_token = "550e8400-e29b-41d4-a716-446655440000"
      local wrong_token = "123e4567-e89b-12d3-a456-426614174000"

      local request_with_wrong_auth = table.concat({
        "GET /websocket HTTP/1.1",
        "Host: localhost:8080",
        "Upgrade: websocket",
        "Connection: upgrade",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13",
        "x-claude-code-ide-authorization: " .. wrong_token,
        "",
        "",
      }, "\r\n")

      local is_valid, error_msg = handshake.validate_upgrade_request(request_with_wrong_auth, expected_token)

      assert.is_false(is_valid)
      assert.equals("Invalid authentication token", error_msg)
    end)

    it("should accept request without auth token when none required", function()
      local is_valid, headers = handshake.validate_upgrade_request(valid_request_base, nil)

      assert.is_true(is_valid)
      assert.is_table(headers)
    end)

    it("should reject request with empty auth token when required", function()
      local expected_token = "550e8400-e29b-41d4-a716-446655440000"

      local request_with_empty_auth = table.concat({
        "GET /websocket HTTP/1.1",
        "Host: localhost:8080",
        "Upgrade: websocket",
        "Connection: upgrade",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13",
        "x-claude-code-ide-authorization: ",
        "",
        "",
      }, "\r\n")

      local is_valid, error_msg = handshake.validate_upgrade_request(request_with_empty_auth, expected_token)

      assert.is_false(is_valid)
      assert.equals("Authentication token too short (min 10 characters)", error_msg)
    end)

    it("should handle case-insensitive auth header name", function()
      local expected_token = "550e8400-e29b-41d4-a716-446655440000"

      local request_with_uppercase_header = table.concat({
        "GET /websocket HTTP/1.1",
        "Host: localhost:8080",
        "Upgrade: websocket",
        "Connection: upgrade",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13",
        "X-Claude-Code-IDE-Authorization: " .. expected_token,
        "",
        "",
      }, "\r\n")

      local is_valid, headers = handshake.validate_upgrade_request(request_with_uppercase_header, expected_token)

      assert.is_true(is_valid)
      assert.is_table(headers)
    end)
  end)

  describe("process_handshake with authentication", function()
    local valid_request_base = table.concat({
      "GET /websocket HTTP/1.1",
      "Host: localhost:8080",
      "Upgrade: websocket",
      "Connection: upgrade",
      "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
      "Sec-WebSocket-Version: 13",
      "",
      "",
    }, "\r\n")

    it("should complete handshake successfully with valid auth token", function()
      local expected_token = "550e8400-e29b-41d4-a716-446655440000"
      local request_with_auth = table.concat({
        "GET /websocket HTTP/1.1",
        "Host: localhost:8080",
        "Upgrade: websocket",
        "Connection: upgrade",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13",
        "x-claude-code-ide-authorization: " .. expected_token,
        "",
        "",
      }, "\r\n")

      local success, response, headers = handshake.process_handshake(request_with_auth, expected_token)

      assert.is_true(success)
      assert.is_string(response)
      assert.is_table(headers)
      assert.matches("HTTP/1.1 101 Switching Protocols", response)
      assert.matches("Upgrade: websocket", response)
      assert.matches("Connection: Upgrade", response)
      assert.matches("Sec%-WebSocket%-Accept:", response)
    end)

    it("should fail handshake with missing auth token", function()
      local expected_token = "550e8400-e29b-41d4-a716-446655440000"

      local success, response, headers = handshake.process_handshake(valid_request_base, expected_token)

      assert.is_false(success)
      assert.is_string(response)
      assert.is_nil(headers)
      assert.matches("HTTP/1.1 400 Bad Request", response)
      assert.matches("Missing authentication header", response)
    end)

    it("should fail handshake with invalid auth token", function()
      local expected_token = "550e8400-e29b-41d4-a716-446655440000"
      local wrong_token = "123e4567-e89b-12d3-a456-426614174000"

      local request_with_wrong_auth = table.concat({
        "GET /websocket HTTP/1.1",
        "Host: localhost:8080",
        "Upgrade: websocket",
        "Connection: upgrade",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13",
        "x-claude-code-ide-authorization: " .. wrong_token,
        "",
        "",
      }, "\r\n")

      local success, response, headers = handshake.process_handshake(request_with_wrong_auth, expected_token)

      assert.is_false(success)
      assert.is_string(response)
      assert.is_nil(headers)
      assert.matches("HTTP/1.1 400 Bad Request", response)
      assert.matches("Invalid authentication token", response)
    end)

    it("should complete handshake without auth when none required", function()
      local success, response, headers = handshake.process_handshake(valid_request_base, nil)

      assert.is_true(success)
      assert.is_string(response)
      assert.is_table(headers)
      assert.matches("HTTP/1.1 101 Switching Protocols", response)
    end)
  end)

  describe("authentication edge cases", function()
    it("should handle malformed auth header format", function()
      local expected_token = "550e8400-e29b-41d4-a716-446655440000"

      local request_with_malformed_auth = table.concat({
        "GET /websocket HTTP/1.1",
        "Host: localhost:8080",
        "Upgrade: websocket",
        "Connection: upgrade",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13",
        "x-claude-code-ide-authorization:not-a-uuid",
        "",
        "",
      }, "\r\n")

      local is_valid, error_msg = handshake.validate_upgrade_request(request_with_malformed_auth, expected_token)

      assert.is_false(is_valid)
      assert.equals("Invalid authentication token", error_msg)
    end)

    it("should handle multiple auth headers (uses last one)", function()
      local expected_token = "550e8400-e29b-41d4-a716-446655440000"
      local wrong_token = "123e4567-e89b-12d3-a456-426614174000"

      local request_with_multiple_auth = table.concat({
        "GET /websocket HTTP/1.1",
        "Host: localhost:8080",
        "Upgrade: websocket",
        "Connection: upgrade",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13",
        "x-claude-code-ide-authorization: " .. wrong_token,
        "x-claude-code-ide-authorization: " .. expected_token,
        "",
        "",
      }, "\r\n")

      local is_valid, headers = handshake.validate_upgrade_request(request_with_multiple_auth, expected_token)

      assert.is_true(is_valid)
      assert.is_table(headers)
      assert.equals(expected_token, headers["x-claude-code-ide-authorization"])
    end)

    it("should reject very long auth tokens", function()
      local expected_token = string.rep("a", 1000) -- Very long token

      local request_with_long_auth = table.concat({
        "GET /websocket HTTP/1.1",
        "Host: localhost:8080",
        "Upgrade: websocket",
        "Connection: upgrade",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13",
        "x-claude-code-ide-authorization: " .. expected_token,
        "",
        "",
      }, "\r\n")

      local is_valid, error_msg = handshake.validate_upgrade_request(request_with_long_auth, expected_token)

      assert.is_false(is_valid)
      assert.equals("Authentication token too long (max 500 characters)", error_msg)
    end)
  end)

  describe("constant_time_compare", function()
    local utils = require("claude_agents.server.utils")

    it("returns true for identical strings", function()
      assert.is_true(utils.constant_time_compare("abcdef0123456789", "abcdef0123456789"))
    end)

    it("returns false for strings that differ in content", function()
      assert.is_false(utils.constant_time_compare("abcdef0123456789", "abcdef012345678X"))
    end)

    it("returns false for strings of different length", function()
      assert.is_false(utils.constant_time_compare("abc", "abcd"))
    end)

    it("returns false for non-string inputs", function()
      assert.is_false(utils.constant_time_compare(nil, "abc"))
      assert.is_false(utils.constant_time_compare("abc", nil))
    end)

    it("returns true for two empty strings", function()
      assert.is_true(utils.constant_time_compare("", ""))
    end)
  end)
end)

describe("WebSocket handshake: a client let in without the token (OpenCode)", function()
  local handshake
  local TOKEN = "550e8400-e29b-41d4-a716-446655440000"

  local function request(extra)
    local lines = {
      "GET / HTTP/1.1",
      "Host: 127.0.0.1:8080",
      "Upgrade: websocket",
      "Connection: Upgrade",
      "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
      "Sec-WebSocket-Version: 13",
    }
    for _, line in ipairs(extra or {}) do
      lines[#lines + 1] = line
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = ""
    return table.concat(lines, "\r\n")
  end

  before_each(function()
    package.loaded["claude_agents.server.handshake"] = nil
    handshake = require("claude_agents.server.handshake")
  end)

  it("refuses a request with no token when nothing allows it", function()
    local valid, err = handshake.validate_upgrade_request(request(), TOKEN)
    assert.is_false(valid)
    assert_contains(err, "Missing authentication header")
  end)

  it("lets it in when the server is armed for it, and says so", function()
    local valid, headers, tokenless = handshake.validate_upgrade_request(request(), TOKEN, function()
      return true
    end)
    assert.is_true(valid)
    assert.is_table(headers)
    assert.is_true(tokenless)
  end)

  it("never lets a browser in that way: a request with an Origin header", function()
    local valid = handshake.validate_upgrade_request(request({ "Origin: http://evil.example" }), TOKEN, function()
      return true
    end)
    assert.is_false(valid)
  end)

  it("refuses when the server is not armed", function()
    local valid = handshake.validate_upgrade_request(request(), TOKEN, function()
      return false
    end)
    assert.is_false(valid)
  end)

  it("still checks a token that is sent, armed or not", function()
    local valid = handshake.validate_upgrade_request(
      request({ "x-claude-code-ide-authorization: wrong-token-value" }),
      TOKEN,
      function()
        return true
      end
    )
    assert.is_false(valid)
  end)

  it("reports the tokenless handshake through process_handshake", function()
    local success, response, _, tokenless = handshake.process_handshake(request(), TOKEN, function()
      return true
    end)
    assert.is_true(success)
    assert_contains(response, "101 Switching Protocols")
    assert.is_true(tokenless)
  end)
end)
