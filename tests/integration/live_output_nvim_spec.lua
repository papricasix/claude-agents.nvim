require("tests.busted_setup")

-- The live output's shell functions and tap only mean anything in a real shell
-- talking to a real Neovim: this runs tests/nvim/live_output_check.lua.
describe("agents live output in a real Neovim", function()
  local nvim = os.getenv("NVIM_BIN") or "nvim"

  local function runnable()
    local probe = io.popen(nvim .. " --version 2>/dev/null")
    if not probe then
      return false
    end
    local out = probe:read("*a") or ""
    probe:close()
    return out:find("NVIM v0%.1[0-9]") ~= nil or out:find("NVIM v[1-9]") ~= nil
  end

  it("passes a piped command's output through unchanged and reports its last lines", function()
    if not runnable() then
      pending("needs Neovim 0.10+ on PATH (or NVIM_BIN)")
      return
    end
    local pipe =
      assert(io.popen(nvim .. ' --headless -u NONE -l tests/nvim/live_output_check.lua 2>&1; echo "exit=$?"'))
    local out = pipe:read("*a") or ""
    pipe:close()
    assert.is_truthy(out:find("exit=0", 1, true), out)
    assert.is_truthy(out:match("ok %d+ checks"), out)
  end)
end)
