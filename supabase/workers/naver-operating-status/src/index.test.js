import test from "node:test"
import assert from "node:assert/strict"
import { request as httpRequest } from "node:http"
import { chromium } from "playwright"
import { createHttpServer, extractNaverPlaceId, isPreOpenCheckWindow, nextCheckAt, normalizeStatus, parseLimit, processShop } from "./index.js"

test("extractNaverPlaceId reads a place id from Naver Map URLs", () => {
  assert.equal(extractNaverPlaceId("https://map.naver.com/p/entry/place/2017341952"), "2017341952")
  assert.equal(extractNaverPlaceId("not-a-url"), null)
})

test("normalizeStatus returns the last non-blank status", () => {
  assert.equal(normalizeStatus(["", "오늘 휴무", ""]), "오늘 휴무")
  assert.equal(normalizeStatus([]), null)
})

test("parseLimit bounds cron batches", () => {
  assert.equal(parseLimit(undefined), 10)
  assert.equal(parseLimit("3"), 3)
  assert.equal(parseLimit("100"), 50)
})

const weekly = Object.fromEntries([
  ["mon", { closed: false, open: "11:30", close: "21:00", close_next_day: false, label: null }],
  ["tue", { closed: true, open: null, close: null, close_next_day: false, label: "정기휴무" }],
  ["wed", { closed: false, open: "11:30", close: "21:00", close_next_day: false, label: null }],
  ["thu", { closed: false, open: "11:30", close: "21:00", close_next_day: false, label: null }],
  ["fri", { closed: false, open: "11:30", close: "21:00", close_next_day: false, label: null }],
  ["sat", { closed: false, open: "11:30", close: "21:00", close_next_day: false, label: null }],
  ["sun", { closed: false, open: "11:30", close: "21:00", close_next_day: false, label: null }],
])

test("nextCheckAt keeps the 08:00 pre-open check and opening check", () => {
  const beforeEight = nextCheckAt({ now: new Date("2026-08-25T22:00:00.000Z"), weekly })
  assert.equal(beforeEight.reason, "pre_open")
  assert.equal(beforeEight.at.toISOString(), "2026-08-25T23:00:00.000Z")

  const morning = nextCheckAt({ now: new Date("2026-08-26T00:00:00.000Z"), weekly })
  assert.equal(isPreOpenCheckWindow({ now: new Date("2026-08-25T23:00:00.000Z"), weekly }), true)
  assert.equal(isPreOpenCheckWindow({ now: new Date("2026-08-26T01:00:00.000Z"), weekly }), true)
  assert.equal(morning.reason, "opening_soon")
  assert.equal(morning.at.toISOString(), "2026-08-26T02:00:00.000Z")
})

test("nextCheckAt skips closed days until the next day's 08:00 pre-open check", () => {
  const result = nextCheckAt({ now: new Date("2026-08-25T03:00:00.000Z"), weekly })
  assert.equal(result.reason, "pre_open")
  assert.equal(result.at.toISOString(), "2026-08-25T23:00:00.000Z")
})

test("nextCheckAt schedules the break end and normal interval", () => {
  const duringBreak = nextCheckAt({
    now: new Date("2026-08-26T06:30:00.000Z"),
    weekly,
    breakTimes: { wed: [{ start: "15:00", end: "17:00" }] },
  })
  assert.equal(duringBreak.reason, "break")
  assert.equal(duringBreak.at.toISOString(), "2026-08-26T08:00:00.000Z")

  const open = nextCheckAt({ now: new Date("2026-08-26T03:00:00.000Z"), weekly })
  assert.equal(open.reason, "open")
  assert.equal(open.at.toISOString(), "2026-08-26T04:00:00.000Z")
})

const config = { supabaseUrl: "https://example.invalid", serviceRoleKey: "test-key" }
const shop = {
  id: "11111111-1111-4111-8111-111111111111",
  name: "Test shop",
  naver_place_url: "https://map.naver.com/p/entry/place/12345",
  business_hours_weekly: weekly,
  check_interval_minutes: 15,
  check_reason: "volatile",
  consecutive_failures: 2,
}

