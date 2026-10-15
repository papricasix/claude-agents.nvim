-- luacheck: globals expect
require("tests.busted_setup")

describe("api_key", function()
  local api_key
  local ran
  local answer

  ---A stream that keeps what is written to it.
  local function sink()
    local s = { text = "" }
    function s:write(text)
      self.text = self.text .. text
    end
    return s
  end

  before_each(function()
    package.loaded["claude_agents.api_key"] = nil
    api_key = require("claude_agents.api_key")
    ran = {}
    answer = { code = 0, stdout = "", stderr = "" }
    api_key._run = function(argv)
      ran[#ran + 1] = argv
      return answer
    end
    api_key._executable = function()
      return true
    end
  end)

  describe("storing", function()
    it("names the one command per platform that asks for the key with hidden input", function()
      expect(api_key.store_command("default", "macos")).to_be(
        "security add-generic-password -U -s claudecode.nvim -a default -w"
      )
      expect(api_key.store_command("work", "linux")).to_be(
        "secret-tool store --label='claudecode.nvim API key (work)' service claudecode.nvim account work"
      )
      expect(api_key.store_command("default", "windows")).to_be(
        "cmdkey /generic:claudecode.nvim/default /user:claudecode.nvim /pass"
      )
    end)

    it("only takes entry names that are safe on a command line", function()
      expect(api_key.valid_entry("default")).to_be_true()
      expect(api_key.valid_entry("team.prod-2_x")).to_be_true()
      expect(api_key.valid_entry("two words")).to_be(false)
      expect(api_key.valid_entry("a;rm -rf")).to_be(false)
      expect(api_key.valid_entry("")).to_be(false)
    end)
  end)

  describe("shape", function()
    it("tells a usable key from one the CLI would refuse, without saying what it is", function()
      expect(api_key.shape("sk-ant-api03-abc_DEF-123")).to_be("ok")
      expect(api_key.shape("  sk-ant-api03-abc\n")).to_be("ok")
      expect(api_key.shape("plain-token")).to_be("unexpected")
      expect(api_key.shape("two words")).to_be("invalid")
      expect(api_key.shape("")).to_be("empty")
      expect(api_key.shape(nil)).to_be("empty")
    end)
  end)

  describe("reading", function()
    it("asks the macOS keychain for the entry's password", function()
      answer = { code = 0, stdout = "sk-ant-api03-key\n", stderr = "" }
      expect(api_key.read("default", "macos")).to_be("sk-ant-api03-key")
      assert.same({ "security", "find-generic-password", "-s", "claudecode.nvim", "-a", "default", "-w" }, ran[1])
    end)

    it("tells a missing macOS entry from a failure", function()
      answer = { code = 44, stdout = "", stderr = "security: The specified item could not be found in the keychain.\n" }
      local key, err, missing = api_key.read("default", "macos")
      expect(key).to_be(nil)
      expect(err).to_be(nil)
      expect(missing).to_be_true()
      answer = { code = 51, stdout = "", stderr = "User interaction is not allowed.\n" }
      local _, failure = api_key.read("default", "macos")
      expect(failure).to_be("User interaction is not allowed.")
    end)

    it("asks the Secret Service on Linux", function()
      answer = { code = 0, stdout = "sk-ant-api03-key", stderr = "" }
      expect(api_key.read("default", "linux")).to_be("sk-ant-api03-key")
      assert.same({ "secret-tool", "lookup", "service", "claudecode.nvim", "account", "default" }, ran[1])
      answer = { code = 1, stdout = "", stderr = "" }
      local _, _, missing = api_key.read("default", "linux")
      expect(missing).to_be_true()
    end)

    it("says what to install when secret-tool is missing", function()
      api_key._executable = function()
        return false
      end
      local _, err = api_key.read("default", "linux")
      expect(err:find("secret-tool is not installed", 1, true) ~= nil).to_be_true()
      expect(#ran).to_be(0)
    end)

    it("reads Credential Manager on Windows, as the UTF-16 cmdkey writes", function()
      local asked
      api_key._credread = function(target)
        asked = target
        return "s\0k\0-\0a\0"
      end
      expect(api_key.read("default", "windows")).to_be("sk-a")
      expect(asked).to_be("claudecode.nvim/default")
      api_key._credread = function()
        return nil, nil, true
      end
      local _, _, missing = api_key.read("default", "windows")
      expect(missing).to_be_true()
    end)

    it("takes a blob that is not UTF-16 as bytes", function()
      expect(api_key.decode_blob("sk-ant-x")).to_be("sk-ant-x")
      expect(api_key.decode_blob("ab")).to_be("ab")
      expect(api_key.decode_blob("")).to_be("")
    end)
  end)

  describe("the helper's command line", function()
    before_each(function()
      api_key.platform = function()
        return "macos"
      end
    end)

    it("prints the key and nothing else for get", function()
      answer = { code = 0, stdout = "sk-ant-api03-key\n", stderr = "" }
      local out, err = sink(), sink()
      expect(api_key.main({ "get", "default" }, out, err)).to_be(0)
      expect(out.text).to_be("sk-ant-api03-key\n")
      expect(err.text).to_be("")
    end)

    it("tells the CLI how to store a missing key, on stderr", function()
      answer = { code = 44, stdout = "", stderr = "could not be found" }
      local out, err = sink(), sink()
      expect(api_key.main({ "get", "default" }, out, err)).to_be(2)
      expect(out.text).to_be("")
      expect(err.text:find("security add-generic-password -U -s claudecode.nvim -a default -w", 1, true) ~= nil).to_be_true()
    end)

    it("describes the key for check without printing it", function()
      answer = { code = 0, stdout = "sk-ant-api03-secretvalue\n", stderr = "" }
      local out = sink()
      expect(api_key.main({ "check", "default" }, out, sink())).to_be(0)
      expect(out.text).to_be("found 24 ok\n")
      expect(out.text:find("secret", 1, true)).to_be(nil)
    end)

    it("says missing for check when nothing is stored", function()
      answer = { code = 44, stdout = "", stderr = "could not be found" }
      local out = sink()
      expect(api_key.main({ "check", "default" }, out, sink())).to_be(2)
      expect(out.text).to_be("missing\n")
    end)

    it("runs a profile's own command for check-cmd, the way the CLI would", function()
      answer = { code = 0, stdout = "sk-ant-api03-x\n", stderr = "" }
      local out = sink()
      expect(api_key.main({ "check-cmd", "op read op://x" }, out, sink())).to_be(0)
      assert.same({ "/bin/sh", "-c", "op read op://x" }, ran[1])
      expect(out.text).to_be("found 14 ok\n")
    end)

    it("refuses a malformed entry rather than putting it on a command line", function()
      local err = sink()
      expect(api_key.main({ "get", "a b" }, sink(), err)).to_be(1)
      expect(#ran).to_be(0)
      expect(err.text:find("usage", 1, true) ~= nil).to_be_true()
    end)
  end)
end)
