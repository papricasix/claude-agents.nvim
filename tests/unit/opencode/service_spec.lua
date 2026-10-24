require("tests.busted_setup")

describe("opencode.service", function()
  local service
  local real_decode
  local files, alive, spawned, answer
  -- What `opencode service get disabled` answers: its result table.
  local disabled_res
  local STANDARD, ELSEWHERE

  local function register(dir, url)
    files[dir .. "/service.json"] = ('{"url":"%s","password":"pw","pid":1,"version":"2.0.30"}'):format(url)
  end

  local function find()
    local got_err, got_conn
    service.find(function(err, conn)
      got_err, got_conn = err, conn
    end)
    return got_err, got_conn
  end

  ---The commands run, as strings.
  local function commands()
    local out = {}
    for _, argv in ipairs(spawned) do
      out[#out + 1] = table.concat(argv, " ")
    end
    return out
  end

  before_each(function()
    real_decode = vim.json.decode
    vim.json.decode = _G.json_decode
    package.loaded["claude_agents.opencode"] = {
      cmd_argv = function()
        return { "opencode" }
      end,
      config = function()
        return { service_timeout_ms = 1000 }
      end,
    }
    package.loaded["claude_agents.opencode.service"] = nil
    service = require("claude_agents.opencode.service")
    STANDARD = service.standard_state_dir()
    ELSEWHERE = "/srv/state/opencode"
    files, alive, spawned = {}, {}, {}
    answer = STANDARD
    disabled_res = { code = 0, stdout = "false\n" }

    service._read_file = function(path)
      return files[path]
    end
    service._http = {
      request = function(opts, cb)
        if alive[opts.url] then
          cb(nil, { status = 200 })
        else
          cb("connection refused", nil)
        end
      end,
    }
    service._system = function(argv, _, on_exit)
      spawned[#spawned + 1] = argv
      local res = { code = 0, stdout = argv[2] == "debug" and (answer .. "\n") or "" }
      if argv[2] == "service" and argv[3] == "get" then
        res = disabled_res
      end
      if on_exit then
        on_exit(res)
        return {}
      end
      return {
        wait = function()
          return res
        end,
      }
    end
    service._defer = function(fn)
      fn()
    end
  end)

  after_each(function()
    vim.json.decode = real_decode
    service._reset()
    package.loaded["claude_agents.opencode"] = nil
    package.loaded["claude_agents.opencode.service"] = nil
  end)

  it("connects to a live registration at the standard place without running anything", function()
    register(STANDARD, "http://127.0.0.1:4096")
    alive["http://127.0.0.1:4096"] = true

    local err, conn = find()

    expect(err).to_be_nil()
    expect(conn.url).to_be("http://127.0.0.1:4096")
    expect(#spawned).to_be(0)
    service.invalidate()
    find()
    expect(service.state_dir()).to_be(STANDARD)
    expect(#spawned).to_be(0)
  end)

  it("asks OpenCode where its state is when nothing is registered at the standard place", function()
    answer = ELSEWHERE
    register(ELSEWHERE, "http://127.0.0.1:5000")
    alive["http://127.0.0.1:5000"] = true

    local err, conn = find()

    expect(err).to_be_nil()
    expect(conn.url).to_be("http://127.0.0.1:5000")
    assert.are.same({ "opencode debug paths state" }, commands())
    -- The answer is kept: asked once.
    service.invalidate()
    find()
    expect(service.state_dir()).to_be(ELSEWHERE)
    expect(#spawned).to_be(1)
  end)

  it("looks past a stale registration at the standard place to OpenCode's own", function()
    register(STANDARD, "http://127.0.0.1:4096")
    answer = ELSEWHERE
    register(ELSEWHERE, "http://127.0.0.1:5000")
    alive["http://127.0.0.1:5000"] = true

    local got
    service.ensure(function(err, conn)
      got = { err = err, conn = conn }
    end)

    expect(got.err).to_be_nil()
    expect(got.conn.url).to_be("http://127.0.0.1:5000")
    -- Found running, so not started a second time.
    assert.are.same({ "opencode debug paths state" }, commands())
  end)

  it("reports a dead registration where OpenCode keeps it as a service not running", function()
    register(STANDARD, "http://127.0.0.1:4096")

    local err, conn = find()

    expect(conn).to_be_nil()
    assert_contains(err, "not running")
    assert.are.same({ "opencode debug paths state" }, commands())
  end)

  it("starts the service where OpenCode keeps its state and waits for it there", function()
    answer = ELSEWHERE
    local real_system = service._system
    service._system = function(argv, opts, on_exit)
      if argv[2] == "service" then
        register(ELSEWHERE, "http://127.0.0.1:5000")
        alive["http://127.0.0.1:5000"] = true
      end
      return real_system(argv, opts, on_exit)
    end

    local got
    service.ensure(function(err, conn)
      got = { err = err, conn = conn }
    end)

    expect(got.err).to_be_nil()
    expect(got.conn.url).to_be("http://127.0.0.1:5000")
    assert.are.same(
      { "opencode debug paths state", "opencode service get disabled", "opencode service start" },
      commands()
    )
  end)

  describe("a service the user switched off", function()
    local function ensure()
      local got
      service.ensure(function(err, conn)
        got = { err = err, conn = conn }
      end)
      return got
    end

    it("is not started, and the answer says how to switch it back on", function()
      disabled_res = { code = 0, stdout = "true\n" }

      local got = ensure()

      expect(got.err).to_be(service.DISABLED_ERR)
      expect(got.conn).to_be_nil()
      assert_contains(got.err, "opencode service unset disabled")
      assert.are.same({ "opencode debug paths state", "opencode service get disabled" }, commands())
    end)

    it("is not asked about when the service already answers", function()
      register(STANDARD, "http://127.0.0.1:4096")
      alive["http://127.0.0.1:4096"] = true
      disabled_res = { code = 0, stdout = "true\n" }

      expect(ensure().err).to_be_nil()
      expect(#spawned).to_be(0)
    end)

    it("is started anyway when OpenCode cannot say (an older one without `service get`)", function()
      disabled_res = { code = 1, stdout = "", stderr = "unknown command" }

      ensure()

      expect(commands()[#commands()]).to_be("opencode service start")
    end)

    it("is read the same way when waited for", function()
      expect(service.disabled_sync(1000)).to_be(false)
      disabled_res = { code = 0, stdout = "true\n" }
      expect(service.disabled_sync(1000)).to_be(true)
      disabled_res = { code = 1, stdout = "" }
      expect(service.disabled_sync(1000)).to_be_nil()
    end)
  end)

  it("answers state_dir from OpenCode, then from memory", function()
    answer = ELSEWHERE
    expect(service.state_dir()).to_be(ELSEWHERE)
    expect(service.state_dir()).to_be(ELSEWHERE)
    expect(#spawned).to_be(1)
  end)

  it("falls back to the standard place when OpenCode cannot be asked", function()
    service._system = function(argv, _, on_exit)
      spawned[#spawned + 1] = argv
      on_exit({ code = 1, stdout = "", stderr = "not found" })
      return {}
    end

    local err = find()

    assert_contains(err, STANDARD .. "/service.json")
    expect(service.state_dir()).to_be(STANDARD)
    expect(#spawned).to_be(1)
  end)
end)