test("processShop stores observed status without the removed RPC and returns to the normal interval", async (t) => {
  t.mock.timers.enable({ apis: ["Date"], now: new Date("2026-08-26T03:00:00.000Z") })
  const statusLocator = {
    first() { return this },
    async waitFor() {},
    async allTextContents() { return ["오늘 휴무"] },
  }
  let browserClosed = false
  t.mock.method(chromium, "launch", async () => ({
    async newPage() {
      return {
        setDefaultTimeout() {},
        async goto() {},
        frameLocator() {
          return {
            locator(selector) {
              if (selector === "h1") return { first() { return { async textContent() { return "Test shop" } } } }
              return statusLocator
            },
          }
        },
        async close() {},
      }
    },
    async close() { browserClosed = true },
  }))
  const requests = []
  t.mock.method(globalThis, "fetch", async (url, options) => {
    requests.push({ url, method: options.method, body: JSON.parse(options.body) })
    return new Response("[]", { status: 200 })
  })

  const result = await processShop(config, shop)

  assert.equal(result.status, "오늘 휴무", result.error)
  assert.equal(browserClosed, true)
  assert.equal(requests.length, 1)
  assert.equal(requests[0].url, "https://example.invalid/rest/v1/shop_operating_status?on_conflict=shop_id")
  assert.equal(requests[0].method, "POST")
  assert.deepEqual(requests[0].body, {
    shop_id: shop.id,
    naver_place_id: "12345",
    status: "오늘 휴무",
    source_url: shop.naver_place_url,
    checked_at: "2026-08-26T03:00:00.000Z",
    last_error: null,
    next_check_at: "2026-08-26T04:00:00.000Z",
    check_interval_minutes: 60,
    check_reason: "open",
    consecutive_failures: 0,
  })
})

test("processShop retains retry scheduling when Naver collection fails", async (t) => {
  t.mock.timers.enable({ apis: ["Date"], now: new Date("2026-08-26T03:00:00.000Z") })
  t.mock.method(chromium, "launch", async () => { throw new Error("Naver unavailable") })
  const requests = []
  t.mock.method(globalThis, "fetch", async (url, options) => {
    requests.push({ url, body: JSON.parse(options.body) })
    return new Response("[]", { status: 200 })
  })

  const result = await processShop(config, { ...shop, consecutive_failures: 0 })

  assert.equal(result.status, null)
  assert.equal(requests.length, 1)
  assert.equal(requests[0].body.last_error, "Naver unavailable")
  assert.equal(requests[0].body.check_reason, "retry")
  assert.equal(requests[0].body.check_interval_minutes, 15)
  assert.equal(requests[0].body.next_check_at, "2026-08-26T03:15:00.000Z")
  assert.equal(requests[0].body.consecutive_failures, 1)
})

