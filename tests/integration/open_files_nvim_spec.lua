require("tests.busted_setup")

-- `open_files` places windows, which the mocked `vim` cannot judge: this runs
-- tests/nvim/open_files_check.lua in a real headless Neovim.
describe("open_files in a real Neovim", function()
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

  it("places tabs, splits and floats as asked", function()
    if not runnable() then
      pending("needs Neovim 0.10+ on PATH (or NVIM_BIN)")
      return
    end
    local pipe = assert(io.popen(nvim .. ' --headless -u NONE -l tests/nvim/open_files_check.lua 2>&1; echo "exit=$?"'))
    local out = pipe:read("*a") or ""
    pipe:close()
    assert.is_truthy(out:find("exit=0", 1, true), out)
    assert.is_truthy(out:match("ok %d+ checks"), out)
  end)
end)
