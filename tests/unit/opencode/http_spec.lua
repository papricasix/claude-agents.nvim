require("tests.busted_setup")

describe("opencode.http", function()
  local http

  before_each(function()
    package.loaded["claude_agents.opencode.http"] = nil
    http = require("claude_agents.opencode.http")
  end)

  describe("parse_url", function()
    it("splits host, port and any path prefix", function()
      local target = http.parse_url("http://127.0.0.1:49374")
      expect(target.host).to_be("127.0.0.1")
      expect(target.port).to_be(49374)
      expect(target.prefix).to_be("")
      expect(http.parse_url("http://localhost:4096/base/").prefix).to_be("/base")
    end)

    it("refuses anything that is not plain http", function()
      expect(http.parse_url("https://127.0.0.1:1")).to_be_nil()
      expect(http.parse_url("127.0.0.1:1")).to_be_nil()
      expect(http.parse_url(nil)).to_be_nil()
    end)
  end)

  it("builds a sorted, encoded query string", function()
    expect(http.query(nil)).to_be("")
    expect(http.query({})).to_be("")
    expect(http.query({ limit = 5, directory = "/a b/c" })).to_be("?directory=%2Fa%20b%2Fc&limit=5")
    expect(http.query({ ["location[directory]"] = "/p" })).to_be("?location%5Bdirectory%5D=%2Fp")
  end)

  it("writes a request with its body length and the connection closed", function()
    local bytes = http.build_request({
      method = "POST",
      host = "127.0.0.1",
      port = 80,
      path = "/api/session",
      headers = { ["Content-Type"] = "application/json" },
      body = "{}",
    })
    assert_contains(bytes, "POST /api/session HTTP/1.1\r\n")
    assert_contains(bytes, "Connection: close\r\n")
    assert_contains(bytes, "Content-Length: 2\r\n")
    expect(bytes:sub(-6)).to_be("\r\n\r\n{}")
  end)

  it("sends an empty table as an empty JSON object", function()
    local body, content_type = http.encode_body({})
    expect(body).to_be("{}")
    expect(content_type).to_be("application/json")
    expect(http.encode_body(nil)).to_be_nil()
  end)

  it("reads a status line and lower-cases header names", function()
    local status, headers = http.parse_head("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nX-Thing: a: b")
    expect(status).to_be(204)
    expect(headers["content-length"]).to_be("0")
    expect(headers["x-thing"]).to_be("a: b")
  end)

  describe("dechunker", function()
    it("decodes a body split anywhere, including inside a chunk and its CRLF", function()
      local feed = http.dechunker()
      local raw = "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
      local out, finished = {}, false
      for i = 1, #raw do
        local piece, done, err = feed(raw:sub(i, i))
        assert.is_nil(err)
        out[#out + 1] = piece
        finished = finished or done
      end
      expect(table.concat(out)).to_be("hello world")
      expect(finished).to_be_true()
    end)

    it("reports a malformed size line", function()
      local _, _, err = http.dechunker()("zz\r\n")
      expect(err).to_be("bad chunk size")
    end)
  end)

  describe("sse_parser", function()
    it("hands over each event's data and skips comments", function()
      local events = {}
      local feed = http.sse_parser(function(event)
        events[#events + 1] = event
      end)
      feed(': heartbeat\n\ndata: {"type":"a"}\n\nevent: x\nid: 7\ndata: one\r\ndata: two\n')
      feed("\n")
      expect(#events).to_be(2)
      expect(events[1].data).to_be('{"type":"a"}')
      expect(events[2].event).to_be("x")
      expect(events[2].id).to_be("7")
      expect(events[2].data).to_be("one\ntwo")
    end)

    it("waits for a line that arrives in pieces", function()
      local events = {}
      local feed = http.sse_parser(function(event)
        events[#events + 1] = event
      end)
      feed("da")
      feed("ta: hel")
      expect(#events).to_be(0)
      feed("lo\n\n")
      expect(events[1].data).to_be("hello")
    end)
  end)

  it("answers nil for a body that is not JSON", function()
    expect(http.decode("")).to_be_nil()
    expect(http.decode(nil)).to_be_nil()
  end)
end)