test("HTTP 실행 요청은 인증과 본문을 검증한 뒤에만 작업을 시작한다", async (t) => {
  const previousEnv = Object.fromEntries(["SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY", "WORKER_TOKEN"]
    .map((key) => [key, process.env[key]]))
  process.env.SUPABASE_URL = "https://example.invalid"
  process.env.SUPABASE_SERVICE_ROLE_KEY = "test-service-key"
  process.env.WORKER_TOKEN = "test-worker-token"
  t.after(() => {
    for (const [key, value] of Object.entries(previousEnv)) {
      if (value === undefined) delete process.env[key]
      else process.env[key] = value
    }
  })

  const databaseRequests = []
  t.mock.method(globalThis, "fetch", async (url, options) => {
    databaseRequests.push({ url, body: JSON.parse(options.body) })
    return new Response("[]", { status: 200 })
  })
  const browserLaunch = t.mock.method(chromium, "launch", async () => {
    throw new Error("테스트 중 실제 수집을 시작하면 안 된다")
  })
  const server = createHttpServer()
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve))
  t.after(() => new Promise((resolve) => {
    server.close(resolve)
    server.closeAllConnections()
  }))
  const port = server.address().port
  const maxBodyBytes = 64 * 1024
  const oversized = "{}" + " ".repeat(maxBodyBytes - 1)
  const rejectedCases = [
    { name: "잘못된 토큰은 JSON 검사보다 먼저 401로 거절한다", body: "{", token: "wrong-token", status: 401, error: "Unauthorized" },
    { name: "토큰 없는 대용량 요청도 401로 거절한다", body: oversized, token: null, status: 401, error: "Unauthorized" },
    { name: "깨진 JSON은 400을 반환한다", body: "{", status: 400, error: "Invalid JSON" },
    ...["null", "[]", '"문자열"', "true", "123"].map((body) => ({
      name: `JSON 객체가 아닌 ${body}는 400을 반환한다`, body, status: 400, error: "Request body must be a JSON object",
    })),
    { name: "Content-Length가 있는 64 KiB 초과 본문은 413을 반환한다", body: oversized, status: 413, error: "Request body is too large" },
    { name: "chunked 요청도 누적 바이트가 초과하면 413을 반환한다", chunks: [Buffer.alloc(maxBodyBytes, " "), Buffer.from("{}")], status: 413, error: "Request body is too large" },
    { name: "본문 종료를 기다리지 않고 초과 시점에 413을 반환한다", chunks: [Buffer.alloc(maxBodyBytes + 1, " ")], finish: false, status: 413, error: "Request body is too large" },
    { name: "한글 본문 크기도 문자 수 대신 UTF-8 바이트로 제한한다", body: JSON.stringify({ text: "가".repeat(22000) }), status: 413, error: "Request body is too large" },
  ]
  for (const { name, status, error, ...request } of rejectedCases) {
    await t.test(name, async () => {
      const before = databaseRequests.length
      const result = await sendRunRequest(port, request)
      assert.equal(result.status, status)
      assert.deepEqual(result.body, { error })
      assert.equal(databaseRequests.length, before, "거절한 요청은 DB 호출을 시작하지 않아야 한다")
      assert.equal(browserLaunch.mock.callCount(), 0, "거절한 요청은 브라우저를 실행하지 않아야 한다")
      if (status === 413) assert.equal(result.headers.connection, "close")
    })
  }

  const utf8Json = Buffer.from(JSON.stringify({ limit: 1, text: "가".repeat(21800) }))
  const boundary = Buffer.concat([utf8Json, Buffer.alloc(maxBodyBytes - utf8Json.length, " ")])
  const acceptedCases = [
    { name: "거절 뒤에도 빈 본문을 정상 처리한다", body: "", limit: 10 },
    { name: "빈 객체의 기본 처리량을 유지한다", body: "{}", limit: 10 },
    { name: "공백 본문의 기본 처리량을 유지한다", body: " \n\t", limit: 10 },
    { name: "정확히 64 KiB인 본문을 허용한다", body: boundary, limit: 1 },
    { name: "한글 바이트가 청크 사이에 나뉜 64 KiB 본문을 허용한다", chunks: [boundary.subarray(0, 20), boundary.subarray(20, 65535), boundary.subarray(65535)], limit: 1 },
    { name: "처리량의 기존 최대값 50을 유지한다", body: '{"limit":100}', limit: 50 },
  ]
  for (const { name, limit, ...request } of acceptedCases) {
    await t.test(name, async () => {
      const before = databaseRequests.length
      const result = await sendRunRequest(port, request)
      assert.equal(result.status, 200)
      assert.deepEqual(result.body, { requested: limit, selected: 0, succeeded: 0, failed: 0, results: [] })
      assert.equal(databaseRequests.length, before + 1)
      assert.deepEqual(databaseRequests.at(-1), {
        url: "https://example.invalid/rest/v1/rpc/claim_due_shop_operating_statuses",
        body: { batch_limit: limit },
      })
      assert.equal(browserLaunch.mock.callCount(), 0)
    })
  }
})

function sendRunRequest(port, { body = "", chunks, token = "test-worker-token", finish = true }) {
  return new Promise((resolve, reject) => {
    const headers = { "Content-Type": "application/json" }
    if (token !== null) headers.Authorization = `Bearer ${token}`
    if (!chunks) headers["Content-Length"] = Buffer.byteLength(body)
    const request = httpRequest({ host: "127.0.0.1", port, path: "/run", method: "POST", headers, agent: false }, (response) => {
      let responseBody = ""
      response.setEncoding("utf8")
      response.on("data", (chunk) => { responseBody += chunk })
      response.on("error", reject)
      response.on("end", () => {
        resolve({ status: response.statusCode, headers: response.headers, body: JSON.parse(responseBody) })
      })
    })
    request.on("error", reject)
    request.setTimeout(3000, () => request.destroy(new Error("HTTP 응답 시간 초과")))
    if (chunks) {
      for (const chunk of chunks) request.write(chunk)
      if (finish) request.end()
    } else {
      request.end(body)
    }
  })
}
