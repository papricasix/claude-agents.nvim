-- luacheck: globals expect
require("tests.busted_setup")

describe("opencode dirs", function()
  local dirs
  local files
  local real_decode
  local real_realpath

  ---An in-memory filesystem standing in for the store's.
  local function fake_io()
    files = {}
    return {
      read = function(path)
        return files[path]
      end,
      write = function(path, data)
        files[path] = data
        return true
      end,
      stat = function(path)
        return files[path] and ("%d:%s"):format(#files[path], files[path]) or nil
      end,
    }
  end

  ---What the store holds on disk.
  local function on_disk()
    local data = files[dirs.store_path()]
    return data and _G.json_decode(data) or nil
  end

  before_each(function()
    real_decode = vim.json.decode
    vim.json.decode = _G.json_decode
    real_realpath = vim.loop.fs_realpath
    package.loaded["claude_agents.opencode.dirs"] = nil
    dirs = require("claude_agents.opencode.dirs")
    dirs._io = fake_io()
  end)

  after_each(function()
    vim.json.decode = real_decode
    vim.loop.fs_realpath = real_realpath
  end)

  it("records a directory and finds it again, from the same Neovim and a fresh one", function()
    dirs.mark("/proj")
    expect(dirs.marked("/proj")).to_be_true()
    expect(on_disk().version).to_be(1)
    expect(type(on_disk().dirs["/proj"].at)).to_be("number")

    local io = dirs._io
    dirs._reset()
    dirs._io = io
    expect(dirs.marked("/proj")).to_be_true()
  end)

  it("counts a directory with a recorded directory inside it, never a sibling or a parent's sibling", function()
    dirs.mark("/repo/.claude/worktrees/wt")
    expect(dirs.marked("/repo")).to_be_true()
    expect(dirs.marked("/repo/.claude/worktrees/wt")).to_be_true()
    expect(dirs.marked("/repo/.claude/worktrees/wt/lua")).to_be_false()
    expect(dirs.marked("/repo-other")).to_be_false()
    expect(dirs.marked("/re")).to_be_false()
  end)

  it("treats a root as covering everything recorded under it", function()
    dirs.mark("/proj")
    expect(dirs.marked("/")).to_be_true()
  end)

  it("matches two spellings of one directory, as OpenCode's processes see it", function()
    vim.loop.fs_realpath = function(path)
      return (path:gsub("^/var/", "/private/var/"))
    end
    dirs.mark("/var/folders/proj")
    expect(dirs.marked("/private/var/folders/proj")).to_be_true()
    expect(on_disk().dirs["/private/var/folders/proj"]).to_be_truthy()
  end)

  it("ignores what is not a directory", function()
    dirs.mark(nil)
    dirs.mark("")
    expect(files[dirs.store_path()]).to_be_nil()
    expect(dirs.marked(nil)).to_be_false()
    expect(dirs.marked("")).to_be_false()
  end)

  it("forgets a directory and everything recorded inside it, and nothing beside it", function()
    dirs.mark("/repo")
    dirs.mark("/repo/.claude/worktrees/wt")
    dirs.mark("/repo-other")
    dirs.forget("/repo")
    expect(dirs.marked("/repo")).to_be_false()
    expect(dirs.marked("/repo-other")).to_be_true()
    expect(on_disk().dirs["/repo/.claude/worktrees/wt"]).to_be_nil()
    expect(on_disk().dirs["/repo-other"]).to_be_truthy()
  end)

  it("forgets only the directory itself when asked to, keeping what is inside it", function()
    dirs.mark("/repo")
    dirs.mark("/repo/sub")
    dirs.forget("/repo", { exact = true })
    expect(on_disk().dirs["/repo"]).to_be_nil()
    expect(on_disk().dirs["/repo/sub"]).to_be_truthy()
    expect(dirs.marked("/repo")).to_be_true()
  end)

  it("writes nothing to forget a directory it never recorded", function()
    dirs.mark("/proj")
    local before = files[dirs.store_path()]
    local writes = 0
    local write = dirs._io.write
    dirs._io.write = function(...)
      writes = writes + 1
      return write(...)
    end
    dirs.forget("/elsewhere")
    expect(writes).to_be(0)
    expect(files[dirs.store_path()]).to_be(before)
  end)

  it("keeps what another Neovim recorded when it records its own", function()
    dirs.mark("/mine")
    -- Another Neovim writes the file since.
    files[dirs.store_path()] = vim.json.encode({
      version = 1,
      dirs = { ["/mine"] = { at = 1 }, ["/theirs"] = { at = 2 } },
    })
    dirs.mark("/third")
    local stored = on_disk().dirs
    expect(stored["/mine"]).to_be_truthy()
    expect(stored["/theirs"]).to_be_truthy()
    expect(stored["/third"]).to_be_truthy()
  end)

  it("takes in another Neovim's record on refresh, and reads nothing when the file did not move", function()
    expect(dirs.marked("/theirs")).to_be_false()
    files[dirs.store_path()] = vim.json.encode({ version = 1, dirs = { ["/theirs"] = { at = 2 } } })
    expect(dirs.marked("/theirs")).to_be_false()
    expect(dirs.refresh()).to_be_true()
    expect(dirs.marked("/theirs")).to_be_true()

    local reads = 0
    local read = dirs._io.read
    dirs._io.read = function(...)
      reads = reads + 1
      return read(...)
    end
    expect(dirs.refresh()).to_be_false()
    expect(reads).to_be(0)
  end)

  it("reads a corrupt or foreign file as empty, and replaces it on the next record", function()
    files[dirs.store_path()] = "{not json"
    expect(dirs.marked("/proj")).to_be_false()
    files[dirs.store_path()] = vim.json.encode({ version = 99, dirs = { ["/proj"] = { at = 1 } } })
    expect(dirs.refresh()).to_be_true()
    expect(dirs.marked("/proj")).to_be_false()
    dirs.mark("/new")
    expect(on_disk().version).to_be(1)
    expect(on_disk().dirs["/proj"]).to_be_nil()
    expect(on_disk().dirs["/new"]).to_be_truthy()
  end)

  it("changes nothing when the file exists but cannot be read", function()
    dirs.mark("/proj")
    local before = files[dirs.store_path()]
    dirs._io.read = function()
      return nil
    end
    dirs.mark("/other")
    expect(files[dirs.store_path()]).to_be(before)
    expect(dirs.marked("/proj")).to_be_true()
  end)
end)
